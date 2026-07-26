import Foundation
import XCTest
import ZIPFoundation
@testable import KeyboardManager

final class V1BackupReaderTests: XCTestCase {
    func testValidSchemaSixBackupProducesReadOnlyDryRun() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let before = try Data(contentsOf: fixture.archiveURL)
        let result = try await V1BackupReader().inspect(at: fixture.archiveURL)
        let after = try Data(contentsOf: fixture.archiveURL)

        XCTAssertEqual(before, after, "Der Prüflauf darf die Quelle nicht verändern.")
        XCTAssertEqual(result.report.sourceKind, .zipBackup)
        XCTAssertEqual(result.report.schemaVersion, 6)
        XCTAssertEqual(result.report.sourceVersion, "1.3.2-test")
        XCTAssertEqual(result.report.counts.boards, 1)
        XCTAssertEqual(result.report.counts.photos, 1)
        XCTAssertEqual(result.snapshot.boards.first?.id, "board_1")
        XCTAssertEqual(result.snapshot.photos.first?.owner, PhotoOwner(type: .board, id: "board_1"))
        XCTAssertTrue(result.report.canImport)
        XCTAssertEqual(result.report.errorCount, 0)
    }

    func testUnexpectedTraversalEntryIsRejected() async throws {
        let fixture = try makeFixture(extraEntries: ["../escape.txt": Data("nope".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await V1BackupReader().inspect(at: fixture.archiveURL)
            XCTFail("Ein unerwarteter Pfad muss blockiert werden.")
        } catch let error as V1BackupReaderError {
            guard case .unsafeArchiveEntry = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }
    }

    func testSchemasThreeThroughFiveAreNormalized() async throws {
        for schemaVersion in 3...5 {
            let fixture = try makeFixture(schemaVersion: schemaVersion)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }

            let result = try await V1BackupReader().inspect(at: fixture.archiveURL)

            XCTAssertEqual(result.report.schemaVersion, schemaVersion)
            XCTAssertEqual(result.report.counts.keycapSets, schemaVersion >= 4 ? 1 : 0)
            XCTAssertEqual(result.report.counts.artisanSets, schemaVersion >= 5 ? 1 : 0)
            XCTAssertEqual(result.report.counts.switchSets, 0)
            XCTAssertEqual(result.snapshot.photos.first?.owner, PhotoOwner(type: .board, id: "board_1"))
            XCTAssertEqual(issueCount("legacy-zip-schema", in: result.report), 1)
            XCTAssertTrue(result.report.canImport)
        }
    }

    func testUnsupportedSchemaIsRejectedBeforeTransformation() async throws {
        let fixture = try makeFixture(schemaVersion: 2)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            _ = try await V1BackupReader().inspect(at: fixture.archiveURL)
            XCTFail("Schema 2 ist kein ZIP-Backup-Schema.")
        } catch let error as V1BackupReaderError {
            guard case let .unsupportedSchema(version) = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
            XCTAssertEqual(version, 2)
        }
    }

    func testLegacyJSONIsCanonicalizedWithoutChangingSource() async throws {
        let fixture = try makeLegacyJSONFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = try Data(contentsOf: fixture.jsonURL)

        let result = try await V1LegacyJSONReader().inspect(at: fixture.jsonURL)

        XCTAssertEqual(try Data(contentsOf: fixture.jsonURL), before)
        XCTAssertEqual(result.report.sourceKind, .legacyJSON)
        XCTAssertEqual(result.report.schemaVersion, 2)
        XCTAssertEqual(result.report.counts.boards, 1)
        XCTAssertEqual(result.report.counts.photos, 1)
        XCTAssertEqual(result.snapshot.photos.first?.owner, PhotoOwner(type: .board, id: "board_1"))
        XCTAssertEqual(issueCount("legacy-json-source", in: result.report), 1)
        XCTAssertTrue(result.report.canImport)
    }

    func testPrivateV1ExportMatchesExpectedDryRun() async throws {
        let backupURL = privateV1ExportURL()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: backupURL.path),
            "Privater V1-Export ist absichtlich kein Repository-Fixture."
        )

        let result = try await V1BackupReader().inspect(at: backupURL)

        XCTAssertEqual(result.report.schemaVersion, 6)
        XCTAssertEqual(result.report.sourceVersion, "1.3.2")
        XCTAssertEqual(result.report.counts, InventoryCounts(
            boards: 54,
            keycapSets: 73,
            artisanSets: 61,
            switchSets: 55,
            photos: 301
        ))
        XCTAssertEqual(result.snapshot.switchInstallations.count, 53)
        XCTAssertEqual(issueCount("photo-mime-mismatch", in: result.report), 15)
        XCTAssertEqual(issueCount("one-sided-switch-installation", in: result.report), 4)
        XCTAssertEqual(issueCount("preserved-v1-import-warnings", in: result.report), 3)
        XCTAssertEqual(result.report.errorCount, 0, "Issues: \(result.report.issues)")
        XCTAssertTrue(result.report.canImport, "Issues: \(result.report.issues)")
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

    private func issueCount(_ code: String, in report: MigrationDryRunReport) -> Int {
        report.issues.first(where: { $0.code == code })?.affectedItems ?? 0
    }

    private func makeFixture(
        schemaVersion: Int = 6,
        extraEntries: [String: Data] = [:]
    ) throws -> (directory: URL, archiveURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("fixture.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)

        let imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        var photo: [String: Any] = [
            "id": "photo_1",
            "name": "pixel.png",
            "type": "image/png",
            "width": 1,
            "height": 1,
            "addedAt": 1_700_000_000_000,
            "file": "photos/photo_1.png"
        ]
        if schemaVersion >= 4 {
            photo["ownerType"] = "board"
            photo["ownerId"] = "board_1"
        } else {
            photo["boardId"] = "board_1"
        }
        let keycapSets: [[String: Any]] = (4...5).contains(schemaVersion)
            ? [["id": "keycap_1", "name": "Historisches Keycap-Set"]]
            : []
        let artisanSets: [[String: Any]] = schemaVersion == 5
            ? [["id": "artisan_1", "name": "Historischer Artisan"]]
            : []
        let manifest: [String: Any] = [
            "schemaVersion": schemaVersion,
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
            "keycapSets": keycapSets,
            "artisanSets": artisanSets,
            "switchSets": [],
            "photos": [photo]
        ]

        try add(JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]), at: "manifest.json", to: archive)
        try add(imageData, at: "photos/photo_1.png", to: archive)
        for (path, data) in extraEntries {
            try add(data, at: path, to: archive)
        }
        return (directory, archiveURL)
    }

    private func makeLegacyJSONFixture() throws -> (directory: URL, jsonURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerLegacyTests-\(UUID().uuidString)", isDirectory: true)
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
}
