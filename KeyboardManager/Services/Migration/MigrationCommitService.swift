import Foundation
import ZIPFoundation

enum MigrationCommitServiceError: LocalizedError, Sendable {
    case dryRunBlocked
    case sourceChanged
    case invalidPhotoPlan
    case photoExtraction(String)
    case verification(String)
    case unsafeCurrentDirectory
    case simulatedFailure

    var errorDescription: String? {
        switch self {
        case .dryRunBlocked:
            L10n.text("Der Import ist durch Fehler im Prüflauf blockiert.")
        case .sourceChanged:
            L10n.text("Die V1-Quelle hat sich seit dem Prüflauf verändert. Bitte erneut prüfen.")
        case .invalidPhotoPlan:
            L10n.text("Der interne Foto-Stagingplan ist ungültig.")
        case let .photoExtraction(message):
            L10n.text("Fotos konnten nicht sicher bereitgestellt werden: %@", arguments: message)
        case let .verification(message):
            L10n.text(
                "Der bereitgestellte V2-Bestand hat die Abschlussprüfung nicht bestanden: %@",
                arguments: message
            )
        case .unsafeCurrentDirectory:
            L10n.text("Der vorhandene V2-Datenordner ist kein reguläres Verzeichnis.")
        case .simulatedFailure:
            L10n.text("Simulierter Aktivierungsfehler.")
        }
    }
}

struct MigrationCommitService: Sendable {
    let layout: MigrationStorageLayout
    let failurePoint: MigrationCommitFailurePoint?
    let v1ProcessDetector: V1ProcessDetector

    init(
        layout: MigrationStorageLayout = .default,
        failurePoint: MigrationCommitFailurePoint? = nil,
        v1ProcessDetector: V1ProcessDetector = V1ProcessDetector()
    ) {
        self.layout = layout
        self.failurePoint = failurePoint
        self.v1ProcessDetector = v1ProcessDetector
    }

