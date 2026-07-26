import AppKit
import Foundation
import SQLite3

enum V1SourceDiscoveryError: LocalizedError, Sendable {
    case v1IsRunning

    var errorDescription: String? {
        switch self {
        case .v1IsRunning:
            L10n.text("Keyboard Manager V1 ist noch geöffnet. Bitte V1 vollständig beenden und die Suche erneut ausführen.")
        }
    }
}

struct V1DiscoveredSource: Equatable, Identifiable, Sendable {
    var directoryURL: URL
    var databaseByteCount: Int64
    var databaseModifiedAt: Date?
    var hasWriteAheadLog: Bool
    var hasPhotosDirectory: Bool
    var isSchemaVerified: Bool

    var id: String { directoryURL.standardizedFileURL.path }
}

struct V1SourceDiscoveryResult: Equatable, Sendable {
    var source: V1DiscoveredSource?
    var isV1Running: Bool
    var searchedCandidateCount: Int
}

enum V1SourceDiscoveryState: Equatable, Sendable {
    case idle
    case scanning
    case notFound(searchedCandidateCount: Int)
    case found(V1DiscoveredSource)
    case blocked(V1DiscoveredSource, reason: String)
    case failed(String)
}

struct V1ProcessDetector: Sendable {
    static let v1BundleIdentifier = "com.keyboard.manager"

    private let lookup: @Sendable () async -> Bool

    init(
        lookup: @escaping @Sendable () async -> Bool = {
            await MainActor.run {
                !NSRunningApplication.runningApplications(
                    withBundleIdentifier: V1ProcessDetector.v1BundleIdentifier
                ).isEmpty
            }
        }
    ) {
        self.lookup = lookup
    }

    func isV1Running() async -> Bool {
        await lookup()
    }
}

struct V1SourceDiscoveryService: Sendable {
    private static let candidateDirectoryNames = [
        "keyboard-manager",
        "Keyboard Manager",
        "com.keyboard.manager"
    ]
    private static let databaseFileName = "keyboard-manager.sqlite"
    private static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)
    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private let applicationSupportRoots: @Sendable () -> [URL]
    private let processDetector: V1ProcessDetector

    init(
        applicationSupportRoots: @escaping @Sendable () -> [URL] = {
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )
        },
        processDetector: V1ProcessDetector = V1ProcessDetector()
    ) {
        self.applicationSupportRoots = applicationSupportRoots
        self.processDetector = processDetector
    }

    func discoverInstalledSource() async throws -> V1SourceDiscoveryResult {
        let isV1Running = await processDetector.isV1Running()
        let candidates = candidateURLs()
        let source = try await Task.detached(priority: .userInitiated) {
            try Self.firstValidSource(
                among: candidates,
                verifySchema: !isV1Running
            )
        }.value
        return V1SourceDiscoveryResult(
            source: source,
            isV1Running: isV1Running,
            searchedCandidateCount: candidates.count
        )
    }

    func isV1Running() async -> Bool {
        await processDetector.isV1Running()
    }

    private func candidateURLs() -> [URL] {
        var seenPaths: Set<String> = []
        var candidates: [URL] = []
        for root in applicationSupportRoots() {
            for name in Self.candidateDirectoryNames {
                let candidate = root
                    .appendingPathComponent(name, isDirectory: true)
                    .standardizedFileURL
                if seenPaths.insert(candidate.path).inserted {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    private static func firstValidSource(
        among candidates: [URL],
        verifySchema: Bool
    ) throws -> V1DiscoveredSource? {
        for candidate in candidates {
            guard let source = try basicSource(at: candidate) else { continue }
            if !verifySchema {
                var discoveredSource = source
                discoveredSource.isSchemaVerified = false
                return discoveredSource
            }
            guard try stagedCopyHasV1Schema(sourceDirectoryURL: candidate) else {
                continue
            }
            var discoveredSource = source
            discoveredSource.isSchemaVerified = true
            return discoveredSource
        }
        return nil
    }

    private static func basicSource(at directoryURL: URL) throws -> V1DiscoveredSource? {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return nil
        }
        let directoryValues = try directoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            return nil
        }

        let databaseURL = directoryURL.appendingPathComponent(databaseFileName)
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              try isSafeRegularFile(databaseURL),
              try hasSQLiteHeader(databaseURL) else {
            return nil
        }

        var byteCount: Int64 = 0
        var latestModificationDate: Date?
        var hasWriteAheadLog = false
        for (index, url) in databaseFamilyURLs(databaseURL).enumerated() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard try isSafeRegularFile(url) else { return nil }
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            byteCount += Int64(values.fileSize ?? 0)
            if let date = values.contentModificationDate {
                latestModificationDate = max(latestModificationDate ?? date, date)
            }
            if index == 1 {
                hasWriteAheadLog = true
            }
        }

        let photosURL = directoryURL.appendingPathComponent("photos", isDirectory: true)
        let hasPhotosDirectory: Bool
        if FileManager.default.fileExists(atPath: photosURL.path) {
            let values = try photosURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                return nil
            }
            hasPhotosDirectory = true
        } else {
            hasPhotosDirectory = false
        }

        return V1DiscoveredSource(
            directoryURL: directoryURL,
            databaseByteCount: byteCount,
            databaseModifiedAt: latestModificationDate,
            hasWriteAheadLog: hasWriteAheadLog,
            hasPhotosDirectory: hasPhotosDirectory,
            isSchemaVerified: false
        )
    }

    private static func stagedCopyHasV1Schema(sourceDirectoryURL: URL) throws -> Bool {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerDiscovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let sourceDatabaseURL = sourceDirectoryURL.appendingPathComponent(databaseFileName)
        let stagedDatabaseURL = temporaryDirectoryURL.appendingPathComponent(databaseFileName)
        for (index, sourceURL) in databaseFamilyURLs(sourceDatabaseURL).enumerated() {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
            let destinationURL: URL
            switch index {
            case 1:
                destinationURL = URL(fileURLWithPath: stagedDatabaseURL.path + "-wal")
            case 2:
                destinationURL = URL(fileURLWithPath: stagedDatabaseURL.path + "-shm")
            default:
                destinationURL = stagedDatabaseURL
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            stagedDatabaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }

        let requiredTables = [
            "app_meta",
            "boards",
            "keycap_sets",
            "artisan_sets",
            "switch_sets",
            "photos"
        ]
        for table in requiredTables where !tableExists(table, in: database) {
            return false
        }
        return appMetadataExists(in: database)
    }

    private static func tableExists(_ table: String, in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func appMetadataExists(in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM app_meta WHERE key = 'app' LIMIT 1;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func databaseFamilyURLs(_ databaseURL: URL) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
    }

    private static func isSafeRegularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func hasSQLiteHeader(_ databaseURL: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: databaseURL)
        defer { try? handle.close() }
        return try handle.read(upToCount: sqliteHeader.count) == sqliteHeader
    }
}
