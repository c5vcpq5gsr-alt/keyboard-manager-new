import XCTest
@testable import KeyboardManager

final class V1MigrationServiceTests: XCTestCase {
    func testPreferredSourceOrderStartsWithPortableZIP() {
        XCTAssertEqual(
            V1MigrationService.supportedSourcesByPriority,
            [.zipBackup, .sqliteDirectory, .legacyJSON, .webStorageExport]
        )
    }

    func testEveryMigrationSourceIsReadOnly() {
        XCTAssertTrue(MigrationSourceKind.allCases.allSatisfy(\.isReadOnly))
    }

    func testReadinessDoesNotPretendAnEmptyScanIsReady() {
        let service = V1MigrationService()
        XCTAssertEqual(service.readiness(for: []), .notScanned)
    }
}
