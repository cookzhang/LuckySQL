import Foundation

protocol DatabaseSession: AnyObject, Sendable {
    func query(_ sql: String) async throws -> QueryResult
    func schemas() async throws -> [String]
    func tables(in schema: String) async throws -> [String]
    func columns(in table: DatabaseTable) async throws -> [TableColumn]
    func structure(in table: DatabaseTable) async throws -> TableStructure
    func close() async
    func cancel() async
    func cancelQuery() async throws
}

extension DatabaseSession {
    func cancel() async { await close() }
    func cancelQuery() async throws { throw QueryCancellationUnavailable() }
    func structure(in table: DatabaseTable) async throws -> TableStructure {
        TableStructure(columns: try await columns(in: table))
    }
}

struct QueryCancellationUnavailable: LocalizedError {
    var errorDescription: String? { "This server could not cancel the query. Use Stop & Disconnect if necessary; committed writes are not rolled back." }
}

protocol DatabaseDriver: Sendable {
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession
}
