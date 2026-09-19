import SwiftUI

@main
struct LuckySQLApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Run Query") { model.runCurrentQuery() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.isConnected || model.isRunning)
            }
        }

        Settings { SettingsView().environmentObject(model) }
    }
}
