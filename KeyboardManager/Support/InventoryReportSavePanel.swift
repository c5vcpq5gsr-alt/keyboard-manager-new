import AppKit
import UniformTypeIdentifiers

@MainActor
enum InventoryReportSavePanel {
    static func chooseDestination(for format: InventoryReportFormat) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.text(
            "%@-Bestandsbericht speichern",
            arguments: format.title
        )
        panel.prompt = L10n.text("Bericht sichern")
        panel.nameFieldLabel = L10n.text("Dateiname:")
        panel.nameFieldStringValue = InventoryReportExportService.defaultFileName(for: format)
        panel.allowedContentTypes = [
            format == .pdf ? .pdf : (UTType(filenameExtension: "xlsx") ?? .data)
        ]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
