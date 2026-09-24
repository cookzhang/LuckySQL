import Foundation

struct ColumnDraft: Identifiable, Equatable {
    var id = UUID()
    var original: TableColumn?
    var name = ""
    var type = "VARCHAR(255)"
    var nullable = true
    var defaultValue = ""
    var defaultKind = "None"
    var autoIncrement = false
    var primaryKey = false
    var comment = ""
    init() {}
    init(_ column: TableColumn) {
        original = column; name = column.name; type = column.dataType; nullable = column.isNullable
        defaultValue = column.defaultValue ?? ""
        defaultKind = column.defaultValue == nil ? "None" : (defaultValue.uppercased().hasPrefix("CURRENT_TIMESTAMP") ? "Current timestamp" : "Literal")
        primaryKey = column.isPrimaryKey
        autoIncrement = column.extra.lowercased().contains("auto_increment"); comment = column.comment
    }
    var changed: Bool {
        guard let original else { return true }
        let baseline = ColumnDraft(original)
        return name != baseline.name || type != baseline.type || nullable != baseline.nullable || defaultValue != baseline.defaultValue || defaultKind != baseline.defaultKind || autoIncrement != baseline.autoIncrement || comment != baseline.comment
    }
    func definition() throws -> String {
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let simple = type.range(of: #"^[A-Za-z]+(?:\([0-9, ]+\))?(?:\s+(?:UNSIGNED|ZEROFILL)){0,2}$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let tokens = SQLTools.tokens(type).filter { $0.kind != .whitespace }
        let enumeration = ["ENUM", "SET"].contains(tokens.first?.text.uppercased() ?? "") && tokens.count >= 4 && tokens[1].text == "(" && tokens.last?.text == ")" && tokens.dropFirst(2).dropLast().allSatisfy { $0.kind == .string && $0.text.hasPrefix("'") && $0.text.hasSuffix("'") || $0.text == "," }
        guard simple || enumeration else { throw UpdateFailure("Use a SQL data type, optionally with numeric length/precision, UNSIGNED, or quoted ENUM/SET values.") }
        guard original?.extra.uppercased().contains("GENERATED") != true else { throw UpdateFailure("Edit generated expressions in the CREATE SQL editor; the column form will not discard them.") }
        var sql = "\(try SQLIdentifier.quote(name)) \(type)" + (nullable ? " NULL" : " NOT NULL")
        switch defaultKind {
        case "NULL": guard nullable else { throw UpdateFailure("NULL default requires a nullable column.") }; sql += " DEFAULT NULL"
        case "Literal": sql += " DEFAULT " + (try SQLStringLiteral.quote(defaultValue))
        case "Current timestamp": sql += " DEFAULT CURRENT_TIMESTAMP"
        default: break
        }
        if autoIncrement { sql += " AUTO_INCREMENT" }
        if original?.extra.lowercased().contains("on update current_timestamp") == true { sql += " ON UPDATE CURRENT_TIMESTAMP" }
        if !comment.isEmpty { sql += " COMMENT " + (try SQLStringLiteral.quote(comment)) }
        return sql
    }
}

enum SchemaChange {
    static func columns(table: DatabaseTable, original: [TableColumn], desired: [ColumnDraft], creating: Bool) throws -> String {
        guard !desired.isEmpty, Set(desired.map(\.name)).count == desired.count else { throw UpdateFailure("Provide distinct column names.") }
        let target = "\(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))"
        if creating {
            var definitions = try desired.map { try $0.definition() }
            let primary = desired.filter(\.primaryKey).map(\.name)
            if !primary.isEmpty { definitions.append("PRIMARY KEY (\(try primary.map(SQLIdentifier.quote).joined(separator: ", ")))") }
            return "CREATE TABLE \(target) (\n  " + definitions.joined(separator: ",\n  ") + "\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
        }
        var changes = try original.filter { old in !desired.contains(where: { $0.original?.name == old.name }) }.map { "DROP COLUMN \(try SQLIdentifier.quote($0.name))" }
        for column in desired where column.changed {
            if let old = column.original { changes.append("CHANGE COLUMN \(try SQLIdentifier.quote(old.name)) \(try column.definition())") }
            else { changes.append("ADD COLUMN \(try column.definition())") }
        }
        let oldPrimary = original.filter(\.isPrimaryKey).map(\.name), newPrimary = desired.filter(\.primaryKey).map(\.name)
        if oldPrimary != newPrimary {
            if !oldPrimary.isEmpty { changes.append("DROP PRIMARY KEY") }
            if !newPrimary.isEmpty { changes.append("ADD PRIMARY KEY (\(try newPrimary.map(SQLIdentifier.quote).joined(separator: ", ")))") }
        }
        guard !changes.isEmpty else { throw UpdateFailure("No column changes to apply.") }
        return "ALTER TABLE \(target)\n  " + changes.joined(separator: ",\n  ") + ";"
    }
    static func index(table: DatabaseTable, name: String, columns: [String], unique: Bool, drop: Bool) throws -> String {
        let target = "\(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))"
        if drop { return "ALTER TABLE \(target) DROP " + (name.uppercased() == "PRIMARY" ? "PRIMARY KEY" : "INDEX \(try SQLIdentifier.quote(name))") + ";" }
        guard !columns.isEmpty else { throw UpdateFailure("Choose index columns in order.") }
        let kind = name.uppercased() == "PRIMARY" ? "PRIMARY KEY" : (unique ? "UNIQUE INDEX " : "INDEX ") + (try SQLIdentifier.quote(name))
        return "ALTER TABLE \(target) ADD \(kind) (\(try columns.map(SQLIdentifier.quote).joined(separator: ", ")));"
    }
    static func foreignKey(table: DatabaseTable, name: String, columns: [String], referenced: DatabaseTable, referenceColumns: [String], onDelete: String, drop: Bool) throws -> String {
        let target = "\(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))"
        if drop { return "ALTER TABLE \(target) DROP FOREIGN KEY \(try SQLIdentifier.quote(name));" }
        guard !columns.isEmpty, columns.count == referenceColumns.count, ["RESTRICT", "CASCADE", "SET NULL", "NO ACTION"].contains(onDelete) else { throw UpdateFailure("Foreign-key columns must match and the action must be valid.") }
        return "ALTER TABLE \(target) ADD CONSTRAINT \(try SQLIdentifier.quote(name)) FOREIGN KEY (\(try columns.map(SQLIdentifier.quote).joined(separator: ", "))) REFERENCES \(try SQLIdentifier.quote(referenced.schema)).\(try SQLIdentifier.quote(referenced.name)) (\(try referenceColumns.map(SQLIdentifier.quote).joined(separator: ", "))) ON DELETE \(onDelete);"
    }
}
