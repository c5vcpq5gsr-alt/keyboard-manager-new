import Foundation
import SQLite3
import XCTest
@testable import KeyboardManager

final class V1SQLiteSourceReaderTests: XCTestCase {
    func testDirectSQLiteInspectionUsesStagedSnapshotAndPreservesSource() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let databaseBefore = try Data(contentsOf: fixture.databaseURL)
        let photoBefore = try Data(contentsOf: fixture.photoURL)

        let first = try await migrationService(isV1Running: false)
            .inspectSource(at: fixture.directory)
        let second = try await V1SQLiteSourceReader().inspect(at: fixture.directory)

        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.photoURL), photoBefore)
        XCTAssertEqual(first.report.sourceKind, .sqliteDirectory)
        XCTAssertEqual(first.report.sourceVersion, "1.3.2-test")
        XCTAssertEqual(first.report.schemaVersion, 0)
        XCTAssertEqual(first.report.counts, InventoryCounts(
            boards: 1,
            keycapSets: 0,
            artisanSets: 0,
            switchSets: 0,
            photos: 1
        ))
        XCTAssertEqual(first.snapshot.boards.first?.name, "Direktes V1-Board")
        XCTAssertEqual(first.snapshot.photos.first?.owner, PhotoOwner(type: .board, id: "board_1"))
        XCTAssertEqual(first.report.sourceSHA256, second.report.sourceSHA256)
        XCTAssertEqual(first.snapshot, second.snapshot)
        XCTAssertEqual(first.photoPlans, second.photoPlans)
        XCTAssertEqual(
            first.report.issues.first(where: { $0.code == "sqlite-readonly-snapshot" })?.affectedItems,
            1
        )
        XCTAssertTrue(first.report.canImport)
    }

    func testDirectSQLiteInspectionIncludesStableWALWithoutTouchingSidecars() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var liveDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.databaseURL.path, &liveDatabase), SQLITE_OK)
        let connection = try XCTUnwrap(liveDatabase)
        defer { sqlite3_close(connection) }
        try execute(
            """
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            """,
            in: connection
        )
        try updateBoardName(in: connection, name: "Nur im stabilen WAL")

        let walURL = URL(fileURLWithPath: fixture.databaseURL.path + "-wal")
        let sharedMemoryURL = URL(fileURLWithPath: fixture.databaseURL.path + "-shm")
        let databaseBefore = try Data(contentsOf: fixture.databaseURL)
        let walBefore = try Data(contentsOf: walURL)
        let sharedMemoryBefore = try Data(contentsOf: sharedMemoryURL)

        let result = try await V1SQLiteSourceReader().inspect(at: fixture.directory)

        XCTAssertEqual(result.snapshot.boards.first?.name, "Nur im stabilen WAL")
        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: walURL), walBefore)
        XCTAssertEqual(try Data(contentsOf: sharedMemoryURL), sharedMemoryBefore)
    }

    func testDirectSQLiteCommitUsesExistingRollbackSafeActivationPath() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let databaseBefore = try Data(contentsOf: fixture.databaseURL)
        let photoBefore = try Data(contentsOf: fixture.photoURL)
        let layout = MigrationStorageLayout(
            rootURL: fixture.directory.appendingPathComponent("V2", isDirectory: true)
        )
        let dryRun = try await V1SQLiteSourceReader().inspect(at: fixture.directory)

        let result = try await commitService(layout: layout, isV1Running: false).commit(
            backupURL: fixture.directory,
            expectedDryRun: dryRun
        )
        let reloaded = try await SQLiteInventoryRepository(
            databaseURL: layout.currentDatabaseURL
        ).loadSnapshot()

        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.photoURL), photoBefore)
        XCTAssertEqual(reloaded, dryRun.snapshot)
        XCTAssertEqual(result.report.sourceKind, .sqliteDirectory)
        XCTAssertEqual(result.report.sourceSHA256, dryRun.report.sourceSHA256)
        XCTAssertEqual(result.report.databaseIntegrityCheck, "ok")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.currentPhotosDirectoryURL
                .appendingPathComponent("photo_1.png").path
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: layout.stagingRootURL.path),
            []
        )
    }

    func testDirectSQLiteCommitBlocksWhenSourceChangedAfterDryRun() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let layout = MigrationStorageLayout(
            rootURL: fixture.directory.appendingPathComponent("V2", isDirectory: true)
        )
        let dryRun = try await V1SQLiteSourceReader().inspect(at: fixture.directory)
        try updateBoardName(in: fixture.databaseURL, name: "Nach Prüflauf geändert")

        do {
            _ = try await commitService(layout: layout, isV1Running: false).commit(
                backupURL: fixture.directory,
                expectedDryRun: dryRun
            )
            XCTFail("Eine nach dem Prüflauf geänderte SQLite-Quelle muss blockiert werden.")
        } catch let error as MigrationCommitServiceError {
            guard case .sourceChanged = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.currentDirectoryURL.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: layout.stagingRootURL.path),
            []
        )
    }

    func testDirectSQLiteCommitBlocksWhileV1IsRunning() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let layout = MigrationStorageLayout(
            rootURL: fixture.directory.appendingPathComponent("V2", isDirectory: true)
        )
        let dryRun = try await V1SQLiteSourceReader().inspect(at: fixture.directory)

        do {
            _ = try await commitService(layout: layout, isV1Running: true).commit(
                backupURL: fixture.directory,
                expectedDryRun: dryRun
            )
            XCTFail("Eine laufende V1 muss den direkten SQLite-Import blockieren.")
        } catch let error as V1SourceDiscoveryError {
            guard case .v1IsRunning = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.currentDirectoryURL.path))
    }

    private func migrationService(isV1Running: Bool) -> V1MigrationService {
        V1MigrationService(
            discoveryService: V1SourceDiscoveryService(
                applicationSupportRoots: { [] },
                processDetector: V1ProcessDetector(lookup: { isV1Running })
            )
        )
    }

    private func commitService(
        layout: MigrationStorageLayout,
        isV1Running: Bool
    ) -> MigrationCommitService {
        MigrationCommitService(
            layout: layout,
            v1ProcessDetector: V1ProcessDetector(lookup: { isV1Running })
        )
    }

    private func makeFixture() throws -> (
        directory: URL,
        databaseURL: URL,
        photoURL: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerSQLiteSource-\(UUID().uuidString)", isDirectory: true)
        let photosURL = directory.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosURL, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("keyboard-manager.sqlite")
        let photoURL = photosURL.appendingPathComponent("photo_1.png")
        let imageData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try imageData.write(to: photoURL)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }

        try execute(
            """
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE app_meta (
                key TEXT PRIMARY KEY,
                value_json TEXT NOT NULL
            );
            CREATE TABLE boards (
                id TEXT PRIMARY KEY,
                board_json TEXT NOT NULL
            );
            CREATE TABLE keycap_sets (
                id TEXT PRIMARY KEY,
                keycap_set_json TEXT NOT NULL
            );
            CREATE TABLE artisan_sets (
                id TEXT PRIMARY KEY,
                artisan_set_json TEXT NOT NULL
            );
            CREATE TABLE switch_sets (
                id TEXT PRIMARY KEY,
                switch_set_json TEXT NOT NULL
            );
            CREATE TABLE photos (
                id TEXT PRIMARY KEY,
                board_id TEXT NOT NULL,
                owner_type TEXT NOT NULL DEFAULT 'board',
                owner_id TEXT,
                name TEXT NOT NULL,
                type TEXT NOT NULL,
                width INTEGER,
                height INTEGER,
                added_at INTEGER NOT NULL,
                file_name TEXT NOT NULL
            );
            """,
            in: connection
        )

        let appValue: [String: Any] = [
            "meta": [
                "version": "1.3.2-test",
                "createdAt": 1_700_000_000_000,
                "updatedAt": 1_700_000_001_000,
                "language": "de"
            ],
            "lists": [String: [String]](),
            "gallery": [String: Any]()
        ]
        let board: [String: Any] = [
            "id": "board_1",
            "name": "Direktes V1-Board",
            "photoIds": ["photo_1"],
            "mainPhotoId": "photo_1",
            "createdAt": 1_700_000_000_000,
            "updatedAt": 1_700_000_001_000
        ]
        try insert(
            sql: "INSERT INTO app_meta (key, value_json) VALUES (?, ?);",
            values: ["app", try jsonString(appValue)],
            in: connection
        )
        try insert(
            sql: "INSERT INTO boards (id, board_json) VALUES (?, ?);",
            values: ["board_1", try jsonString(board)],
            in: connection
        )
        try insert(
            sql: """
            INSERT INTO photos (
                id, board_id, owner_type, owner_id, name, type,
                width, height, added_at, file_name
            ) VALUES (
                'photo_1', 'board_1', 'board', 'board_1', 'pixel.png', 'image/png',
                1, 1, 1700000000000, 'photo_1.png'
            );
            """,
            values: [],
            in: connection
        )
        return (directory, databaseURL, photoURL)
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func updateBoardName(in databaseURL: URL, name: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "V1SQLiteSourceReaderTests", code: 3)
        }
        defer { sqlite3_close(database) }
        try updateBoardName(in: database, name: name)
    }

    private func updateBoardName(in database: OpaquePointer, name: String) throws {
        let board: [String: Any] = [
            "id": "board_1",
            "name": name,
            "photoIds": ["photo_1"],
            "mainPhotoId": "photo_1",
            "createdAt": 1_700_000_000_000,
            "updatedAt": 1_700_000_002_000
        ]
        try insert(
            sql: "UPDATE boards SET board_json = ? WHERE id = 'board_1';",
            values: [try jsonString(board)],
            in: database
        )
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite-Fehler \(result)"
            sqlite3_free(errorPointer)
            throw NSError(domain: "V1SQLiteSourceReaderTests", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    private func insert(
        sql: String,
        values: [String],
        in database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "V1SQLiteSourceReaderTests", code: 1)
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(
                statement,
                Int32(index + 1),
                value,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            ) == SQLITE_OK else {
                throw NSError(domain: "V1SQLiteSourceReaderTests", code: 2)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(
                domain: "V1SQLiteSourceReaderTests",
                code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
            )
        }
    }
}
