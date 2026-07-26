import AppKit
import CoreGraphics
import Foundation
import PDFKit
import ZIPFoundation

actor InventoryReportExportService {
    static func defaultFileName(for format: InventoryReportFormat, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "keyboard-manager-bestand-\(formatter.string(from: date)).\(format.fileExtension)"
    }

    private let layout: MigrationStorageLayout
    private let fileManager: FileManager

    init(
        layout: MigrationStorageLayout = .default,
        fileManager: FileManager = .default
    ) {
        self.layout = layout
        self.fileManager = fileManager
    }

    func export(
        report: InventoryReport,
        format: InventoryReportFormat,
        to destinationURL: URL
    ) throws -> InventoryReportExportResult {
        let destinationURL = destinationURL.standardizedFileURL
        guard destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == format.fileExtension,
              !destinationURL.lastPathComponent.isEmpty else {
            throw InventoryReportError.invalidDestination
        }
        try validate(report)

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let partialURL = parentURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).partial-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: partialURL) }

        switch format {
        case .pdf:
            try writePDF(report, to: partialURL)
            try validatePDF(at: partialURL)
        case .xlsx:
            try writeXLSX(report, to: partialURL)
            try validateXLSX(at: partialURL, expectedSheetCount: report.sections.count + 1)
        }

        let byteCount = try fileSize(at: partialURL)
        guard byteCount > 0 else {
            throw InventoryReportError.validationFailed(
                L10n.text("Die erzeugte Datei ist leer.", language: report.language)
            )
        }
        try install(from: partialURL, at: destinationURL)
        return InventoryReportExportResult(
            destinationURL: destinationURL,
            format: format,
            byteCount: byteCount,
            sectionCount: report.sections.count,
            itemCount: report.totalItemCount
        )
    }

    private func validate(_ report: InventoryReport) throws {
        guard !report.sections.isEmpty, report.sections.count <= 4 else {
            throw InventoryReportError.invalidReport(
                L10n.text(
                    "Es müssen ein bis vier Bereiche enthalten sein.",
                    language: report.language
                )
            )
        }
        guard report.totalItemCount <= 40_000 else {
            throw InventoryReportError.tooManyRows
        }
        for section in report.sections {
            guard !section.columns.isEmpty, section.columns.count <= 32 else {
                throw InventoryReportError.tooManyColumns
            }
            guard section.rows.allSatisfy({ $0.values.count == section.columns.count }) else {
                throw InventoryReportError.invalidReport(
                    L10n.text(
                        "Die Tabellenzeilen passen nicht zu ihren Spalten.",
                        language: report.language
                    )
                )
            }
        }
    }

    // MARK: - PDF

    private func writePDF(_ report: InventoryReport, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 841.89, height: 595.28)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw InventoryReportError.cannotCreateDocument
        }

        let renderer = PDFReportRenderer(
            context: context,
            pageRect: mediaBox,
            report: report,
            photoDirectoryURL: layout.currentPhotosDirectoryURL
        )
        try renderer.render()
        context.closePDF()
    }

    private func validatePDF(at url: URL) throws {
        let prefix = try Data(contentsOf: url, options: [.mappedIfSafe]).prefix(5)
        guard String(decoding: prefix, as: UTF8.self) == "%PDF-" else {
            throw InventoryReportError.validationFailed(
                L10n.text("PDF-Signatur fehlt.")
            )
        }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw InventoryReportError.validationFailed(
                L10n.text("Das PDF enthält keine lesbare Seite.")
            )
        }
        let firstPageText = document.page(at: 0)?.string ?? ""
        guard firstPageText.contains("Keyboard Manager") else {
            throw InventoryReportError.validationFailed(
                L10n.text("Das PDF-Deckblatt konnte nicht gelesen werden.")
            )
        }
    }

    // MARK: - XLSX

    private func writeXLSX(_ report: InventoryReport, to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        var entries: [(String, String)] = [
            ("[Content_Types].xml", contentTypesXML(sectionCount: report.sections.count)),
            ("_rels/.rels", packageRelationshipsXML),
            ("docProps/app.xml", appPropertiesXML(sheetCount: report.sections.count + 1)),
            ("docProps/core.xml", corePropertiesXML(createdAt: report.createdAt)),
            ("xl/workbook.xml", workbookXML(report: report)),
            ("xl/_rels/workbook.xml.rels", workbookRelationshipsXML(sectionCount: report.sections.count)),
            ("xl/styles.xml", stylesXML)
        ]

        entries.append(("xl/worksheets/sheet1.xml", summarySheetXML(report)))
        for (index, section) in report.sections.enumerated() {
            let sheetNumber = index + 2
            let sheet = sectionSheetXML(section, language: report.language)
            entries.append(("xl/worksheets/sheet\(sheetNumber).xml", sheet.xml))
            if !sheet.relationships.isEmpty {
                entries.append((
                    "xl/worksheets/_rels/sheet\(sheetNumber).xml.rels",
                    relationshipsXML(sheet.relationships)
                ))
            }
        }
        for (path, xml) in entries {
            try add(Data(xml.utf8), at: path, to: archive)
        }
    }

    private func validateXLSX(at url: URL, expectedSheetCount: Int) throws {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw InventoryReportError.validationFailed(
                L10n.text("Die Excel-Datei ist kein lesbares ZIP-Paket.")
            )
        }
        let paths = Set(archive.map(\.path))
        let required = [
            "[Content_Types].xml", "xl/workbook.xml", "xl/styles.xml",
            "xl/worksheets/sheet1.xml"
        ]
        guard required.allSatisfy(paths.contains) else {
            throw InventoryReportError.validationFailed(
                L10n.text("Im Excel-Paket fehlen Pflichtdateien.")
            )
        }
        guard (1...expectedSheetCount).allSatisfy({
            paths.contains("xl/worksheets/sheet\($0).xml")
        }) else {
            throw InventoryReportError.validationFailed(
                L10n.text("Nicht alle Tabellenblätter wurden geschrieben.")
            )
        }
    }

    private func summarySheetXML(_ report: InventoryReport) -> String {
        var rows: [String] = []
        rows.append(rowXML(1, cells: [
            stringCell("A1", L10n.text("Keyboard Manager Bestand", language: report.language), style: 1)
        ]))
        rows.append(rowXML(2, cells: [
            stringCell(
                "A2",
                L10n.text("Übersicht des exportierten Bestands", language: report.language),
                style: 2
            )
        ]))
        rows.append(rowXML(4, cells: [
            stringCell("A4", L10n.text("Erstellt", language: report.language), style: 3),
            stringCell("B4", reportDateTime(report.createdAt, language: report.language), style: 4)
        ]))
        rows.append(rowXML(5, cells: [
            stringCell("A5", "App-Version", style: 3),
            stringCell("B5", report.appVersion, style: 5)
        ]))
        rows.append(rowXML(6, cells: [
            stringCell("A6", L10n.text("Umfang", language: report.language), style: 3),
            stringCell("B6", report.scope.title(language: report.language), style: 4)
        ]))
        rows.append(rowXML(7, cells: [
            stringCell("A7", L10n.text("Filter", language: report.language), style: 3),
            stringCell(
                "B7",
                L10n.text(
                    report.appliesFilters ? "Angewendet" : "Nicht angewendet",
                    language: report.language
                ),
                style: 5
            )
        ]))
        rows.append(rowXML(9, cells: [
            stringCell("A9", L10n.text("Bereich", language: report.language), style: 3),
            stringCell("B9", L10n.text("Einträge", language: report.language), style: 3),
            stringCell("C9", L10n.text("Filter", language: report.language), style: 3)
        ]))
        for (offset, section) in report.sections.enumerated() {
            let row = 10 + offset
            rows.append(rowXML(row, cells: [
                stringCell("A\(row)", section.title, style: offset.isMultiple(of: 2) ? 4 : 5),
                numberCell("B\(row)", Double(section.rows.count), style: 8),
                stringCell("C\(row)", section.filterDescription, style: offset.isMultiple(of: 2) ? 4 : 5)
            ]))
        }
        let totalRow = 11 + report.sections.count
        rows.append(rowXML(totalRow, cells: [
            stringCell("A\(totalRow)", L10n.text("Gesamt", language: report.language), style: 3),
            numberCell("B\(totalRow)", Double(report.totalItemCount), style: 3)
        ]))
        return worksheetXML(
            columns: [("A", 24), ("B", 18), ("C", 62)],
            rows: rows,
            mergeRefs: ["A1:C1", "A2:C2"],
            autoFilter: nil,
            freezeRows: nil,
            hyperlinks: []
        )
    }

    private func sectionSheetXML(
        _ section: InventoryReportSection,
        language: String
    ) -> (
        xml: String,
        relationships: [(id: String, target: String)]
    ) {
        let lastColumn = columnName(section.columns.count)
        var rows = [
            rowXML(1, cells: [stringCell("A1", section.title, style: 1)]),
            rowXML(2, cells: [
                stringCell(
                    "A2",
                    L10n.text(
                        "%lld Einträge · Filter: %@",
                        language: language,
                        arguments: section.rows.count,
                        section.filterDescription
                    ),
                    style: 2
                )
            ])
        ]
        rows.append(rowXML(4, cells: section.columns.enumerated().map { index, column in
            stringCell("\(columnName(index + 1))4", column.title, style: 3)
        }))

        var hyperlinks: [(ref: String, id: String)] = []
        var relationships: [(id: String, target: String)] = []
        for (rowOffset, reportRow) in section.rows.enumerated() {
            let rowNumber = rowOffset + 5
            let baseStyle = rowOffset.isMultiple(of: 2) ? 4 : 5
            let cells = reportRow.values.enumerated().map { columnIndex, value in
                let ref = "\(columnName(columnIndex + 1))\(rowNumber)"
                switch value {
                case let .text(text):
                    return stringCell(ref, text, style: baseStyle)
                case let .number(number):
                    return numberCell(ref, Double(number), style: baseStyle)
                case let .date(date):
                    return numberCell(ref, excelSerial(date), style: 6)
                case let .url(url):
                    guard isHTTPSURL(url) else {
                        return stringCell(ref, url, style: baseStyle)
                    }
                    let id = "rId\(relationships.count + 1)"
                    hyperlinks.append((ref, id))
                    relationships.append((id, url))
                    return stringCell(ref, url, style: 7)
                }
            }
            rows.append(rowXML(rowNumber, cells: cells))
        }

        return (
            worksheetXML(
                columns: section.columns.enumerated().map {
                    (columnName($0.offset + 1), $0.element.width)
                },
                rows: rows,
                mergeRefs: ["A1:\(lastColumn)1", "A2:\(lastColumn)2"],
                autoFilter: "A4:\(lastColumn)\(max(4, section.rows.count + 4))",
                freezeRows: 4,
                hyperlinks: hyperlinks
            ),
            relationships
        )
    }

    private func worksheetXML(
        columns: [(String, Double)],
        rows: [String],
        mergeRefs: [String],
        autoFilter: String?,
        freezeRows: Int?,
        hyperlinks: [(ref: String, id: String)]
    ) -> String {
        let pane = freezeRows.map {
            "<pane ySplit=\"\($0)\" topLeftCell=\"A\($0 + 1)\" activePane=\"bottomLeft\" state=\"frozen\"/>"
        } ?? ""
        let cols = columns.enumerated().map { index, column in
            "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(column.1)\" customWidth=\"1\"/>"
        }.joined()
        let merges = mergeRefs.isEmpty ? "" :
            "<mergeCells count=\"\(mergeRefs.count)\">"
            + mergeRefs.map { "<mergeCell ref=\"\($0)\"/>" }.joined()
            + "</mergeCells>"
        let filter = autoFilter.map { "<autoFilter ref=\"\(xmlEscape($0))\"/>" } ?? ""
        let links = hyperlinks.isEmpty ? "" :
            "<hyperlinks>"
            + hyperlinks.map {
                "<hyperlink ref=\"\(xmlEscape($0.ref))\" r:id=\"\($0.id)\"/>"
            }.joined()
            + "</hyperlinks>"
        return xmlHeader
            + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            + "<sheetViews><sheetView showGridLines=\"0\" workbookViewId=\"0\">\(pane)</sheetView></sheetViews>"
            + "<cols>\(cols)</cols><sheetData>\(rows.joined())</sheetData>"
            + "\(merges)\(filter)\(links)"
            + "<pageMargins left=\"0.25\" right=\"0.25\" top=\"0.5\" bottom=\"0.5\" header=\"0.2\" footer=\"0.2\"/>"
            + "<pageSetup orientation=\"landscape\" fitToWidth=\"1\" fitToHeight=\"0\"/>"
            + "<headerFooter><oddFooter>&amp;LKeyboard Manager V2&amp;RSeite &amp;P / &amp;N</oddFooter></headerFooter>"
            + "</worksheet>"
    }

    private func workbookXML(report: InventoryReport) -> String {
        let names = [L10n.text("Übersicht", language: report.language)] + report.sections.map(\.title)
        let sheets = names.enumerated().map { index, name in
            "<sheet name=\"\(xmlEscape(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return xmlHeader
            + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            + "<bookViews><workbookView/></bookViews><sheets>\(sheets)</sheets>"
            + "<calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>"
    }

    private func workbookRelationshipsXML(sectionCount: Int) -> String {
        var relationships = (1...(sectionCount + 1)).map { index in
            "<Relationship Id=\"rId\(index)\" "
            + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" "
            + "Target=\"worksheets/sheet\(index).xml\"/>"
        }
        relationships.append(
            "<Relationship Id=\"rId\(sectionCount + 2)\" "
            + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" "
            + "Target=\"styles.xml\"/>"
        )
        return relationshipsDocument(relationships)
    }

    private func relationshipsXML(_ relationships: [(id: String, target: String)]) -> String {
        relationshipsDocument(relationships.map {
            "<Relationship Id=\"\($0.id)\" "
            + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" "
            + "Target=\"\(xmlEscape($0.target))\" TargetMode=\"External\"/>"
        })
    }

    private func relationshipsDocument(_ relationships: [String]) -> String {
        xmlHeader
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + relationships.joined()
            + "</Relationships>"
    }

    private func contentTypesXML(sectionCount: Int) -> String {
        let sheets = (1...(sectionCount + 1)).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" "
            + "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return xmlHeader
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
            + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
            + "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
            + sheets + "</Types>"
    }

    private func corePropertiesXML(createdAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return xmlHeader
            + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:dcterms=\"http://purl.org/dc/terms/\" "
            + "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + "<dc:title>Keyboard Manager Bestand</dc:title><dc:creator>Keyboard Manager V2</dc:creator>"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(formatter.string(from: createdAt))</dcterms:created>"
            + "</cp:coreProperties>"
    }

    private func appPropertiesXML(sheetCount: Int) -> String {
        xmlHeader
            + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" "
            + "xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
            + "<Application>Keyboard Manager V2</Application><Sheets>\(sheetCount)</Sheets></Properties>"
    }

    private var packageRelationshipsXML: String {
        relationshipsDocument([
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>",
            "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>",
            "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
        ])
    }

    private var stylesXML: String {
        xmlHeader
            + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"dd.mm.yyyy hh:mm\"/></numFmts>"
            + "<fonts count=\"5\">"
            + "<font><sz val=\"11\"/><name val=\"Aptos\"/></font>"
            + "<font><b/><color rgb=\"FFFFFFFF\"/><sz val=\"16\"/><name val=\"Aptos Display\"/></font>"
            + "<font><i/><color rgb=\"FF536170\"/><sz val=\"10\"/><name val=\"Aptos\"/></font>"
            + "<font><b/><color rgb=\"FFFFFFFF\"/><sz val=\"11\"/><name val=\"Aptos\"/></font>"
            + "<font><u/><color rgb=\"FF0563C1\"/><sz val=\"11\"/><name val=\"Aptos\"/></font>"
            + "</fonts>"
            + "<fills count=\"5\"><fill><patternFill patternType=\"none\"/></fill>"
            + "<fill><patternFill patternType=\"gray125\"/></fill>"
            + "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF102B46\"/><bgColor indexed=\"64\"/></patternFill></fill>"
            + "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF147FEA\"/><bgColor indexed=\"64\"/></patternFill></fill>"
            + "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFEAF2F8\"/><bgColor indexed=\"64\"/></patternFill></fill>"
            + "</fills>"
            + "<borders count=\"2\"><border/><border><left/><right/><top/>"
            + "<bottom style=\"thin\"><color rgb=\"FFD4DFE8\"/></bottom><diagonal/></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"9\">"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
            + "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\" applyAlignment=\"1\"><alignment vertical=\"center\"/></xf>"
            + "<xf numFmtId=\"0\" fontId=\"2\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
            + "<xf numFmtId=\"0\" fontId=\"3\" fillId=\"3\" borderId=\"1\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\" applyAlignment=\"1\"><alignment wrapText=\"1\"/></xf>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyBorder=\"1\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"4\" borderId=\"1\" xfId=\"0\" applyFill=\"1\" applyBorder=\"1\" applyAlignment=\"1\"><alignment vertical=\"top\" wrapText=\"1\"/></xf>"
            + "<xf numFmtId=\"22\" fontId=\"0\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyNumberFormat=\"1\" applyBorder=\"1\"/>"
            + "<xf numFmtId=\"0\" fontId=\"4\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyBorder=\"1\" applyFont=\"1\"><alignment wrapText=\"1\"/></xf>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyBorder=\"1\" applyAlignment=\"1\"><alignment horizontal=\"center\" vertical=\"top\"/></xf>"
            + "</cellXfs>"
            + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
            + "</styleSheet>"
    }

    private func rowXML(_ number: Int, cells: [String]) -> String {
        "<row r=\"\(number)\">\(cells.joined())</row>"
    }

    private func stringCell(_ ref: String, _ value: String, style: Int) -> String {
        "<c r=\"\(ref)\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">"
            + xmlEscape(String(value.prefix(20_000)))
            + "</t></is></c>"
    }

    private func numberCell(_ ref: String, _ value: Double, style: Int) -> String {
        "<c r=\"\(ref)\" s=\"\(style)\"><v>\(decimal(value))</v></c>"
    }

    private func excelSerial(_ date: Date) -> Double {
        let localOffset = TimeZone.current.secondsFromGMT(for: date)
        return (
            date.timeIntervalSince(Date(timeIntervalSince1970: -2_209_161_600))
            + Double(localOffset)
        ) / 86_400
    }

    private func decimal(_ value: Double) -> String {
        String(format: "%.10g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func columnName(_ number: Int) -> String {
        var number = number
        var result = ""
        while number > 0 {
            number -= 1
            result = String(UnicodeScalar(65 + number % 26)!) + result
            number /= 26
        }
        return result
    }

    private func isHTTPSURL(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return false }
        return url.host != nil
    }

    private var xmlHeader: String { "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func add(_ data: Data, at path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            modificationDate: Date(timeIntervalSince1970: 315_532_800),
            permissions: 0o644,
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private func install(from partialURL: URL, at destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: partialURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: partialURL, to: destinationURL)
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
}

private final class PDFReportRenderer {
    private let context: CGContext
    private let pageRect: CGRect
    private let report: InventoryReport
    private let photoDirectoryURL: URL
    private let margin: CGFloat = 34
    private var pageNumber = 0
    private var imageCount = 0

    init(
        context: CGContext,
        pageRect: CGRect,
        report: InventoryReport,
        photoDirectoryURL: URL
    ) {
        self.context = context
        self.pageRect = pageRect
        self.report = report
        self.photoDirectoryURL = photoDirectoryURL
    }

    func render() throws {
        beginPage()
        drawCover()
        endPage()

        for section in report.sections {
            var rowIndex = 0
            repeat {
                beginPage()
                var y = drawSectionHeader(section)
                y = drawTableHeader(section, at: y)
                while rowIndex < section.rows.count {
                    let row = section.rows[rowIndex]
                    let hasImage = report.includesImages
                        && imageCount < 200
                        && row.mainPhotoID.flatMap { report.photosByID[$0] } != nil
                    let height: CGFloat = hasImage ? 40 : 25
                    guard y + height <= pageRect.height - margin - 24 else { break }
                    drawRow(row, section: section, y: y, height: height, shaded: rowIndex.isMultiple(of: 2))
                    y += height
                    rowIndex += 1
                }
                if section.rows.isEmpty {
                    drawText(
                        L10n.text("Keine Einträge in diesem Bereich.", language: report.language),
                        rect: CGRect(x: margin, y: y + 10, width: pageRect.width - 2 * margin, height: 30),
                        font: .systemFont(ofSize: 11),
                        color: mutedInk
                    )
                    rowIndex = 1
                }
                endPage()
            } while rowIndex < section.rows.count
        }
    }

    private func beginPage() {
        pageNumber += 1
        context.beginPDFPage(nil)
        context.saveGState()
        context.translateBy(x: 0, y: pageRect.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSColor.white.setFill()
        pageRect.fill()
    }

    private func endPage() {
        drawText(
            "Keyboard Manager V2",
            rect: CGRect(x: margin, y: pageRect.height - 25, width: 250, height: 14),
            font: .systemFont(ofSize: 8),
            color: mutedInk
        )
        drawText(
            L10n.text("Seite %lld", language: report.language, arguments: pageNumber),
            rect: CGRect(x: pageRect.width - margin - 100, y: pageRect.height - 25, width: 100, height: 14),
            font: .monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            color: mutedInk,
            alignment: .right
        )
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        context.endPDFPage()
    }

    private func drawCover() {
        NSColor(calibratedRed: 16 / 255, green: 43 / 255, blue: 70 / 255, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: pageRect.width, height: 178).fill()
        drawText(
            "Keyboard Manager",
            rect: CGRect(x: margin, y: 45, width: 600, height: 45),
            font: .systemFont(ofSize: 34, weight: .bold),
            color: .white
        )
        drawText(
            L10n.text("Bestandsbericht", language: report.language),
            rect: CGRect(x: margin, y: 98, width: 600, height: 36),
            font: .systemFont(ofSize: 24, weight: .medium),
            color: .white.withAlphaComponent(0.88)
        )
        let metadata = [
            (
                L10n.text("Erstellt", language: report.language),
                reportDateTime(report.createdAt, language: report.language)
            ),
            ("App-Version", report.appVersion),
            (
                L10n.text("Umfang", language: report.language),
                report.scope.title(language: report.language)
            ),
            (
                L10n.text("Filter", language: report.language),
                L10n.text(
                    report.appliesFilters ? "Angewendet" : "Nicht angewendet",
                    language: report.language
                )
            )
        ]
        for (index, item) in metadata.enumerated() {
            let y = 215 + CGFloat(index * 33)
            drawText(item.0, rect: CGRect(x: margin, y: y, width: 120, height: 22),
                     font: .systemFont(ofSize: 10, weight: .semibold), color: mutedInk)
            drawText(item.1, rect: CGRect(x: margin + 125, y: y, width: 500, height: 22),
                     font: .systemFont(ofSize: 11), color: ink)
        }
        drawText(
            L10n.text(
                "%lld Einträge",
                language: report.language,
                arguments: report.totalItemCount
            ),
            rect: CGRect(x: margin, y: 372, width: 260, height: 42),
            font: .systemFont(ofSize: 28, weight: .semibold),
            color: NSColor(calibratedRed: 20 / 255, green: 127 / 255, blue: 234 / 255, alpha: 1)
        )
        for (index, section) in report.sections.enumerated() {
            let x = margin + CGFloat(index % 2) * 310
            let y = 430 + CGFloat(index / 2) * 42
            drawText(
                "\(section.title): \(section.rows.count)",
                rect: CGRect(x: x, y: y, width: 290, height: 24),
                font: .systemFont(ofSize: 12, weight: .medium),
                color: ink
            )
        }
    }

    private func drawSectionHeader(_ section: InventoryReportSection) -> CGFloat {
        drawText(
            section.title,
            rect: CGRect(x: margin, y: 24, width: 500, height: 34),
            font: .systemFont(ofSize: 24, weight: .bold),
            color: ink
        )
        drawText(
            L10n.text(
                "%lld Einträge · %@",
                language: report.language,
                arguments: section.rows.count,
                section.filterDescription
            ),
            rect: CGRect(x: margin, y: 59, width: pageRect.width - 2 * margin, height: 18),
            font: .systemFont(ofSize: 9),
            color: mutedInk
        )
        return 87
    }

    private func drawTableHeader(_ section: InventoryReportSection, at y: CGFloat) -> CGFloat {
        let columns = pdfColumns(section)
        let imageWidth: CGFloat = report.includesImages ? 47 : 0
        NSColor(calibratedRed: 20 / 255, green: 127 / 255, blue: 234 / 255, alpha: 1).setFill()
        CGRect(x: margin, y: y, width: pageRect.width - 2 * margin, height: 27).fill()
        var x = margin + imageWidth
        if report.includesImages {
            drawText(
                L10n.text("Foto", language: report.language),
                rect: CGRect(x: margin + 4, y: y + 7, width: 39, height: 14),
                     font: .systemFont(ofSize: 8, weight: .semibold), color: .white)
        }
        for column in columns {
            drawText(column.title, rect: CGRect(x: x + 4, y: y + 7, width: column.renderWidth - 8, height: 14),
                     font: .systemFont(ofSize: 8, weight: .semibold), color: .white)
            x += column.renderWidth
        }
        return y + 27
    }

    private func drawRow(
        _ row: InventoryReportRow,
        section: InventoryReportSection,
        y: CGFloat,
        height: CGFloat,
        shaded: Bool
    ) {
        if shaded {
            NSColor(calibratedRed: 234 / 255, green: 242 / 255, blue: 248 / 255, alpha: 1).setFill()
            CGRect(x: margin, y: y, width: pageRect.width - 2 * margin, height: height).fill()
        }
        let columns = pdfColumns(section)
        let imageWidth: CGFloat = report.includesImages ? 47 : 0
        if report.includesImages,
           imageCount < 200,
           let photoID = row.mainPhotoID,
           let photo = report.photosByID[photoID] {
            if let fileName = photo.managedFileName,
               let image = NSImage(contentsOf: photoDirectoryURL.appendingPathComponent(fileName)) {
                image.draw(
                    in: CGRect(x: margin + 4, y: y + 3, width: 39, height: height - 6),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
                imageCount += 1
            }
        }
        var x = margin + imageWidth
        for column in columns {
            let value = row.values[column.index].displayText(language: report.language)
            drawText(
                value,
                rect: CGRect(x: x + 4, y: y + 5, width: column.renderWidth - 8, height: height - 8),
                font: .systemFont(ofSize: 7.5),
                color: ink
            )
            x += column.renderWidth
        }
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        CGRect(x: margin, y: y + height - 0.5, width: pageRect.width - 2 * margin, height: 0.5).fill()
    }

    private func pdfColumns(_ section: InventoryReportSection) -> [
        (index: Int, title: String, renderWidth: CGFloat)
    ] {
        let selected = section.columns.enumerated().filter(\.element.isPDFVisible)
        let available = pageRect.width - 2 * margin - (report.includesImages ? 47 : 0)
        let total = selected.reduce(0) { $0 + $1.element.width }
        return selected.map {
            ($0.offset, $0.element.title, available * CGFloat($0.element.width / total))
        }
    }

    private func drawText(
        _ text: String,
        rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        ).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private var ink: NSColor {
        NSColor(calibratedWhite: 0.12, alpha: 1)
    }

    private var mutedInk: NSColor {
        NSColor(calibratedWhite: 0.38, alpha: 1)
    }
}

private func reportDateTime(_ date: Date, language: String) -> String {
    let formatter = DateFormatter()
    let selected = AppLanguage.normalized(language)
    formatter.locale = selected.locale
    formatter.dateFormat = selected == .english ? "dd/MM/yyyy, HH:mm" : "dd.MM.yyyy, HH:mm"
    return formatter.string(from: date)
}
