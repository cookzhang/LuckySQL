import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationSplitView {
            SchemaSidebar().navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 380)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.section == .query ? "SQL Workspace" : model.selectedTable?.name ?? "Table Preview").font(.title3.bold())
                        Text(model.section == .query ? model.profiles.first(where: { $0.id == model.connectedProfileID })?.name ?? "Not connected" : model.selectedTable?.schema ?? "Choose a table from the sidebar")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Workspace", selection: Binding(get: { model.section }, set: { model.changeSection($0) })) {
                        Text("SQL").tag(WorkspaceSection.query)
                        Text("Data").tag(WorkspaceSection.data)
                        Text("Structure").tag(WorkspaceSection.structure)
                    }.pickerStyle(.segmented).frame(width: 260).disabled(model.isRunning)
                }.padding(.horizontal, 18).frame(height: 66).background(.bar)
                Divider()
                switch model.section {
                case .query:
                    VSplitView {
                        EditorView().frame(minHeight: 190, idealHeight: 290)
                        ResultGrid().frame(minHeight: 170)
                    }
                case .data: TableBrowserView()
                case .structure: StructureView()
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(model.isConnected ? .green : .secondary).frame(width: 6, height: 6)
                    Text(model.isConnected ? "Connected" : "Disconnected")
                    if let profile = model.profiles.first(where: { $0.id == model.connectedProfileID }) { Text(profile.host + ":" + String(profile.port)).foregroundStyle(.secondary) }
                    Spacer()
                    if model.isLoadingPassword { ProgressView().controlSize(.mini); Text("Waiting for Keychain authorization…") }
                    else if model.isRunning { ProgressView().controlSize(.mini); Text("Working…") }
                    else { Text("MySQL workspace").foregroundStyle(.secondary) }
                }.font(.caption).padding(.horizontal, 12).frame(height: 28).background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isConnected { Button("Disconnect", systemImage: "bolt.slash") { model.disconnect() }.disabled(model.isRunning) }
                else { Button("Connect", systemImage: "bolt") { model.connect() }.disabled(model.isRunning) }
                Button("Run", systemImage: "play.fill") { model.runCurrentQuery() }.disabled(!model.isConnected || model.isRunning).help("Execute current statement or selection (⌘↩)")
                if model.isRunning {
                    Button("Stop & Disconnect", systemImage: "stop.fill") { model.disconnect() }
                        .help("Close the connection immediately. A write already sent to the server may still complete; this does not roll it back.")
                }
                Menu {
                    Button("Run All Statements") { model.runCurrentQuery(all: true) }
                    Button("Explain Current Statement") { model.explainQuery() }
                    Divider()
                    Button("Server Processes") { model.newQuery(sql: "SHOW FULL PROCESSLIST;", title: "Processes"); model.runCurrentQuery() }
                    Button("Server Variables") { model.newQuery(sql: "SHOW VARIABLES;", title: "Variables"); model.runCurrentQuery() }
                    Button("Server Status") { model.newQuery(sql: "SHOW GLOBAL STATUS;", title: "Status"); model.runCurrentQuery() }
                } label: { Image(systemName: "ellipsis.circle") }.disabled(!model.isConnected || model.isRunning)
            }
        }
        .alert("Database Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "Unknown error") }
        .sheet(isPresented: $model.showHistory) { QueryHistoryView() }
        .sheet(isPresented: Binding(get: { model.pendingSQL != nil }, set: { if !$0 { model.cancelExecution() } })) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Review before executing", systemImage: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                Text("This SQL may modify data or server state. Statements run in order and are not automatically rolled back on failure.")
                Text("Database: \(model.selectedDatabase.isEmpty ? "(none)" : model.selectedDatabase)").font(.caption.bold())
                SQLTextEditor(text: .constant(model.pendingSQL ?? ""), isEditable: false).frame(height: 220)
                HStack { Spacer(); Button("Cancel") { model.cancelExecution() }.keyboardShortcut(.cancelAction); Button("Execute SQL") { model.confirmExecution() }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 700)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.saveWorkspace() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.saveWorkspace() }
    }
}
