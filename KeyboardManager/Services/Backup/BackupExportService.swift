import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

struct BackupExportResult: Equatable, Sendable {
    var destinationURL: URL
    var byteCount: Int64
    var counts: InventoryCounts
    var transcodedHEICPhotoCount: Int
}

enum BackupExportError: LocalizedError, Sendable {
    case invalidDestination
    case tooManyItems
    case invalidIdentifier(String)
    case missingPhoto(String)
    case unsafePhotoFileName(String)
    case photoTooLarge(String)
    case photoDataTooLarge
    case heicTranscodingFailed(String)
    case manifestTooLarge
    case archiveTooLarge
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            L10n.text("Das gewählte Backup-Ziel ist ungültig.")
        case .tooManyItems:
            L10n.text("Der Bestand überschreitet die vom Backupformat erlaubte Anzahl von Einträgen.")
        case let .invalidIdentifier(identifier):
            L10n.text(
                "Die interne ID „%@“ ist nicht mit dem V1-Backupformat kompatibel.",
                arguments: identifier
            )
        case let .missingPhoto(name):
            L10n.text("Die verwaltete Fotodatei „%@“ fehlt.", arguments: name)
        case let .unsafePhotoFileName(name):
            L10n.text("Der interne Fotodateiname „%@“ ist ungültig.", arguments: name)
        case let .photoTooLarge(name):
            L10n.text("„%@“ überschreitet das Backup-Limit von 30 MiB.", arguments: name)
        case .photoDataTooLarge:
            L10n.text("Die Fotodaten überschreiten das Backup-Limit von 500 MiB.")
        case let .heicTranscodingFailed(name):
            L10n.text(
                "Das HEIC-Foto „%@“ konnte nicht kompatibel als JPEG exportiert werden.",
                arguments: name
            )
        case .manifestTooLarge:
            L10n.text("Die Bestandsdaten überschreiten das Manifest-Limit von 10 MiB.")
        case .archiveTooLarge:
            L10n.text("Das fertige ZIP überschreitet das Limit von 500 MiB.")
        case let .validationFailed(message):
            L10n.text(
                "Das erzeugte Backup hat die Kontrollprüfung nicht bestanden: %@",
                arguments: message
            )
        }
    }
}

