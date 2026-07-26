import AppKit
import Observation
import SwiftUI

struct InventoryLargePhotoView: View {
    @Bindable var store: InventoryStore
    var item: InventoryItemSummary
    var navigator: InventoryLargePhotoNavigator
    var onPhotoSelection: (String?) -> Void
    var onDismiss: () -> Void

    init(
        store: InventoryStore,
        item: InventoryItemSummary,
        navigator: InventoryLargePhotoNavigator,
        onPhotoSelection: @escaping (String?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.item = item
        self.navigator = navigator
        self.onPhotoSelection = onPhotoSelection
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ManagedPhotoView(
                store: store,
                record: store.photoRecord(id: navigator.selectedPhotoID ?? item.mainPhotoID ?? item.photoIDs.first),
                purpose: .full
            )
            .padding(44)

            VStack {
                HStack {
                    Button("Großansicht schließen", systemImage: "xmark") {
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Text(positionText)
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            navigator.stepPhoto(by: -1)
                        } label: {
                            Label("Vorheriges Foto", systemImage: "chevron.left")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(currentIndex == 0)

                        Button {
                            navigator.stepPhoto(by: 1)
                        } label: {
                            Label("Nächstes Foto", systemImage: "chevron.right")
                                .labelStyle(.iconOnly)
                        }
                        .disabled(currentIndex == item.photoIDs.count - 1)
                    }
                }
                .padding(20)
                .foregroundStyle(.white)

                Spacer()
            }
        }
        .onExitCommand {
            onDismiss()
        }
        .onChange(of: navigator.selectedPhotoID) { _, newValue in
            onPhotoSelection(newValue)
        }
        .frame(minWidth: 800, minHeight: 450)
    }

    private var currentIndex: Int {
        navigator.currentIndex
    }

    private var positionText: String {
        guard !item.photoIDs.isEmpty else { return "" }
        return L10n.text("%lld von %lld", arguments: currentIndex + 1, item.photoIDs.count)
    }

}

@MainActor
@Observable
final class InventoryLargePhotoNavigator {
    let photoIDs: [String]
    var selectedPhotoID: String?

    init(photoIDs: [String], selectedPhotoID: String?) {
        self.photoIDs = photoIDs
        self.selectedPhotoID = selectedPhotoID ?? photoIDs.first
    }

    var currentIndex: Int {
        guard let selectedPhotoID,
              let index = photoIDs.firstIndex(of: selectedPhotoID) else {
            return 0
        }
        return index
    }

    func stepPhoto(by offset: Int) {
        let nextIndex = currentIndex + offset
        guard photoIDs.indices.contains(nextIndex) else { return }
        selectedPhotoID = photoIDs[nextIndex]
    }
}

@MainActor
final class InventoryLargePhotoWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var navigator: InventoryLargePhotoNavigator?
    weak var parentWindow: NSWindow?
    private weak var presentationParentWindow: NSWindow?

    func present(
        store: InventoryStore,
        item: InventoryItemSummary,
        selectedPhotoID: String?,
        onPhotoSelection: @escaping (String?) -> Void
    ) {
        close()

        let navigator = InventoryLargePhotoNavigator(
            photoIDs: item.photoIDs,
            selectedPhotoID: selectedPhotoID ?? item.mainPhotoID
        )
        let content = InventoryLargePhotoView(
            store: store,
            item: item,
            navigator: navigator,
            onPhotoSelection: onPhotoSelection,
            onDismiss: { [weak self] in self?.close() }
        )
        // V1 keeps the large photo inside its application window. The
        // Spotlight is a sheet, so its sheet parent is the actual visual
        // boundary for the overlay.
        let sizingWindow = parentWindow?.sheetParent ?? parentWindow
        let overlayFrame = sizingWindow?.frame
            ?? NSRect(x: 0, y: 0, width: 1_600, height: 900)
        let window = NSPanel(
            contentRect: overlayFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: content)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.level = .modalPanel
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.setFrame(overlayFrame, display: true)
        // The Spotlight sheet must own the overlay so AppKit always orders it
        // above the sheet. Sizing still follows the larger main app window.
        parentWindow?.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.navigator = navigator
        presentationParentWindow = parentWindow
    }

    func close() {
        if let window {
            presentationParentWindow?.removeChildWindow(window)
            window.orderOut(nil)
        }
        window = nil
        navigator = nil
        presentationParentWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        navigator = nil
    }

    func stepPhotoIfPresented(by offset: Int) -> Bool {
        guard let navigator else { return false }
        navigator.stepPhoto(by: offset)
        return true
    }
}

struct SpotlightWindowReference: NSViewRepresentable {
    var onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowReferenceView(onWindowChange: onWindowChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReferenceView: NSView {
        let onWindowChange: (NSWindow?) -> Void

        init(onWindowChange: @escaping (NSWindow?) -> Void) {
            self.onWindowChange = onWindowChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange(window)
        }
    }
}
