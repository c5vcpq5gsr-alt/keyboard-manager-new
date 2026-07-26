import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ZIPFoundation
@testable import KeyboardManager

final class BackupExportServiceTests: XCTestCase {
    func testExportIsReadableAndPreservesManagedPhoto() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("roundtrip.zip")
        let before = try Data(contentsOf: fixture.photoURL)

        let result = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt,
            appVersion: "0.1.0-test"
        )
        let inspected = try await V1BackupReader().inspect(at: destination)
        let after = try Data(contentsOf: fixture.photoURL)

        XCTAssertEqual(before, after, "Der Export darf das verwaltete Originalfoto nicht verändern.")
        XCTAssertEqual(result.destinationURL, destination)
        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertEqual(result.counts, fixture.snapshot.counts)
        XCTAssertEqual(result.transcodedHEICPhotoCount, 0)
        XCTAssertEqual(inspected.report.schemaVersion, 6)
        XCTAssertEqual(inspected.report.sourceVersion, "0.1.0-test")
        XCTAssertEqual(inspected.report.errorCount, 0, "Issues: \(inspected.report.issues)")
        XCTAssertEqual(inspected.snapshot.boards.first?.keycapSetID, "keycap_1")
        XCTAssertEqual(
            inspected.snapshot.switchInstallations,
            [SwitchInstallation(switchSetID: "switch_1", boardID: "board_1", quantity: 70)]
        )
        XCTAssertEqual(
            inspected.snapshot.photos.first?.owner,
            PhotoOwner(type: .board, id: "board_1")
        )
    }

    func testSameSnapshotAndTimestampProduceByteIdenticalArchives() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstURL = fixture.directory.appendingPathComponent("first.zip")
        let secondURL = fixture.directory.appendingPathComponent("second.zip")

        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: firstURL,
            exportedAt: fixture.exportedAt,
            appVersion: "0.1.0-test"
        )
        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: secondURL,
            exportedAt: fixture.exportedAt,
            appVersion: "0.1.0-test"
        )

        XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))
    }

    func testMissingPhotoFailsWithoutInstallingDestination() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.photoURL)
        let destination = fixture.directory.appendingPathComponent("missing.zip")

        do {
            _ = try await fixture.service.export(
                snapshot: fixture.snapshot,
                to: destination,
                exportedAt: fixture.exportedAt,
                appVersion: "0.1.0-test"
            )
            XCTFail("Ein Backup mit fehlendem verwaltetem Foto darf nicht installiert werden.")
        } catch let error as BackupExportError {
            guard case .missingPhoto = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".partial-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testExistingDestinationIsReplacedWithValidatedArchive() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("replace.zip")
        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt,
            appVersion: "first"
        )
        fixture.snapshot.boards[0].name = "Ersetztes Board"

        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt.addingTimeInterval(2),
            appVersion: "second"
        )
        let inspected = try await V1BackupReader().inspect(at: destination)

        XCTAssertEqual(inspected.report.sourceVersion, "second")
        XCTAssertEqual(inspected.snapshot.boards.first?.name, "Ersetztes Board")
    }

    func testManifestUsesV1SchemaSixPhotoLayout() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let destination = fixture.directory.appendingPathComponent("manifest.zip")
        _ = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt,
            appVersion: "0.1.0-test"
        )

        let archive = try Archive(url: destination, accessMode: .read)
        let paths = Array(archive).map(\.path)
        XCTAssertEqual(paths, ["photos/photo_1.png", "manifest.json"])
        let manifestEntry = try XCTUnwrap(archive["manifest.json"])
        var manifestData = Data()
        _ = try archive.extract(manifestEntry) { manifestData.append($0) }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let photos = try XCTUnwrap(object["photos"] as? [[String: Any]])

        XCTAssertEqual(object["schemaVersion"] as? Int, 6)
        XCTAssertEqual(object["format"] as? String, "keyboard-manager-zip")
        XCTAssertEqual(photos.first?["file"] as? String, "photos/photo_1.png")
        XCTAssertEqual(photos.first?["ownerType"] as? String, "board")
    }

    func testHEICIsExportedAsJPEGWithoutChangingManagedOriginal() async throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let heicData = try makeHEICData()
        let heicURL = fixture.photoURL.deletingLastPathComponent()
            .appendingPathComponent("photo_1.heic")
        try FileManager.default.removeItem(at: fixture.photoURL)
        try heicData.write(to: heicURL)
        fixture.photoURL = heicURL
        fixture.snapshot.photos[0].mimeType = .heic
        fixture.snapshot.photos[0].relativeFileName = "photo_1.heic"
        fixture.snapshot.photos[0].originalName = "original.heic"
        let before = try Data(contentsOf: heicURL)
        let destination = fixture.directory.appendingPathComponent("heic.zip")

        let result = try await fixture.service.export(
            snapshot: fixture.snapshot,
            to: destination,
            exportedAt: fixture.exportedAt,
            appVersion: "0.1.0-test"
        )
        let inspected = try await V1BackupReader().inspect(at: destination)

        XCTAssertEqual(result.transcodedHEICPhotoCount, 1)
        XCTAssertEqual(try Data(contentsOf: heicURL), before)
        XCTAssertEqual(inspected.snapshot.photos.first?.mimeType, .jpeg)
        XCTAssertEqual(inspected.snapshot.photos.first?.relativeFileName, "photo_1.jpg")
    }

    private func makeFixture() throws -> (
        directory: URL,
        photoURL: URL,
        service: BackupExportService,
        snapshot: InventorySnapshot,
        exportedAt: Date
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerBackupTests-\(UUID().uuidString)", isDirectory: true)
        let layout = MigrationStorageLayout(rootURL: directory.appendingPathComponent("AppData"))
        try FileManager.default.createDirectory(
            at: layout.currentPhotosDirectoryURL,
            withIntermediateDirectories: true
        )
        let imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let photoURL = layout.currentPhotosDirectoryURL.appendingPathComponent("photo_1.png")
        try imageData.write(to: photoURL)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let board = Board(
            id: "board_1",
            name: "Testboard",
            manufacturer: "Test",
            format: "65%",
            keycapSetID: "keycap_1",
            photoIDs: ["photo_1"],
            mainPhotoID: "photo_1",
            createdAt: date,
            updatedAt: date
        )
        let snapshot = InventorySnapshot(
            metadata: AppMetadata(
                schemaVersion: 1,
                createdAt: date,
                updatedAt: date,
                preferredLanguage: "de"
            ),
            libraryValues: LibraryValues(valuesByKey: ["formats": ["65%"]]),
            boards: [board],
            keycapSets: [
                KeycapSet(
                    id: "keycap_1",
                    name: "Testcaps",
                    mountedBoardID: "board_1",
                    createdAt: date,
                    updatedAt: date
                )
            ],
            artisanSets: [],
            switchSets: [
                SwitchSet(
                    id: "switch_1",
                    name: "Testswitch",
                    switchType: "Linear",
                    quantity: 90,
                    createdAt: date,
                    updatedAt: date
                )
            ],
            switchInstallations: [
                SwitchInstallation(switchSetID: "switch_1", boardID: "board_1", quantity: 70)
            ],
            photos: [
                PhotoRecord(
                    id: "photo_1",
                    owner: PhotoOwner(type: .board, id: "board_1"),
                    originalName: "pixel.png",
                    mimeType: .png,
                    pixelWidth: 1,
                    pixelHeight: 1,
                    addedAt: date,
                    relativeFileName: "photo_1.png"
                )
            ]
        )
        return (
            directory,
            photoURL,
            BackupExportService(layout: layout),
            snapshot,
            date
        )
    }

    private func makeHEICData() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Testbild konnte nicht erzeugt werden.")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage() else {
            throw XCTSkip("Testbild konnte nicht gerendert werden.")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw XCTSkip("HEIC-Encoding ist auf diesem System nicht verfügbar.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("HEIC-Testbild konnte nicht kodiert werden.")
        }
        return data as Data
    }
}
