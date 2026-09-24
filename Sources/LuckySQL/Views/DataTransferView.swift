import SwiftUI
import UniformTypeIdentifiers

struct DataTransferView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var page = "Export"
    @State private var format: TransferFormat = .csv
    @State private var filtered = true
    @State private var selected = Set<String>()
    @State private var tableSearch = ""
    @State private var file: URL?
    @State private var separator: UInt8 = 44
    @State private var latin1 = false
    @State private var header = true
    @State private var preview: [[String]] = []
    @State private var mapping: [String] = []
    @State private var headers: [String] = []
    @State private var error: String?
    @State private var confirm = false
    private var tables: [DatabaseTable] { model.schemas.flatMap(\.tables) }
    private var visibleTables: [DatabaseTable] {
        tables.filter { tableSearch.isEmpty || $0.id.localizedCaseInsensitiveContains(tableSearch) }
            .sorted {
                let lhsCurrent = $0.schema == model.selectedDatabase
                let rhsCurrent = $1.schema == model.selectedDatabase
                if lhsCurrent != rhsCurrent { return lhsCurrent }
                return $0.id.localizedStandardCompare($1.id) == .orderedAscending
            }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Data Transfer").font(.title2); Spacer(); Button("Close") { dismiss() }.disabled(model.isRunning) }
            Text(model.connectionLabel).font(.caption)
            Picker("Operation", selection: $page) { Text("Export").tag("Export"); Text("CSV Import").tag("CSV Import"); Text("SQL Script").tag("SQL Script") }.pickerStyle(.segmented).disabled(model.isRunning)
            if page == "Export" {
                HStack {
                    Picker("Format", selection: $format) { ForEach(TransferFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 170)
                    Toggle("Use current applied filter (one table only)", isOn: $filtered).disabled(selected.count != 1)
                }
                Text("Full table data streams to disk, including full large fields. This is separate from exporting the displayed preview. Multiple tables produce separate files; external writes may change data during export.").font(.caption)
                HStack {
                    TextField("Filter tables", text: $tableSearch).textFieldStyle(.roundedBorder)
                    Text("Selected: \(selected.count)").font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                List(visibleTables) { table in
                    Toggle(isOn: Binding(get: { selected.contains(table.id) }, set: { value in
                        if value { selected.insert(table.id) } else { selected.remove(table.id) }
                    })) { Text(table.id) }.toggleStyle(.checkbox)
                }
                .disabled(model.isRunning)
                HStack {
                    Button("Select Database") { selected = Set(tables.filter { $0.schema == model.selectedDatabase }.map(\.id)) }
                    Spacer(); Button("Export Full Data…") { export() }.disabled(selected.isEmpty || model.isRunning)
                }
            } else {
                HStack { Button("Choose File…") { chooseFile() }; Text(file?.lastPathComponent ?? "No file selected").lineLimit(1) }.disabled(model.isRunning)
                if page == "CSV Import" {
                    Text("Destination: \(model.selectedTable?.id ?? "Select a table first")").font(.headline)
                    HStack {
                        Picker("Separator", selection: $separator) { Text("Comma").tag(UInt8(44)); Text("Tab").tag(UInt8(9)); Text("Semicolon").tag(UInt8(59)) }
                        Toggle("Header", isOn: $header); Toggle("Latin-1 (otherwise UTF-8)", isOn: $latin1)
                        Button("Preview") { Task { await loadPreview() } }
                    }.disabled(model.isRunning)
                    Text("Map source fields below. Unquoted \\N is SQL NULL; quoted \\N is text. Empty fields remain empty strings. Binary columns accept hex bytes. InnoDB only: all rows commit together or roll back on failure.").font(.caption)
                    ScrollView {
                        ForEach(Array(mapping.indices), id: \.self) { index in
                            HStack {
                                Text(headers.indices.contains(index) ? headers[index] : "Field \(index + 1)").frame(width: 200, alignment: .leading)
                                Picker("Destination", selection: $mapping[index]) {
                                    Text("Skip").tag("")
                                    ForEach(model.tableColumns[model.selectedTable?.id ?? "", default: []].filter { !$0.extra.uppercased().contains("GENERATED") }) { Text($0.name).tag($0.name) }
                                }
                            }
                        }
                    }.frame(maxHeight: 150)
                    DataGrid(result: QueryResult(columns: headers, rows: preview, elapsed: .zero, message: "Preview only")).frame(minHeight: 100)
                    Button("Review Import…") { confirm = true }.disabled(file == nil || mapping.isEmpty || model.selectedTable == nil || model.isRunning || model.isReadOnly || model.importCommitUnknown)
                } else {
                    Text("Runs a UTF-8 script without loading it into the editor. Supports DELIMITER and routine bodies. One statement may be up to 16 MiB; the file can be larger. The script runs in an independent session. DDL/committed statements cannot be rolled back; failures stop at the reported source line. Uncommitted transactions are rolled back when the session closes.").font(.body)
                    Spacer()
                    Button("Review Script Execution…") { confirm = true }.disabled(file == nil || model.isRunning || model.isReadOnly)
                }
            }
            if model.importCommitUnknown {
                Text("The last import commit could not be confirmed. Inspect the destination in Table Data before importing again.").foregroundStyle(.red)
                Button("I verified the destination; allow another import") { model.importCommitUnknown = false }.disabled(model.isRunning)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text(model.transferStatus).font(.caption).textSelection(.enabled)
            if model.isRunning { HStack { ProgressView().controlSize(.small); Button("Cancel Transfer") { model.cancelCurrentQuery() }.disabled(model.isCancelling) } }
        }.padding(20).frame(width: 740, height: 620)
        .onChange(of: separator) { _, _ in invalidatePreview() }
        .onChange(of: latin1) { _, _ in invalidatePreview() }
        .onChange(of: header) { _, _ in invalidatePreview() }
        .onChange(of: page) { _, _ in file = nil; invalidatePreview() }
        .interactiveDismissDisabled(model.isRunning)
        .task {
            if let table = model.selectedTable { selected = [table.id]; await model.loadColumns(in: table) }
            await model.loadAllTablesForSearch()
        }
        .confirmationDialog(page == "CSV Import" ? "Import into \(model.selectedTable?.id ?? "")?" : "Execute this script on \(model.connectionLabel)?", isPresented: $confirm) {
            Button("Execute", role: .destructive) {
                guard let file else { return }
                if page == "CSV Import", let table = model.selectedTable { model.importCSV(at: file, table: table, mapping: mapping, separator: separator, latin1: latin1, header: header) }
                else { model.executeScript(at: file) }
            }
        } message: { Text("Review the destination and source file. Writes will be sent to the database; scripts may contain irreversible DDL and commits.") }
    }
    private func invalidatePreview() { preview = []; mapping = []; headers = []; error = nil }
    private func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { file = panel.url; preview = []; mapping = []; headers = []; if page == "CSV Import" { Task { await loadPreview() } } }
    }
    private func loadPreview() async {
        guard let file else { return }
        do {
            let reader = try CSVReader(url: file, separator: separator, latin1: latin1)
            guard let first = try await reader.next() else { throw UpdateFailure("CSV is empty.") }
            headers = header ? first.map(\.value) : first.indices.map { "Field \($0 + 1)" }
            let columns = model.tableColumns[model.selectedTable?.id ?? "", default: []]
            mapping = headers.enumerated().map { index, name in
                if header { return columns.first(where: { $0.name == name })?.name ?? "" }
                return columns.indices.contains(index) ? columns[index].name : ""
            }
            preview = header ? [] : [first.map(\.value)]
            for _ in 0..<20 { guard let row = try await reader.next() else { break }; preview.append(row.map(\.value)) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func export() {
        let chosen = tables.filter { selected.contains($0.id) }
        if chosen.count == 1 {
            let panel = NSSavePanel(); panel.nameFieldStringValue = chosen[0].name + "." + format.rawValue.lowercased()
            if panel.runModal() == .OK, let url = panel.url { model.exportTables(chosen, to: url, format: format, filtered: filtered && chosen[0] == model.selectedTable) }
        } else {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url { model.exportTables(chosen, to: url, format: format, filtered: false) }
        }
    }
}
