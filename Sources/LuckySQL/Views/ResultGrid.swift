import SwiftUI

struct ResultGrid: View {
    @EnvironmentObject private var model: AppModel
    @State private var preview: CellPreview?
    @State private var pendingDelete: Int?
    private var result: QueryResult { model.result }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(model.section == .data ? "Table data" : "Results", systemImage: "tablecells").font(.headline)
                if model.section == .query, model.queryTabs[model.activeTabIndex].results.count > 1 {
                    Menu("Result sets") {
                        ForEach(Array(model.queryTabs[model.activeTabIndex].results.enumerated()), id: \.offset) { index, item in
                            Button("\(index + 1) · \(item.message)") { model.queryTabs[model.activeTabIndex].result = item }
                        }
                    }.fixedSize()
                }
                Spacer()
                Text("\(result.message) · \(result.elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))")
                    .font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Copy as TSV") { model.copy(ResultExport.csv(result, separator: "\t")) }
                    Button("Copy as CSV") { model.copy(ResultExport.csv(result)) }
                    Divider()
                    Button("Export CSV…") { model.exportResult(json: false) }
                    Button("Export JSON…") { model.exportResult(json: true) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .fixedSize().disabled(result.columns.isEmpty)
            }.padding(.horizontal, 14).frame(height: 40).background(.bar)
            Divider()
            if result.columns.isEmpty {
                ContentUnavailableView(model.isRunning ? "Running query…" : "Ready to query", systemImage: "terminal", description: Text("Run SQL or select a table in the sidebar to preview its data."))
            } else {
                DataGrid(result: result, inspect: { row, column in
                    preview = CellPreview(row: row, column: column, name: result.columns[column], value: result.rows[row][column], isNull: result.isNull(row: row, column: column))
                }, sort: model.section == .data ? { model.sortData(column: $0) } : nil,
                         quickFilter: model.section == .data ? { row, column in
                    guard !model.isRunning else { return }
                    model.browseOptions.filterColumn = result.columns[column]
                    model.browseOptions.filterOperator = result.isNull(row: row, column: column) ? .isNull : .equals
                    model.browseOptions.filterValue = result.rows[row][column]; model.refreshData(resetPage: true)
                } : nil, delete: model.canMutateSelectedTable ? { pendingDelete = $0 } : nil)
                if result.rows.isEmpty { Text("No matching rows · column headers are preserved").font(.caption).foregroundStyle(.secondary).padding(8) }
            }
        }
        .sheet(item: $preview) { cell in
            CellPreviewSheet(cell: cell, editable: model.canEditColumn(cell.column) && !model.isRunning) { value, isNull in
                model.updateCell(row: cell.row, column: cell.column, value: value, isNull: isNull)
            }
        }
        .confirmationDialog("Delete this row from \(model.selectedTable?.id ?? "table")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Row", role: .destructive) { if let row = pendingDelete { model.deleteRow(row) }; pendingDelete = nil }
        } message: { Text("This writes to the database immediately and cannot be undone. The row is matched by its primary key.") }
        .onChange(of: result.id) { _, _ in preview = nil; pendingDelete = nil }
    }
}

private struct CellPreview: Identifiable {
    let id = UUID()
    let row: Int
    let column: Int
    let name: String
    let value: String
    let isNull: Bool
}
private struct CellPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let cell: CellPreview
    let editable: Bool
    let save: (String, Bool) -> Void
    @State private var value: String
    @State private var isNull: Bool
    @State private var editing = false
    init(cell: CellPreview, editable: Bool, save: @escaping (String, Bool) -> Void) {
        self.cell = cell; self.editable = editable; self.save = save
        _value = State(initialValue: cell.isNull ? "" : cell.value); _isNull = State(initialValue: cell.isNull)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label(cell.name, systemImage: "doc.text.magnifyingglass").font(.title3.bold()); Spacer(); Text("Row \(cell.row + 1)").foregroundStyle(.secondary) }
            if editing {
                Toggle("SQL NULL (different from the text \"NULL\")", isOn: $isNull)
                TextEditor(text: $value).font(.system(.body, design: .monospaced)).disabled(isNull)
                Text("Save writes directly to the database, matched by the row's primary key.").font(.caption).foregroundStyle(.orange)
            } else {
                ScrollView { Text(isNull ? "NULL" : (value.isEmpty ? "(empty string)" : value)).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Text("\(value.utf8.count) bytes · \(value.count) characters").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if editable && !editing { Button("Edit Value…") { editing = true } }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if editing { Button("Save to Database") { save(value, isNull); dismiss() }.buttonStyle(.borderedProminent) }
            }
        }.padding(22).frame(width: 640, height: 400)
    }
}
