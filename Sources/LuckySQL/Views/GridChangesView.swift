import SwiftUI

struct GridChangesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "Changes"
    @State private var row = 1
    @State private var column = 0
    @State private var value = SQLParameter()
    @State private var newValues: [String: SQLParameter] = [:]
    @State private var included = Set<String>()
    @State private var pasted = ""
    @State private var error: String?
    @State private var confirm = false
    @State private var pasting = false
    private var columns: [TableColumn] { model.tableColumns[model.selectedTable?.id ?? "", default: []] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Table Changes").font(.title2); Spacer(); Button("Close") { dismiss() }.disabled(model.isRunning) }
            Text(model.connectionLabel + " · " + (model.selectedTable?.id ?? "")).font(.caption)
            Text("Changes are staged locally. Commit uses a separate InnoDB transaction, checks original values and rolls back the batch on conflict. It does not commit the SQL workspace's transaction.").font(.caption)
            Picker("Mode", selection: $mode) { ForEach(["Changes", "Edit Cell", "New Row", "Paste TSV"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).disabled(model.isRunning)
            if mode == "Changes" {
                List {
                    ForEach(model.gridChanges) { change in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(change.kind.rawValue + " · " + change.table.id + " · " + change.label)
                                Text(change.values.keys.sorted().map { "\($0) = \(change.values[$0]!.kind == .null ? "NULL" : String(change.values[$0]!.value.prefix(100)))" }.joined(separator: ", ")).font(.caption).lineLimit(2)
                            }
                            Spacer(); Button("Discard") { model.gridChanges.removeAll { $0.id == change.id } }.disabled(model.isRunning)
                        }
                    }
                }
                HStack { Button("Discard All") { model.gridChanges = []; model.gridCommitUnknown = false }.disabled(model.isRunning); Spacer(); Button("Commit Batch…") { confirm = true }.disabled(!model.canCommitGridChanges) }
            } else if mode == "New Row" {
                ScrollView {
                    ForEach(columns.filter { !$0.extra.uppercased().contains("GENERATED") }) { definition in
                        HStack {
                            Toggle(definition.name, isOn: Binding(get: { included.contains(definition.name) }, set: { if $0 { included.insert(definition.name) } else { included.remove(definition.name) } })).frame(width: 180, alignment: .leading)
                            ParameterValueEditor(value: Binding(get: { newValues[definition.name] ?? SQLParameter(kind: definition.isNullable ? .null : .text) }, set: { newValues[definition.name] = $0 })).disabled(!included.contains(definition.name))
                            Text(definition.dataType).font(.caption).frame(width: 100)
                        }
                    }
                }
                Text("Unchecked columns use server defaults, including auto-increment. Generated columns cannot be assigned.").font(.caption)
                Button("Stage New Row") {
                    perform {
                        guard let table = model.selectedTable else { throw UpdateFailure("Select a table.") }
                        var values: [String: SQLParameter] = [:]
                        for name in included { values[name] = newValues[name] ?? SQLParameter(kind: columns.first(where: { $0.name == name })?.isNullable == true ? .null : .text) }
                        try model.stageInsert(table: table, values: values); mode = "Changes"
                    }
                }.disabled(model.isRunning || model.isReadOnly)
            } else {
                HStack {
                    TextField("Starting row (1-based)", value: $row, format: .number).frame(width: 160)
                    Picker("Column", selection: $column) { ForEach(Array(model.browseResult.columns.enumerated()), id: \.offset) { index, name in Text(name).tag(index) } }
                }
                if mode == "Edit Cell" {
                    ParameterValueEditor(value: $value)
                    HStack {
                        Button("Load Full Original") {
                            Task {
                                do {
                                    let full = try await model.loadFullValue(row: row - 1, column: column)
                                    if full.isNull(row: 0, column: 0) { value = SQLParameter(kind: .null) }
                                    else if let bytes = full.binaryCells[CellAddress(row: 0, column: 0)] { value = SQLParameter(kind: .binary, value: bytes.map { String(format: "%02x", $0) }.joined()) }
                                    else { value = SQLParameter(kind: .text, value: full.rows[0][0]) }
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(model.isRunning)
                        Button("Stage Value") { perform { try model.stageCell(row: row - 1, column: column, value: value); mode = "Changes" } }.disabled(model.isRunning || model.isReadOnly)
                        Button("Stage Delete Row") { perform { try model.stageDelete(row: row - 1); mode = "Changes" } }.disabled(model.isRunning || model.isReadOnly)
                    }
                    Spacer()
                } else {
                    Text("Paste a rectangular TSV range without headers. Starting row/column map to the displayed snapshot. Unquoted \\N is NULL. All cells are validated before the paste is staged.").font(.caption)
                    TextEditor(text: $pasted).font(.system(.body, design: .monospaced))
                    Button("Preview / Stage Paste") { Task { await stagePaste() } }.disabled(model.isRunning || model.isReadOnly || pasted.isEmpty)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text(model.gridChangeStatus).font(.caption).textSelection(.enabled)
            if model.isRunning { Button("Cancel Batch") { model.cancelCurrentQuery() }.disabled(model.isCancelling) }
        }.padding(20).frame(width: 800, height: 580).disabled(pasting).interactiveDismissDisabled(model.isRunning || pasting)
        .confirmationDialog("Commit \(model.gridChanges.count) changes?", isPresented: $confirm) { Button("Commit Transaction", role: .destructive) { model.commitGridChanges() } }
    }
    private func perform(_ work: () throws -> Void) { do { try work(); error = nil } catch { self.error = error.localizedDescription } }
    private func stagePaste() async {
        guard !pasting else { return }; pasting = true
        defer { pasting = false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LuckySQL-paste-\(UUID()).tsv")
        let previous = model.gridChanges
        let snapshotID = model.browseResult.id, profileID = model.connectedProfileID
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data(pasted.utf8).write(to: url)
            let reader = try CSVReader(url: url, separator: 9)
            var targetRow = row - 1
            while let fields = try await reader.next() {
                guard model.browseResult.id == snapshotID, model.connectedProfileID == profileID else { throw UpdateFailure("The snapshot or connection changed during paste. Reload and try again.") }
                guard targetRow >= 0, model.browseResult.rows.indices.contains(targetRow), column >= 0, column + fields.count <= model.browseResult.columns.count else { throw UpdateFailure("Paste extends outside the loaded snapshot.") }
                for (offset, field) in fields.enumerated() {
                    let value = SQLParameter(kind: !field.quoted && field.value == "\\N" ? .null : .text, value: field.value)
                    try model.stageCell(row: targetRow, column: column + offset, value: value)
                }
                targetRow += 1
            }
            mode = "Changes"; error = nil
        } catch { model.gridChanges = previous; self.error = error.localizedDescription }
    }
}

struct ParameterValueEditor: View {
    @Binding var value: SQLParameter
    var body: some View {
        HStack {
            Picker("Type", selection: $value.kind) { ForEach(SQLParameter.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 135)
            TextField("Value", text: $value.value, axis: .vertical).lineLimit(1...4).disabled(value.kind == .null)
            if value.kind == .text {
                Button("UTF-8 → Hex") { value = SQLParameter(kind: .binary, value: value.value.utf8.map { String(format: "%02x", $0) }.joined()) }.help("Encode this text as binary UTF-8 bytes")
            }
        }
    }
}
