import SwiftUI
import UniformTypeIdentifiers

struct MigrationView: View {
    @Bindable var store: InventoryStore
    @State private var showingBackupImporter = false
    @State private var showingImportConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PhaseBanner(
                    title: "Kontrollierte V1-Migration",
                    message: "Der Prüflauf liest V1 ausschließlich. Erst nach der separaten Bestätigung baut V2 einen neuen Bestand im Staging auf, prüft ihn vollständig und aktiviert ihn mit Rollback-Schutz."
                )

                GroupBox("Bereitschaft") {
                    HStack(spacing: 12) {
                        Image(systemName: "shield.checkered")
                            .font(.title2)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.migrationReadiness.title)
                                .font(.headline)
                            Text(readinessDetail)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }

                discoveryResult

                GroupBox("Unterstützte Quellen") {
                    VStack(spacing: 0) {
                        ForEach(V1MigrationService.supportedSourcesByPriority) { kind in
                            HStack(spacing: 12) {
                                Image(systemName: sourceIcon(for: kind))
                                    .frame(width: 24)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.displayName)
                                    Text(kind.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Nur lesen")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)

                            if kind != V1MigrationService.supportedSourcesByPriority.last {
                                Divider()
                            }
                        }
                    }
                }

                inspectionResult
                commitResult

                HStack {
                    Button("Andere V1-Quelle auswählen …") {
                        showingBackupImporter = true
                    }
                    .disabled(isBusy)

                    Spacer()

                    Button("Import in V2 übernehmen …") {
                        showingImportConfirmation = true
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canCommitMigration)
                        .help("Erstellt einen geprüften V2-Bestand; V1 bleibt unverändert")
                }
            }
            .padding(24)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("V1-Quelle prüfen …", systemImage: "doc.badge.arrow.up") {
                    showingBackupImporter = true
                }
                .disabled(isBusy)
            }
        }
        .fileImporter(
            isPresented: $showingBackupImporter,
            allowedContentTypes: [.zip, .json, .folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                await store.inspectMigrationSource(at: url)
            }
        }
        .confirmationDialog(
            "V1-Bestand in V2 übernehmen?",
            isPresented: $showingImportConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                store.hasExistingV2Data ? "Vorhandenen V2-Bestand sichern und ersetzen" : "V2-Bestand erstellen",
                role: store.hasExistingV2Data ? .destructive : nil
            ) {
                Task {
                    await store.commitPendingMigration()
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .task {
            await store.discoverMigrationSources()
        }
    }

    @ViewBuilder
    private var discoveryResult: some View {
        switch store.migrationDiscoveryState {
        case .idle:
            EmptyView()
        case .scanning:
            GroupBox("Installierte V1") {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Bekannte App-Support-Orte werden ausschließlich lesend geprüft …")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        case let .notFound(searchedCandidateCount):
            GroupBox("Installierte V1") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "Keine eindeutige V1-SQLite-Quelle gefunden",
                        systemImage: "externaldrive.badge.questionmark"
                    )
                    .font(.headline)
                    .accessibilityIdentifier("migration.discovery.notFound")
                    Text("\(searchedCandidateCount) bekannte Kandidaten wurden geprüft. ZIP, JSON oder ein anderer Datenordner können weiterhin manuell gewählt werden.")
                        .foregroundStyle(.secondary)
                    Button("Erneut suchen") {
                        Task { await store.discoverMigrationSources(force: true) }
                    }
                    .disabled(isBusy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        case let .found(source):
            discoveredSourceBox(
                source,
                title: "Installierte V1-Datenquelle gefunden",
                message: "Die SQLite-Signatur ist bestätigt. Es wurde noch nichts importiert.",
                isBlocked: false
            )
        case let .blocked(source, reason):
            discoveredSourceBox(
                source,
                title: "Installierte V1 ist noch geöffnet",
                message: reason,
                isBlocked: true
            )
        case let .failed(message):
            GroupBox("Installierte V1") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Button("Erneut suchen") {
                        Task { await store.discoverMigrationSources(force: true) }
                    }
                    .disabled(isBusy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
    }

    private func discoveredSourceBox(
        _ source: V1DiscoveredSource,
        title: String,
        message: String,
        isBlocked: Bool
    ) -> some View {
        GroupBox("Installierte V1") {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    title,
                    systemImage: isBlocked ? "exclamationmark.lock.fill" : "checkmark.seal.fill"
                )
                .font(.headline)
                .foregroundStyle(isBlocked ? .orange : .green)

                Text(source.directoryURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text(message)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    discoveryBadge(
                        source.isSchemaVerified ? "V1-Schema bestätigt" : "Prüfung nach Beenden",
                        systemImage: source.isSchemaVerified ? "checkmark.shield" : "pause.circle"
                    )
                    discoveryBadge(
                        formattedBytes(source.databaseByteCount),
                        systemImage: "internaldrive"
                    )
                    if source.hasWriteAheadLog {
                        discoveryBadge("WAL erkannt", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if source.hasPhotosDirectory {
                        discoveryBadge("Fotoordner", systemImage: "photo.stack")
                    }
                }

                if let date = source.databaseModifiedAt {
                    Text("Letzte Datenbankänderung: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    if isBlocked {
                        Button("Nach Beenden erneut suchen") {
                            Task { await store.discoverMigrationSources(force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Gefundene V1-Quelle prüfen") {
                            Task { await store.inspectDiscoveredMigrationSource() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("migration.discovery.inspect")

                        Button("Erneut suchen") {
                            Task { await store.discoverMigrationSources(force: true) }
                        }
                    }
                }
                .disabled(isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private func discoveryBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.7), in: Capsule())
    }

    @ViewBuilder
    private var commitResult: some View {
        switch store.migrationCommitState {
        case .idle:
            EmptyView()
        case let .committing(fileName):
            GroupBox("V2-Bestand wird aufgebaut") {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(fileName)
                            .font(.headline)
                        Text("Quelle wird fixiert, Fotos werden kopiert und SQLite wird geprüft …")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        case let .succeeded(report):
            GroupBox("Migration abgeschlossen") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("V2-Bestand wurde erfolgreich aktiviert", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("\(report.counts.totalItems) Inventareinträge und \(report.counts.photos) Fotos · SQLite-Integrität: \(report.databaseIntegrityCheck)")
                    if let reportURL = store.migrationReportURL {
                        Text(reportURL.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if report.replacedExistingV2Data {
                        Text("Der vorherige V2-Bestand wurde als Backup erhalten.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        case let .failed(message):
            GroupBox("Migration fehlgeschlagen") {
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text("Der vorherige V2-Bestand wurde nicht verändert oder automatisch wiederhergestellt.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var inspectionResult: some View {
        switch store.migrationInspectionState {
        case .idle:
            GroupBox("V1-Quelle") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Wähle ein V1-ZIP (Schema 3–6), ein älteres JSON-Vollbackup oder den V1-Datenordner mit keyboard-manager.sqlite und photos/. Beende V1 vor einer direkten SQLite-Prüfung. Die Quelle bleibt unverändert.")
                        .foregroundStyle(.secondary)
                    Button("V1-Quelle auswählen …") {
                        showingBackupImporter = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }

        case let .inspecting(fileName):
            GroupBox("Prüflauf") {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(fileName)
                            .font(.headline)
                        Text("Metadaten, Beziehungen, Prüfsummen und Bilddaten werden validiert …")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }

        case let .failed(message):
            GroupBox("Prüfung fehlgeschlagen") {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }

        case let .ready(report):
            reportView(report)
        }
    }

    private func reportView(_ report: MigrationDryRunReport) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Prüfergebnis") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        report.canImport ? "Quelle ist für den Import bereit" : "Quelle enthält blockierende Fehler",
                        systemImage: report.canImport ? "checkmark.seal.fill" : "xmark.octagon.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(report.canImport ? .green : .red)

                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        reportRow(report.sourceKind == .sqliteDirectory ? "Ordner" : "Datei", report.sourceFileName)
                        reportRow("Quelle", report.sourceKind.displayName)
                        reportRow(
                            "V1",
                            report.schemaVersion == 0
                                ? "Version \(report.sourceVersion), ohne Schemaangabe"
                                : "Version \(report.sourceVersion), Schema \(report.schemaVersion)"
                        )
                        reportRow("Dateigröße", formattedBytes(report.sourceByteCount))
                        reportRow("SHA-256", report.sourceSHA256)
                        reportRow("Geprüfte Bilddaten", formattedBytes(report.validatedPhotoByteCount))
                        reportRow("Hinweise", "\(report.warningCount) Warnung(en), \(report.errorCount) Fehler")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }

            GroupBox("Erkannter Bestand") {
                HStack(spacing: 12) {
                    countCard("Keyboards", report.counts.boards, "keyboard")
                    countCard("Keycaps", report.counts.keycapSets, "square.grid.3x3.fill")
                    countCard("Artisans", report.counts.artisanSets, "sparkles")
                    countCard("Switches", report.counts.switchSets, "switch.2")
                    countCard("Fotos", report.counts.photos, "photo.stack")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }

            if !report.issues.isEmpty {
                GroupBox("Validierungshinweise") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(report.issues) { issue in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.localizedMessage)
                                    Text("Betroffen: \(issue.affectedItems) · \(issue.code)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func reportRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func countCard(_ title: String, _ count: Int, _ systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            Text(count, format: .number)
                .font(.title2.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 86, maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var isInspecting: Bool {
        if case .inspecting = store.migrationInspectionState { return true }
        return false
    }

    private var isBusy: Bool {
        if case .scanning = store.migrationDiscoveryState { return true }
        if isInspecting { return true }
        if case .committing = store.migrationCommitState { return true }
        return false
    }

    private var confirmationMessage: String {
        if store.hasExistingV2Data {
            return L10n.text("Der aktuelle V2-Bestand wird zuerst vollständig in Backups verschoben. Danach wird der geprüfte Staging-Bestand aktiviert. Die V1-Quelle wird nicht verändert.")
        }
        return L10n.text("V2 fixiert die Quelle zunächst in einem eigenen Staging-Bereich, prüft Hash, Fotos und SQLite erneut und aktiviert den Bestand erst nach erfolgreicher Abschlussprüfung. V1 bleibt unverändert.")
    }

    private var readinessDetail: String {
        if case let .blocked(reason) = store.migrationReadiness { return reason }
        return L10n.text("Probe, Validierung, Vorschau und explizite Bestätigung gehen jedem späteren Commit voraus.")
    }

    private func formattedBytes(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func sourceIcon(for kind: MigrationSourceKind) -> String {
        switch kind {
        case .zipBackup: "doc.zipper"
        case .sqliteDirectory: "externaldrive"
        case .legacyJSON: "curlybraces"
        case .webStorageExport: "archivebox"
        }
    }
}
