import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    var workspaceTabs: AnyView? = nil
    var body: some View {
        NavigationSplitView {
            SchemaSidebar().navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if let workspaceTabs { workspaceTabs }
                switch model.section {
                case .query:
                    VSplitView {
                        EditorView().frame(minHeight: 190, idealHeight: 290)
                        ResultGrid().frame(minHeight: 170)
                    }
                    .background(SplitLayoutPersistence())
                case .data: TableBrowserView()
                case .structure: StructureView()
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(model.isConnected ? .green : .secondary).frame(width: 6, height: 6)
                    Text(LocalizedStringKey(model.isConnected ? "Connected" : "Disconnected"))
                    if let profile = model.profiles.first(where: { $0.id == model.connectedProfileID }) { Text(profile.host + ":" + String(profile.port)).foregroundStyle(.secondary) }
                    Spacer()
                    if model.isLoadingPassword { ProgressView().controlSize(.mini); Text("Loading saved password…") }
                    else if model.isRunning {
                        ProgressView().controlSize(.mini)
                        Text(model.busyStage.isEmpty ? "Working…" : model.busyStage).lineLimit(1)
                        if let start = model.busySince { Text(start, style: .timer).monospacedDigit() }
                    }
                    else if let notice = model.passwordNotice { Text(notice).lineLimit(1).help(notice).foregroundStyle(.secondary) }
                    else { Text("MySQL workspace").foregroundStyle(.secondary) }
                }.font(.caption).padding(.horizontal, 12).frame(height: 28).background(.bar)
            }
        }
        .background(WorkspaceWindowMarker())
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 16) {
                    HStack(spacing: 2) {
                        sectionButton("SQL", symbol: "chevron.left.forwardslash.chevron.right", section: .query)
                        sectionButton("Data", symbol: "tablecells", section: .data)
                        sectionButton("Structure", symbol: "square.stack.3d.up", section: .structure)
                    }.fixedSize()
                    if let table = model.selectedTable {
                        Text(table.id).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200).help(table.id)
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isConnected { Button("Disconnect", systemImage: "bolt.slash") { model.disconnect() }.disabled(model.isRunning) }
                else { Button("Connect", systemImage: "bolt") { model.requestConnect() }.disabled(model.isRunning) }
                Button("Find Table", systemImage: "magnifyingglass") { model.showTableFinder = true }.disabled(!model.isConnected)
                if model.isRunning {
                    if model.canCancelOperation {
                        Button("Cancel Query", systemImage: "stop.circle") { model.cancelCurrentQuery() }.disabled(model.isCancelling)
                            .help("Cancel the current statement without closing the connection. This does not roll back earlier statements or committed writes.")
                    }
                    Button("Stop & Disconnect", systemImage: "stop.fill") { model.disconnect() }
                        .help("Close the connection immediately. A write already sent to the server may still complete; this does not roll it back.")
                }
                Menu {
                    Button("Run All Statements") { model.runCurrentQuery(all: true) }
                    Button("Explain Current Statement") { model.explainQuery() }
                    Divider()
                    Button("Schema & Objects…") { model.showSchemaDesigner = true }
                    Button("Data Transfer…") { model.showTransfer = true }
                    Button("Server Processes") { model.newQuery(sql: "SHOW FULL PROCESSLIST;", title: "Processes"); model.runCurrentQuery() }
                    Button("Server Variables") { model.newQuery(sql: "SHOW VARIABLES;", title: "Variables"); model.runCurrentQuery() }
                    Button("Server Status") { model.newQuery(sql: "SHOW GLOBAL STATUS;", title: "Status"); model.runCurrentQuery() }
                } label: { Image(systemName: "ellipsis.circle") }.disabled(!model.isConnected || model.isRunning)
            }
        }
        .alert("Database Error", isPresented: Binding(get: { model.errorMessage != nil && model.connectionDraft == nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "Unknown error") }
        .sheet(item: $model.connectionDraft) { draft in ConnectionEditorView(draft: draft) }
        .sheet(isPresented: $model.showSchemaDesigner) { SchemaDesignerView() }
        .sheet(isPresented: $model.showGridChanges) { GridChangesView() }
        .sheet(isPresented: $model.showTransfer) { DataTransferView() }
        .sheet(isPresented: $model.showHistory) { QueryHistoryView() }
        .sheet(isPresented: $model.showTableFinder) { TableFinderView() }
        .sheet(isPresented: Binding(get: { model.pendingSQL != nil }, set: { if !$0 { model.cancelExecution() } })) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Review before executing", systemImage: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                Text("This SQL may modify data or server state. Statements run in order and are not automatically rolled back on failure.")
                Text("Database: \(model.selectedDatabase.isEmpty ? "(none)" : model.selectedDatabase)").font(.caption.bold())
                Text(model.connectionLabel).font(.caption.bold()).foregroundStyle(.red)
                SQLTextEditor(text: .constant(model.pendingSQL ?? ""), isEditable: false).frame(height: 220)
                HStack { Spacer(); Button("Cancel") { model.cancelExecution() }.keyboardShortcut(.cancelAction); Button("Execute SQL") { model.confirmExecution() }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 700)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.flushWorkspace() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.saveWorkspace() }
    }

    private func sectionButton(_ title: LocalizedStringKey, symbol: String, section: WorkspaceSection) -> some View {
        Button { model.changeSection(section) } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .font(.system(size: 12, weight: model.section == section ? .semibold : .regular))
                .padding(.horizontal, 10).frame(height: 28)
                .foregroundStyle(model.section == section ? Color.accentColor : Color.secondary)
                .background(model.section == section ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(model.section == section ? .isSelected : [])
    }

}
