import SwiftUI

@main
struct LuckySQLApp: App {
    @NSApplicationDelegateAdaptor(WorkspaceLifecycle.self) private var lifecycle
    @StateObject private var workspaces = ConnectionWorkspaces()
    private var model: AppModel { workspaces.active }
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            ConnectionWorkspacesView(workspaces: workspaces)
                .environmentObject(model)
                .onAppear { lifecycle.workspaces = workspaces }
                .sheet(isPresented: $updater.isPresented) { UpdateView(updater: updater, workspaces: workspaces) }
                .frame(minWidth: 960, minHeight: 580)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }.disabled(updater.busy)
            }
            CommandGroup(after: .newItem) {
                Button("New Connection Workspace") { workspaces.newWorkspace() }
                Button("Add Connection…") { model.beginNewConnection() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.isRunning)
                Divider()
                Button("New Query Tab") { model.newQuery() }.keyboardShortcut("t", modifiers: .command)
                Button("Open SQL File…") { model.openSQLFile() }.keyboardShortcut("o", modifiers: .command)
                Button("Save SQL As…") { model.saveSQLFile() }.keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("Run Query") { model.runCurrentQuery() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.isConnected || model.isRunning)
                Button("Run All Statements") { model.runCurrentQuery(all: true) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!model.isConnected || model.isRunning)
                Button("SQL Workspace") { model.changeSection(.query) }.keyboardShortcut("1", modifiers: .command)
                Button("Table Data") { model.changeSection(.data) }.keyboardShortcut("2", modifiers: .command)
                Button("Table Structure") { model.changeSection(.structure) }.keyboardShortcut("3", modifiers: .command)
                Button("Query History") { model.showHistory = true }.keyboardShortcut("y", modifiers: .command)
                Button("Find Table") { model.showTableFinder = true }.keyboardShortcut("p", modifiers: .command).disabled(!model.isConnected || model.isRunning)
                Button("Next Query Tab") { model.cycleTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Query Tab") { model.cycleTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Close") {
                    if model.connectionDraft != nil {
                        if model.isRunning { model.disconnect() }
                        model.cancelConnectionEditor(); return
                    }
                    guard let window = NSApplication.shared.keyWindow else { return }
                    if WorkspaceWindows.closesQueryTab(in: window, section: model.section) { model.requestCloseTab(model.activeTabID) }
                    else { window.performClose(nil) }
                }.keyboardShortcut("w", modifiers: .command)
                Button("Cancel Query") { model.cancelCurrentQuery() }.keyboardShortcut(".", modifiers: .command).disabled(!model.canCancelOperation)
            }
        }
    }
}

@MainActor final class WorkspaceLifecycle: NSObject, NSApplicationDelegate {
    weak var workspaces: ConnectionWorkspaces?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspaces else { return .terminateNow }
        if workspaces.isBusy || workspaces.hasPendingGridChanges {
            let alert = NSAlert()
            alert.messageText = "Quit with unfinished work?"
            alert.informativeText = "Active connections will close and staged grid changes will be discarded. SQL drafts are saved. A write already sent may have committed; verify its outcome before retrying."
            alert.addButton(withTitle: "Keep Working")
            alert.addButton(withTitle: "Quit and Discard")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        workspaces.flush()
        for entry in workspaces.entries { entry.model.disconnect() }
        return .terminateNow
    }
}
