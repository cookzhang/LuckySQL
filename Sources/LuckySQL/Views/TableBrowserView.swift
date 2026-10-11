import SwiftUI

struct TableBrowserView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let table = model.selectedTable {
            VStack(spacing: 0) {
                BrowseFilterBar(model: model, draft: model.browseDraft,
                                columns: model.tableColumns[table.id] ?? [],
                                appliedOptions: model.appliedBrowseOptions, isRunning: model.isRunning)
                if !model.appliedBrowseOptions.sortColumn.isEmpty {
                    Text("Sort: \(model.appliedBrowseOptions.sortColumn) \(model.appliedBrowseOptions.descending ? "↓" : "↑")").font(.caption)
                }
                Divider()
                ResultGrid(section: .data)
                Divider()
                HStack(spacing: 12) {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refreshData(forceMetadata: true) }
                    Button("Edit / New Row…", systemImage: "square.and.pencil") { model.showGridChanges = true }
                    Text(model.canMutateSelectedTable ? "Enter: preview · ⌘C: cell · ⇧⌘C: rows" : "Read-only: protected connection, partial result or no usable primary key")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    BrowsePageControls(model: model, draft: model.browseDraft,
                                       appliedPage: model.appliedBrowseOptions.page, hasNextPage: model.hasNextPage)
                }.controlSize(.small).padding(12).disabled(model.isRunning)
            }
        } else {
            ContentUnavailableView("Choose a table", systemImage: "tablecells", description: Text("Click a table in the sidebar to preview data without replacing your SQL drafts."))
        }
    }
}

private struct BrowseFilterBar: View {
    let model: AppModel
    @ObservedObject var draft: BrowseDraft
    let columns: [TableColumn]
    let appliedOptions: TableBrowseOptions
    let isRunning: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                BrowseFilterColumnPicker(columns: columns.map(\.name), selection: $draft.options.filterColumn)
                    .frame(width: 150)
                Picker("Operator", selection: $draft.options.filterOperator) {
                    ForEach(FilterOperator.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 100).disabled(draft.options.filterColumn.isEmpty)
                TextField("Filter value", text: $draft.options.filterValue).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    .disabled(draft.options.filterColumn.isEmpty || !draft.options.filterOperator.needsValue)
                    .onSubmit { model.refreshData(resetPage: true) }
                BrowseVisibleColumnsMenu(columns: columns, selection: $draft.options.selectedColumns) {
                    model.refreshData(resetPage: true)
                }.fixedSize()
                Button("Apply") { model.refreshData(resetPage: true) }
                Button("Reset") { draft.options.filterColumn = ""; draft.options.filterValue = ""; model.refreshData(resetPage: true) }
            }.controlSize(.small).padding(12).disabled(isRunning)
            if draft.hasPendingFilter(comparedTo: appliedOptions) {
                Text("Filter changes not applied").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

private struct BrowsePageControls: View {
    let model: AppModel
    @ObservedObject var draft: BrowseDraft
    let appliedPage: Int
    let hasNextPage: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Only a user's picker change starts a request. Restoring another
            // table's saved page size must not launch a second refresh.
            Picker("Rows", selection: Binding(get: { draft.options.pageSize }, set: { size in
                guard draft.options.pageSize != size else { return }
                draft.options.pageSize = size
                model.refreshData(resetPage: true)
            })) { Text("100").tag(100); Text("200").tag(200); Text("500").tag(500) }.frame(width: 110)
            Button { model.nextPage(-1) } label: { Image(systemName: "chevron.left") }.disabled(draft.options.page == 0).help("Previous page")
            Text("Page \(appliedPage + 1)").font(.caption).monospacedDigit()
            Button { model.nextPage(1) } label: { Image(systemName: "chevron.right") }.disabled(!hasNextPage).help("Next page")
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
