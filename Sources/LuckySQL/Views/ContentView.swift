import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SchemaSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                EditorView()
                    .frame(minHeight: 170, idealHeight: 250)
                Divider()
                ResultGrid(result: model.result)
            }
        }
        .toolbar { toolbar }
        .alert("Database Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "Unknown error") }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if model.isConnected {
                Button("Disconnect", systemImage: "bolt.slash") { model.disconnect() }
            } else {
                Button("Connect", systemImage: "bolt") { model.connect() }
                    .disabled(model.isRunning)
            }
            Button("Run", systemImage: "play.fill") { model.runCurrentQuery() }
                .disabled(!model.isConnected || model.isRunning)
                .help("Run query (⌘↩)")
            if model.isRunning { ProgressView().controlSize(.small) }
        }
    }
}
