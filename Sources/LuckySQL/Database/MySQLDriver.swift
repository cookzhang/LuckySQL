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
            do {
                // MySQLNIO requests collation 255 (8.0's utf8mb4_0900_ai_ci)
                // during handshake. Older servers silently fall back to their
                // default charset. Explicitly negotiate a collation shared by
                // 5.6, 5.7 and 8.x before sending any user SQL.
                _ = try await connection.textQuery("SET NAMES utf8mb4 COLLATE utf8mb4_general_ci")
                let probe = try await connection.textQuery("SELECT 1")
                guard probe.rows.count == 1 else { throw MySQLError.protocolError }
                return MySQLSession(connection: connection)
            } catch {
                try? await connection.close().get()
                throw error
            }
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
        let previewSQL = try SQLPreview.query(sql)
        let response = try await connection.textQuery(previewSQL, rowLimit: SQLPreview.rowLimit)
        let rows = response.rows
        let columns = response.columns.map(\.name)
        var nullCells = Set<CellAddress>()
        let values = rows.enumerated().map { rowIndex, row in
            row.values.enumerated().map { columnIndex, buffer -> String in
                if buffer == nil { nullCells.insert(CellAddress(row: rowIndex, column: columnIndex)) }
                // Positional access preserves distinct values when columns have duplicate names.
                let definition = row.columnDefinitions[columnIndex]
                let data = MySQLData(type: definition.columnType, format: row.format, buffer: buffer, isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED))
                return Self.display(data)
            }
        }
        let elapsed = start.duration(to: clock.now)
        let message = columns.isEmpty ? "\(response.affectedRows) affected row(s)" : values.count == SQLPreview.rowLimit ? "\(values.count) row(s) · 1,000-row preview limit" : "\(values.count) row(s)"
        return QueryResult(columns: columns, rows: values, elapsed: elapsed, message: message, nullCells: nullCells)
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

    func columns(in table: DatabaseTable) async throws -> [TableColumn] {
        let schema = try SQLStringLiteral.quote(table.schema)
        let name = try SQLStringLiteral.quote(table.name)
        let sql = """
        SELECT `COLUMN_NAME`, `COLUMN_TYPE`, `IS_NULLABLE`, `COLUMN_KEY`, `COLUMN_DEFAULT`, `EXTRA`, `COLUMN_COMMENT`
        FROM `information_schema`.`COLUMNS`
        WHERE `TABLE_SCHEMA` = \(schema) AND `TABLE_NAME` = \(name)
        ORDER BY `ORDINAL_POSITION`
        """
        let rows = try await connection.textQuery(sql).rows
        return rows.map { row in
            TableColumn(
                name: Self.display(row.column("COLUMN_NAME")),
                dataType: Self.display(row.column("COLUMN_TYPE")),
                isNullable: Self.display(row.column("IS_NULLABLE")) == "YES",
                isPrimaryKey: Self.display(row.column("COLUMN_KEY")) == "PRI",
                defaultValue: row.column("COLUMN_DEFAULT").flatMap { $0.string },
                extra: Self.display(row.column("EXTRA")) == "NULL" ? "" : Self.display(row.column("EXTRA")),
                comment: row.column("COLUMN_COMMENT")?.string ?? ""
            )
        }
    }

    func structure(in table: DatabaseTable) async throws -> TableStructure {
        let qualified = "\(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))"
        let columns = try await columns(in: table)
        let schema = try SQLStringLiteral.quote(table.schema)
        let name = try SQLStringLiteral.quote(table.name)
        let indexes = try await query("""
        SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, COLLATION, CARDINALITY, SUB_PART, INDEX_TYPE, INDEX_COMMENT
        FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(name)
        ORDER BY INDEX_NAME, SEQ_IN_INDEX
        """)
        let foreignKeys = try await query("""
        SELECT CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
        FROM information_schema.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(name) AND REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY CONSTRAINT_NAME, ORDINAL_POSITION
        """)
        let create = try await query("SHOW CREATE TABLE \(qualified)")
        return TableStructure(columns: columns, indexes: indexes, foreignKeys: foreignKeys, createSQL: create.rows.first?.dropFirst().first ?? "")
    }

    func close() async { try? await connection.close().get() }
    func cancel() async { try? await connection.channel.close().get() }

    private func firstColumn(of sql: String) async throws -> [String] {
        let rows = try await connection.textQuery(sql).rows
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
        guard let data, data.buffer != nil else { return "NULL" }
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
