import Foundation

struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "Local MySQL"
    var host = "127.0.0.1"
    var port = 3306
    var username = "root"
    var database = ""

    static let local = ConnectionProfile()
}

struct DatabaseSchema: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var tables: [DatabaseTable] = []
    var tableLoadState: MetadataLoadState = .idle
}

enum MetadataLoadState: Hashable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct DatabaseTable: Identifiable, Hashable {
    var id: String { "\(schema).\(name)" }
    let schema: String
    let name: String
}

struct TableColumn: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let dataType: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let defaultValue: String?
    let extra: String
    var comment: String = ""
}

struct QueryResult: Sendable {
    let id = UUID()
    let columns: [String]
    let rows: [[String]]
    let elapsed: Duration
    let message: String
    var nullCells: Set<CellAddress> = []

    func isNull(row: Int, column: Int) -> Bool { nullCells.contains(CellAddress(row: row, column: column)) }

    static let empty = QueryResult(columns: [], rows: [], elapsed: .zero, message: "Ready")
}

enum DatabaseError: LocalizedError {
    case notConnected
    case invalidIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Connect to a server first."
        case .invalidIdentifier(let value): "Invalid database identifier: \(value)"
        }
    }
}

enum SQLIdentifier {
    static func quote(_ value: String) throws -> String {
        guard !value.isEmpty, !value.contains("\0") else { throw DatabaseError.invalidIdentifier(value) }
        return "`\(value.replacingOccurrences(of: "`", with: "``"))`"
    }
}

enum SQLStringLiteral {
    static func quote(_ value: String) throws -> String {
        guard !value.contains("\0") else { throw DatabaseError.invalidIdentifier(value) }
        // Hex literals are independent of NO_BACKSLASH_ESCAPES. A backslash
        // followed by a quote must never change the generated SQL's meaning.
        if value.contains("\\") {
            return "CONVERT(X'\(value.utf8.map { String(format: "%02x", $0) }.joined())' USING utf8mb4)"
        }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

struct CellAddress: Hashable, Sendable {
    let row: Int
    let column: Int
}

enum WorkspaceSection: String, CaseIterable {
    case query = "SQL", data = "Data", structure = "Structure"
}

struct QueryTab: Identifiable {
    let id = UUID()
    var title: String
    var sql: String
    var database: String
    var selection = NSRange(location: 0, length: 0)
    var result = QueryResult.empty
    var results: [QueryResult] = []
    var fileURL: URL?
}

struct QueryHistoryEntry: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let sql: String
    let database: String
    let connection: String
    let outcome: String
}

struct TableStructure: Sendable {
    var columns: [TableColumn] = []
    var indexes = QueryResult.empty
    var foreignKeys = QueryResult.empty
    var createSQL = ""
}

enum FilterOperator: String, CaseIterable {
    case equals = "=", notEquals = "≠", contains = "contains", greater = ">", less = "<", isNull = "IS NULL", isNotNull = "IS NOT NULL"
    var needsValue: Bool { self != .isNull && self != .isNotNull }
}

struct TableBrowseOptions {
    var page = 0
    var pageSize = 100
    var filterColumn = ""
    var filterOperator: FilterOperator = .contains
    var filterValue = ""
    var sortColumn = ""
    var descending = false

    func query(for table: DatabaseTable, primaryKeys: [String]) throws -> String {
        var sql = "SELECT * FROM \(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))"
        if !filterColumn.isEmpty {
            let column = try SQLIdentifier.quote(filterColumn)
            let value = try SQLStringLiteral.quote(filterValue)
            switch filterOperator {
            case .equals: sql += " WHERE \(column) = \(value)"
            case .notEquals: sql += " WHERE \(column) <> \(value)"
            case .contains: sql += " WHERE LOCATE(\(value), \(column)) > 0"
            case .greater: sql += " WHERE \(column) > \(value)"
            case .less: sql += " WHERE \(column) < \(value)"
            case .isNull: sql += " WHERE \(column) IS NULL"
            case .isNotNull: sql += " WHERE \(column) IS NOT NULL"
            }
        }
        var ordering = sortColumn.isEmpty ? [] : [sortColumn]
        ordering += primaryKeys.filter { !ordering.contains($0) }
        if !ordering.isEmpty {
            sql += " ORDER BY " + (try ordering.map { try SQLIdentifier.quote($0) + (descending ? " DESC" : " ASC") }.joined(separator: ", "))
        }
        return sql + " LIMIT \(pageSize + 1) OFFSET \(max(0, page) * pageSize);"
    }
}

enum SQLInputNormalizer {
    static func normalize(_ sql: String) -> String {
        sql
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
    }
}
