import XCTest
@testable import KeyboardManager

final class AppUpdateServiceTests: XCTestCase {
    func testVersionComparisonAcceptsReleaseTags() throws {
        let current = try XCTUnwrap(AppVersion(releaseTag: "v1.0.0"))
        let newer = try XCTUnwrap(AppVersion(releaseTag: "1.0.1"))

        XCTAssertLessThan(current, newer)
        XCTAssertNil(AppVersion(releaseTag: "v1.0"))
        XCTAssertNil(AppVersion(releaseTag: "v1.0.0-beta"))
    }

    func testLatestReleaseReturnsVerifiedInstallerAssets() async throws {
        let fixture = """
        {
          "tag_name": "v1.2.0",
          "html_url": "https://github.com/example/keyboard/releases/tag/v1.2.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Keyboard-Manager-1.2.0-universal.dmg",
              "browser_download_url": "https://example.invalid/Keyboard-Manager-1.2.0-universal.dmg"
            },
            {
              "name": "Keyboard-Manager-1.2.0-universal.dmg.sha256",
              "browser_download_url": "https://example.invalid/Keyboard-Manager-1.2.0-universal.dmg.sha256"
            }
          ]
        }
        """.data(using: .utf8)!
        let service = GitHubReleaseUpdateService(loadData: { _ in fixture })
        let current = try XCTUnwrap(AppVersion(releaseTag: "1.0.0"))

        let result = try await service.checkForUpdate(currentVersion: current)

        guard case let .updateAvailable(update) = result else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(update.version.description, "1.2.0")
        XCTAssertEqual(update.diskImageURL.lastPathComponent, "Keyboard-Manager-1.2.0-universal.dmg")
        XCTAssertEqual(update.checksumURL.lastPathComponent, "Keyboard-Manager-1.2.0-universal.dmg.sha256")
    }

    func testCurrentVersionDoesNotOfferSameRelease() async throws {
        let fixture = """
        {
          "tag_name": "v1.0.0",
          "html_url": "https://github.com/example/keyboard/releases/tag/v1.0.0",
          "draft": false,
          "prerelease": false,
          "assets": []
        }
        """.data(using: .utf8)!
        let service = GitHubReleaseUpdateService(loadData: { _ in fixture })
        let current = try XCTUnwrap(AppVersion(releaseTag: "1.0.0"))

        let result = try await service.checkForUpdate(currentVersion: current)
        XCTAssertEqual(result, .upToDate)
    }

    func testChecksumParserAndHashRejectTampering() throws {
        let data = Data("abc".utf8)
        XCTAssertEqual(
            GitHubReleaseUpdateService.sha256Hex(of: data),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            try GitHubReleaseUpdateService.checksum(
                from: Data("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  update.dmg\n".utf8)
            ),
            GitHubReleaseUpdateService.sha256Hex(of: data)
        )
        XCTAssertThrowsError(
            try GitHubReleaseUpdateService.checksum(from: Data("not-a-checksum".utf8))
        )
    }
}
