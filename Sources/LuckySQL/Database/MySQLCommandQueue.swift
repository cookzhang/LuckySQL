import Foundation
import MySQLNIO

/// Serializes all commands, including metadata. A cancellation barrier prevents
/// a delayed KILL from targeting the next statement on the same connection.
actor MySQLCommandQueue {
    private let connection: MySQLConnection
    private let connectionID: UInt64
    private let controlConnection: @Sendable () async throws -> MySQLConnection
    private var tail: Task<Void, Never>?
    private var activeID: UUID?
    private var cancellation: Task<Void, Error>?

    init(connection: MySQLConnection, connectionID: UInt64, controlConnection: @escaping @Sendable () async throws -> MySQLConnection) {
        self.connection = connection; self.connectionID = connectionID; self.controlConnection = controlConnection
    }
    func query(_ sql: String, rowLimit: Int? = nil, byteLimit: Int? = nil, timeout: Int = 0, rowConsumer: (@Sendable (MySQLRow) throws -> Void)? = nil) async throws -> MySQLTextQuery {
        let previous = tail
        let task = Task {
            await previous?.value
            self.activeID = UUID()
            let deadline = timeout > 0 ? self.connection.eventLoop.scheduleTask(in: .seconds(Int64(timeout))) {
                self.connection.channel.close(promise: nil)
            } : nil
            defer { deadline?.cancel() }
            do {
                let value = try await self.connection.textQuery(sql, rowLimit: rowLimit, byteLimit: byteLimit, rowConsumer: rowConsumer)
                await self.finish()
                return value
            } catch {
                await self.finish()
                if self.connection.isClosed { throw DatabaseSessionLost() }
                throw error
            }
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
    private func finish() async {
        _ = try? await cancellation?.value
        activeID = nil; cancellation = nil
    }
    func cancelQuery() async throws {
        if let cancellation { return try await cancellation.value }
        guard let target = activeID else { return }
        let task = Task {
            let control = try await self.controlConnection()
            do {
                if self.activeID == target { _ = try await control.textQuery("KILL QUERY \(self.connectionID)") }
                try? await control.close().get()
            } catch { try? await control.close().get(); throw error }
        }
        cancellation = task
        try await task.value
    }
}
