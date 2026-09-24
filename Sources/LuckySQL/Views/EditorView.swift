import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("sqlFontSize") private var fontSize = 13.0
    @State private var parametersSQL: String?
    @State private var rename = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.queryTabs) { tab in
                            HStack(spacing: 8) {
                                Button { model.selectTab(tab.id) } label: {
                                    QueryTabLabel(title: tab.title, document: tab.document)
                                }.buttonStyle(.plain)
                                Button {
                                    model.requestCloseTab(tab.id)
                                } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                                    .buttonStyle(.plain).disabled(model.isRunning).help("Close query tab")
                            }.padding(.horizontal, 12).frame(height: 28)
                                .background(tab.id == model.activeTabID ? Color.accentColor.opacity(0.12) : .clear)
                                .overlay(alignment: .bottom) { if tab.id == model.activeTabID { Color.accentColor.frame(height: 2) } }
                                .contextMenu {
                                    Button("Rename Tab…") { rename = tab.title; model.renamingTab = tab.id }
                                    Button("Close Tab") { model.requestCloseTab(tab.id) }.disabled(model.isRunning)
                                }
                        }
                    }
                }
                Button { model.newQuery() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).padding(.horizontal, 12).help("New query (⌘T)")
            }.background(.bar)
            Divider()
            HStack(spacing: 8) {
                if model.canCancelOperation {
                    Button("Cancel", systemImage: "stop.circle") { model.cancelCurrentQuery() }
                } else {
                    Menu {
                        Button("Run Selection / Current Statement") { model.runCurrentQuery() }
                        Button("Run with Parameters…") { parametersSQL = SQLTools.executable(model.sql, selection: model.sqlSelection) }
                        Button("Run All Statements") { model.runCurrentQuery(all: true) }
                    } label: { Label("Run", systemImage: "play.fill") }
                    .fixedSize().disabled(!model.isConnected || model.isRunning)
                }
                Picker("Database", selection: $model.selectedDatabase) {
                    Text("No database").tag("")
                    if !model.selectedDatabase.isEmpty && !model.schemas.contains(where: { $0.name == model.selectedDatabase }) { Text(model.selectedDatabase).tag(model.selectedDatabase) }
                    ForEach(model.schemas) { Text($0.name).tag($0.name) }
                }.frame(maxWidth: 220).disabled(model.isRunning)
                Button("Format", systemImage: "text.alignleft") { model.formatSQL() }.help("Format SQL keywords and clauses")
                Button("Explain", systemImage: "list.bullet.indent") { model.explainQuery() }.disabled(!model.isConnected || model.isRunning)
                Menu("Snippets") {
                    Button("SELECT from selected table") { model.insertWhereTemplate() }.disabled(model.selectedTable == nil)
                    Button("INSERT into selected table") { model.generateInsert() }.disabled(model.selectedTable == nil)
                    Button("New table template") { model.newQuery(sql: "CREATE TABLE `new_table` (\n  `id` BIGINT NOT NULL AUTO_INCREMENT,\n  `name` VARCHAR(255) NOT NULL,\n  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,\n  PRIMARY KEY (`id`)\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;", title: "Create table") }
                }.fixedSize()
                Spacer()
                Menu("Text") {
                    Button("Larger SQL Text") { fontSize = min(24, fontSize + 1) }
                    Button("Smaller SQL Text") { fontSize = max(10, fontSize - 1) }
                    Button("Default Size (13)") { fontSize = 13 }
                }.fixedSize()
                Button("History", systemImage: "clock.arrow.circlepath") { model.showHistory = true }
            }.controlSize(.small).padding(.horizontal, 12).frame(height: 32)
            Divider()
            QueryDocumentEditor(model: model, document: model.queryTabs[model.activeTabIndex].document, id: model.activeTabID)
            HStack {
                Text("⌘↩ Run   ⇧⌘↩ All   ⌃Space / ⌥Esc Complete   ⌘F Find")
                Spacer()
                QueryLineCount(document: model.queryTabs[model.activeTabIndex].document)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 18).background(.bar)
        }
        .sheet(isPresented: Binding(get: { parametersSQL != nil }, set: { if !$0 { parametersSQL = nil } })) {
            if let source = parametersSQL { ParameterEditorView(source: source).environmentObject(model) }
        }
        .task(id: model.selectedDatabase + model.activeTabID.uuidString + String(model.isConnected)) { await model.loadCompletionMetadata() }
        .confirmationDialog("Close this query tab?", isPresented: Binding(get: { model.closingTab != nil }, set: { if !$0 { model.closingTab = nil } })) {
            Button("Close Tab", role: .destructive) { if let id = model.closingTab { model.closeTab(id) }; model.closingTab = nil }
        } message: { Text("Its local draft will be removed. Save it to a SQL file first if you want to keep it.") }
        .alert("Rename Tab", isPresented: Binding(get: { model.renamingTab != nil }, set: { if !$0 { model.renamingTab = nil } })) {
            TextField("Tab name", text: $rename)
            Button("Cancel", role: .cancel) { model.renamingTab = nil }
            Button("Save") { if let id = model.renamingTab { model.renameTab(id, title: rename) }; model.renamingTab = nil }
        }
    }
}

private struct QueryTabLabel: View {
    let title: String
    @ObservedObject var document: QueryDocument
    var body: some View { Label(title + (document.isDirty ? " •" : ""), systemImage: "chevron.left.forwardslash.chevron.right").lineLimit(1) }
}

private struct QueryLineCount: View {
    @ObservedObject var document: QueryDocument
    var body: some View { Text("Preview ≤ 1,000 rows · \(document.lineCount) lines") }
}

private struct QueryDocumentEditor: View {
    let model: AppModel
    @ObservedObject var document: QueryDocument
    let id: UUID
    var body: some View {
        SQLTextEditor(text: Binding(get: { document.sql }, set: { model.sql = $0 }),
                      selection: Binding(get: { document.selection }, set: { document.selection = $0 }),
                      completionCatalog: model.completionCatalog, documentID: id.uuidString, sessions: model.editorSessions) { count in
            if document.lineCount != count { document.lineCount = count }
        }
    }
}
