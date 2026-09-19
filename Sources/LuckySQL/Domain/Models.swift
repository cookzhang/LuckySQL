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

struct QueryResult: Sendable {
    let columns: [String]
    let rows: [[String]]
    let elapsed: Duration
    let message: String

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
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
