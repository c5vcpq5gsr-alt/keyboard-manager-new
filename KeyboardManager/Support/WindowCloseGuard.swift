import AppKit
import SwiftUI

/// Bridges the one window behavior SwiftUI does not expose: vetoing the red
/// close button while an editor contains unsaved changes.
@MainActor
struct WindowCloseGuard: NSViewRepresentable {
    var closeRevision: Int
    var shouldAllowClose: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            initialCloseRevision: closeRevision,
            shouldAllowClose: shouldAllowClose
        )
    }

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        context.coordinator.shouldAllowClose = shouldAllowClose
        context.coordinator.attach(to: nsView.window)
        context.coordinator.closeIfRequested(revision: closeRevision)
    }

    static func dismantleNSView(_ nsView: WindowReaderView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var shouldAllowClose: () -> Bool

        private var lastCloseRevision: Int
        private weak var window: NSWindow?
        private var delegateProxy: WindowDelegateProxy?

        init(
            initialCloseRevision: Int,
            shouldAllowClose: @escaping () -> Bool
        ) {
            lastCloseRevision = initialCloseRevision
            self.shouldAllowClose = shouldAllowClose
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            guard self.window !== window || window.delegate !== delegateProxy else {
                return
            }

            detach()

            let proxy = WindowDelegateProxy(
                forwardedDelegate: window.delegate,
                shouldAllowClose: { [weak self] in
                    self?.shouldAllowClose() ?? true
                }
            )
            self.window = window
            delegateProxy = proxy
            window.delegate = proxy
        }

        func closeIfRequested(revision: Int) {
            guard revision != lastCloseRevision else { return }
            lastCloseRevision = revision
            guard let window, let delegateProxy else { return }
            delegateProxy.allowNextClose = true
            Task { @MainActor [weak window] in
                await Task.yield()
                window?.performClose(nil)
            }
        }

        func detach() {
            if let window, window.delegate === delegateProxy {
                window.delegate = delegateProxy?.forwardedDelegate
            }
            window = nil
            delegateProxy = nil
        }
    }
}

@MainActor
final class WindowReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

@MainActor
private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    nonisolated(unsafe) weak var forwardedDelegate: (any NSWindowDelegate)?
    var allowNextClose = false

    private let shouldAllowClose: () -> Bool

    init(
        forwardedDelegate: (any NSWindowDelegate)?,
        shouldAllowClose: @escaping () -> Bool
    ) {
        self.forwardedDelegate = forwardedDelegate
        self.shouldAllowClose = shouldAllowClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowNextClose {
            allowNextClose = false
            return true
        }
        guard shouldAllowClose() else { return false }
        return forwardedDelegate?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector)
            || forwardedDelegate?.responds(to: aSelector) == true
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: aSelector) == true {
            return forwardedDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}