actor BackupExportService {
    static let defaultFileName = "keyboard-manager-backup.zip"

    private static let maximumItemsPerKind = 10_000
    private static let maximumPhotos = 50_000
    private static let maximumPhotoBytes = 30 * 1_024 * 1_024
    private static let maximumPhotoTotalBytes = 500 * 1_024 * 1_024
    private static let maximumManifestBytes = 10 * 1_024 * 1_024
    private static let maximumArchiveBytes: Int64 = 500 * 1_024 * 1_024
    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )

    private let layout: MigrationStorageLayout
    private let fileManager: FileManager

    init(
        layout: MigrationStorageLayout = .default,
        fileManager: FileManager = .default
    ) {
        self.layout = layout
        self.fileManager = fileManager
    }

    func export(
        snapshot: InventorySnapshot,
        to destinationURL: URL,
        exportedAt: Date = .now,
        appVersion: String
    ) async throws -> BackupExportResult {
        let destinationURL = destinationURL.standardizedFileURL
        guard destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == "zip",
              !destinationURL.lastPathComponent.isEmpty else {
            throw BackupExportError.invalidDestination
        }
        try validateCounts(snapshot.counts)
        try validateIdentifiers(in: snapshot)

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let partialURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).partial-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: partialURL) }

        let archive = try Archive(url: partialURL, accessMode: .create)
        let stableDate = zipCompatibleDate(exportedAt)
        let photos = try preparePhotos(snapshot.photos)
        var photoByteCount = 0
        var transcodedHEICPhotoCount = 0
        var exportPhotos: [V1ExportPhoto] = []

        for prepared in photos {
            photoByteCount += prepared.data.count
            guard prepared.data.count <= Self.maximumPhotoBytes else {
                throw BackupExportError.photoTooLarge(prepared.record.originalName)
            }
            guard photoByteCount <= Self.maximumPhotoTotalBytes else {
                throw BackupExportError.photoDataTooLarge
            }
            if prepared.wasTranscodedFromHEIC {
                transcodedHEICPhotoCount += 1
            }

            try add(
                prepared.data,
                at: prepared.archivePath,
                modificationDate: stableDate,
                to: archive
            )
            exportPhotos.append(V1ExportPhoto(
                id: prepared.record.id,
                boardId: prepared.record.owner.type == .board ? prepared.record.owner.id : nil,
                ownerType: prepared.record.owner.type.rawValue,
                ownerId: prepared.record.owner.id,
                name: prepared.record.originalName,
                type: prepared.exportMIME.rawValue,
                width: prepared.record.pixelWidth,
                height: prepared.record.pixelHeight,
                addedAt: milliseconds(prepared.record.addedAt),
                file: prepared.archivePath
            ))
        }

        let manifest = makeManifest(
            snapshot: snapshot,
            photos: exportPhotos,
            exportedAt: exportedAt,
            appVersion: appVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        guard manifestData.count <= Self.maximumManifestBytes else {
            throw BackupExportError.manifestTooLarge
        }
        try add(manifestData, at: "manifest.json", modificationDate: stableDate, to: archive)

        let archiveSize = try fileSize(at: partialURL)
        guard archiveSize > 0, archiveSize <= Self.maximumArchiveBytes else {
            throw BackupExportError.archiveTooLarge
        }

        let validation: MigrationDryRunResult
        do {
            validation = try await V1BackupReader().inspect(at: partialURL)
        } catch {
            throw BackupExportError.validationFailed(error.localizedDescription)
        }
        guard validation.report.canImport,
              validation.report.counts == snapshot.counts else {
            throw BackupExportError.validationFailed(
                "Bestandszähler oder Beziehungen weichen nach dem Rücklesen ab."
            )
        }

        try installArchive(from: partialURL, at: destinationURL)
        return BackupExportResult(
            destinationURL: destinationURL,
            byteCount: archiveSize,
            counts: validation.report.counts,
            transcodedHEICPhotoCount: transcodedHEICPhotoCount
        )
    }

    private func validateCounts(_ counts: InventoryCounts) throws {
        guard counts.boards <= Self.maximumItemsPerKind,
              counts.keycapSets <= Self.maximumItemsPerKind,
              counts.artisanSets <= Self.maximumItemsPerKind,
              counts.switchSets <= Self.maximumItemsPerKind,
              counts.photos <= Self.maximumPhotos else {
            throw BackupExportError.tooManyItems
        }
    }

    private func validateIdentifiers(in snapshot: InventorySnapshot) throws {
        let identifiers = snapshot.boards.map(\.id)
            + snapshot.keycapSets.map(\.id)
            + snapshot.artisanSets.map(\.id)
            + snapshot.switchSets.map(\.id)
            + snapshot.photos.map(\.id)
        for identifier in identifiers {
            guard !identifier.isEmpty,
                  identifier.unicodeScalars.allSatisfy(Self.identifierCharacters.contains) else {
                throw BackupExportError.invalidIdentifier(identifier)
            }
        }
    }

    private func preparePhotos(_ records: [PhotoRecord]) throws -> [PreparedBackupPhoto] {
        try records.sorted { $0.id < $1.id }.map { record in
            guard let fileName = record.managedFileName else {
                throw BackupExportError.unsafePhotoFileName(record.relativeFileName)
            }
            let sourceURL = layout.currentPhotosDirectoryURL.appendingPathComponent(fileName)
            guard fileManager.isReadableFile(atPath: sourceURL.path) else {
                throw BackupExportError.missingPhoto(fileName)
            }
            let sourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            guard sourceData.count <= Self.maximumPhotoBytes else {
                throw BackupExportError.photoTooLarge(record.originalName)
            }

            if record.mimeType == .heic {
                let jpegData = try transcodeHEICToJPEG(sourceData, name: record.originalName)
                return PreparedBackupPhoto(
                    record: record,
                    data: jpegData,
                    exportMIME: .jpeg,
                    archivePath: "photos/\(record.id).jpg",
                    wasTranscodedFromHEIC: true
                )
            }
            return PreparedBackupPhoto(
                record: record,
                data: sourceData,
                exportMIME: record.mimeType,
                archivePath: "photos/\(record.id).\(record.mimeType.fileExtension)",
                wasTranscodedFromHEIC: false
            )
        }
    }

    private func transcodeHEICToJPEG(_ data: Data, name: String) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw BackupExportError.heicTranscodingFailed(name)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw BackupExportError.heicTranscodingFailed(name)
        }
        CGImageDestinationAddImageFromSource(
            destination,
            source,
            0,
            [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw BackupExportError.heicTranscodingFailed(name)
        }
        return output as Data
    }

    private func makeManifest(
        snapshot: InventorySnapshot,
        photos: [V1ExportPhoto],
        exportedAt: Date,
        appVersion: String
    ) -> V1ExportManifest {
        let installationsByBoard = Dictionary(grouping: snapshot.switchInstallations, by: \.boardID)
        let installationsBySwitch = Dictionary(grouping: snapshot.switchInstallations, by: \.switchSetID)

        let boards = snapshot.boards.sorted { $0.id < $1.id }.map { board in
            let installations = (installationsByBoard[board.id] ?? []).sorted {
                $0.switchSetID < $1.switchSetID
            }
            let switchIDs = installations.map(\.switchSetID)
            return V1ExportBoard(
                id: board.id,
                name: board.name,
                manufacturer: board.manufacturer,
                format: board.format,
                plate: board.plate,
                pcb: board.pcb,
                keycaps: board.legacyKeycapsName,
                keycapSetId: board.keycapSetID,
                stabs: board.stabilizers,
                switches: board.legacySwitchesName,
                switchSetId: switchIDs.first,
                switchSetIds: switchIDs,
                switchSetQuantities: Dictionary(
                    uniqueKeysWithValues: installations.map { ($0.switchSetID, $0.quantity) }
                ),
                remark: board.remark,
                photoIds: board.photoIDs,
                mainPhotoId: board.mainPhotoID,
                createdAt: milliseconds(board.createdAt),
                updatedAt: milliseconds(board.updatedAt)
            )
        }
        let keycapSets = snapshot.keycapSets.sorted { $0.id < $1.id }.map {
            V1ExportKeycapSet(
                id: $0.id,
                name: $0.name,
                manufacturer: $0.manufacturer,
                profile: $0.profile,
                material: $0.material,
                status: $0.status,
                kits: $0.kits,
                sourceUrl: $0.sourceURL,
                sourceShop: $0.sourceShop,
                mountedBoardId: $0.mountedBoardID,
                notes: $0.notes,
                photoIds: $0.photoIDs,
                mainPhotoId: $0.mainPhotoID,
                coverUrl: $0.coverURL,
                externalImageUrls: $0.externalImageURLs,
                trelloCardId: $0.trelloCardID,
                trelloListName: $0.trelloListName,
                createdAt: milliseconds($0.createdAt),
                updatedAt: milliseconds($0.updatedAt)
            )
        }
        let artisanSets = snapshot.artisanSets.sorted { $0.id < $1.id }.map {
            V1ExportArtisanSet(
                id: $0.id,
                name: $0.name,
                manufacturer: $0.manufacturer,
                profile: $0.profile,
                material: $0.material,
                status: $0.status,
                tags: $0.tags,
                sourceUrl: $0.sourceURL,
                sourceShop: $0.sourceShop,
                mountedBoardId: $0.mountedBoardID,
                notes: $0.notes,
                photoIds: $0.photoIDs,
                mainPhotoId: $0.mainPhotoID,
                coverUrl: $0.coverURL,
                externalImageUrls: $0.externalImageURLs,
                trelloCardId: $0.trelloCardID,
                trelloListName: $0.trelloListName,
                createdAt: milliseconds($0.createdAt),
                updatedAt: milliseconds($0.updatedAt)
            )
        }
        let switchSets = snapshot.switchSets.sorted { $0.id < $1.id }.map { switchSet in
            let installations = (installationsBySwitch[switchSet.id] ?? []).sorted {
                $0.boardID < $1.boardID
            }
            return V1ExportSwitchSet(
                id: switchSet.id,
                name: switchSet.name,
                switchType: switchSet.switchType,
                topHousingMaterial: switchSet.topHousingMaterial,
                bottomHousingMaterial: switchSet.bottomHousingMaterial,
                stemMaterial: switchSet.stemMaterial,
                springLength: switchSet.springLength,
                springType: switchSet.springType,
                preTravel: switchSet.preTravel,
                totalTravel: switchSet.totalTravel,
                operatingForce: switchSet.operatingForce,
                bottomOutForce: switchSet.bottomOutForce,
                pins: switchSet.pins.rawValue,
                ledDiffuser: switchSet.hasLEDDiffuser,
                factoryLubed: switchSet.isFactoryLubed,
                quantity: switchSet.quantity,
                mountedQuantity: installations.first?.quantity,
                mountedBoardId: installations.first?.boardID,
                installations: installations.map {
                    V1ExportSwitchInstallation(boardId: $0.boardID, quantity: $0.quantity)
                },
                importedBoardText: switchSet.importedBoardText,
                importedBoardAllocations: switchSet.importedBoardAllocations.map {
                    V1ExportImportedBoardAllocation(
                        board: $0.boardName,
                        quantity: $0.quantity,
                        inferred: $0.inferred
                    )
                },
                importSource: switchSet.importSource,
                importRow: switchSet.importRow,
                importKey: switchSet.importKey,
                importWarnings: switchSet.importWarnings,
                notes: switchSet.notes,
                photoIds: switchSet.photoIDs,
                mainPhotoId: switchSet.mainPhotoID,
                createdAt: milliseconds(switchSet.createdAt),
                updatedAt: milliseconds(switchSet.updatedAt)
            )
        }

        return V1ExportManifest(
            schemaVersion: 6,
            format: "keyboard-manager-zip",
            meta: V1ExportMetadata(
                version: appVersion,
                createdAt: milliseconds(snapshot.metadata.createdAt),
                updatedAt: milliseconds(snapshot.metadata.updatedAt),
                exportedAt: milliseconds(exportedAt),
                language: snapshot.metadata.preferredLanguage == "en" ? "en" : "de",
                note: "ZIP-Backup mit Manifest und Bilddateien."
            ),
            lists: snapshot.libraryValues.valuesByKey,
            gallery: V1ExportGallery(
                showFields: [
                    "manufacturer": true,
                    "format": true,
                    "switches": true,
                    "keycaps": false
                ]
            ),
            boards: boards,
            keycapSets: keycapSets,
            artisanSets: artisanSets,
            switchSets: switchSets,
            photos: photos
        )
    }

    private func add(
        _ data: Data,
        at path: String,
        modificationDate: Date,
        to archive: Archive
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            modificationDate: modificationDate,
            permissions: 0o644,
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private func installArchive(from partialURL: URL, at destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: partialURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: partialURL, to: destinationURL)
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func zipCompatibleDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 2) * 2)
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private struct PreparedBackupPhoto {
    var record: PhotoRecord
    var data: Data
    var exportMIME: PhotoMIMEType
    var archivePath: String
    var wasTranscodedFromHEIC: Bool
}

