import AppKit
import SwiftUI

@MainActor
final class AssistantWindowLifecycle: NSObject {
    private weak var mainWindow: NSWindow?
    private let notifications: NotificationCenter
    private let applyPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private var closeTask: Task<Void, Never>?

    init(notifications: NotificationCenter = .default,
         applyPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { policy in
             if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
         }) {
        self.notifications = notifications
        self.applyPolicy = applyPolicy
        super.init()
    }

    func attach(to window: NSWindow) {
        guard mainWindow !== window else { return }
        notifications.removeObserver(self)
        mainWindow = window
        // Quick-panel and menu-bar windows never determine Dock visibility.
        notifications.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
        notifications.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
        prepareToOpenMainWindow()
    }

    func prepareToOpenMainWindow() {
        closeTask?.cancel(); closeTask = nil
        applyPolicy(.regular)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        prepareToOpenMainWindow()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        closeTask?.cancel()
        // Let AppKit finish closing before changing the application's mode.
        closeTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.applyPolicy(.accessory)
            self.closeTask = nil
        }
    }

    deinit {
        closeTask?.cancel()
        notifications.removeObserver(self)
    }
}

struct MainWindowObserver: NSViewRepresentable {
    let lifecycle: AssistantWindowLifecycle

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.didAttach = { [weak lifecycle] window in lifecycle?.attach(to: window) }
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        var didAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { didAttach?(window) }
        }
    }
}
