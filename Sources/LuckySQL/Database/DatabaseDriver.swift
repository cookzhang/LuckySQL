import Foundation

protocol DatabaseSession: AnyObject, Sendable {
    func query(_ sql: String) async throws -> QueryResult
    func export(_ sql: String, to url: URL, format: TransferFormat, progress: @escaping @Sendable (Int) -> Void) async throws -> Int
    func schemas() async throws -> [String]
    func tables(in schema: String) async throws -> [String]
    func columns(in table: DatabaseTable) async throws -> [TableColumn]
    func structure(in table: DatabaseTable) async throws -> TableStructure
    func close() async
    func cancel() async
    func cancelQuery() async throws
}

extension DatabaseSession {
    func export(_ sql: String, to url: URL, format: TransferFormat, progress: @escaping @Sendable (Int) -> Void) async throws -> Int { throw UpdateFailure("This driver does not support streaming export.") }
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
    func connect(profile: ConnectionProfile, password: String, sshPassword: String) async throws -> any DatabaseSession
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession
    func connectPreview(profile: ConnectionProfile, password: String) async throws -> (any DatabaseSession)?
}

extension DatabaseDriver {
    func connect(profile: ConnectionProfile, password: String, sshPassword: String) async throws -> any DatabaseSession { try await connect(profile: profile, password: password) }
    func connectPreview(profile: ConnectionProfile, password: String) async throws -> (any DatabaseSession)? { nil }
}

struct DatabaseSessionLost: LocalizedError {
    var errorDescription: String? { "The database connection closed or timed out. Transaction/session state was lost; drafts are preserved. A sent write may have committed. Reconnect and verify before retrying; no writes were replayed." }
}
