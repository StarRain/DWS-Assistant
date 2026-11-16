import AppKit
import SwiftUI

extension View {
    func dashboardInputFocus() -> some View {
        background(DashboardInputFocus())
    }
}

/// Keeps newly presented surfaces out of their first text field. Mouse events
/// still reach native controls; only clicks outside editable text end editing.
private struct DashboardInputFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusView { FocusView() }
    func updateNSView(_ nsView: FocusView, context: Context) {}
    static func dismantleNSView(_ nsView: FocusView, coordinator: ()) { nsView.detach() }

    final class FocusView: NSView {
        private var monitor: Any?
        private var initialFocusTask: Task<Void, Never>?
        private var interacted = false
        private weak var attachedWindow: NSWindow?

        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            attachedWindow = window
            interacted = false
            window.initialFirstResponder = self
            initialFocusTask = Task { @MainActor [weak self, weak window] in
                await Task.yield()
                guard !Task.isCancelled, let self, let window,
                      self.window === window, !self.interacted else { return }
                window.makeFirstResponder(self)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                self.interacted = true
                guard event.type == .leftMouseDown,
                      window.firstResponder is NSText || window.firstResponder is NSTextField,
                      let root = window.contentView else { return event }
                let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                var hit = root.hitTest(point)
                while let view = hit {
                    if let field = view as? NSTextField, field.isEditable { return event }
                    if let text = view as? NSTextView, text.isEditable { return event }
                    if let scroll = view as? NSScrollView,
                       let text = scroll.documentView as? NSTextView, text.isEditable { return event }
                    hit = view.superview
                }
                window.makeFirstResponder(self)
                return event
            }
        }

        func detach() {
            initialFocusTask?.cancel(); initialFocusTask = nil
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if attachedWindow?.initialFirstResponder === self { attachedWindow?.initialFirstResponder = nil }
            if attachedWindow?.firstResponder === self { attachedWindow?.makeFirstResponder(nil) }
            attachedWindow = nil
        }
    }
}