private struct V1ExportManifest: Encodable {
    var schemaVersion: Int
    var format: String
    var meta: V1ExportMetadata
    var lists: [String: [String]]
    var gallery: V1ExportGallery
    var boards: [V1ExportBoard]
    var keycapSets: [V1ExportKeycapSet]
    var artisanSets: [V1ExportArtisanSet]
    var switchSets: [V1ExportSwitchSet]
    var photos: [V1ExportPhoto]
}

private struct V1ExportMetadata: Encodable {
    var version: String
    var createdAt: Int64
    var updatedAt: Int64
    var exportedAt: Int64
    var language: String
    var note: String
}

private struct V1ExportGallery: Encodable {
    var showFields: [String: Bool]
}

private struct V1ExportBoard: Encodable {
    var id: String
    var name: String
    var manufacturer: String
    var format: String
    var plate: String
    var pcb: String
    var keycaps: String
    var keycapSetId: String?
    var stabs: String
    var switches: String
    var switchSetId: String?
    var switchSetIds: [String]
    var switchSetQuantities: [String: Int]
    var remark: String
    var photoIds: [String]
    var mainPhotoId: String?
    var createdAt: Int64
    var updatedAt: Int64
}

private struct V1ExportKeycapSet: Encodable {
    var id: String
    var name: String
    var manufacturer: String
    var profile: String
    var material: String
    var status: String
    var kits: [String]
    var sourceUrl: String
    var sourceShop: String
    var mountedBoardId: String?
    var notes: String
    var photoIds: [String]
    var mainPhotoId: String?
    var coverUrl: String
    var externalImageUrls: [String]
    var trelloCardId: String
    var trelloListName: String
    var createdAt: Int64
    var updatedAt: Int64
}

