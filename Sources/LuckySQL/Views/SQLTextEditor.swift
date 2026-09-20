import AppKit
import SwiftUI

struct SQLTextEditor: NSViewRepresentable {
    @Binding var text: String
    var selection: Binding<NSRange> = .constant(NSRange(location: 0, length: 0))
    var completionWords: [String] = Array(SQLTools.keywords)
    var isEditable = true
    var documentID = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CodeScrollView()
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        editor.clipsToBounds = true
        editor.delegate = context.coordinator
        editor.isRichText = false; editor.isEditable = isEditable
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.allowsUndo = true; editor.usesFindBar = true
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.containerSize = NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.backgroundColor = .textBackgroundColor; editor.textColor = .textColor
        editor.insertionPointColor = .controlAccentColor
        editor.setAccessibilityLabel(isEditable ? "SQL editor" : "SQL preview")
        editor.string = text
        scroll.documentView = editor
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = SQLLineRuler(scrollView: scroll, orientation: .verticalRuler)
        scroll.rulersVisible = true
        context.coordinator.documentID = documentID
        context.coordinator.highlight(editor)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = isEditable
        if editor.hasMarkedText() { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        if editor.string != text || coordinator.documentID != documentID {
            let changedDocument = coordinator.documentID != documentID
            if changedDocument {
                editor.string = text; editor.undoManager?.removeAllActions()
            } else {
                editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            }
            coordinator.documentID = documentID
            let range = selection.wrappedValue
            editor.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: min(range.length, max(0, (text as NSString).length - range.location))))
            coordinator.highlight(editor)
            if changedDocument {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                editor.scrollRangeToVisible(editor.selectedRange())
            }
        }
        scroll.verticalRulerView?.needsDisplay = true
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextEditor
        var updating = false
        var documentID = ""
        private var highlightWork: DispatchWorkItem?
        init(_ parent: SQLTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            parent.text = editor.string
            parent.selection.wrappedValue = editor.selectedRange()
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak editor] in
                if let editor { self?.highlight(editor) }
            }
            highlightWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            parent.selection.wrappedValue = editor.selectedRange()
        }
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange)
            index?.pointee = 0
            return parent.completionWords.filter { $0.lowercased().hasPrefix(prefix.lowercased()) }.prefix(100).map { $0 }
        }
        func highlight(_ editor: NSTextView) {
            guard !editor.hasMarkedText(), let layout = editor.layoutManager else { return }
            let range = NSRange(location: 0, length: (editor.string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for token in SQLTools.tokens(editor.string) {
                let color: NSColor
                switch token.kind {
                case .keyword: color = .systemBlue
                case .string: color = .systemRed
                case .identifier: color = .systemPurple
                case .number: color = .systemOrange
                case .comment: color = .systemGreen
                default: continue
                }
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
            }
            editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

private final class CodeScrollView: NSScrollView {
    private var needsInitialScroll = true
    override func layout() {
        super.layout()
        if needsInitialScroll, contentView.bounds.width > 0 {
            contentView.scroll(to: .zero)
            reflectScrolledClipView(contentView)
            needsInitialScroll = false
        }
    }
}

private final class CodeTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == " " { complete(nil); return }
        super.keyDown(with: event)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class SQLLineRuler: NSRulerView {
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 48
        clipsToBounds = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor = scrollView?.documentView as? NSTextView,
              let layout = editor.layoutManager, let container = editor.textContainer else { return }
        NSColor.controlBackgroundColor.setFill(); bounds.intersection(rect).fill()
        let string = editor.string as NSString
        let visible = editor.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var index = string.lineRange(for: NSRange(location: min(characters.location, string.length), length: 0)).location
        var line = string.substring(to: index).filter { $0 == "\n" }.count + 1
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while index <= min(NSMaxRange(characters), string.length) {
            if index == string.length, string.length > 0, string.character(at: string.length - 1) != 10 { break }
            let y: CGFloat
            if index < string.length {
                let glyph = layout.glyphIndexForCharacter(at: index)
                y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            } else { y = layout.extraLineFragmentRect.minY }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y + editor.textContainerInset.height - visible.minY + 2), withAttributes: attributes)
            if index == string.length { break }
            index = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0))); line += 1
        }
    }
}
