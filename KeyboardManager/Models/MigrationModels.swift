import Foundation

enum MigrationIssueSeverity: String, Codable, Hashable, Sendable {
    case warning
    case error
}

struct MigrationIssue: Identifiable, Codable, Hashable, Sendable {
    var code: String
    var severity: MigrationIssueSeverity
    var message: String
    var affectedItems: Int

    var id: String { "\(severity.rawValue):\(code)" }

    var localizedMessage: String {
        switch code {
        case "legacy-zip-schema":
            L10n.text("Ein älteres V1-ZIP-Schema wird kontrolliert auf das aktuelle V2-Modell normalisiert.")
        case "empty-board-name":
            L10n.text("%@ ohne Namen können nicht importiert werden.", arguments: "Boards")
        case "empty-keycap-name":
            L10n.text("%@ ohne Namen können nicht importiert werden.", arguments: "Keycap-Sets")
        case "empty-artisan-name":
            L10n.text("%@ ohne Namen können nicht importiert werden.", arguments: "Artisans")
        case "empty-switch-name":
            L10n.text("%@ ohne Namen können nicht importiert werden.", arguments: "Switches")
        case "photo-dimension-mismatch":
            L10n.text("Dekodierte Bildabmessungen weichen von V1-Metadaten ab.")
        case "photo-mime-mismatch":
            L10n.text("Der dekodierte Bildtyp weicht von V1 ab und wird anhand der Bilddaten normalisiert.")
        case "preserved-v1-import-warnings":
            L10n.text("V1-Importhinweise werden zur späteren Prüfung erhalten.")
        case "missing-photo-reference":
            L10n.text("Inventareinträge referenzieren nicht vorhandene Fotos.")
        case "invalid-main-photo":
            L10n.text("Hauptfotos gehören nicht zur Fotoliste ihres Eintrags.")
        case "missing-keycap-link":
            L10n.text("Boards referenzieren nicht vorhandene Keycap-Sets.")
        case "missing-switch-link":
            L10n.text("Boards referenzieren nicht vorhandene Switch-Sets.")
        case "missing-mounted-board":
            L10n.text("Komponenten referenzieren nicht vorhandene Boards.")
        case "invalid-photo-owner":
            L10n.text("Fotos besitzen keinen gültigen Inventar-Eigentümer.")
        case "one-sided-switch-installation":
            L10n.text("Switch-Installationen werden als kanonische Beziehung übernommen, obwohl die Board-Rückseite fehlt.")
        case "duplicate-switch-installation":
            L10n.text("Doppelte Switch-/Board-Installationen wurden zusammengeführt.")
        case "switch-quantity-conflict":
            L10n.text("Explizite Switch-Installationen gewinnen bei widersprüchlichen Board-Mengen.")
        case "unsafe-external-url":
            L10n.text("Nicht-HTTPS- oder ungültige externe URLs werden nicht übernommen.")
        case "sqlite-readonly-snapshot":
            L10n.text("Die direkte V1-Datenbank wurde ausschließlich lesend in einen konsistenten V2-Staging-Snapshot überführt.")
        case "legacy-json-source":
            L10n.text("Eingebettete Legacy-Fotos werden vor dem Import in getrennte, geprüfte Dateien überführt.")
        default:
            L10n.text(message)
        }
    }
}

struct MigrationDryRunReport: Codable, Hashable, Sendable {
    var sourceKind: MigrationSourceKind
    var sourceFileName: String
    var sourceByteCount: Int64
    var sourceSHA256: String
    var sourceVersion: String
    var schemaVersion: Int
    var counts: InventoryCounts
    var validatedPhotoByteCount: Int64
    var inspectedAt: Date
    var issues: [MigrationIssue]

    var warningCount: Int {
        issues.filter { $0.severity == .warning }.reduce(0) { $0 + $1.affectedItems }
    }

    var errorCount: Int {
        issues.filter { $0.severity == .error }.reduce(0) { $0 + $1.affectedItems }
    }

    var canImport: Bool { errorCount == 0 }
}

struct MigrationPhotoPlan: Codable, Hashable, Sendable {
    var photoID: String
    var sourceEntryPath: String
    var destinationRelativeFileName: String
    var uncompressedByteCount: Int64
    var checksum: UInt32
}

struct MigrationDryRunResult: Sendable {
    var report: MigrationDryRunReport
    var snapshot: InventorySnapshot
    var photoPlans: [MigrationPhotoPlan]
}

enum MigrationInspectionState: Equatable, Sendable {
    case idle
    case inspecting(fileName: String)
    case ready(MigrationDryRunReport)
    case failed(String)
}

struct MigrationCompletionReport: Codable, Hashable, Sendable {
    var migrationID: String
    var sourceKind: MigrationSourceKind
    var sourceFileName: String
    var sourceSHA256: String
    var sourceVersion: String
    var sourceSchemaVersion: Int
    var startedAt: Date
    var completedAt: Date
    var counts: InventoryCounts
    var switchInstallationCount: Int
    var copiedPhotoByteCount: Int64
    var warnings: [MigrationIssue]
    var replacedExistingV2Data: Bool
    var backupDirectoryName: String?
    var databaseIntegrityCheck: String
}

struct MigrationCommitResult: Sendable {
    var snapshot: InventorySnapshot
    var report: MigrationCompletionReport
    var reportURL: URL
    var backupURL: URL?
}

enum MigrationCommitState: Equatable, Sendable {
    case idle
    case committing(fileName: String)
    case succeeded(MigrationCompletionReport)
    case failed(String)
}

enum MigrationCommitFailurePoint: Sendable {
    case afterBackupMove
}
