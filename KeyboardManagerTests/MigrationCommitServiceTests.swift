import Foundation
import XCTest
import ZIPFoundation
@testable import KeyboardManager

final class MigrationCommitServiceTests: XCTestCase {
    func testCommitBuildsVerifiedCurrentStateWithoutChangingSource() async throws {
        let fixture = try makeBackupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let layout = MigrationStorageLayout(
            rootURL: fixture.directory.appendingPathComponent("V2", isDirectory: true)
        )
        let before = try Data(contentsOf: fixture.archiveURL)
        let dryRun = try await V1BackupReader().inspect(at: fixture.archiveURL)

        let result = try await MigrationCommitService(layout: layout).commit(
            backupURL: fixture.archiveURL,
            expectedDryRun: dryRun
        )
        let committedSnapshot = try await SQLiteInventoryRepository(
            databaseURL: layout.currentDatabaseURL
        ).loadSnapshot()

        XCTAssertEqual(try Data(contentsOf: fixture.archiveURL), before)
        XCTAssertEqual(committedSnapshot, dryRun.snapshot)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.currentPhotosDirectoryURL
                .appendingPathComponent("photo_1.png").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.reportURL.path))
        XCTAssertNil(result.backupURL)
        XCTAssertEqual(result.report.databaseIntegrityCheck, "ok")
        XCTAssertEqual(result.report.copiedPhotoByteCount, Int64(fixture.imageData.count))
        XCTAssertTrue(try directoryContents(at: layout.stagingRootURL).isEmpty)
    }

    func testReplacingCurrentStateCreatesReadableBackup() async throws {
        let fixture = try makeBackupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let layout = MigrationStorageLayout(
            rootURL: fixture.directory.appendingPathComponent("V2", isDirectory: true)
        )
        let previousSnapshot = oldSnapshot()
        try await SQLiteInventoryRepository(
            databaseURL: layout.currentDatabaseURL
        ).saveSnapshot(previousSnapshot)
        let dryRun = try await V1BackupReader().inspect(at: fixture.archiveURL)

        let result = try await MigrationCommitService(layout: layout).commit(
            backupURL: fixture.archiveURL,
            expectedDryRun: dryRun
        )

        let backupURL = try XCTUnwrap(result.backupURL)
        let backupSnapshot = try await SQLiteInventoryRepository(
            databaseURL: backupURL.appendingPathComponent("inventory.sqlite")
        ).loadSnapshot()
        let currentSnapshot = try await SQLiteInventoryRepository(
            databaseURL: layout.currentDatabaseURL
        ).loadSnapshot()
        XCTAssertEqual(backupSnapshot, previousSnapshot)
        XCTAssertEqual(currentSnapshot, dryRun.snapshot)
        XCTAssertTrue(result.report.replacedExistingV2Data)
    }

    func testActivationFailureRestoresPreviousCurrentState() async throws {
        let fixture = try makeBackupFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let layout = MigrationStorageLayout(
            rootURL: fixture.directory.appendingPathComponent("V2", isDirectory: true)
        )
        let previousSnapshot = oldSnapshot()
        try await SQLiteInventoryRepository(
            databaseURL: layout.currentDatabaseURL
        ).saveSnapshot(previousSnapshot)
        let markerURL = layout.currentDirectoryURL.appendingPathComponent("previous-marker")
        try Data("old".utf8).write(to: markerURL)
        let dryRun = try await V1BackupReader().inspect(at: fixture.archiveURL)
        let service = MigrationCommitService(
            layout: layout,
            failurePoint: .afterBackupMove
        )

        do {
            _ = try await service.commit(
                backupURL: fixture.archiveURL,
                expectedDryRun: dryRun
            )
            XCTFail("Der simulierte Aktivierungsfehler muss den Commit abbrechen.")
        } catch let error as MigrationCommitServiceError {
            guard case .simulatedFailure = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }
        let restoredSnapshot = try await SQLiteInventoryRepository(
            databaseURL: layout.currentDatabaseURL
        ).loadSnapshot()

        XCTAssertEqual(restoredSnapshot, previousSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(try directoryContents(at: layout.stagingRootURL).isEmpty)
    }

    func testPrivateV1ExportCanBeCommittedIntoIsolatedV2Layout() async throws {
        let backupURL = privateV1ExportURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: backupURL.path),
            "Privater V1-Export ist absichtlich kein Repository-Fixture."
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerRealCommit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let layout = MigrationStorageLayout(rootURL: directory)
        let dryRun = try await V1BackupReader().inspect(at: backupURL)

        let result = try await MigrationCommitService(layout: layout).commit(
            backupURL: backupURL,
            expectedDryRun: dryRun
        )
        let reloaded = try await SQLiteInventoryRepository(
            databaseURL: layout.currentDatabaseURL
        ).loadSnapshot()
        let photoFiles = try FileManager.default.contentsOfDirectory(
            at: layout.currentPhotosDirectoryURL,
            includingPropertiesForKeys: nil
        )

        XCTAssertEqual(reloaded, dryRun.snapshot)
        XCTAssertEqual(result.report.counts, dryRun.report.counts)
        XCTAssertEqual(result.report.switchInstallationCount, 53)
        XCTAssertEqual(photoFiles.count, 301)
        XCTAssertEqual(result.report.sourceSHA256, dryRun.report.sourceSHA256)
        XCTAssertEqual(result.report.databaseIntegrityCheck, "ok")
    }

    private func privateV1ExportURL() -> URL {
        if let stagedPath = ProcessInfo.processInfo.environment[
            "KEYBOARD_MANAGER_PRIVATE_V1_EXPORT"
        ], !stagedPath.isEmpty {
            return URL(fileURLWithPath: stagedPath)
        }
        let stagedURL = URL(
            fileURLWithPath: "/private/tmp/keyboard-manager-private-v1-export.zip"
        )
        if FileManager.default.fileExists(atPath: stagedURL.path) {
            return stagedURL
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("keyboard-manager-backup.zip")
    }

    func testLegacyJSONCommitUsesCanonicalArchiveAndPreservesSource() async throws {
        let fixture = try makeLegacyJSONFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let layout = MigrationStorageLayout(
            rootURL: fixture.directory.appendingPathComponent("V2", isDirectory: true)
        )
        let sourceBefore = try Data(contentsOf: fixture.jsonURL)
        let dryRun = try await V1LegacyJSONReader().inspect(at: fixture.jsonURL)

        let result = try await MigrationCommitService(layout: layout).commit(
            backupURL: fixture.jsonURL,
            expectedDryRun: dryRun
        )
        let reloaded = try await SQLiteInventoryRepository(
            databaseURL: layout.currentDatabaseURL
        ).loadSnapshot()

        XCTAssertEqual(try Data(contentsOf: fixture.jsonURL), sourceBefore)
        XCTAssertEqual(reloaded, dryRun.snapshot)
        XCTAssertEqual(result.report.sourceKind, .legacyJSON)
        XCTAssertEqual(result.report.sourceSchemaVersion, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.currentPhotosDirectoryURL
                .appendingPathComponent("photo_1.png").path
        ))
        XCTAssertTrue(try directoryContents(at: layout.stagingRootURL).isEmpty)
    }

    private func oldSnapshot() -> InventorySnapshot {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return InventorySnapshot(
            metadata: AppMetadata(
                schemaVersion: 1,
                createdAt: timestamp,
                updatedAt: timestamp,
                preferredLanguage: "de"
            ),
            libraryValues: .empty,
            boards: [
                Board(
                    id: "old_board",
                    name: "Vorheriger Bestand",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            ],
            keycapSets: [],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: []
        )
    }

    private func makeBackupFixture() throws -> (
        directory: URL,
        archiveURL: URL,
        imageData: Data
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerCommitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("fixture.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let manifest: [String: Any] = [
            "schemaVersion": 6,
            "format": "keyboard-manager-zip",
            "meta": [
                "version": "1.3.2-test",
                "createdAt": 1_700_000_000_000,
                "updatedAt": 1_700_000_001_000,
                "language": "de"
            ],
            "lists": [String: [String]](),
            "boards": [[
                "id": "board_1",
                "name": "Testboard",
                "photoIds": ["photo_1"],
                "mainPhotoId": "photo_1"
            ]],
            "keycapSets": [],
            "artisanSets": [],
            "switchSets": [],
            "photos": [[
                "id": "photo_1",
                "ownerType": "board",
                "ownerId": "board_1",
                "name": "pixel.png",
                "type": "image/png",
                "width": 1,
                "height": 1,
                "addedAt": 1_700_000_000_000,
                "file": "photos/photo_1.png"
            ]]
        ]
        try add(
            JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
            at: "manifest.json",
            to: archive
        )
        try add(imageData, at: "photos/photo_1.png", to: archive)
        return (directory, archiveURL, imageData)
    }

    private func makeLegacyJSONFixture() throws -> (directory: URL, jsonURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerLegacyCommit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jsonURL = directory.appendingPathComponent("legacy.json")
        let imageBase64 =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let payload: [String: Any] = [
            "schemaVersion": 2,
            "meta": [
                "version": "1.1-legacy",
                "createdAt": 1_700_000_000_000,
                "updatedAt": 1_700_000_001_000,
                "language": "de"
            ],
            "lists": [String: [String]](),
            "boards": [[
                "id": "board_1",
                "name": "Legacy Board",
                "photoIds": ["photo_1"],
                "mainPhotoId": "photo_1"
            ]],
            "photos": [[
                "id": "photo_1",
                "boardId": "board_1",
                "name": "pixel.png",
                "type": "image/png",
                "width": 1,
                "height": 1,
                "addedAt": 1_700_000_000_000,
                "dataUrl": "data:image/png;base64,\(imageBase64)"
            ]]
        ]
        try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: jsonURL, options: [.atomic])
        return (directory, jsonURL)
    }

    private func add(_ data: Data, at path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private func directoryContents(at url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
    }
}
