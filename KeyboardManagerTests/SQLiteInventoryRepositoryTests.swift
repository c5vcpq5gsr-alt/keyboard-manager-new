import Foundation
import XCTest
@testable import KeyboardManager

final class SQLiteInventoryRepositoryTests: XCTestCase {
    func testMissingDatabaseLoadsEmptySnapshotWithoutCreatingFiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = SQLiteInventoryRepository(databaseURL: fixture.databaseURL)

        let snapshot = try await repository.loadSnapshot()

        XCTAssertEqual(snapshot, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }

    func testSnapshotRoundTripsThroughSQLiteAndPassesIntegrityCheck() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = SQLiteInventoryRepository(databaseURL: fixture.databaseURL)
        let expected = sampleSnapshot()

        try await repository.saveSnapshot(expected)
        let loaded = try await repository.loadSnapshot()
        try await repository.verifyIntegrity()

        XCTAssertEqual(loaded, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }

    func testSavingASecondSnapshotReplacesTheSingleCommittedState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = SQLiteInventoryRepository(databaseURL: fixture.databaseURL)
        var replacement = sampleSnapshot()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        replacement.boards.append(Board(
            id: "board_2",
            name: "Zweites Board",
            createdAt: timestamp,
            updatedAt: timestamp
        ))

        try await repository.saveSnapshot(sampleSnapshot())
        try await repository.saveSnapshot(replacement)
        let loaded = try await repository.loadSnapshot()

        XCTAssertEqual(loaded, replacement)
    }

    private func makeFixture() throws -> (directory: URL, databaseURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerSQLiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("inventory.sqlite"))
    }

    private func sampleSnapshot() -> InventorySnapshot {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return InventorySnapshot(
            metadata: AppMetadata(
                schemaVersion: 1,
                createdAt: timestamp,
                updatedAt: timestamp,
                preferredLanguage: "de"
            ),
            libraryValues: LibraryValues(valuesByKey: ["manufacturer": ["Test"]]),
            boards: [
                Board(
                    id: "board_1",
                    name: "Testboard",
                    manufacturer: "Test",
                    photoIDs: ["photo_1"],
                    mainPhotoID: "photo_1",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            ],
            keycapSets: [],
            artisanSets: [],
            switchSets: [],
            switchInstallations: [],
            photos: [
                PhotoRecord(
                    id: "photo_1",
                    owner: PhotoOwner(type: .board, id: "board_1"),
                    originalName: "Test.png",
                    mimeType: .png,
                    pixelWidth: 1,
                    pixelHeight: 1,
                    addedAt: timestamp,
                    relativeFileName: "Photos/photo_1.png"
                )
            ]
        )
    }
}
