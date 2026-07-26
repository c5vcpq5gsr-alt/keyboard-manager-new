import Foundation
import Observation

@MainActor
@Observable
final class InventoryStore {
    var snapshot: InventorySnapshot = .empty
    var route: AppRoute = .overview
    var selectedKind: InventoryItemKind = .board
    var selectedItemID: String?
    var overviewFiltersByKind: [InventoryItemKind: InventoryFilters] = [:]
    var overviewSortsByKind: [InventoryItemKind: InventorySort] = [:]
    private(set) var overviewSelectionByKind: [InventoryItemKind: String] = [:]
    private(set) var overviewScrollOffsetByKind: [InventoryItemKind: Double] = [:]
    private(set) var overviewRestoreRequest: OverviewRestoreRequest?
    var loadState: LoadState = .idle
    var editorSaveState: EditorSaveState = .idle
    var isEditorDirty = false
    var isDiscardConfirmationPresented = false
    var isWindowCloseConfirmationPresented = false
    var navigationRevision = 0
    private(set) var windowCloseRevision = 0
    var migrationReadiness: MigrationReadiness = .notScanned
    var migrationDiscoveryState: V1SourceDiscoveryState = .idle
    var migrationInspectionState: MigrationInspectionState = .idle
    var migrationCommitState: MigrationCommitState = .idle
    var backupExportState: BackupExportState = .idle
    var reportExportState: InventoryReportExportState = .idle
    private(set) var languagePersistenceError: String?
    private(set) var migrationReportURL: URL?
    private(set) var pendingMigrationSnapshot: InventorySnapshot?
    private var pendingMigrationResult: MigrationDryRunResult?
    private var pendingMigrationSourceURL: URL?

    private let repository: any InventoryRepository
    private let migrationService: V1MigrationService
    private let migrationCommitService: MigrationCommitService
    private let backupExportService: BackupExportService
    private let reportExportService: InventoryReportExportService
    private let editingService = InventoryEditingService()
    private let photoService: PhotoImportService
    private let thumbnailService: ThumbnailService
    private var pendingEditorNavigation: EditorNavigationTarget?
    private var pendingOverviewReturn: OverviewReturnContext?
    private var overviewRestoreRevision = 0

    init(
        repository: any InventoryRepository = SQLiteInventoryRepository(),
        migrationService: V1MigrationService = V1MigrationService(),
        migrationCommitService: MigrationCommitService = MigrationCommitService(),
        backupExportService: BackupExportService = BackupExportService(),
        reportExportService: InventoryReportExportService = InventoryReportExportService(),
        photoService: PhotoImportService = PhotoImportService(),
        thumbnailService: ThumbnailService = ThumbnailService()
    ) {
        self.repository = repository
        self.migrationService = migrationService
        self.migrationCommitService = migrationCommitService
        self.backupExportService = backupExportService
        self.reportExportService = reportExportService
        self.photoService = photoService
        self.thumbnailService = thumbnailService
    }

