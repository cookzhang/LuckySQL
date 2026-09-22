import AppKit
import SwiftUI

struct SQLTextEditor: NSViewRepresentable {
    @Binding var text: String
    var selection: Binding<NSRange> = .constant(NSRange(location: 0, length: 0))
    var completionCatalog = SQLCompletionCatalog()
    var isEditable = true
    var documentID = ""
    var sessions: EditorSessions?
    var onAnalysis: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        install(in: host, coordinator: context.coordinator)
        return host
    }
    private func makeScroll(_ coordinator: Coordinator) -> NSScrollView {
        let scroll = CodeScrollView()
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        editor.clipsToBounds = true
        editor.delegate = coordinator
        editor.completionCatalog = completionCatalog
        editor.analysisID = documentID
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
        coordinator.documentID = documentID
        coordinator.scheduleHighlight(editor)
        return scroll
    }
    private func install(in host: NSView, coordinator: Coordinator) {
        if let old = host.subviews.first as? NSScrollView {
            (old.documentView as? CodeTextView)?.dismissCompletions()
            (old.documentView as? CodeTextView)?.delegate = nil
            old.removeFromSuperview()
        }
        let scroll = sessions?.views[documentID] ?? makeScroll(coordinator)
        sessions?.views[documentID] = scroll
        coordinator.documentID = documentID
        (scroll.documentView as? CodeTextView)?.delegate = coordinator
        scroll.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor), scroll.topAnchor.constraint(equalTo: host.topAnchor), scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        if let editor = scroll.documentView as? CodeTextView { coordinator.scheduleHighlight(editor) }
        if isEditable {
            DispatchQueue.main.async { [weak scroll] in
                guard let editor = scroll?.documentView as? CodeTextView, editor.window?.isKeyWindow == true else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }
    func updateNSView(_ host: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.documentID != documentID { install(in: host, coordinator: coordinator) }
        guard let scroll = host.subviews.first as? NSScrollView else { return }
        guard let editor = scroll.documentView as? CodeTextView else { return }
        editor.completionCatalog = completionCatalog
        editor.analysisID = documentID
        editor.isEditable = isEditable
        if editor.hasMarkedText() { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        if editor.string != text || coordinator.documentID != documentID {
            let changedDocument = coordinator.documentID != documentID
            if changedDocument {
                editor.dismissCompletions()
                editor.string = text; editor.undoManager?.removeAllActions()
            } else {
                editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            }
            coordinator.documentID = documentID
            let range = selection.wrappedValue
            editor.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: min(range.length, max(0, (text as NSString).length - range.location))))
            coordinator.scheduleHighlight(editor)
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
        private var highlightTask: Task<Void, Never>?
        init(_ parent: SQLTextEditor) { self.parent = parent }
        func undoManager(for view: NSTextView) -> UndoManager? { (view as? CodeTextView)?.undoManager }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            parent.text = editor.string
            parent.selection.wrappedValue = editor.selectedRange()
            scheduleHighlight(editor)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            parent.selection.wrappedValue = editor.selectedRange()
        }
        func highlight(_ editor: NSTextView) {
            apply(SQLTools.tokens(editor.string), to: editor)
        }
        func scheduleHighlight(_ editor: NSTextView) {
            highlightTask?.cancel()
            let source = editor.string, id = documentID
            highlightTask = Task { @MainActor [weak self, weak editor] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                let analysis = await SQLAnalysisService.shared.analyze(source, document: id)
                guard !Task.isCancelled, let self, self.documentID == id, let editor, editor.string == source else { return }
                if let code = editor as? CodeTextView {
                    code.analysis = analysis
                    code.colorVisibleText()
                } else { self.apply(analysis.tokens, to: editor) }
                self.parent.onAnalysis?(analysis.lineStarts.count)
            }
        }
        private func apply(_ tokens: [SQLToken], to editor: NSTextView) {
            guard !editor.hasMarkedText(), let layout = editor.layoutManager else { return }
            let range = NSRange(location: 0, length: (editor.string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for token in tokens {
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

/// Owned by the workspace, not a SwiftUI view lifetime. Each tab keeps its native
/// undo manager, selection and scroll offset, including when browsing a table.
@MainActor final class EditorSessions {
    var views: [String: NSScrollView] = [:]
    func remove(_ id: UUID) {
        (views[id.uuidString]?.documentView as? CodeTextView)?.undoManager?.removeAllActions()
        views.removeValue(forKey: id.uuidString)
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

final class CodeTextView: NSTextView {
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
    var analysisID = UUID().uuidString
    var analysis: SQLAnalysis?
    private var scrollObserver: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.colorVisibleText() }
        }
    }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
    func colorVisibleText() {
        guard !hasMarkedText(), let analysis, analysis.sql == string, let layout = layoutManager, let container = textContainer else { return }
        let glyphs = layout.glyphRange(forBoundingRect: visibleRect.insetBy(dx: 0, dy: -300), in: container)
        let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        var low = 0, high = analysis.tokens.count
        while low < high { let mid = (low + high) / 2; if NSMaxRange(analysis.tokens[mid].range) < range.location { low = mid + 1 } else { high = mid } }
        for token in analysis.tokens.dropFirst(low) {
            if token.range.location > NSMaxRange(range) { break }
            let color: NSColor
            switch token.kind {
            case .keyword: color = .systemBlue
            case .string: color = .systemRed
            case .identifier: color = .systemPurple
            case .number: color = .systemOrange
            case .comment: color = .systemGreen
            default: continue
            }
            layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: NSIntersectionRange(range, token.range))
        }
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
    var completionCatalog = SQLCompletionCatalog() {
        didSet {
            if (awaitingMetadata || suggestions.isShown),
               oldValue.schemas != completionCatalog.schemas || oldValue.columns != completionCatalog.columns {
                DispatchQueue.main.async { [weak self] in self?.showCompletions(automatic: true) }
            }
        }
    }
    private var completionWork: DispatchWorkItem?
    private let suggestions = NSPopover()
    private var request: SQLCompletionRequest?
    private var selectedSuggestion = 0
    private var completionSource = ""
    private var awaitingMetadata = false
    private var completionTask: Task<Void, Never>?
    private let suggestionModel = CompletionSuggestionModel()

    override func keyDown(with event: NSEvent) {
        if (event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == " ") || (event.modifierFlags.contains(.option) && event.keyCode == 53) { showCompletions(automatic: false); return }
        if suggestions.isShown {
            if event.keyCode == 53 { dismissCompletions(); return }
            if event.keyCode == 125 || event.keyCode == 126, let request {
                selectedSuggestion = (selectedSuggestion + (event.keyCode == 125 ? 1 : request.candidates.count - 1)) % request.candidates.count
                renderSuggestions(); return
            }
            if event.keyCode == 36 || event.keyCode == 48 { acceptCompletion(selectedSuggestion); return }
            if event.modifierFlags.contains(.command) || [123, 124].contains(event.keyCode) { dismissCompletions() }
        }
        let previous = string
        super.keyDown(with: event)
        completionWork?.cancel()
        guard string != previous, !hasMarkedText(), selectedRange().length == 0,
              !event.modifierFlags.contains(.command) else { return }
        let work = DispatchWorkItem { [weak self] in self?.showCompletions(automatic: true) }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    override func mouseDown(with event: NSEvent) { dismissCompletions(); super.mouseDown(with: event) }
    override func resignFirstResponder() -> Bool { dismissCompletions(); return super.resignFirstResponder() }
    override func complete(_ sender: Any?) { showCompletions(automatic: false) }

    func dismissCompletions() { completionWork?.cancel(); completionTask?.cancel(); suggestions.close(); request = nil; awaitingMetadata = false }
    func showCompletions(automatic: Bool) {
        guard isEditable, !hasMarkedText(), selectedRange().length == 0, window?.firstResponder === self else { dismissCompletions(); return }
        completionTask?.cancel()
        let source = string, caret = selectedRange().location, catalog = completionCatalog, id = analysisID
        completionTask = Task { @MainActor [weak self] in
            let next = await SQLAnalysisService.shared.completion(source, document: id, caret: caret, catalog: catalog, automatic: automatic)
            guard !Task.isCancelled, let self, self.string == source, self.selectedRange().location == caret, !self.hasMarkedText(), self.window?.firstResponder === self else { return }
            self.present(next)
        }
    }
    private func present(_ next: SQLCompletionRequest?) {
        guard let next else {
            dismissCompletions(); awaitingMetadata = true; return
        }
        awaitingMetadata = false
        let previous = request?.candidates.indices.contains(selectedSuggestion) == true ? request?.candidates[selectedSuggestion] : nil
        request = next; completionSource = string
        selectedSuggestion = previous.flatMap { next.candidates.firstIndex(of: $0) } ?? 0
        suggestions.behavior = .applicationDefined; suggestions.animates = false
        renderSuggestions()
        let screen = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        guard let window else { return }
        let rect = convert(window.convertFromScreen(screen), from: nil)
        if !suggestions.isShown { suggestions.show(relativeTo: rect, of: self, preferredEdge: .maxY) }
    }
    private func renderSuggestions() {
        guard let request else { return }
        suggestionModel.words = request.candidates; suggestionModel.selected = selectedSuggestion
        suggestionModel.prefix = request.prefix; suggestionModel.details = request.details
        if suggestions.contentViewController == nil {
            suggestions.contentViewController = NSHostingController(rootView: CompletionSuggestions(model: suggestionModel) { [weak self] in self?.acceptCompletion($0) })
        }
        suggestions.contentSize = NSSize(width: 380, height: min(request.candidates.count, 8) * 40 + 28)
    }
    private func acceptCompletion(_ index: Int) {
        guard let request, request.candidates.indices.contains(index), string == completionSource,
              selectedRange().location == request.caret else { dismissCompletions(); return }
        let word = request.candidates[index]
        dismissCompletions()
        window?.makeFirstResponder(self)
        insertText(word, replacementRange: request.range)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class CompletionSuggestionModel: ObservableObject {
    @Published var words: [String] = []
    @Published var selected = 0
    @Published var prefix = ""
    @Published var details: [String: String] = [:]
}
private struct CompletionSuggestions: View {
    @ObservedObject var model: CompletionSuggestionModel
    var words: [String] { model.words }
    var selected: Int { model.selected }
    let accept: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(words.indices, id: \.self) { index in
                            Button { accept(index) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    (Text(String(words[index].prefix(model.prefix.count))).bold() + Text(String(words[index].dropFirst(model.prefix.count)))).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                    Text(model.details[words[index]] ?? "Identifier").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                    .background(index == selected ? Color.accentColor.opacity(0.2) : .clear)
                            }.buttonStyle(.plain).id(index)
                        }
                    }
                }.onChange(of: selected) { _, value in proxy.scrollTo(value) }
            }
            Divider()
            Text("↑↓ Select · Tab/Return Insert · Esc Dismiss").font(.system(size: 10)).foregroundStyle(.secondary).padding(6)
        }.frame(width: 380, height: CGFloat(min(words.count, 8) * 40 + 28))
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
        var line = (editor as? CodeTextView)?.analysis?.line(at: index) ?? 1
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
