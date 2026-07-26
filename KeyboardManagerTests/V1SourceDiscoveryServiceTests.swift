import Foundation
import SQLite3
import XCTest
@testable import KeyboardManager

final class V1SourceDiscoveryServiceTests: XCTestCase {
    func testDiscoveryFindsLowercaseElectronDirectoryWithoutChangingSource() async throws {
        let fixture = try makeFixture()
        defer {
            sqlite3_close(fixture.database)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let databaseBefore = try Data(contentsOf: fixture.databaseURL)
        let walURL = URL(fileURLWithPath: fixture.databaseURL.path + "-wal")
        let walBefore = try Data(contentsOf: walURL)
        let service = makeService(root: fixture.applicationSupportRoot, isV1Running: false)

        let result = try await service.discoverInstalledSource()

        let source = try XCTUnwrap(result.source)
        XCTAssertEqual(source.directoryURL, fixture.sourceDirectory)
        XCTAssertTrue(source.isSchemaVerified)
        XCTAssertTrue(source.hasWriteAheadLog)
        XCTAssertTrue(source.hasPhotosDirectory)
        XCTAssertFalse(result.isV1Running)
        XCTAssertEqual(result.searchedCandidateCount, 3)
        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: walURL), walBefore)
    }

    func testDiscoveryIgnoresNamesakeSQLiteWithoutV1Schema() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerDiscoveryInvalid-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("keyboard-manager", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = sourceDirectory.appendingPathComponent("keyboard-manager.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        try execute("CREATE TABLE unrelated (id TEXT PRIMARY KEY);", in: try XCTUnwrap(database))
        sqlite3_close(database)
        let service = makeService(
            root: sourceDirectory.deletingLastPathComponent(),
            isV1Running: false
        )

        let result = try await service.discoverInstalledSource()

        XCTAssertNil(result.source)
        XCTAssertFalse(result.isV1Running)
    }

    func testRunningV1BlocksDirectInspectionUntilRefresh() async throws {
        let fixture = try makeFixture()
        defer {
            sqlite3_close(fixture.database)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let discoveryService = makeService(
            root: fixture.applicationSupportRoot,
            isV1Running: true
        )
        let discovery = try await discoveryService.discoverInstalledSource()
        let source = try XCTUnwrap(discovery.source)

        XCTAssertTrue(discovery.isV1Running)
        XCTAssertFalse(source.isSchemaVerified)

        let migrationService = V1MigrationService(discoveryService: discoveryService)
        do {
            _ = try await migrationService.inspectSource(at: fixture.sourceDirectory)
            XCTFail("Eine laufende V1 muss die direkte SQLite-Prüfung blockieren.")
        } catch let error as V1SourceDiscoveryError {
            guard case .v1IsRunning = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }
    }

    private func makeService(
        root: URL,
        isV1Running: Bool
    ) -> V1SourceDiscoveryService {
        V1SourceDiscoveryService(
            applicationSupportRoots: { [root] in [root] },
            processDetector: V1ProcessDetector(lookup: { isV1Running })
        )
    }

    private func makeFixture() throws -> (
        root: URL,
        applicationSupportRoot: URL,
        sourceDirectory: URL,
        databaseURL: URL,
        database: OpaquePointer
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerDiscovery-\(UUID().uuidString)", isDirectory: true)
        let applicationSupportRoot = root
            .appendingPathComponent("Application Support", isDirectory: true)
        let sourceDirectory = applicationSupportRoot
            .appendingPathComponent("keyboard-manager", isDirectory: true)
        let photosDirectory = sourceDirectory.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        let databaseURL = sourceDirectory.appendingPathComponent("keyboard-manager.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        try execute(
            """
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE app_meta (key TEXT PRIMARY KEY, value_json TEXT NOT NULL);
            CREATE TABLE boards (id TEXT PRIMARY KEY, board_json TEXT NOT NULL);
            CREATE TABLE keycap_sets (id TEXT PRIMARY KEY, keycap_set_json TEXT NOT NULL);
            CREATE TABLE artisan_sets (id TEXT PRIMARY KEY, artisan_set_json TEXT NOT NULL);
            CREATE TABLE switch_sets (id TEXT PRIMARY KEY, switch_set_json TEXT NOT NULL);
            CREATE TABLE photos (
                id TEXT PRIMARY KEY,
                board_id TEXT NOT NULL,
                owner_type TEXT NOT NULL,
                owner_id TEXT,
                name TEXT NOT NULL,
                type TEXT NOT NULL,
                width INTEGER,
                height INTEGER,
                added_at INTEGER NOT NULL,
                file_name TEXT NOT NULL
            );
            INSERT INTO app_meta (key, value_json)
            VALUES ('app', '{"meta":{"version":"1.3.2-test"},"lists":{}}');
            """,
            in: connection
        )
        return (root, applicationSupportRoot, sourceDirectory, databaseURL, connection)
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite-Fehler \(result)"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "V1SourceDiscoveryServiceTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