    func load() async {
        guard loadState == .idle else { return }
        loadState = .loading

        do {
            snapshot = try await repository.loadSnapshot()
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func updatePreferredLanguage(_ value: String) async {
        let normalized = AppLanguage.normalized(value).rawValue
        guard loadState == .loaded else { return }
        guard snapshot.metadata.preferredLanguage != normalized else {
            languagePersistenceError = nil
            return
        }
        var updated = snapshot
        updated.metadata.preferredLanguage = normalized
        do {
            try await repository.saveSnapshot(updated)
            snapshot = updated
            languagePersistenceError = nil
        } catch {
            languagePersistenceError = L10n.text(
                "Die Sprachauswahl konnte nicht gespeichert werden: %@",
                arguments: error.localizedDescription
            )
        }
    }

    func prepareNewItem(_ kind: InventoryItemKind) {
        guard !needsDiscardConfirmation else {
            pendingEditorNavigation = .new(kind)
            isDiscardConfirmationPresented = true
            return
        }
        openNewItem(kind)
    }

    func requestRoute(_ newRoute: AppRoute) {
        guard newRoute != route else { return }
        guard !needsDiscardConfirmation else {
            pendingEditorNavigation = .route(newRoute)
            isDiscardConfirmationPresented = true
            navigationRevision += 1
            return
        }
        if newRoute == .capture {
            openNewItem(selectedKind)
            return
        }
        if newRoute == .overview, let pendingOverviewReturn {
            scheduleOverviewRestore(
                kind: pendingOverviewReturn.kind,
                itemID: pendingOverviewReturn.itemID
            )
        }
        route = newRoute
    }

    func editItem(kind: InventoryItemKind, id: String) {
        guard !needsDiscardConfirmation else {
            pendingEditorNavigation = .edit(kind, id)
            isDiscardConfirmationPresented = true
            return
        }
        openEditor(kind: kind, id: id)
    }

    func updateOverviewSelection(_ id: String?, for kind: InventoryItemKind) {
        if let id {
            overviewSelectionByKind[kind] = id
        } else {
            overviewSelectionByKind.removeValue(forKey: kind)
        }
        if selectedKind == kind {
            selectedItemID = id
        }
    }

    func updateOverviewScrollOffset(_ offset: Double, for kind: InventoryItemKind) {
        guard offset.isFinite else { return }
        overviewScrollOffsetByKind[kind] = max(0, offset)
    }

    func consumeOverviewRestoreRequest(revision: Int) {
        guard overviewRestoreRequest?.revision == revision else { return }
        overviewRestoreRequest = nil
    }

    func confirmDiscardAndContinue() {
        isEditorDirty = false
        isDiscardConfirmationPresented = false
        let target = pendingEditorNavigation
        pendingEditorNavigation = nil
        switch target {
        case let .route(route):
            if route == .capture {
                openNewItem(selectedKind)
                return
            }
            if route == .overview, let pendingOverviewReturn {
                scheduleOverviewRestore(
                    kind: pendingOverviewReturn.kind,
                    itemID: pendingOverviewReturn.itemID
                )
            }
            self.route = route
        case let .new(kind):
            openNewItem(kind)
        case let .edit(kind, id):
            openEditor(kind: kind, id: id)
        case nil:
            break
        }
    }

    func cancelDiscard() {
        pendingEditorNavigation = nil
        isDiscardConfirmationPresented = false
        navigationRevision += 1
    }

    func shouldAllowWindowClose() -> Bool {
        guard needsDiscardConfirmation else { return true }
        isWindowCloseConfirmationPresented = true
        return false
    }

    func confirmDiscardAndCloseWindow() {
        isEditorDirty = false
        isWindowCloseConfirmationPresented = false
        windowCloseRevision += 1
    }

    func cancelWindowClose() {
        isWindowCloseConfirmationPresented = false
    }

    func editorDraft() -> InventoryDraft {
        guard let selectedItemID else {
            return InventoryDraft(kind: selectedKind)
        }
        switch selectedKind {
        case .board:
            return snapshot.boards.first(where: { $0.id == selectedItemID })
                .map { InventoryDraft(board: $0, installations: snapshot.switchInstallations) }
                ?? InventoryDraft(kind: .board)
        case .keycapSet:
            return snapshot.keycapSets.first(where: { $0.id == selectedItemID })
                .map(InventoryDraft.init(keycapSet:))
                ?? InventoryDraft(kind: .keycapSet)
        case .artisanSet:
            return snapshot.artisanSets.first(where: { $0.id == selectedItemID })
                .map(InventoryDraft.init(artisanSet:))
                ?? InventoryDraft(kind: .artisanSet)
        case .switchSet:
            return snapshot.switchSets.first(where: { $0.id == selectedItemID })
                .map { InventoryDraft(switchSet: $0, installations: snapshot.switchInstallations) }
                ?? InventoryDraft(kind: .switchSet)
        }
    }

    var editorIdentity: String {
        "\(selectedKind.rawValue)::\(selectedItemID ?? "new")"
    }

    func preparePhotos(urls: [URL], for draft: InventoryDraft) async throws -> [PreparedPhoto] {
        let owner = PhotoOwner(type: photoOwnerType(for: draft.kind), id: draft.id)
        return try await photoService.prepare(urls: urls, owner: owner)
    }

    func prepareExternalPhotos(urlStrings: [String], for draft: InventoryDraft) async throws -> [PreparedPhoto] {
        let owner = PhotoOwner(type: photoOwnerType(for: draft.kind), id: draft.id)
        return try await photoService.prepareExternal(urlStrings: urlStrings, owner: owner)
    }

    func photoRecord(id: String?) -> PhotoRecord? {
        guard let id else { return nil }
        return snapshot.photos.first { $0.id == id }
    }

    func thumbnailData(for record: PhotoRecord) async -> Data? {
        await thumbnailService.thumbnailData(for: record)
    }

    func photoData(for record: PhotoRecord) async -> Data? {
        await photoService.data(for: record)
    }

    func save(_ draft: InventoryDraft, preparedPhotos: [PreparedPhoto]) async -> Bool {
        editorSaveState = .saving
        var draft = draft
        for photo in preparedPhotos where !draft.photoIDs.contains(photo.record.id) {
            draft.photoIDs.append(photo.record.id)
        }
        if draft.mainPhotoID == nil {
            draft.mainPhotoID = draft.photoIDs.first
        }

        do {
            let result = try editingService.saving(
                draft,
                newPhotos: preparedPhotos.map(\.record),
                in: snapshot
            )
            try await photoService.commit(preparedPhotos)
            do {
                try await repository.saveSnapshot(result.snapshot)
            } catch {
                await photoService.remove(preparedPhotos.map(\.record))
                throw error
            }
            await photoService.remove(result.removedPhotos)
            await thumbnailService.remove(result.removedPhotos)
            snapshot = result.snapshot
            selectedKind = draft.kind
            selectedItemID = draft.id
            isEditorDirty = false
            editorSaveState = .saved("„\(draft.normalizedName)“ wurde gespeichert.")
            scheduleOverviewRestore(kind: draft.kind, itemID: draft.id)
            route = .overview
            return true
        } catch {
            editorSaveState = .failed(error.localizedDescription)
            return false
        }
    }

    func deleteItem(kind: InventoryItemKind, id: String) async -> Bool {
        editorSaveState = .saving
        let wasEditing = route == .capture
        do {
            let result = try editingService.deleting(kind: kind, id: id, in: snapshot)
            try await repository.saveSnapshot(result.snapshot)
            await photoService.remove(result.removedPhotos)
            await thumbnailService.remove(result.removedPhotos)
            snapshot = result.snapshot
            if selectedItemID == id {
                selectedItemID = nil
            }
            isEditorDirty = false
            editorSaveState = .saved("Der Eintrag wurde gelöscht.")
            if wasEditing {
                scheduleOverviewRestore(kind: kind, itemID: nil)
            }
            route = .overview
            return true
        } catch {
            editorSaveState = .failed(error.localizedDescription)
            return false
        }
    }

    func clearEditorStatus() {
        editorSaveState = .idle
    }

    func exportBackup(to destinationURL: URL) async {
        if case .exporting = backupExportState {
            return
        }
        backupExportState = .exporting
        let hasSecurityScope = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let appVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1.0"
            let result = try await backupExportService.export(
                snapshot: snapshot,
                to: destinationURL,
                appVersion: appVersion
            )
            backupExportState = .succeeded(result)
        } catch {
            backupExportState = .failed(error.localizedDescription)
        }
    }

    func clearBackupExportStatus() {
        if case .exporting = backupExportState {
            return
        }
        backupExportState = .idle
    }

    func exportReport(
        context: InventoryReportContext,
        options: InventoryReportOptions,
        to destinationURL: URL
    ) async {
        reportExportState = .exporting(options.format)
        let hasSecurityScope = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let appVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1.0"
            let report = try InventoryReportBuilder.build(
                snapshot: snapshot,
                context: context,
                options: options,
                appVersion: appVersion
            )
            let result = try await reportExportService.export(
                report: report,
                format: options.format,
                to: destinationURL
            )
            reportExportState = .succeeded(result)
        } catch {
            reportExportState = .failed(error.localizedDescription)
        }
    }

