import SwiftUI

struct TableBrowserView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let table = model.selectedTable {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    Picker("Column", selection: $model.browseOptions.filterColumn) {
                        Text("All rows").tag("")
                        ForEach(model.tableColumns[table.id] ?? []) { Text($0.name).tag($0.name) }
                    }.labelsHidden().frame(width: 150)
                    Picker("Operator", selection: $model.browseOptions.filterOperator) {
                        ForEach(FilterOperator.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 100).disabled(model.browseOptions.filterColumn.isEmpty)
                    TextField("Filter value", text: $model.browseOptions.filterValue).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        .disabled(model.browseOptions.filterColumn.isEmpty || !model.browseOptions.filterOperator.needsValue)
                        .onSubmit { model.refreshData(resetPage: true) }
                    Menu("Columns") {
                        Button("All columns") { model.browseOptions.selectedColumns = []; model.refreshData(resetPage: true) }
                        ForEach(model.tableColumns[table.id] ?? []) { column in
                            Toggle(column.name, isOn: Binding(get: {
                                model.browseOptions.selectedColumns.isEmpty || model.browseOptions.selectedColumns.contains(column.name) || column.isPrimaryKey
                            }, set: { selected in
                                if model.browseOptions.selectedColumns.isEmpty { model.browseOptions.selectedColumns = Set((model.tableColumns[table.id] ?? []).map(\.name)) }
                                if selected { model.browseOptions.selectedColumns.insert(column.name) }
                                else { model.browseOptions.selectedColumns.remove(column.name) }
                                model.refreshData(resetPage: true)
                            })).disabled(column.isPrimaryKey)
                        }
                    }.fixedSize()
                    Button("Apply") { model.refreshData(resetPage: true) }
                    Button("Reset") { model.browseOptions.filterColumn = ""; model.browseOptions.filterValue = ""; model.refreshData(resetPage: true) }
                }.controlSize(.small).padding(12).disabled(model.isRunning)
                if model.hasPendingFilter { Text("Filter changes not applied").font(.caption).foregroundStyle(.orange) }
                if !model.appliedBrowseOptions.sortColumn.isEmpty {
                    Text("Sort: \(model.appliedBrowseOptions.sortColumn) \(model.appliedBrowseOptions.descending ? "↓" : "↑")").font(.caption)
                }
                Divider()
                ResultGrid()
                Divider()
                HStack(spacing: 12) {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refreshData(forceMetadata: true) }
                    Button("Edit / New Row…", systemImage: "square.and.pencil") { model.showGridChanges = true }
                    Text(model.canMutateSelectedTable ? "Enter: preview · ⌘C: cell · ⇧⌘C: rows" : "Read-only: protected connection, partial result or no usable primary key")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Picker("Rows", selection: $model.browseOptions.pageSize) { Text("100").tag(100); Text("200").tag(200); Text("500").tag(500) }.frame(width: 110)
                        .onChange(of: model.browseOptions.pageSize) { _, _ in model.refreshData(resetPage: true) }
                    Button { model.nextPage(-1) } label: { Image(systemName: "chevron.left") }.disabled(model.browseOptions.page == 0).help("Previous page")
                    Text("Page \(model.appliedBrowseOptions.page + 1)").font(.caption).monospacedDigit()
                    Button { model.nextPage(1) } label: { Image(systemName: "chevron.right") }.disabled(!model.hasNextPage).help("Next page")
                }.controlSize(.small).padding(12).disabled(model.isRunning)
            }
        } else {
            ContentUnavailableView("Choose a table", systemImage: "tablecells", description: Text("Click a table in the sidebar to preview data without replacing your SQL drafts."))
        }
    }
}

struct StructureView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page = "Columns"
    private let pages = ["Columns", "Indexes", "Foreign keys", "CREATE SQL"]
    var body: some View {
        if model.selectedTable == nil {
            ContentUnavailableView("Choose a table", systemImage: "square.stack.3d.up", description: Text("View columns, indexes, foreign keys and the original CREATE statement."))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Picker("Structure details", selection: $page) { ForEach(pages, id: \.self) { Text(LocalizedStringKey($0)).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 440)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { model.showStructure(force: true) }.disabled(model.isRunning)
                    Button("Design…") { model.showSchemaDesigner = true }.disabled(model.isRunning)
                    Menu("SQL") {
                        Button("Copy CREATE SQL") { model.copy(model.structure.createSQL) }
                        Button("Open CREATE SQL in New Tab") { model.newQuery(sql: model.structure.createSQL, title: "DDL · \(model.selectedTable?.name ?? "")") }
                    }.fixedSize().disabled(model.structure.createSQL.isEmpty)
                }.controlSize(.small).padding(12)
                Divider()
                switch model.structureState {
                case .idle, .loading: ProgressView("Loading table structure…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message): ContentUnavailableView("Could not load structure", systemImage: "exclamationmark.triangle", description: Text(message))
                case .loaded:
                    if page == "CREATE SQL" { SQLTextEditor(text: .constant(model.structure.createSQL), isEditable: false, documentID: model.selectedTable?.id ?? "") }
                    else if page == "Columns" { DataGrid(result: columnsResult) }
                    else if page == "Indexes" { DataGrid(result: model.structure.indexes) }
                    else { DataGrid(result: model.structure.foreignKeys) }
                }
                HStack {
                    Text("\(model.structure.columns.count) columns · \(model.structure.indexes.rows.count) index entries · \(model.structure.foreignKeys.rows.count) foreign-key columns")
                    Spacer(); Text("Read-only metadata preview")
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
    }
    private var columnsResult: QueryResult {
        QueryResult(id: model.structure.id, columns: ["Column", "Type", "Key", "Nullable", "Default", "Extra", "Comment"], rows: model.structure.columns.map {
            [$0.name, $0.dataType, $0.isPrimaryKey ? "PRIMARY" : "", $0.isNullable ? "YES" : "NO", $0.defaultValue ?? "NULL / none", $0.extra, $0.comment]
        }, elapsed: .zero, message: "")
    }
}

struct QueryHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Query history").font(.title2.bold()); Spacer(); Button("Clear…") { confirmClear = true }.disabled(model.history.isEmpty); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Last 100 executions, stored only on this Mac. SQL may contain sensitive values.").font(.caption).foregroundStyle(.secondary)
            TextField("Search SQL, database or connection", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            List(model.history.filter { search.isEmpty || "\($0.sql) \($0.database) \($0.connection)".localizedCaseInsensitiveContains(search) }) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(entry.connection + " / " + entry.database).font(.caption.bold()); Spacer(); Text(entry.date, style: .time).font(.caption) }
                    Text(entry.sql).font(.system(.caption, design: .monospaced)).lineLimit(3)
                    HStack { Text(entry.outcome).font(.caption).foregroundStyle(.secondary).lineLimit(1); Spacer(); Button("Open in New Tab") { model.newQuery(sql: entry.sql, title: "History"); model.selectedDatabase = entry.database; model.saveWorkspace(); dismiss() } }
                }.padding(.vertical, 6)
            }
        }.padding(22).frame(width: 760, height: 540)
        .confirmationDialog("Clear local query history?", isPresented: $confirmClear) { Button("Clear History", role: .destructive) { model.clearHistory() } }
    }
}
