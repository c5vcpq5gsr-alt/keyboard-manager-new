import SwiftUI

struct SettingsView: View {
    @Bindable var store: InventoryStore
    @Bindable var updateController: AppUpdateController
    @Binding var preferredLanguage: String
    @AppStorage("followSystemAppearance") private var followSystemAppearance = true

    var body: some View {
        Form {
            Picker("Sprache", selection: $preferredLanguage) {
                Text("Deutsch").tag("de")
                Text("English").tag("en")
            }

            Toggle("Systemdarstellung verwenden", isOn: $followSystemAppearance)
            Text(
                followSystemAppearance
                    ? "Die App folgt Hell- oder Dunkelmodus von macOS."
                    : "Die App verwendet den hellen Modus."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            LabeledContent("Datenhaltung", value: "SQLite · lokal")
            LabeledContent("Migrationsmodus", value: "Nur lesende V1-Quelle")

            Section("Updates") {
                LabeledContent("Installierte Version", value: updateController.installedVersion)
                updateStatus
                Button("Nach Updates suchen") {
                    Task {
                        await updateController.checkForUpdates()
                    }
                }
                .disabled(updateController.isWorking)
            }

            if let message = store.languagePersistenceError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 380)
        .navigationTitle("Allgemein")
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updateController.state {
        case .idle:
            Text("Beim Start wird nach stabilen GitHub-Releases gesucht.")
                .foregroundStyle(.secondary)
        case .checking:
            Label("Suche nach Updates …", systemImage: "arrow.triangle.2.circlepath")
        case .upToDate:
            Label("Die App ist aktuell.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .updateAvailable(update):
            HStack {
                Label("Version \(update.version.description) ist verfügbar.", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Button("Laden") {
                    Task {
                        await updateController.downloadAndOpen(update)
                    }
                }
            }
        case .downloading:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Installer wird geladen und geprüft …")
            }
        case let .installerOpened(update, url):
            Label(
                "Version \(update.version.description) wurde geprüft und geöffnet: \(url.lastPathComponent)",
                systemImage: "checkmark.shield.fill"
            )
            .foregroundStyle(.green)
        case let .failed(message):
            Label("Updateprüfung fehlgeschlagen: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
