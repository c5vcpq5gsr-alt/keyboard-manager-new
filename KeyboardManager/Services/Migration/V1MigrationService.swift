import Foundation

enum MigrationSourceKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case zipBackup
    case sqliteDirectory
    case legacyJSON
    case webStorageExport

    var id: Self { self }

    var priority: Int {
        switch self {
        case .zipBackup: 0
        case .sqliteDirectory: 1
        case .legacyJSON: 2
        case .webStorageExport: 3
        }
    }

    var displayName: String {
        switch self {
        case .zipBackup: L10n.text("V1-ZIP-Backup (empfohlen)")
        case .sqliteDirectory: L10n.text("Installierte V1-Datenbank")
        case .legacyJSON: L10n.text("Legacy-JSON-Backup")
        case .webStorageExport: L10n.text("IndexedDB/localStorage-Export")
        }
    }

    var detail: String {
        switch self {
        case .zipBackup: L10n.text("V1-Schema 3–6 mit Manifest und separaten Fotos")
        case .sqliteDirectory: "keyboard-manager.sqlite plus photos/"
        case .legacyJSON: L10n.text("Älteres Vollbackup mit eingebetteten Fotos")
        case .webStorageExport: L10n.text("Sonderpfad für sehr alte Installationen")
        }
    }

    var isReadOnly: Bool { true }
}

struct MigrationSource: Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: MigrationSourceKind
    var url: URL?
}

enum MigrationReadiness: Equatable, Sendable {
    case notScanned
    case scanning
    case ready(sourceCount: Int)
    case blocked(reason: String)

    var title: String {
        switch self {
        case .notScanned: L10n.text("Noch keine Quelle ausgewählt")
        case .scanning: L10n.text("V1-Quelle wird geprüft")
        case let .ready(sourceCount):
            L10n.text("%lld Quelle(n) bereit", arguments: sourceCount)
        case .blocked: L10n.text("Migration blockiert")
        }
    }
}

struct V1MigrationService: Sendable {
    private let discoveryService: V1SourceDiscoveryService

    init(
        discoveryService: V1SourceDiscoveryService = V1SourceDiscoveryService()
    ) {
        self.discoveryService = discoveryService
    }

    static var supportedSourcesByPriority: [MigrationSourceKind] {
        MigrationSourceKind.allCases.sorted { $0.priority < $1.priority }
    }

    func readiness(for sources: [MigrationSource]) -> MigrationReadiness {
        sources.isEmpty ? .notScanned : .ready(sourceCount: sources.count)
    }

    func discoverInstalledSource() async throws -> V1SourceDiscoveryResult {
        try await discoveryService.discoverInstalledSource()
    }

    func isV1Running() async -> Bool {
        await discoveryService.isV1Running()
    }

    func inspectSource(at url: URL) async throws -> MigrationDryRunResult {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let isRunning = await isV1Running()
            guard !isRunning else {
                throw V1SourceDiscoveryError.v1IsRunning
            }
            let result = try await V1SQLiteSourceReader().inspect(at: url)
            let isRunningAfterInspection = await isV1Running()
            guard !isRunningAfterInspection else {
                throw V1SourceDiscoveryError.v1IsRunning
            }
            return result
        }

        switch url.pathExtension.lowercased() {
        case "zip":
            return try await V1BackupReader().inspect(at: url)
        case "json":
            return try await V1LegacyJSONReader().inspect(at: url)
        default:
            throw V1BackupReaderError.unsupportedSource
        }
    }
}
