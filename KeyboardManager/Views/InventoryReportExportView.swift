import SwiftUI

struct InventoryReportExportView: View {
    var currentKind: InventoryItemKind
    var export: (InventoryReportOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options = InventoryReportOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Bestandsbericht exportieren")
                    .font(.title2.weight(.semibold))
                Text("Erstellt einen eigenständigen, kontrollierten Bericht aus dem aktuellen V2-Bestand.")
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker("Format", selection: $options.format) {
                    ForEach(InventoryReportFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Umfang", selection: $options.scope) {
                    ForEach(InventoryReportScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }

                Toggle("Aktuelle Filter anwenden", isOn: $options.appliesFilters)
                Toggle("Vorschaubilder einbetten", isOn: $options.includesImages)
                    .disabled(options.format != .pdf)
            }
            .formStyle(.grouped)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label(scopeDescription, systemImage: "doc.text.magnifyingglass")
                    if options.format == .xlsx {
                        Text("Excel enthält eine Übersicht und je Bereich ein filterbares Tabellenblatt.")
                    } else {
                        Text("PDF enthält ein Deckblatt, wiederholte Tabellenköpfe und Seitenzahlen.")
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Weiter …") {
                    var finalOptions = options
                    if finalOptions.format == .xlsx {
                        finalOptions.includesImages = false
                    }
                    dismiss()
                    export(finalOptions)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: options.format) {
            if options.format == .xlsx {
                options.includesImages = false
            }
        }
    }

    private var scopeDescription: String {
        switch options.scope {
        case .all:
            "Exportiert Keyboards, Keycap-Sets, Artisans und Switches."
        case .current:
            "Exportiert nur den Bereich „\(currentKind.displayName)“."
        }
    }
}
