import SwiftUI

struct ParameterEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: String
    @State private var parameters: [SQLParameter]
    @State private var error: String?
    init(source: String) { self.source = source; _parameters = State(initialValue: (0..<SQLParameter.count(in: source)).map { _ in SQLParameter() }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run with Parameters").font(.title2)
            Text(model.connectionLabel).font(.caption)
            SQLTextEditor(text: .constant(source), isEditable: false).frame(height: 130)
            Text("Each ? outside strings/comments is a parameter. Values bind on the server; NULL and text 'NULL' remain distinct.").font(.caption)
            ScrollView {
                ForEach(Array(parameters.indices), id: \.self) { index in
                    HStack {
                        Text("\(index + 1)").frame(width: 30)
                        Picker("Type", selection: $parameters[index].kind) { ForEach(SQLParameter.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 160)
                        TextField("Value", text: $parameters[index].value).disabled(parameters[index].kind == .null)
                    }
                }
            }.frame(maxHeight: 240)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Run") {
                    do { _ = try parameters.map { try $0.literal() }; model.runParameterized(source, parameters: parameters); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(!model.isConnected || model.isRunning)
            }
        }.padding(20).frame(width: 640)
    }
}