    func clearReportExportStatus() {
        if case .exporting = reportExportState {
            return
        }
        reportExportState = .idle
    }

    func libraryValues(for key: String) -> [String] {
        snapshot.libraryValues.valuesByKey[key, default: []]
    }

    private var needsDiscardConfirmation: Bool {
        route == .capture && isEditorDirty
    }

    private func openNewItem(_ kind: InventoryItemKind) {
        pendingOverviewReturn = nil
        selectedKind = kind
        selectedItemID = nil
        editorSaveState = .idle
        isEditorDirty = false
        route = .capture
    }

    private func openEditor(kind: InventoryItemKind, id: String) {
        updateOverviewSelection(id, for: kind)
        pendingOverviewReturn = OverviewReturnContext(
            kind: kind,
            itemID: id,
            scrollOffset: overviewScrollOffsetByKind[kind]
        )
        selectedKind = kind
        selectedItemID = id
        editorSaveState = .idle
        isEditorDirty = false
        route = .capture
    }

    private func scheduleOverviewRestore(kind: InventoryItemKind, itemID: String?) {
        let scrollOffset: Double?
        if pendingOverviewReturn?.kind == kind {
            scrollOffset = pendingOverviewReturn?.scrollOffset
        } else {
            scrollOffset = nil
        }
        overviewRestoreRevision += 1
        overviewRestoreRequest = OverviewRestoreRequest(
            revision: overviewRestoreRevision,
            kind: kind,
            itemID: itemID,
            scrollOffset: scrollOffset
        )
        selectedKind = kind
        updateOverviewSelection(itemID, for: kind)
        pendingOverviewReturn = nil
    }

    private func photoOwnerType(for kind: InventoryItemKind) -> PhotoOwnerType {
        switch kind {
        case .board: .board
        case .keycapSet: .keycapSet
        case .artisanSet: .artisanSet
        case .switchSet: .switchSet
        }
    }

    func showMigration() {
        requestRoute(.migration)
    }

