import Foundation
import PDFKit
import XCTest
import ZIPFoundation
@testable import KeyboardManager

final class InventoryReportServiceTests: XCTestCase {
    func testBuilderAppliesPerKindFiltersAndPreservesTypedValues() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var filters = InventoryFilters()
        filters.manufacturer = "Acme"
        let report = try InventoryReportBuilder.build(
            snapshot: fixture.snapshot,
            context: InventoryReportContext(
                currentKind: .board,
                filtersByKind: [.board: filters],
                sortsByKind: [.board: .name]
            ),
            options: InventoryReportOptions(
                format: .xlsx,
                scope: .all,
                appliesFilters: true,
                includesImages: false
            ),
            createdAt: fixture.date,
            appVersion: "test"
        )

        XCTAssertEqual(report.sections.map(\.kind), InventoryItemKind.allCases)
        XCTAssertEqual(report.sections[0].rows.map(\.id), ["board_1"])
        XCTAssertEqual(report.sections[0].filterDescription, "Hersteller: Acme")
        XCTAssertEqual(report.sections[3].rows[0].values[14], .number(90))
        XCTAssertEqual(report.sections[3].rows[0].values[15], .number(70))
        XCTAssertEqual(report.sections[3].rows[0].values[16], .number(20))
    }

    func testPDFAndXLSXExportsAreReadableAndStructured() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let outputDirectory = try qaOutputDirectory()
        let report = try InventoryReportBuilder.build(
            snapshot: fixture.snapshot,
            context: InventoryReportContext(
                currentKind: .board,
                filtersByKind: [:],
                sortsByKind: [:]
            ),
            options: InventoryReportOptions(
                format: .pdf,
                scope: .all,
                appliesFilters: true,
                includesImages: true
            ),
            createdAt: fixture.date,
            appVersion: "0.1.0-test"
        )
        let pdfURL = outputDirectory.appendingPathComponent("keyboard-manager-report-qa.pdf")
        let xlsxURL = outputDirectory.appendingPathComponent("keyboard-manager-report-qa.xlsx")

        let pdfResult = try await fixture.service.export(report: report, format: .pdf, to: pdfURL)
        let xlsxResult = try await fixture.service.export(report: report, format: .xlsx, to: xlsxURL)

        XCTAssertGreaterThan(pdfResult.byteCount, 1_000)
        XCTAssertGreaterThan(xlsxResult.byteCount, 1_000)
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertEqual(pdf.pageCount, 5)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Bestandsbericht") == true)
        XCTAssertTrue(pdf.page(at: 4)?.string?.contains("Testswitch") == true)

        let archive = try Archive(url: xlsxURL, accessMode: .read)
        XCTAssertNotNil(archive["xl/worksheets/sheet5.xml"])
        let workbook = try extract("xl/workbook.xml", from: archive)
        let switchSheet = try extract("xl/worksheets/sheet5.xml", from: archive)
        let keycapSheet = try extract("xl/worksheets/sheet3.xml", from: archive)
        let keycapRelationships = try extract(
            "xl/worksheets/_rels/sheet3.xml.rels",
            from: archive
        )
        XCTAssertEqual(workbook.components(separatedBy: "<sheet ").count - 1, 5)
        XCTAssertTrue(switchSheet.contains("ySplit=\"4\""))
        XCTAssertTrue(switchSheet.contains("<autoFilter ref=\"A4:U5\"/>"))
        XCTAssertTrue(switchSheet.contains("<c r=\"O5\" s=\"4\"><v>90</v></c>"))
        XCTAssertTrue(keycapSheet.contains("<hyperlink ref=\"I5\" r:id=\"rId1\"/>"))
        XCTAssertTrue(keycapRelationships.contains("https://example.com/keycaps"))
    }

    private func qaOutputDirectory() throws -> URL {
        let path = ProcessInfo.processInfo.environment["KEYBOARD_MANAGER_REPORT_QA_DIR"]
            ?? "/private/tmp/KeyboardManagerReportQA"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func extract(_ path: String, from archive: Archive) throws -> String {
        let entry = try XCTUnwrap(archive[path])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerReportTests-\(UUID().uuidString)", isDirectory: true)
        let layout = MigrationStorageLayout(rootURL: directory.appendingPathComponent("AppData"))
        try FileManager.default.createDirectory(
            at: layout.currentPhotosDirectoryURL,
            withIntermediateDirectories: true
        )
        let image = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try image.write(to: layout.currentPhotosDirectoryURL.appendingPathComponent("photo_1.png"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = InventorySnapshot(
            metadata: AppMetadata(
                schemaVersion: 1,
                createdAt: date,
                updatedAt: date,
                preferredLanguage: "de"
            ),
            libraryValues: .empty,
            boards: [
                Board(
                    id: "board_1",
                    name: "Testboard",
                    manufacturer: "Acme",
                    format: "65%",
                    plate: "Aluminium",
                    pcb: "Hot-Swap",
                    stabilizers: "TX",
                    remark: "Täglicher Begleiter",
                    keycapSetID: "keycap_1",
                    photoIDs: ["photo_1"],
                    mainPhotoID: "photo_1",
                    createdAt: date,
                    updatedAt: date
                ),
                Board(
                    id: "board_2",
                    name: "Zweitboard",
                    manufacturer: "Andere",
                    createdAt: date,
                    updatedAt: date
                )
            ],
            keycapSets: [
                KeycapSet(
                    id: "keycap_1",
                    name: "Testcaps",
                    manufacturer: "Caps Co",
                    profile: "Cherry",
                    material: "PBT",
                    status: "owned",
                    kits: ["Base", "Numpad"],
                    sourceURL: "https://example.com/keycaps",
                    sourceShop: "Beispielshop",
                    mountedBoardID: "board_1",
                    createdAt: date,
                    updatedAt: date
                )
            ],
            artisanSets: [
                ArtisanSet(
                    id: "artisan_1",
                    name: "Testartisan",
                    manufacturer: "Maker",
                    profile: "MX",
                    tags: ["blau", "resin"],
                    mountedBoardID: "board_1",
                    createdAt: date,
                    updatedAt: date
                )
            ],
            switchSets: [
                SwitchSet(
                    id: "switch_1",
                    name: "Testswitch",
                    switchType: "Linear",
                    operatingForce: "45 g",
                    bottomOutForce: "55 g",
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
        return Fixture(
            directory: directory,
            service: InventoryReportExportService(layout: layout),
            snapshot: snapshot,
            date: date
        )
    }
}

private struct Fixture {
    var directory: URL
    var service: InventoryReportExportService
    var snapshot: InventorySnapshot
    var date: Date

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
