import Foundation

struct GridChange: Identifiable, Sendable {
    enum Kind: String, Sendable { case insert = "Insert", update = "Update", delete = "Delete" }
    let id = UUID()
    let table: DatabaseTable
    let kind: Kind
    var before: [String: SQLParameter]
    var values: [String: SQLParameter]
    var label: String
    var rowID: String? = nil
    func statement() throws -> (sql: String, parameters: [SQLParameter]) {
        let target = "\(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))"
        var parameters: [SQLParameter] = []
        func predicate() throws -> String {
            guard !before.isEmpty else { throw UpdateFailure("A stable original row identity is required.") }
            return try before.keys.sorted().map { key in
                parameters.append(before[key]!); return "BINARY \(try SQLIdentifier.quote(key)) <=> BINARY ?"
            }.joined(separator: " AND ")
        }
        switch kind {
        case .insert:
            let names = values.keys.sorted()
            parameters = names.map { values[$0]! }
            return ("INSERT INTO \(target) (\(try names.map(SQLIdentifier.quote).joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))", parameters)
        case .update:
            guard !values.isEmpty else { throw UpdateFailure("No values to update.") }
            let assignments = try values.keys.sorted().map { key -> String in
                parameters.append(values[key]!); return "\(try SQLIdentifier.quote(key)) = ?"
            }.joined(separator: ", ")
            let whereSQL = try predicate()
            return ("UPDATE \(target) SET \(assignments) WHERE \(whereSQL) LIMIT 1", parameters)
        case .delete:
            let whereSQL = try predicate()
            return ("DELETE FROM \(target) WHERE \(whereSQL) LIMIT 1", parameters)
        }
    }
}
