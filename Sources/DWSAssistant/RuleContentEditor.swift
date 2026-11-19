import AppKit
import SwiftUI

/// Plain-text editing with a width-tracking container. Character wrapping keeps
/// Chinese phrases and script paths from moving to the next line as a block.
struct RuleContentEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.locale) private var locale

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = Self.makeTextView()
        editor.setAccessibilityLabel(UILocalizer(locale: locale).label("规则内容"))
        editor.delegate = context.coordinator
        editor.string = text
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.setAccessibilityLabel(UILocalizer(locale: locale).label("规则内容"))
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
    }

    static func makeTextView() -> NSTextView {
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.drawsBackground = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.lineFragmentPadding = 5
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineBreakStrategy = []
        editor.defaultParagraphStyle = paragraph
        editor.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = NSColor(AssistantTheme.text)
        editor.insertionPointColor = NSColor(AssistantTheme.accent)
        editor.typingAttributes = [.paragraphStyle: paragraph, .font: editor.font!, .foregroundColor: editor.textColor!]
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.setAccessibilityLabel("规则内容")
        return editor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
