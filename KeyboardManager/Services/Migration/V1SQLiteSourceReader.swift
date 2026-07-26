import CryptoKit
import Foundation
import SQLite3
import ZIPFoundation

enum V1SQLiteSourceReaderError: LocalizedError, Sendable {
    case sourceIsNotDirectory
    case unsafeSourceDirectory
    case missingDatabase
    case databaseTooLarge
    case databaseOpen(String)
    case databaseBackup(String)
    case databaseIntegrity(String)
    case invalidSchema(String)
    case invalidMetadata
    case invalidEntityRow(String)
    case missingPhotosDirectory
    case unsafePhotoFile(String)
    case photoTooLarge(String)
    case photoDataTooLarge

    var errorDescription: String? {
        switch self {
        case .sourceIsNotDirectory:
            L10n.text("Bitte den V1-Datenordner auswählen, der keyboard-manager.sqlite und photos/ enthält.")
        case .unsafeSourceDirectory:
            L10n.text("Der gewählte V1-Datenordner oder eine benötigte Quelle ist kein regulärer, sicher lesbarer Pfad.")
        case .missingDatabase:
            L10n.text("Im gewählten Ordner fehlt keyboard-manager.sqlite.")
        case .databaseTooLarge:
            L10n.text("Die V1-Datenbank einschließlich WAL überschreitet das Limit von 100 MiB.")
        case let .databaseOpen(message):
            L10n.text("Die V1-Datenbank konnte nicht ausschließlich lesend geöffnet werden: %@", arguments: message)
        case let .databaseBackup(message):
            L10n.text(
                "Die V1-Datenbank konnte nicht konsistent in V2-Staging kopiert werden: %@. Bitte V1 vollständig beenden und erneut versuchen.",
                arguments: message
            )
        case let .databaseIntegrity(message):
            L10n.text("Die kopierte V1-Datenbank hat die Integritätsprüfung nicht bestanden: %@", arguments: message)
        case let .invalidSchema(detail):
            L10n.text("Die V1-Datenbank besitzt nicht das erwartete Schema: %@", arguments: detail)
        case .invalidMetadata:
            L10n.text("Die V1-App-Metadaten sind nicht lesbar.")
        case let .invalidEntityRow(table):
            L10n.text(
                "Ein Datensatz in %@ ist nicht lesbar oder seine ID stimmt nicht mit dem JSON-Inhalt überein.",
                arguments: table
            )
        case .missingPhotosDirectory:
            L10n.text("Die V1-Datenbank referenziert Fotos, aber der Ordner photos/ fehlt.")
        case let .unsafePhotoFile(name):
            L10n.text("Eine V1-Fotodatei fehlt oder besitzt einen unsicheren Dateinamen: %@", arguments: name)
        case let .photoTooLarge(name):
            L10n.text("Die V1-Fotodatei %@ überschreitet das Limit von 30 MiB.", arguments: name)
        case .photoDataTooLarge:
            L10n.text("Die V1-Fotodaten überschreiten das Limit von 500 MiB.")
        }
    }
}

struct V1SQLiteSourceReader: Sendable {
    private static let databaseFileName = "keyboard-manager.sqlite"
    private static let photosDirectoryName = "photos"
    private static let maximumDatabaseBytes: Int64 = 100 * 1_024 * 1_024
    private static let maximumPhotoBytes = 30 * 1_024 * 1_024
    private static let maximumPhotoTotalBytes = 500 * 1_024 * 1_024
    private static let maximumManifestBytes = 10 * 1_024 * 1_024

