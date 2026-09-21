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
                        Text(model.section == .query ? NSLocalizedString("SQL Workspace", comment: "") : model.selectedTable?.name ?? NSLocalizedString("Table Preview", comment: "")).font(.title3.bold())
                        Text(model.section == .query ? model.profiles.first(where: { $0.id == model.connectedProfileID })?.name ?? NSLocalizedString("Not connected", comment: "") : model.selectedTable?.schema ?? NSLocalizedString("Choose a table from the sidebar", comment: ""))
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
                    if model.isLoadingPassword { ProgressView().controlSize(.mini); Text("Waiting for Keychain authorization…") }
                    else if model.isRunning {
                        ProgressView().controlSize(.mini)
                        Text(model.busyStage.isEmpty ? "Working…" : model.busyStage).lineLimit(1)
                        if let start = model.busySince { Text(start, style: .timer).monospacedDigit() }
                    }
                    else { Text("MySQL workspace").foregroundStyle(.secondary) }
                }.font(.caption).padding(.horizontal, 12).frame(height: 28).background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isConnected { Button("Disconnect", systemImage: "bolt.slash") { model.disconnect() }.disabled(model.isRunning) }
                else { Button("Connect", systemImage: "bolt") { model.connect() }.disabled(model.isRunning) }
                Button("Run", systemImage: "play.fill") { model.runCurrentQuery() }.disabled(!model.isConnected || model.isRunning).help("Execute current statement or selection (⌘↩)")
                Button("Find Table", systemImage: "magnifyingglass") { model.showTableFinder = true }.disabled(!model.isConnected || model.isRunning)
                if !model.connectionLabel.isEmpty {
                    Text(model.connectionLabel).font(.caption).foregroundStyle(model.isProduction ? .red : .secondary).lineLimit(1)
                }
                if model.isRunning {
                    if model.executingTabID != nil {
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
}