private struct V1ExportArtisanSet: Encodable {
    var id: String
    var name: String
    var manufacturer: String
    var profile: String
    var material: String
    var status: String
    var tags: [String]
    var sourceUrl: String
    var sourceShop: String
    var mountedBoardId: String?
    var notes: String
    var photoIds: [String]
    var mainPhotoId: String?
    var coverUrl: String
    var externalImageUrls: [String]
    var trelloCardId: String
    var trelloListName: String
    var createdAt: Int64
    var updatedAt: Int64
}

private struct V1ExportSwitchSet: Encodable {
    var id: String
    var name: String
    var switchType: String
    var topHousingMaterial: String
    var bottomHousingMaterial: String
    var stemMaterial: String
    var springLength: String
    var springType: String
    var preTravel: String
    var totalTravel: String
    var operatingForce: String
    var bottomOutForce: String
    var pins: String
    var ledDiffuser: Bool
    var factoryLubed: Bool
    var quantity: Int
    var mountedQuantity: Int?
    var mountedBoardId: String?
    var installations: [V1ExportSwitchInstallation]
    var importedBoardText: String
    var importedBoardAllocations: [V1ExportImportedBoardAllocation]
    var importSource: String
    var importRow: Int
    var importKey: String
    var importWarnings: [String]
    var notes: String
    var photoIds: [String]
    var mainPhotoId: String?
    var createdAt: Int64
    var updatedAt: Int64
}

private struct V1ExportSwitchInstallation: Encodable {
    var boardId: String
    var quantity: Int
}

private struct V1ExportImportedBoardAllocation: Encodable {
    var board: String
    var quantity: Int
    var inferred: Bool
}

private struct V1ExportPhoto: Encodable {
    var id: String
    var boardId: String?
    var ownerType: String
    var ownerId: String
    var name: String
    var type: String
    var width: Int?
    var height: Int?
    var addedAt: Int64
    var file: String
}