    func inspect(at sourceDirectoryURL: URL) async throws -> MigrationDryRunResult {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardManagerSQLite-\(UUID().uuidString)", isDirectory: true)
        let canonicalArchiveURL = temporaryDirectoryURL.appendingPathComponent("Canonical.zip")
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }
        return try await prepareInspection(
            at: sourceDirectoryURL,
            canonicalArchiveURL: canonicalArchiveURL
        )
    }

    func prepareInspection(
        at sourceDirectoryURL: URL,
        canonicalArchiveURL: URL
    ) async throws -> MigrationDryRunResult {
        let descriptor = try await Task.detached(priority: .userInitiated) {
            try Self.createCanonicalArchive(
                from: sourceDirectoryURL,
                at: canonicalArchiveURL
            )
        }.value

        var result = try await V1BackupReader().inspect(at: canonicalArchiveURL)
        result.report.sourceKind = .sqliteDirectory
        result.report.sourceFileName = sourceDirectoryURL.lastPathComponent
        result.report.sourceByteCount = descriptor.sourceByteCount
        result.report.sourceSHA256 = descriptor.sourceSHA256
        result.report.sourceVersion = descriptor.sourceVersion
        result.report.schemaVersion = 0
        result.report.issues.append(MigrationIssue(
            code: "sqlite-readonly-snapshot",
            severity: .warning,
            message: "Die direkte V1-Datenbank wurde ausschließlich lesend in einen konsistenten V2-Staging-Snapshot überführt.",
            affectedItems: 1
        ))
        result.report.issues.sort {
            if $0.severity != $1.severity { return $0.severity == .error }
            return $0.code < $1.code
        }
        return result
    }

    private struct SourceDescriptor: Sendable {
        var sourceByteCount: Int64
        var sourceSHA256: String
        var sourceVersion: String
    }

    private struct CanonicalSource {
        var manifestData: Data
        var photos: [(path: String, data: Data)]
        var sourceVersion: String
        var sourceByteCount: Int64
    }

    private static func createCanonicalArchive(
        from sourceDirectoryURL: URL,
        at archiveURL: URL
    ) throws -> SourceDescriptor {
        let sourceDirectoryURL = sourceDirectoryURL.standardizedFileURL
        let directoryValues = try sourceDirectoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true else {
            throw V1SQLiteSourceReaderError.sourceIsNotDirectory
        }
        guard directoryValues.isSymbolicLink != true else {
            throw V1SQLiteSourceReaderError.unsafeSourceDirectory
        }

        let databaseURL = sourceDirectoryURL.appendingPathComponent(databaseFileName)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw V1SQLiteSourceReaderError.missingDatabase
        }
        try validateRegularFile(databaseURL)

        let databaseByteCount = try databaseSourceByteCount(databaseURL)
        guard databaseByteCount > 0, databaseByteCount <= maximumDatabaseBytes else {
            throw V1SQLiteSourceReaderError.databaseTooLarge
        }

        let snapshotDatabaseURL = archiveURL.deletingLastPathComponent()
            .appendingPathComponent("V1Snapshot.sqlite")
        let stagedSourceDatabaseURL = archiveURL.deletingLastPathComponent()
            .appendingPathComponent("V1Source.sqlite")
        try stageDatabaseFamily(
            from: databaseURL,
            to: stagedSourceDatabaseURL
        )
        try backupDatabase(
            from: stagedSourceDatabaseURL,
            to: snapshotDatabaseURL
        )
        let canonical = try readCanonicalSource(
            from: snapshotDatabaseURL,
            sourceDirectoryURL: sourceDirectoryURL,
            databaseSourceByteCount: databaseByteCount
        )

        guard canonical.manifestData.count <= maximumManifestBytes else {
            throw V1BackupReaderError.manifestTooLarge
        }
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try add(canonical.manifestData, at: "manifest.json", to: archive)
        for photo in canonical.photos.sorted(by: { $0.path < $1.path }) {
            try add(photo.data, at: photo.path, to: archive)
        }

        return SourceDescriptor(
            sourceByteCount: canonical.sourceByteCount,
            sourceSHA256: logicalSourceSHA256(
                manifestData: canonical.manifestData,
                photos: canonical.photos
            ),
            sourceVersion: canonical.sourceVersion
        )
    }

    private static func readCanonicalSource(
        from snapshotDatabaseURL: URL,
        sourceDirectoryURL: URL,
        databaseSourceByteCount: Int64
    ) throws -> CanonicalSource {
        // The copied database can retain V1's WAL journal mode. It is V2-owned
        // staging data, so opening this copy read-write lets SQLite create its
        // own sidecars without ever granting write access to the V1 source.
        let database = try openDatabase(at: snapshotDatabaseURL, readOnly: false)
        defer { sqlite3_close(database) }
        try verifyIntegrity(of: database)

        let appValue = try readAppValue(from: database)
        let boards = try readJSONRows(
            table: "boards",
            idColumn: "id",
            jsonColumn: "board_json",
            database: database
        )
        let keycapSets = try readJSONRows(
            table: "keycap_sets",
            idColumn: "id",
            jsonColumn: "keycap_set_json",
            database: database
        )
        let artisanSets = try readJSONRows(
            table: "artisan_sets",
            idColumn: "id",
            jsonColumn: "artisan_set_json",
            database: database
        )
        let switchSets = try readJSONRows(
            table: "switch_sets",
            idColumn: "id",
            jsonColumn: "switch_set_json",
            database: database
        )
        let photoRows = try readPhotoRows(from: database)

        let photosDirectoryURL = sourceDirectoryURL
            .appendingPathComponent(photosDirectoryName, isDirectory: true)
        if !photoRows.isEmpty {
            guard FileManager.default.fileExists(atPath: photosDirectoryURL.path) else {
                throw V1SQLiteSourceReaderError.missingPhotosDirectory
            }
            let values = try photosDirectoryURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw V1SQLiteSourceReaderError.unsafeSourceDirectory
            }
        }

        var manifestPhotos: [[String: Any]] = []
        var photoPayloads: [(path: String, data: Data)] = []
        var totalPhotoBytes = 0
        for row in photoRows {
            let photoID = try requiredString(row, key: "id", table: "photos")
            let declaredType = try requiredString(row, key: "type", table: "photos")
            guard let mimeType = PhotoMIMEType(rawValue: declaredType), mimeType != .heic else {
                throw V1BackupReaderError.unsupportedPhotoType(declaredType)
            }
            let expectedFileName = "\(photoID).\(mimeType.fileExtension)"
            let storedFileName = try requiredString(row, key: "file_name", table: "photos")
            guard storedFileName == expectedFileName,
                  URL(fileURLWithPath: storedFileName).lastPathComponent == storedFileName else {
                throw V1SQLiteSourceReaderError.unsafePhotoFile(storedFileName)
            }

            let photoURL = photosDirectoryURL.appendingPathComponent(storedFileName)
            try validateRegularFile(photoURL)
            let data = try Data(contentsOf: photoURL, options: [.mappedIfSafe])
            guard !data.isEmpty, data.count <= maximumPhotoBytes else {
                throw V1SQLiteSourceReaderError.photoTooLarge(storedFileName)
            }
            totalPhotoBytes += data.count
            guard totalPhotoBytes <= maximumPhotoTotalBytes else {
                throw V1SQLiteSourceReaderError.photoDataTooLarge
            }

            let archivePath = "photos/\(expectedFileName)"
            var photo: [String: Any] = [
                "id": photoID,
                "boardId": optionalString(row, key: "board_id") ?? "",
                "ownerType": optionalString(row, key: "owner_type") ?? "board",
                "ownerId": optionalString(row, key: "owner_id")
                    ?? optionalString(row, key: "board_id")
                    ?? "",
                "name": optionalString(row, key: "name") ?? "",
                "type": declaredType,
                "addedAt": number(row, key: "added_at") ?? 0,
                "file": archivePath
            ]
            if let width = number(row, key: "width") {
                photo["width"] = width
            }
            if let height = number(row, key: "height") {
                photo["height"] = height
            }
            manifestPhotos.append(photo)
            photoPayloads.append((archivePath, data))
        }

        let metadata = appValue["meta"] as? [String: Any] ?? [:]
        let lists = appValue["lists"] as? [String: Any] ?? [:]
        let gallery = appValue["gallery"] as? [String: Any] ?? [:]
        let manifest: [String: Any] = [
            "schemaVersion": 6,
            "format": "keyboard-manager-zip",
            "meta": metadata,
            "lists": lists,
            "gallery": gallery,
            "boards": boards,
            "keycapSets": keycapSets,
            "artisanSets": artisanSets,
            "switchSets": switchSets,
            "photos": manifestPhotos
        ]
        let manifestData: Data
        do {
            manifestData = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw V1SQLiteSourceReaderError.invalidMetadata
        }
        return CanonicalSource(
            manifestData: manifestData,
            photos: photoPayloads,
            sourceVersion: metadata["version"] as? String ?? "unbekannt",
            sourceByteCount: databaseSourceByteCount + Int64(totalPhotoBytes)
        )
    }

    private static func readAppValue(from database: OpaquePointer) throws -> [String: Any] {
        let statement = try prepare(
            "SELECT value_json FROM app_meta WHERE key = 'app' LIMIT 1;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            throw V1SQLiteSourceReaderError.invalidMetadata
        }
        guard result == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              let data = String(cString: text).data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw V1SQLiteSourceReaderError.invalidMetadata
        }
        return value
    }

    private static func readJSONRows(
        table: String,
        idColumn: String,
        jsonColumn: String,
        database: OpaquePointer
    ) throws -> [[String: Any]] {
        let statement = try prepare(
            "SELECT \(idColumn), \(jsonColumn) FROM \(table) ORDER BY \(idColumn);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var rows: [[String: Any]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idText = sqlite3_column_text(statement, 0),
                      let jsonText = sqlite3_column_text(statement, 1),
                      let data = String(cString: jsonText).data(using: .utf8),
                      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      value["id"] as? String == String(cString: idText) else {
                    throw V1SQLiteSourceReaderError.invalidEntityRow(table)
                }
                rows.append(value)
            case SQLITE_DONE:
                return rows
            default:
                throw V1SQLiteSourceReaderError.invalidSchema(errorMessage(database))
            }
        }
    }

    private static func readPhotoRows(from database: OpaquePointer) throws -> [[String: Any?]] {
        let statement = try prepare(
            """
            SELECT id, board_id, owner_type, owner_id, name, type, width, height, added_at, file_name
            FROM photos
            ORDER BY id;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        let columns = [
            "id", "board_id", "owner_type", "owner_id", "name",
            "type", "width", "height", "added_at", "file_name"
        ]
        var rows: [[String: Any?]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row: [String: Any?] = [:]
                for (index, column) in columns.enumerated() {
                    switch sqlite3_column_type(statement, Int32(index)) {
                    case SQLITE_INTEGER:
                        row[column] = sqlite3_column_int64(statement, Int32(index))
                    case SQLITE_FLOAT:
                        row[column] = sqlite3_column_double(statement, Int32(index))
                    case SQLITE_TEXT:
                        row[column] = sqlite3_column_text(statement, Int32(index)).map {
                            String(cString: $0)
                        }
                    case SQLITE_NULL:
                        row[column] = nil
                    default:
                        throw V1SQLiteSourceReaderError.invalidEntityRow("photos")
                    }
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw V1SQLiteSourceReaderError.invalidSchema(errorMessage(database))
            }
        }
    }

    private static func requiredString(
        _ row: [String: Any?],
        key: String,
        table: String
    ) throws -> String {
        guard let value = optionalString(row, key: key), !value.isEmpty else {
            throw V1SQLiteSourceReaderError.invalidEntityRow(table)
        }
        return value
    }

    private static func optionalString(_ row: [String: Any?], key: String) -> String? {
        row[key] as? String
    }

    private static func number(_ row: [String: Any?], key: String) -> NSNumber? {
        if let value = row[key] as? Int64 {
            return NSNumber(value: value)
        }
        if let value = row[key] as? Double {
            return NSNumber(value: value)
        }
        return nil
    }

    private static func databaseSourceByteCount(_ databaseURL: URL) throws -> Int64 {
        var total: Int64 = 0
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] where FileManager.default.fileExists(atPath: url.path) {
            try validateRegularFile(url)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func validateRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw V1SQLiteSourceReaderError.unsafeSourceDirectory
        }
    }

    private static func stageDatabaseFamily(
        from sourceDatabaseURL: URL,
        to stagedDatabaseURL: URL
    ) throws {
        let fileManager = FileManager.default
        let sourceURLs = [
            sourceDatabaseURL,
            URL(fileURLWithPath: sourceDatabaseURL.path + "-wal"),
            URL(fileURLWithPath: sourceDatabaseURL.path + "-shm")
        ]
        let destinationURLs = [
            stagedDatabaseURL,
            URL(fileURLWithPath: stagedDatabaseURL.path + "-wal"),
            URL(fileURLWithPath: stagedDatabaseURL.path + "-shm")
        ]

        do {
            for (sourceURL, destinationURL) in zip(sourceURLs, destinationURLs) {
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                try validateRegularFile(sourceURL)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            throw V1SQLiteSourceReaderError.databaseBackup(
                "Die V1-Dateifamilie konnte nicht in den V2-Bereich kopiert werden: "
                + error.localizedDescription
            )
        }
    }

    private static func backupDatabase(from sourceURL: URL, to destinationURL: URL) throws {
        var source: OpaquePointer?
        // This database is the V2-owned staged copy, not the V1 original.
        // A read-only source can open successfully but fail during
        // `sqlite3_backup_step` on an otherwise valid V1 database. Opening the
        // staged copy read-write lets SQLite resolve its own transient state;
        // the original V1 database family remains byte-for-byte untouched.
        let sourceResult = sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceResult == SQLITE_OK, let source else {
            let message = source.map(errorMessage)
                ?? L10n.text("SQLite-Fehler %lld", arguments: sourceResult)
            if let source { sqlite3_close(source) }
            throw V1SQLiteSourceReaderError.databaseOpen(message)
        }
        defer { sqlite3_close(source) }
        var destination: OpaquePointer?
        let destinationResult = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationResult == SQLITE_OK, let destination else {
            let message = destination.map(errorMessage)
                ?? L10n.text("SQLite-Fehler %lld", arguments: destinationResult)
            if let destination { sqlite3_close(destination) }
            throw V1SQLiteSourceReaderError.databaseBackup(message)
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw V1SQLiteSourceReaderError.databaseBackup(errorMessage(destination))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw V1SQLiteSourceReaderError.databaseBackup(errorMessage(destination))
        }
    }

    private static func openDatabase(at url: URL, readOnly: Bool) throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE)
            | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map(errorMessage)
                ?? L10n.text("SQLite-Fehler %lld", arguments: result)
            if let database { sqlite3_close(database) }
            throw V1SQLiteSourceReaderError.databaseOpen(message)
        }
        return database
    }

    private static func verifyIntegrity(of database: OpaquePointer) throws {
        let statement = try prepare("PRAGMA integrity_check;", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0),
              String(cString: value) == "ok" else {
            throw V1SQLiteSourceReaderError.databaseIntegrity(errorMessage(database))
        }
    }

    private static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw V1SQLiteSourceReaderError.invalidSchema(errorMessage(database))
        }
        return statement
    }

    private static func errorMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private static func add(_ data: Data, at path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<(start + size))
        }
    }

    private static func logicalSourceSHA256(
        manifestData: Data,
        photos: [(path: String, data: Data)]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("KeyboardManagerV1SQLiteSource\u{0}".utf8))
        updateHashRecord(path: "manifest.json", data: manifestData, hasher: &hasher)
        for photo in photos.sorted(by: { $0.path < $1.path }) {
            updateHashRecord(path: photo.path, data: photo.data, hasher: &hasher)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func updateHashRecord(
        path: String,
        data: Data,
        hasher: inout SHA256
    ) {
        hasher.update(data: Data("\(path.utf8.count):\(path)\(data.count):".utf8))
        hasher.update(data: data)
    }
}
