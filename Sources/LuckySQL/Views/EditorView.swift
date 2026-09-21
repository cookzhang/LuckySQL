import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var closingTab: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.queryTabs) { tab in
                            HStack(spacing: 8) {
                                Button { model.selectTab(tab.id) } label: {
                                    Label(tab.title, systemImage: "chevron.left.forwardslash.chevron.right").lineLimit(1)
                                }.buttonStyle(.plain)
                                Button {
                                    if tab.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.closeTab(tab.id) }
                                    else { closingTab = tab.id }
                                } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                                    .buttonStyle(.plain).disabled(model.isRunning).help("Close query tab")
                            }.padding(.horizontal, 12).frame(height: 34)
                                .background(tab.id == model.activeTabID ? Color.accentColor.opacity(0.12) : .clear)
                                .overlay(alignment: .bottom) { if tab.id == model.activeTabID { Color.accentColor.frame(height: 2) } }
                        }
                    }
                }
                Button { model.newQuery() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).padding(.horizontal, 12).help("New query (⌘T)")
            }.background(.bar)
            Divider()
            HStack(spacing: 12) {
                Picker("Database", selection: $model.selectedDatabase) {
                    Text("No database").tag("")
                    if !model.selectedDatabase.isEmpty && !model.schemas.contains(where: { $0.name == model.selectedDatabase }) { Text(model.selectedDatabase).tag(model.selectedDatabase) }
                    ForEach(model.schemas) { Text($0.name).tag($0.name) }
                }.frame(maxWidth: 220).disabled(model.isRunning)
                Button("Format", systemImage: "text.alignleft") { model.sql = SQLTools.format(model.sql) }.help("Format SQL keywords and clauses")
                Button("Explain", systemImage: "list.bullet.indent") { model.explainQuery() }.disabled(!model.isConnected || model.isRunning)
                Menu("Snippets") {
                    Button("SELECT from selected table") { model.insertWhereTemplate() }.disabled(model.selectedTable == nil)
                    Button("INSERT into selected table") { model.generateInsert() }.disabled(model.selectedTable == nil)
                    Button("New table template") { model.newQuery(sql: "CREATE TABLE `new_table` (\n  `id` BIGINT NOT NULL AUTO_INCREMENT,\n  `name` VARCHAR(255) NOT NULL,\n  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,\n  PRIMARY KEY (`id`)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;", title: "Create table") }
                }.fixedSize()
                Spacer()
                Button("History", systemImage: "clock.arrow.circlepath") { model.showHistory = true }
            }.controlSize(.small).padding(.horizontal, 12).frame(height: 40)
            Divider()
            SQLTextEditor(text: $model.sql, selection: $model.sqlSelection, completionCatalog: model.completionCatalog, documentID: model.activeTabID.uuidString)
            HStack {
                Text("⌘↩ Run   ⇧⌘↩ All   ⌃Space / ⌥Esc Complete   ⌘F Find")
                Spacer()
                Text("Preview ≤ 1,000 rows · \(model.sql.components(separatedBy: "\n").count) lines")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 24).background(.bar)
        }
        .task(id: model.selectedDatabase + model.activeTabID.uuidString + String(model.isConnected)) { await model.loadCompletionMetadata() }
        .confirmationDialog("Close this query tab?", isPresented: Binding(get: { closingTab != nil }, set: { if !$0 { closingTab = nil } })) {
            Button("Close Tab", role: .destructive) { if let id = closingTab { model.closeTab(id) }; closingTab = nil }
        } message: { Text("Its local draft will be removed. Save it to a SQL file first if you want to keep it.") }
    }
}
