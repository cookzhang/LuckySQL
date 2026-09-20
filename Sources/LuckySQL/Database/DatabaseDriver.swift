import Foundation

protocol DatabaseSession: AnyObject, Sendable {
    func query(_ sql: String) async throws -> QueryResult
    func schemas() async throws -> [String]
    func tables(in schema: String) async throws -> [String]
    func columns(in table: DatabaseTable) async throws -> [TableColumn]
    func structure(in table: DatabaseTable) async throws -> TableStructure
    func close() async
    func cancel() async
}

extension DatabaseSession {
    func cancel() async { await close() }
    func structure(in table: DatabaseTable) async throws -> TableStructure {
        TableStructure(columns: try await columns(in: table))
    }
}

protocol DatabaseDriver: Sendable {
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession
}
