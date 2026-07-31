import SwiftUI

@main
struct KeyboardManagerApp: App {
    @State private var store: InventoryStore
    @State private var updateController = AppUpdateController()
    @AppStorage(AppLanguage.preferenceKey) private var preferredLanguage = AppLanguage.german.rawValue
    @AppStorage("followSystemAppearance") private var followSystemAppearance = true
    private let shouldAdoptStoredLanguage: Bool

    init() {
        shouldAdoptStoredLanguage = UserDefaults.standard.object(
            forKey: AppLanguage.preferenceKey
        ) == nil
        let environment = ProcessInfo.processInfo.environment
        if let testRoot = environment["KEYBOARD_MANAGER_UI_TEST_ROOT"], !testRoot.isEmpty {
            let rootURL = URL(fileURLWithPath: testRoot, isDirectory: true)
            let databaseURL = rootURL
                .appendingPathComponent("inventory.sqlite")
            let processDetector = V1ProcessDetector(lookup: { false })
            let discoveryService = V1SourceDiscoveryService(
                applicationSupportRoots: {
                    [
                        rootURL.appendingPathComponent(
                            "V1 Application Support",
                            isDirectory: true
                        )
                    ]
                },
                processDetector: processDetector
            )
            _store = State(
                initialValue: InventoryStore(
                    repository: SQLiteInventoryRepository(databaseURL: databaseURL),
                    migrationService: V1MigrationService(
                        discoveryService: discoveryService
                    ),
                    migrationCommitService: MigrationCommitService(
                        layout: MigrationStorageLayout(
                            rootURL: rootURL.appendingPathComponent(
                                "Migration",
                                isDirectory: true
                            )
                        ),
                        v1ProcessDetector: processDetector
                    )
                )
            )
        } else {
            _store = State(initialValue: InventoryStore())
        }
    }

    var body: some Scene {
        WindowGroup("Keyboard Manager") {
            ContentView(
                store: store,
                updateController: updateController,
                preferredLanguage: $preferredLanguage,
                shouldAdoptStoredLanguage: shouldAdoptStoredLanguage,
                shouldCheckForUpdates: ProcessInfo.processInfo.environment[
                    "KEYBOARD_MANAGER_UI_TEST_ROOT"
                ] == nil
            )
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(followSystemAppearance ? nil : .light)
                .environment(
                    \.locale,
                    AppLanguage.normalized(preferredLanguage).locale
                )
        }
        .defaultSize(width: 1600, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Sammlung") {
                Button("Neues Board") {
                    store.prepareNewItem(.board)
                }
                .keyboardShortcut("n", modifiers: .command)

                Menu("Neuer Eintrag") {
                    ForEach(InventoryItemKind.allCases) { kind in
                        Button(kind.singularName) {
                            store.prepareNewItem(kind)
                        }
                    }
                }

                Divider()

                Button("V1-Migration öffnen") {
                    store.showMigration()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(
                store: store,
                updateController: updateController,
                preferredLanguage: $preferredLanguage
            )
            .preferredColorScheme(followSystemAppearance ? nil : .light)
            .environment(
                \.locale,
                AppLanguage.normalized(preferredLanguage).locale
            )
        }
    }
}
