import Foundation

protocol DatabaseSession: AnyObject, Sendable {
    func query(_ sql: String) async throws -> QueryResult
    func schemas() async throws -> [String]
    func tables(in schema: String) async throws -> [String]
    func close() async
}

protocol DatabaseDriver: Sendable {
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession
}
