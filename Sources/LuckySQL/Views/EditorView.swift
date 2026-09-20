import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("SQL Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.headline)
                Spacer()
                Picker("Database", selection: $model.selectedDatabase) {
                    Text("No database").tag("")
                    ForEach(model.schemas) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                Button("Add WHERE", systemImage: "line.3.horizontal.decrease.circle") {
                    model.insertWhereTemplate()
                }
                .disabled(model.selectedTable == nil)
                Text("⌘↩ to run").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 38)
            SQLTextEditor(text: $model.sql)
        }
    }
}