    func discoverMigrationSources(force: Bool = false) async {
        if !force, migrationDiscoveryState != .idle {
            return
        }
        migrationDiscoveryState = .scanning
        let canUpdateReadiness = migrationInspectionState == .idle

        do {
            let result = try await migrationService.discoverInstalledSource()
            guard let source = result.source else {
                migrationDiscoveryState = .notFound(
                    searchedCandidateCount: result.searchedCandidateCount
                )
                if canUpdateReadiness {
                    migrationReadiness = .notScanned
                }
                return
            }

            if result.isV1Running {
                let reason = V1SourceDiscoveryError.v1IsRunning.localizedDescription
                migrationDiscoveryState = .blocked(source, reason: reason)
                if canUpdateReadiness {
                    migrationReadiness = .blocked(reason: reason)
                }
            } else {
                migrationDiscoveryState = .found(source)
                if canUpdateReadiness {
                    migrationReadiness = .ready(sourceCount: 1)
                }
            }
        } catch {
            migrationDiscoveryState = .failed(error.localizedDescription)
            if canUpdateReadiness {
                migrationReadiness = .blocked(reason: error.localizedDescription)
            }
        }
    }

    func inspectDiscoveredMigrationSource() async {
        guard case let .found(source) = migrationDiscoveryState else { return }
        await inspectMigrationSource(at: source.directoryURL)
    }

    func inspectMigrationSource(at url: URL) async {
        let fileName = url.lastPathComponent
        migrationReadiness = .scanning
        migrationInspectionState = .inspecting(fileName: fileName)
        migrationCommitState = .idle
        migrationReportURL = nil
        pendingMigrationSnapshot = nil
        pendingMigrationResult = nil
        pendingMigrationSourceURL = nil

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let result = try await migrationService.inspectSource(at: url)
            pendingMigrationSnapshot = result.snapshot
            pendingMigrationResult = result
            pendingMigrationSourceURL = url
            migrationInspectionState = .ready(result.report)
            migrationReadiness = .ready(sourceCount: 1)
        } catch {
            let message = error.localizedDescription
            migrationInspectionState = .failed(message)
            migrationReadiness = .blocked(reason: message)
            if let discoverySource = discoveredSource(matching: url),
               error is V1SourceDiscoveryError {
                migrationDiscoveryState = .blocked(discoverySource, reason: message)
            }
        }
    }

    var hasExistingV2Data: Bool {
        snapshot.counts.totalItems > 0 || snapshot.counts.photos > 0
    }

    var canCommitMigration: Bool {
        guard case let .ready(report) = migrationInspectionState,
              report.canImport,
              pendingMigrationResult != nil,
              pendingMigrationSourceURL != nil else {
            return false
        }
        if case .committing = migrationCommitState { return false }
        if case .succeeded = migrationCommitState { return false }
        return true
    }

    func commitPendingMigration() async {
        guard let sourceURL = pendingMigrationSourceURL,
              let dryRun = pendingMigrationResult,
              canCommitMigration else {
            return
        }

        migrationCommitState = .committing(fileName: dryRun.report.sourceFileName)
        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let result = try await migrationCommitService.commit(
                backupURL: sourceURL,
                expectedDryRun: dryRun
            )
            snapshot = result.snapshot
            loadState = .loaded
            migrationReportURL = result.reportURL
            migrationCommitState = .succeeded(result.report)
            migrationReadiness = .ready(sourceCount: 1)
        } catch {
            migrationCommitState = .failed(error.localizedDescription)
            if dryRun.report.sourceKind == .sqliteDirectory,
               let discoverySource = discoveredSource(matching: sourceURL),
               error is V1SourceDiscoveryError {
                migrationDiscoveryState = .blocked(
                    discoverySource,
                    reason: error.localizedDescription
                )
            }
        }
    }

    private func discoveredSource(matching url: URL) -> V1DiscoveredSource? {
        let source: V1DiscoveredSource?
        switch migrationDiscoveryState {
        case let .found(value), let .blocked(value, _):
            source = value
        case .idle, .scanning, .notFound, .failed:
            source = nil
        }
        guard source?.directoryURL.standardizedFileURL == url.standardizedFileURL else {
            return nil
        }
        return source
    }
}

struct OverviewRestoreRequest: Equatable, Sendable {
    var revision: Int
    var kind: InventoryItemKind
    var itemID: String?
    var scrollOffset: Double?
}

private struct OverviewReturnContext {
    var kind: InventoryItemKind
    var itemID: String
    var scrollOffset: Double?
}

enum EditorSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved(String)
    case failed(String)
}

enum BackupExportState: Equatable, Sendable {
    case idle
    case exporting
    case succeeded(BackupExportResult)
    case failed(String)
}

private enum EditorNavigationTarget {
    case route(AppRoute)
    case new(InventoryItemKind)
    case edit(InventoryItemKind, String)
}
