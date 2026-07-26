import SwiftUI

struct SettingsView: View {
    @Bindable var store: InventoryStore
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

            if let message = store.languagePersistenceError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 290)
        .navigationTitle("Allgemein")
    }
}
