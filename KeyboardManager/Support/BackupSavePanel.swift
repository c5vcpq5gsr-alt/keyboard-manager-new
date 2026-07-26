import AppKit
import UniformTypeIdentifiers

@MainActor
enum BackupSavePanel {
    static func chooseDestination(
        defaultFileName: String = BackupExportService.defaultFileName
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.text("ZIP-Backup speichern")
        panel.prompt = L10n.text("Backup sichern")
        panel.nameFieldLabel = L10n.text("Dateiname:")
        panel.nameFieldStringValue = defaultFileName
        panel.allowedContentTypes = [.zip]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
