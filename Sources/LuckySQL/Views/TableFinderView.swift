import SwiftUI

@MainActor enum WorkspaceWindows {
    static let windows = NSHashTable<NSWindow>.weakObjects()
    static func closesQueryTab(in window: NSWindow, section: WorkspaceSection) -> Bool {
        windows.contains(window) && section == .query
    }
}

struct WorkspaceWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WorkspaceWindows.windows.add(window) }
        }
    }
}

struct TableFinderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?
    @State private var loading = true
    @State private var index: TableSearchIndex?
    @State private var indexRevision = 0
    @State private var tables: [DatabaseTable] = []
    @FocusState private var focused: Bool
    private struct SearchRequest: Equatable { let text: String; let revision: Int }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Find Table").font(.title2.bold()); Spacer(); if loading { ProgressView().controlSize(.small) }; Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            TextField("Search all databases and tables…", text: $search).textFieldStyle(.roundedBorder).focused($focused)
            Text("Recent tables first · searches databases even when the sidebar is collapsed").font(.caption).foregroundStyle(.secondary)
            List(tables, selection: $selection) { table in
                HStack { Image(systemName: model.recentTables.contains(table) ? "clock" : "tablecells"); Text(table.name); Spacer(); Text(table.schema).foregroundStyle(.secondary) }.tag(table.id)
                    .onTapGesture(count: 2) { open(table) }
            }
            HStack { Text("\(tables.count) tables").font(.caption); Spacer(); Button("Open Table") { if let table = tables.first(where: { $0.id == selection }) ?? tables.first { open(table) } }.keyboardShortcut(.defaultAction).disabled(tables.isEmpty || model.isRunning) }
        }.padding(20).frame(width: 620, height: 480)
        .task { focused = true; await model.loadAllTablesForSearch(); loading = false }
        .task(id: TableSearchSnapshot(schemas: model.schemas, database: model.selectedDatabase, recent: model.recentTables)) {
            let snapshot = TableSearchSnapshot(schemas: model.schemas, database: model.selectedDatabase, recent: model.recentTables)
            let built = await Task.detached(priority: .utility) { TableSearchIndex(snapshot) }.value
            guard !Task.isCancelled else { return }
            index = built; indexRevision += 1
        }
        .task(id: SearchRequest(text: search, revision: indexRevision)) {
            guard let index else { return }
            let query = search
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(70)) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { index.search(query) }.value
            guard !Task.isCancelled else { return }
            tables = found
            if !found.contains(where: { $0.id == selection }) { selection = found.first?.id }
        }
    }
    private func open(_ table: DatabaseTable) { model.browse(table); dismiss() }
}

/// Native AppKit divider persistence, without replacing SwiftUI's view ownership.
struct SplitLayoutPersistence: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.setFrameAutosaveName("LuckySQL.workspace.window")
                func visit(_ view: NSView) {
                    if let split = view as? NSSplitView, split.autosaveName == nil {
                        split.autosaveName = split.isVertical ? "LuckySQL.sidebar" : "LuckySQL.editor-results"
                    }
                    for child in view.subviews { visit(child) }
                }
                if let root = window.contentView { visit(root) }
            }
        }
    }
}
