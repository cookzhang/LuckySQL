import Foundation
import Combine

struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name = "Local MySQL"
    var host = "127.0.0.1"
    var port = 3306
    var username = "root"
    var database = ""
    var readOnly: Bool?
    var tls: TLSOptions?
    var ssh: SSHOptions?
    var connectTimeout: Int?
    var queryTimeout: Int?

    static let local = ConnectionProfile()
}

struct TLSOptions: Codable, Hashable, Sendable {
    var enabled = false
    var caFile = ""
    var serverName = ""
    var certificateFile = ""
    var privateKeyFile = ""
}
struct SSHOptions: Codable, Hashable, Sendable {
    var secretID = UUID()
    var enabled = false
    var host = ""
    var port = 22
    var username = ""
    var identityFile = ""
    var knownHostsFile = ""
}

struct DatabaseSchema: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    var tables: [DatabaseTable] = []
    var tableLoadState: MetadataLoadState = .idle
}

enum MetadataLoadState: Hashable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct DatabaseTable: Identifiable, Hashable, Sendable, Codable {
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
    var id = UUID()
    let columns: [String]
    let rows: [[String]]
    let elapsed: Duration
    let message: String
    var nullCells: Set<CellAddress> = []
    var isTruncated = false
    var retainedBytes = 0
    var affectedRows: UInt64? = nil
    var deferredColumns: Set<String> = []
    var binaryCells: [CellAddress: Data] = [:]

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
    let document: QueryDocument
    var sql: String { get { document.sql } nonmutating set { document.sql = newValue } }
    var database: String
    var selection: NSRange { get { document.selection } nonmutating set { document.selection = newValue } }
    var result = QueryResult.empty
    var results: [QueryResult] = []
    var fileURL: URL?
    var savedSQL: String? { get { document.savedSQL } nonmutating set { document.savedSQL = newValue } }
    var lineCount: Int { get { document.lineCount } nonmutating set { document.lineCount = newValue } }
    var isDirty: Bool { document.isDirty }

    init(title: String, sql: String, database: String) {
        self.title = title; self.document = QueryDocument(sql: sql); self.database = database
    }
}

/// High-frequency editor state never publishes a workspace-wide change.
/// Selection is native editor state; observing it would redraw on every arrow key.
final class QueryDocument: ObservableObject {
    @Published var sql: String
    @Published var savedSQL: String?
    @Published var lineCount = 1
    var selection = NSRange(location: 0, length: 0)
    var isDirty: Bool { savedSQL.map { $0 != sql } ?? !sql.isEmpty }
    init(sql: String) { self.sql = sql }
}

struct QueryHistoryEntry: Identifiable, Codable, Sendable {
    var id = UUID()
    let date: Date
    let sql: String
    let database: String
    let connection: String
    let outcome: String
}

struct TableStructure: Sendable {
    var id = UUID()
    var columns: [TableColumn] = []
    var indexes = QueryResult.empty
    var foreignKeys = QueryResult.empty
    var createSQL = ""
}

enum FilterOperator: String, CaseIterable {
    case equals = "=", notEquals = "≠", contains = "contains", prefix = "prefix", greater = ">", less = "<", isNull = "IS NULL", isNotNull = "IS NOT NULL"
    var needsValue: Bool { self != .isNull && self != .isNotNull }
}

struct TableBrowseOptions: Hashable, Sendable {
    var page = 0
    var pageSize = 100
    var filterColumn = ""
    var filterOperator: FilterOperator = .contains
    var filterValue = ""
    var sortColumn = ""
    var descending = false
    var selectedColumns: Set<String> = []

    func query(for table: DatabaseTable, primaryKeys: [String], afterPrimaryKey: String? = nil, projection: String = "*", seekPredicate: String? = nil) throws -> String {
        var sql = "SELECT \(projection) FROM \(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))"
        if !filterColumn.isEmpty {
            let column = try SQLIdentifier.quote(filterColumn)
            let value = try SQLStringLiteral.quote(filterValue)
            switch filterOperator {
            case .equals: sql += " WHERE \(column) = \(value)"
            case .notEquals: sql += " WHERE \(column) <> \(value)"
            case .contains: sql += " WHERE LOCATE(\(value), \(column)) > 0"
            case .prefix:
                let pattern = filterValue.replacingOccurrences(of: "!", with: "!!").replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_") + "%"
                sql += " WHERE \(column) LIKE \(try SQLStringLiteral.quote(pattern)) ESCAPE '!'"
            case .greater: sql += " WHERE \(column) > \(value)"
            case .less: sql += " WHERE \(column) < \(value)"
            case .isNull: sql += " WHERE \(column) IS NULL"
            case .isNotNull: sql += " WHERE \(column) IS NOT NULL"
            }
        }
        let seek = page > 0 && afterPrimaryKey != nil && primaryKeys.count == 1 && (sortColumn.isEmpty || sortColumn == primaryKeys[0])
        if seek, let afterPrimaryKey {
            // Quoted numeric cursors can force DOUBLE comparison in MySQL and
            // lose BIGINT precision. Only emit a validated integer literal.
            let digits = afterPrimaryKey.hasPrefix("-") ? afterPrimaryKey.dropFirst() : afterPrimaryKey[...]
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  Int64(afterPrimaryKey) != nil || UInt64(afterPrimaryKey) != nil else { throw DatabaseError.invalidIdentifier(afterPrimaryKey) }
            sql += filterColumn.isEmpty ? " WHERE " : " AND "
            sql += "\(try SQLIdentifier.quote(primaryKeys[0])) \(descending ? "<" : ">") \(afterPrimaryKey)"
        }
        if let seekPredicate {
            sql += (filterColumn.isEmpty ? " WHERE " : " AND ") + seekPredicate
        }
        var ordering = sortColumn.isEmpty ? [] : [sortColumn]
        ordering += primaryKeys.filter { !ordering.contains($0) }
        if !ordering.isEmpty {
            sql += " ORDER BY " + (try ordering.map { try SQLIdentifier.quote($0) + (descending ? " DESC" : " ASC") }.joined(separator: ", "))
        }
        return sql + " LIMIT \(pageSize + 1)" + (seek || seekPredicate != nil ? ";" : " OFFSET \(max(0, page) * pageSize);")
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