    func commit(
        backupURL: URL,
        expectedDryRun: MigrationDryRunResult
    ) async throws -> MigrationCommitResult {
        guard expectedDryRun.report.canImport else {
            throw MigrationCommitServiceError.dryRunBlocked
        }
        if expectedDryRun.report.sourceKind == .sqliteDirectory,
           await v1ProcessDetector.isV1Running() {
            throw V1SourceDiscoveryError.v1IsRunning
        }

        let migrationID = UUID().uuidString.lowercased()
        let startedAt = Date.now
        let stageDirectoryURL = layout.stagingRootURL
            .appendingPathComponent(migrationID, isDirectory: true)
        let stagedSourceURL = stageDirectoryURL.appendingPathComponent(
            expectedDryRun.report.sourceKind == .legacyJSON ? "Source.json" : "Source.zip"
        )
        let stagedCurrentURL = stageDirectoryURL.appendingPathComponent("Current", isDirectory: true)

        do {
            try await prepareStagedSource(
                sourceURL: backupURL,
                stageDirectoryURL: stageDirectoryURL,
                stagedSourceURL: stagedSourceURL,
                sourceKind: expectedDryRun.report.sourceKind
            )

            let stagedDryRun: MigrationDryRunResult
            let extractionArchiveURL: URL
            switch expectedDryRun.report.sourceKind {
            case .zipBackup:
                stagedDryRun = try await V1BackupReader().inspect(at: stagedSourceURL)
                extractionArchiveURL = stagedSourceURL
            case .legacyJSON:
                extractionArchiveURL = stageDirectoryURL.appendingPathComponent("Canonical.zip")
                stagedDryRun = try await V1LegacyJSONReader().prepareInspection(
                    at: stagedSourceURL,
                    canonicalArchiveURL: extractionArchiveURL
                )
            case .sqliteDirectory:
                extractionArchiveURL = stageDirectoryURL.appendingPathComponent("Canonical.zip")
                stagedDryRun = try await V1SQLiteSourceReader().prepareInspection(
                    at: backupURL,
                    canonicalArchiveURL: extractionArchiveURL
                )
            case .webStorageExport:
                throw V1BackupReaderError.unsupportedSource
            }
            guard stagedDryRun.report.sourceKind == expectedDryRun.report.sourceKind,
                  stagedDryRun.report.sourceSHA256 == expectedDryRun.report.sourceSHA256,
                  stagedDryRun.snapshot == expectedDryRun.snapshot,
                  stagedDryRun.photoPlans == expectedDryRun.photoPlans else {
                throw MigrationCommitServiceError.sourceChanged
            }
            if expectedDryRun.report.sourceKind == .sqliteDirectory,
               await v1ProcessDetector.isV1Running() {
                throw V1SourceDiscoveryError.v1IsRunning
            }

            let copiedPhotoByteCount = try await extractPhotos(
                from: extractionArchiveURL,
                plans: stagedDryRun.photoPlans,
                snapshot: stagedDryRun.snapshot,
                stagedCurrentURL: stagedCurrentURL
            )

            let stagedDatabaseURL = stagedCurrentURL.appendingPathComponent("inventory.sqlite")
            let stagedRepository = SQLiteInventoryRepository(databaseURL: stagedDatabaseURL)
            try await stagedRepository.saveSnapshot(stagedDryRun.snapshot)
            let reloadedSnapshot = try await stagedRepository.loadSnapshot()
            guard reloadedSnapshot == stagedDryRun.snapshot else {
                throw MigrationCommitServiceError.verification(
                    L10n.text("SQLite-Rückleseprobe weicht ab.")
                )
            }
            try await stagedRepository.verifyIntegrity()
            try await verifyStagedPhotos(
                plans: stagedDryRun.photoPlans,
                stagedCurrentURL: stagedCurrentURL
            )

            let replacedExistingData = try currentDirectoryExistsSafely()
            let backupDirectoryName = replacedExistingData ? "\(migrationID)-previous" : nil
            let completionReport = MigrationCompletionReport(
                migrationID: migrationID,
                sourceKind: expectedDryRun.report.sourceKind,
                sourceFileName: expectedDryRun.report.sourceFileName,
                sourceSHA256: expectedDryRun.report.sourceSHA256,
                sourceVersion: stagedDryRun.report.sourceVersion,
                sourceSchemaVersion: stagedDryRun.report.schemaVersion,
                startedAt: startedAt,
                completedAt: .now,
                counts: stagedDryRun.snapshot.counts,
                switchInstallationCount: stagedDryRun.snapshot.switchInstallations.count,
                copiedPhotoByteCount: copiedPhotoByteCount,
                warnings: stagedDryRun.report.issues.filter { $0.severity == .warning },
                replacedExistingV2Data: replacedExistingData,
                backupDirectoryName: backupDirectoryName,
                databaseIntegrityCheck: "ok"
            )

            try await writeCompletionReport(
                completionReport,
                to: stagedCurrentURL.appendingPathComponent("MigrationReport.json")
            )
            let backupURL = try await activate(
                stagedCurrentURL: stagedCurrentURL,
                stageDirectoryURL: stageDirectoryURL,
                backupDirectoryName: backupDirectoryName,
                migrationID: migrationID
            )

            return MigrationCommitResult(
                snapshot: stagedDryRun.snapshot,
                report: completionReport,
                reportURL: layout.currentDirectoryURL.appendingPathComponent("MigrationReport.json"),
                backupURL: backupURL
            )
        } catch {
            try? await removeOwnedStagingDirectory(stageDirectoryURL)
            throw error
        }
    }

