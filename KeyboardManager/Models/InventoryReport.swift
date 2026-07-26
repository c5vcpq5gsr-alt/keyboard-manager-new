import Foundation

enum InventoryReportFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf
    case xlsx

    var id: Self { self }

    var title: String {
        return switch self {
        case .pdf: "PDF"
        case .xlsx: "Excel (.xlsx)"
        }
    }

    var fileExtension: String { rawValue }
}

enum InventoryReportScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case current

    var id: Self { self }

    var title: String {
        title()
    }

    func title(language: String? = nil) -> String {
        switch self {
        case .all: L10n.text("Gesamter Bestand", language: language)
        case .current: L10n.text("Aktueller Inventartyp", language: language)
        }
    }
}

struct InventoryReportOptions: Equatable, Sendable {
    var format: InventoryReportFormat = .pdf
    var scope: InventoryReportScope = .all
    var appliesFilters = true
    var includesImages = true
}

struct InventoryReportContext: Sendable {
    var currentKind: InventoryItemKind
    var filtersByKind: [InventoryItemKind: InventoryFilters]
    var sortsByKind: [InventoryItemKind: InventorySort]
}

enum InventoryReportValue: Equatable, Sendable {
    case text(String)
    case number(Int)
    case date(Date)
    case url(String)

    var displayText: String {
        displayText(language: AppLanguage.current.rawValue)
    }

    func displayText(language: String) -> String {
        let locale = AppLanguage.normalized(language).locale
        return switch self {
        case let .text(value), let .url(value):
            value
        case let .number(value):
            value.formatted(.number.locale(locale))
        case let .date(value):
            value.formatted(
                Date.FormatStyle(date: .numeric, time: .shortened, locale: locale)
            )
        }
    }
}

struct InventoryReportColumn: Equatable, Sendable {
    var title: String
    var width: Double
    var isPDFVisible: Bool
}

struct InventoryReportRow: Equatable, Sendable {
    var id: String
    var values: [InventoryReportValue]
    var mainPhotoID: String?
}

struct InventoryReportSection: Equatable, Sendable {
    var kind: InventoryItemKind
    var title: String
    var columns: [InventoryReportColumn]
    var rows: [InventoryReportRow]
    var filterDescription: String
}

struct InventoryReport: Equatable, Sendable {
    var language: String
    var createdAt: Date
    var appVersion: String
    var scope: InventoryReportScope
    var appliesFilters: Bool
    var includesImages: Bool
    var sections: [InventoryReportSection]
    var photosByID: [String: PhotoRecord]

    var totalItemCount: Int {
        sections.reduce(0) { $0 + $1.rows.count }
    }
}

struct InventoryReportExportResult: Equatable, Sendable {
    var destinationURL: URL
    var format: InventoryReportFormat
    var byteCount: Int64
    var sectionCount: Int
    var itemCount: Int
}

enum InventoryReportExportState: Equatable, Sendable {
    case idle
    case exporting(InventoryReportFormat)
    case succeeded(InventoryReportExportResult)
    case failed(String)
}

enum InventoryReportError: LocalizedError, Sendable {
    case invalidDestination
    case tooManyRows
    case tooManyColumns
    case invalidReport(String)
    case cannotCreateDocument
    case cannotReadPhoto(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            L10n.text("Das gewählte Berichtsziel ist ungültig.")
        case .tooManyRows:
            L10n.text("Der Bericht überschreitet das Limit von 40.000 Zeilen.")
        case .tooManyColumns:
            L10n.text("Eine Berichtstabelle überschreitet das Limit von 32 Spalten.")
        case let .invalidReport(message):
            L10n.text("Der Bericht enthält ungültige Daten: %@", arguments: message)
        case .cannotCreateDocument:
            L10n.text("Das Berichtsdokument konnte nicht erzeugt werden.")
        case let .cannotReadPhoto(name):
            L10n.text(
                "Das Foto „%@“ konnte nicht für den PDF-Bericht gelesen werden.",
                arguments: name
            )
        case let .validationFailed(message):
            L10n.text(
                "Die Kontrollprüfung des Berichts ist fehlgeschlagen: %@",
                arguments: message
            )
        }
    }
}
