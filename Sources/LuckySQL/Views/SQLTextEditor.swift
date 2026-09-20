import AppKit
import SwiftUI

struct SQLTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let editor = NSTextView()
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 12, height: 10)
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.backgroundColor = .textBackgroundColor
        editor.textColor = .textColor
        editor.string = text
        scroll.documentView = editor
        context.coordinator.highlight(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        let selection = editor.selectedRanges
        editor.string = text
        editor.selectedRanges = selection
        context.coordinator.highlight(editor)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: SQLTextEditor
        private var highlighting = false
        private let keywords = "SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AS|AND|OR|NOT|NULL|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|ALTER|DROP|TABLE|DATABASE|USE|SHOW|ORDER|BY|GROUP|HAVING|LIMIT|OFFSET|DISTINCT|UNION|ALL|CASE|WHEN|THEN|ELSE|END|IS|IN|LIKE|ASC|DESC"

        init(_ parent: SQLTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !highlighting, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            highlight(editor)
        }

        func highlight(_ editor: NSTextView) {
            guard let storage = editor.textStorage else { return }
            highlighting = true
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.textColor
            ], range: range)
            apply("\\b(\(keywords))\\b", color: .systemBlue, to: storage, options: .caseInsensitive)
            apply("'(?:''|[^'])*'", color: .systemRed, to: storage)
            apply("`[^`]*`", color: .systemPurple, to: storage)
            apply("--.*$|/\\*[\\s\\S]*?\\*/", color: .systemGreen, to: storage, options: [.anchorsMatchLines])
            storage.endEditing()
            highlighting = false
        }

        private func apply(_ pattern: String, color: NSColor, to storage: NSTextStorage, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let range = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                if let match { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
            }
        }
    }
}
