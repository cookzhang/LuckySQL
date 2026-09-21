import SwiftUI

struct TableFinderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?
    @State private var loading = true
    @FocusState private var focused: Bool
    private var tables: [DatabaseTable] {
        let available = model.schemas.sorted { left, right in
            if (left.name == model.selectedDatabase) != (right.name == model.selectedDatabase) { return left.name == model.selectedDatabase }
            return left.name < right.name
        }.flatMap(\.tables)
        if search.isEmpty {
            let recent = model.recentTables.filter { available.contains($0) }
            return recent + available.filter { !recent.contains($0) }
        }
        return available.filter { $0.id.localizedCaseInsensitiveContains(search) }
    }
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
