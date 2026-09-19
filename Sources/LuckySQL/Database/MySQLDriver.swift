import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix

final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup

    init() { group = MultiThreadedEventLoopGroup(numberOfThreads: 1) }
    deinit { try? group.syncShutdownGracefully() }

    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession {
        do {
            let address = try SocketAddress.makeAddressResolvingHost(profile.host, port: profile.port)
            let connection = try await MySQLConnection.connect(
                to: address,
                username: profile.username,
                database: profile.database,
                password: password,
                tlsConfiguration: nil,
                serverHostname: nil,
                logger: Logger(label: "LuckySQL.MySQL"),
                on: group.next()
            ).get()
            return MySQLSession(connection: connection)
        } catch {
            throw MySQLConnectionFailure(host: profile.host, port: profile.port, underlying: error)
        }
    }
}

struct MySQLConnectionFailure: LocalizedError {
    let host: String
    let port: Int
    let underlying: Error

    var errorDescription: String? {
        let detail = String(describing: underlying)
        if detail.localizedCaseInsensitiveContains("connection refused") ||
            detail.localizedCaseInsensitiveContains("errno: 61") ||
            detail.localizedCaseInsensitiveContains("error: 61") {
            return "无法连接到 \(host):\(port)。该地址没有 MySQL 服务在监听，请确认 MySQL 已启动，或检查 Host 和 Port。"
        }
        return "无法连接到 \(host):\(port)。\(underlying.localizedDescription)"
    }
}

final class MySQLSession: DatabaseSession, @unchecked Sendable {
    private let connection: MySQLConnection
    init(connection: MySQLConnection) { self.connection = connection }

    func query(_ sql: String) async throws -> QueryResult {
        let clock = ContinuousClock()
        let start = clock.now
        let rows = try await connection.simpleQuery(sql).get()
        let columns = rows.first?.columnDefinitions.map(\.name) ?? []
        let values = rows.map { row in
            columns.map { name in Self.display(row.column(name)) }
        }
        let elapsed = start.duration(to: clock.now)
        let message = columns.isEmpty ? "Statement completed" : "\(values.count) row(s)"
        return QueryResult(columns: columns, rows: values, elapsed: elapsed, message: message)
    }

    func schemas() async throws -> [String] {
        do {
            return Self.normalizedNames(try await firstColumn(of: "SHOW DATABASES"))
        } catch let showError {
            do {
                return Self.normalizedNames(try await firstColumn(of: "SELECT `SCHEMA_NAME` FROM `information_schema`.`SCHEMATA` ORDER BY `SCHEMA_NAME`"))
            } catch let informationSchemaError {
                throw MySQLMetadataFailure(
                    object: "数据库",
                    attempts: [showError.localizedDescription, informationSchemaError.localizedDescription]
                )
            }
        }
    }

    func tables(in schema: String) async throws -> [String] {
        let quoted = try SQLIdentifier.quote(schema)
        do {
            return Self.normalizedNames(try await firstColumn(of: "SHOW FULL TABLES FROM \(quoted)"))
        } catch let showError {
            do {
                let literal = try SQLStringLiteral.quote(schema)
                let sql = "SELECT `TABLE_NAME` FROM `information_schema`.`TABLES` WHERE `TABLE_SCHEMA` = \(literal) AND `TABLE_TYPE` IN ('BASE TABLE', 'VIEW') ORDER BY `TABLE_NAME`"
                return Self.normalizedNames(try await firstColumn(of: sql))
            } catch let informationSchemaError {
                throw MySQLMetadataFailure(
                    object: "数据库 \(schema) 中的表",
                    attempts: [showError.localizedDescription, informationSchemaError.localizedDescription]
                )
            }
        }
    }

    func close() async { try? await connection.close().get() }

    private func firstColumn(of sql: String) async throws -> [String] {
        let rows = try await connection.simpleQuery(sql).get()
        return rows.compactMap { row in
            guard let name = row.columnDefinitions.first?.name else { return nil }
            return Self.display(row.column(name))
        }
    }

    private static func normalizedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func display(_ data: MySQLData?) -> String {
        guard let data else { return "NULL" }
        if let value = data.string { return value }
        if let value = data.int64 { return String(value) }
        if let value = data.uint64 { return String(value) }
        if let value = data.double { return String(value) }
        if let value = data.date { return value.formatted(.iso8601) }
        return data.description
    }
}

struct MySQLMetadataFailure: LocalizedError {
    let object: String
    let attempts: [String]

    var errorDescription: String? {
        "无法读取\(object)。已尝试 SHOW 命令和 information_schema；请检查账号的 SHOW DATABASES / 对象访问权限。\(attempts.joined(separator: "；"))"
    }
}
