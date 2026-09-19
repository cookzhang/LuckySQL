import SwiftUI

struct SchemaSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        List {
            if !model.isConnected {
                ContentUnavailableView("Not Connected", systemImage: "cylinder.split.1x2", description: Text("Open Settings to configure a server, then connect."))
            }
            ForEach(model.schemas) { schema in
                DisclosureGroup(schema.name) {
                    ForEach(schema.tables) { table in
                        Button { model.browse(table) } label: {
                            Label(table.name, systemImage: "tablecells")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onAppear { model.loadTables(in: schema.name) }
            }
        }
        .navigationTitle("Databases")
        .safeAreaInset(edge: .bottom) {
            Button {
                openSettings()
            } label: {
                Label("Add Connection…", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadSchemas() } }
                    .disabled(!model.isConnected)
            }
        }
    }
}
