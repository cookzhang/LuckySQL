import SwiftUI

struct SchemaDesignerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var page = "Columns"
    @State private var database = ""
    @State private var name = ""
    @State private var creating = false
    @State private var columns: [ColumnDraft] = []
    @State private var original: [TableColumn] = []
    @State private var originalSQL = ""
    @State private var sql = ""
    @State private var error: String?
    @State private var notice = ""
    @State private var confirm = false
    @State private var indexName = ""
    @State private var columnNames = ""
    @State private var unique = false
    @State private var dropping = false
    @State private var referenceTable = ""
    @State private var referenceColumns = ""
    @State private var onDelete = "RESTRICT"
    @State private var objectKind = "View"
    @State private var objects: [String] = []
    @State private var replacement = false
    @State private var newName = ""
    private var table: DatabaseTable { DatabaseTable(schema: database, name: name) }
    private func names(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Schema & Objects").font(.title2); Spacer(); Button("Close") { dismiss() }.disabled(model.isRunning) }
            Text(model.connectionLabel).font(.caption)
            HStack { TextField("Database", text: $database); TextField("Object name", text: $name) }.textFieldStyle(.roundedBorder).disabled(model.isRunning)
            Picker("Page", selection: $page) { ForEach(["Columns", "Indexes", "Foreign Keys", "Objects"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).disabled(model.isRunning)
            if page == "Columns" {
                HStack {
                    Toggle("Create new table", isOn: $creating)
                    Button("Add Column") { columns.append(ColumnDraft()) }
                    Button("Preview SQL") { preview { try SchemaChange.columns(table: table, original: original, desired: columns, creating: creating) } }
                }.disabled(model.isRunning)
                ScrollView {
                    ForEach($columns) { $column in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("Column name", text: $column.name)
                                TextField("Type", text: $column.type)
                                Toggle("NULL", isOn: $column.nullable).fixedSize()
                                Toggle("PK", isOn: $column.primaryKey).fixedSize()
                                Toggle("Auto", isOn: $column.autoIncrement).fixedSize()
                                Button("Remove") { columns.removeAll { $0.id == column.id } }
                            }
                            HStack {
                                Picker("Default", selection: $column.defaultKind) { ForEach(["None", "NULL", "Literal", "Current timestamp"], id: \.self) { Text($0).tag($0) } }.frame(width: 220)
                                TextField("Default value", text: $column.defaultValue).disabled(column.defaultKind != "Literal")
                                TextField("Comment", text: $column.comment)
                            }.font(.caption)
                            if column.original?.extra.uppercased().contains("GENERATED") == true { Text("Generated expression: use the SQL definition editor; this form preserves unchanged generated columns.").font(.caption).foregroundStyle(.secondary) }
                        }.padding(6).background(column.changed ? Color.orange.opacity(0.08) : .clear)
                    }
                }.frame(maxHeight: 145).disabled(model.isRunning)
            } else if page == "Indexes" || page == "Foreign Keys" {
                HStack { TextField("Constraint / index name", text: $indexName); Toggle("Drop", isOn: $dropping) }
                TextField("Columns in order, comma separated", text: $columnNames).disabled(dropping)
                if page == "Indexes" {
                    Toggle("Unique", isOn: $unique).disabled(dropping)
                    Text("Use PRIMARY as the index name to edit the primary key. Change an existing index by reviewing its drop and replacement separately.").font(.caption)
                } else {
                    TextField("Referenced table (same database)", text: $referenceTable).disabled(dropping)
                    TextField("Referenced columns in order", text: $referenceColumns).disabled(dropping)
                    Picker("On delete", selection: $onDelete) { ForEach(["RESTRICT", "CASCADE", "SET NULL", "NO ACTION"], id: \.self) { Text($0).tag($0) } }
                }
                Button("Preview SQL") {
                    preview {
                        if page == "Indexes" { return try SchemaChange.index(table: table, name: indexName, columns: names(columnNames), unique: unique, drop: dropping) }
                        return try SchemaChange.foreignKey(table: table, name: indexName, columns: names(columnNames), referenced: DatabaseTable(schema: database, name: referenceTable), referenceColumns: names(referenceColumns), onDelete: onDelete, drop: dropping)
                    }
                }.disabled(model.isRunning)
            } else {
                HStack {
                    Picker("Kind", selection: $objectKind) { ForEach(["Table", "Database", "View", "Procedure", "Function", "Trigger", "Event"], id: \.self) { Text($0).tag($0) } }
                    Menu("Existing objects") { ForEach(objects, id: \.self) { object in Button(object) { name = object; loadDefinition() } } }
                    Button("Load Definition") { loadDefinition() }.disabled(objectKind == "Database" || model.isRunning)
                    Button("New Template") { template() }.disabled(model.isRunning)
                }
                HStack {
                    TextField("New table name", text: $newName).disabled(objectKind != "Table")
                    Button("Rename Table") { preview { "RENAME TABLE \(try target()) TO \(try SQLIdentifier.quote(database)).\(try SQLIdentifier.quote(newName));" } }.disabled(objectKind != "Table" || model.isRunning)
                    Button("Preview Drop") { preview { "DROP \(objectKind.uppercased()) \(try objectKind == "Database" ? SQLIdentifier.quote(database) : target());" } }.disabled(model.isRunning)
                }
                if ["Procedure", "Function", "Trigger", "Event"].contains(objectKind) {
                    Toggle("Replace existing object: DROP first, then execute the edited CREATE", isOn: $replacement)
                    Text("Replacement is not atomic. If CREATE fails after DROP, the original object is gone. Its loaded definition remains in this editor.").font(.caption).foregroundStyle(.orange)
                }
            }
            DisclosureGroup("Original structure / definition") {
                ScrollView { Text(originalSQL).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 65)
            }
            Text("Review the SQL difference before applying. DDL may implicitly commit and cannot be automatically rolled back. Type narrowing or drops can lose data. Unsupported version-specific SQL fails on the server without automatic retries.").font(.caption).foregroundStyle(.orange)
            SQLTextEditor(text: $sql).frame(minHeight: 120)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text(notice).font(.caption)
            HStack {
                if model.isRunning { Button("Cancel") { model.cancelCurrentQuery() } }
                Spacer(); Button("Review & Apply…") { confirm = true }.disabled(sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning || model.isReadOnly)
            }
        }.padding(20).frame(width: 850, height: 580).interactiveDismissDisabled(model.isRunning)
        .task {
            database = model.selectedTable?.schema ?? model.selectedDatabase; name = model.selectedTable?.name ?? "new_table"
            original = model.structure.columns.isEmpty ? model.tableColumns[model.selectedTable?.id ?? "", default: []] : model.structure.columns
            columns = original.map(ColumnDraft.init); originalSQL = model.structure.createSQL
            if columns.isEmpty { columns = [ColumnDraft()]; creating = true }
        }
        .task(id: objectKind + database) { if !database.isEmpty { objects = (try? await model.loadObjectDefinitions(kind: objectKind, database: database)) ?? [] } }
        .confirmationDialog("Apply schema change to \(database).\(name)?", isPresented: $confirm) {
            Button("Apply DDL", role: .destructive) {
                Task {
                    do {
                        let preceding = replacement && page == "Objects" && ["Procedure", "Function", "Trigger", "Event"].contains(objectKind) ? ["DROP \(objectKind.uppercased()) IF EXISTS \(try target())"] : []
                        try await model.executeSchemaChange(sql, preceding: preceding)
                        notice = "DDL applied. Metadata invalidated; refresh the structure to compare the new definition."; error = nil
                        await model.loadSchemas()
                    } catch { self.error = "DDL failed; the draft is retained. Earlier DDL may have committed. " + error.localizedDescription }
                }
            }
        }
    }
    private func target() throws -> String { "\(try SQLIdentifier.quote(database)).\(try SQLIdentifier.quote(name))" }
    private func preview(_ build: () throws -> String) { do { sql = try build(); error = nil } catch { self.error = error.localizedDescription } }
    private func loadDefinition() {
        Task { do { sql = try await model.objectSQL(kind: objectKind, table: table); originalSQL = sql; error = nil } catch { self.error = error.localizedDescription } }
    }
    private func template() {
        preview {
            let target = try target()
            switch objectKind {
            case "Database": return "CREATE DATABASE \(try SQLIdentifier.quote(database)) DEFAULT CHARACTER SET utf8mb4;"
            case "View": return "CREATE OR REPLACE VIEW \(target) AS\nSELECT 1 AS value;"
            case "Procedure": return "CREATE PROCEDURE \(target)()\nBEGIN\n  SELECT 1;\nEND"
            case "Function": return "CREATE FUNCTION \(target)() RETURNS INT DETERMINISTIC\nRETURN 1"
            case "Trigger": return "CREATE TRIGGER \(target) BEFORE INSERT ON `choose_table`\nFOR EACH ROW BEGIN\n  SET NEW.`choose_column` = 1;\nEND"
            case "Event": return "CREATE EVENT \(target) ON SCHEDULE EVERY 1 DAY\nDISABLE\nDO SELECT 1"
            default: return "CREATE TABLE \(target) (`id` BIGINT NOT NULL AUTO_INCREMENT, PRIMARY KEY (`id`)) ENGINE=InnoDB;"
            }
        }
    }
}
