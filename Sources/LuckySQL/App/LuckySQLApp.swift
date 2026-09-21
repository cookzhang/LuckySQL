import SwiftUI

@main
struct LuckySQLApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .sheet(isPresented: $updater.isPresented) { UpdateView(updater: updater).environmentObject(model) }
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }.disabled(updater.busy)
            }
            CommandGroup(after: .newItem) {
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
                Button("Query History") { model.showHistory = true }.keyboardShortcut("y", modifiers: .command)
            }
        }

        Settings { SettingsView().environmentObject(model) }
    }
}