    private func prepareStagedSource(
        sourceURL: URL,
        stageDirectoryURL: URL,
        stagedSourceURL: URL,
        sourceKind: MigrationSourceKind
    ) async throws {
        let stagingRootURL = layout.stagingRootURL
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: stageDirectoryURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try fileManager.createDirectory(at: stageDirectoryURL, withIntermediateDirectories: false)
            if sourceKind != .sqliteDirectory {
                try fileManager.copyItem(at: sourceURL, to: stagedSourceURL)
            }
        }.value
    }

    private func extractPhotos(
        from archiveURL: URL,
        plans: [MigrationPhotoPlan],
        snapshot: InventorySnapshot,
        stagedCurrentURL: URL
    ) async throws -> Int64 {
        try await Task.detached(priority: .userInitiated) {
            guard plans.count == snapshot.photos.count else {
                throw MigrationCommitServiceError.invalidPhotoPlan
            }
            let recordsByID = Dictionary(uniqueKeysWithValues: snapshot.photos.map { ($0.id, $0) })
            let archive = try Archive(url: archiveURL, accessMode: .read)
            let fileManager = FileManager.default
            let photosURL = stagedCurrentURL.appendingPathComponent("Photos", isDirectory: true)
            try fileManager.createDirectory(at: photosURL, withIntermediateDirectories: true)
            var copiedBytes: Int64 = 0

            for plan in plans {
                guard let record = recordsByID[plan.photoID],
                      record.managedFileName == plan.destinationRelativeFileName,
                      Self.isSafePhotoDestination(plan.destinationRelativeFileName, photoID: plan.photoID),
                      let entry = archive[plan.sourceEntryPath],
                      entry.type == .file,
                      Int64(entry.uncompressedSize) == plan.uncompressedByteCount,
                      entry.checksum == plan.checksum else {
                    throw MigrationCommitServiceError.invalidPhotoPlan
                }

                let destinationURL = photosURL
                    .appendingPathComponent(plan.destinationRelativeFileName)
                    .standardizedFileURL
                guard destinationURL.path.hasPrefix(photosURL.standardizedFileURL.path + "/") else {
                    throw MigrationCommitServiceError.invalidPhotoPlan
                }

                do {
                    let checksum = try archive.extract(entry, to: destinationURL, skipCRC32: false)
                    guard checksum == plan.checksum else {
                        throw MigrationCommitServiceError.photoExtraction(
                            "CRC-Prüfung fehlgeschlagen: \(plan.sourceEntryPath)"
                        )
                    }
                } catch let error as MigrationCommitServiceError {
                    throw error
                } catch {
                    throw MigrationCommitServiceError.photoExtraction(error.localizedDescription)
                }
                copiedBytes += plan.uncompressedByteCount
            }
            return copiedBytes
        }.value
    }

    private func verifyStagedPhotos(
        plans: [MigrationPhotoPlan],
        stagedCurrentURL: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            for plan in plans {
                let url = stagedCurrentURL
                    .appendingPathComponent("Photos", isDirectory: true)
                    .appendingPathComponent(plan.destinationRelativeFileName)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true,
                      Int64(values.fileSize ?? -1) == plan.uncompressedByteCount else {
                    throw MigrationCommitServiceError.verification(
                        "Fotodatei fehlt oder besitzt eine falsche Größe."
                    )
                }
            }
        }.value
    }

    private func currentDirectoryExistsSafely() throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: layout.currentDirectoryURL.path) else {
            return false
        }
        let values = try layout.currentDirectoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MigrationCommitServiceError.unsafeCurrentDirectory
        }
        return true
    }

    private func writeCompletionReport(
        _ report: MigrationCompletionReport,
        to url: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        }.value
    }

    private func activate(
        stagedCurrentURL: URL,
        stageDirectoryURL: URL,
        backupDirectoryName: String?,
        migrationID: String
    ) async throws -> URL? {
        let layout = layout
        let failurePoint = failurePoint
        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: layout.rootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: layout.backupsRootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: layout.reportsRootURL, withIntermediateDirectories: true)

            let backupURL = backupDirectoryName.map {
                layout.backupsRootURL.appendingPathComponent($0, isDirectory: true)
            }
            var movedPreviousData = false
            var activatedNewData = false

            do {
                if let backupURL {
                    guard !fileManager.fileExists(atPath: backupURL.path) else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    try fileManager.moveItem(at: layout.currentDirectoryURL, to: backupURL)
                    movedPreviousData = true
                }

                if failurePoint == .afterBackupMove {
                    throw MigrationCommitServiceError.simulatedFailure
                }

                try fileManager.moveItem(at: stagedCurrentURL, to: layout.currentDirectoryURL)
                activatedNewData = true

                let reportSourceURL = layout.currentDirectoryURL
                    .appendingPathComponent("MigrationReport.json")
                let archivedReportURL = layout.reportsRootURL
                    .appendingPathComponent("\(migrationID).json")
                try fileManager.copyItem(at: reportSourceURL, to: archivedReportURL)

                try fileManager.removeItem(at: stageDirectoryURL)
                return backupURL
            } catch {
                if activatedNewData,
                   fileManager.fileExists(atPath: layout.currentDirectoryURL.path) {
                    try? fileManager.removeItem(at: layout.currentDirectoryURL)
                }
                if movedPreviousData, let backupURL,
                   fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.moveItem(at: backupURL, to: layout.currentDirectoryURL)
                }
                throw error
            }
        }.value
    }

    private func removeOwnedStagingDirectory(_ url: URL) async throws {
        let stagingRootURL = layout.stagingRootURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == stagingRootURL else {
            throw MigrationCommitServiceError.invalidPhotoPlan
        }
        try await Task.detached(priority: .utility) {
            if FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.removeItem(at: candidate)
            }
        }.value
    }

    private static func isSafePhotoDestination(_ path: String, photoID: String) -> Bool {
        let filename = path
        guard URL(fileURLWithPath: filename).lastPathComponent == filename,
              filename.hasPrefix("\(photoID).") else { return false }
        let suffix = filename.dropFirst(photoID.count + 1).lowercased()
        return ["jpg", "png", "webp", "gif", "heic"].contains(suffix)
    }
}
