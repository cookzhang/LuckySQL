import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

final class MySQLDriver: DatabaseDriver, @unchecked Sendable {
    private let runtime = DatabaseEventLoopRuntime()
    private var group: MultiThreadedEventLoopGroup { runtime.group }
    init() {}

    /// A received value/constraint rejection is different from losing the
    /// connection after sending a write. A user may correct it and resubmit;
    /// the original-value predicate still protects against concurrent changes.
    static func isCorrectableValueRejection(_ error: Error) -> Bool {
        guard let mysql = error as? MySQLError, case .server(let packet) = mysql else { return false }
        let codes: [MySQLProtocol.ErrorCode] = [.BAD_NULL_ERROR, .DUP_ENTRY, .DUP_ENTRY_WITH_KEY_NAME,
            .WARN_DATA_OUT_OF_RANGE, .TRUNCATED_WRONG_VALUE_FOR_FIELD, .DATA_TOO_LONG,
            .NO_REFERENCED_ROW, .NO_REFERENCED_ROW_2]
        return codes.contains(packet.errorCode)
    }

    func connectPreview(profile: ConnectionProfile, password: String) async throws -> (any DatabaseSession)? {
        try await connect(profile: profile, password: password)
    }

    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession {
        let secret = if let options = profile.ssh, options.enabled { try await RecoveringPasswordStore().password(for: options.secretID) ?? "" } else { "" }
        return try await connect(profile: profile, password: password, sshPassword: secret)
    }
    func connect(profile: ConnectionProfile, password: String, sshPassword: String) async throws -> any DatabaseSession {
        let timeout = max(1, min(profile.connectTimeout ?? 30, 300))
        let tunnel = try await profile.ssh.flatMap { $0.enabled ? $0 : nil }.asyncMap {
            try await SSHTunnel.start(options: $0, destination: profile.host, destinationPort: profile.port, password: sshPassword, timeout: timeout)
        }
        let cancellation = ConnectionCancellation()
        do {
            let tls = try RemoteConnection.tls(profile.tls)
            let host = tunnel == nil ? profile.host : "127.0.0.1", port = tunnel?.port ?? profile.port
            let serverName = profile.tls?.serverName.isEmpty == false ? profile.tls!.serverName : profile.host
            return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let connection = try await MySQLConnection.connect(
                host: host, port: port, timeout: .seconds(Int64(timeout)), onChannel: { cancellation.register($0) },
                username: profile.username,
                database: profile.database,
                password: password,
                tlsConfiguration: tls,
                serverHostname: tls == nil ? nil : serverName,
                additionalCertificateVerification: { certificate, channel in
                    channel.eventLoop.makeCompletedFuture { try RemoteConnection.verifyIdentity(certificate, hostname: serverName) }
                },
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
                let identity = try await connection.textQuery("SELECT CONNECTION_ID() AS id")
                guard let connectionID = identity.rows.first?.column("id")?.uint64 else { throw MySQLError.protocolError }
                let loop = group.next()
                let queue = MySQLCommandQueue(connection: connection, connectionID: connectionID) {
                    try await MySQLConnection.connect(host: host, port: port, timeout: .seconds(Int64(timeout)), username: profile.username, database: "", password: password,
                        tlsConfiguration: tls, serverHostname: tls == nil ? nil : serverName, additionalCertificateVerification: { certificate, channel in channel.eventLoop.makeCompletedFuture { try RemoteConnection.verifyIdentity(certificate, hostname: serverName) } }, logger: Logger(label: "LuckySQL.Cancel"), on: loop).get()
                }
                try Task.checkCancellation()
                return MySQLSession(connection: connection, commands: queue, runtime: runtime, tunnel: tunnel, queryTimeout: profile.queryTimeout ?? 0)
            } catch {
                try? await connection.close().get()
                throw error
            }
            } onCancel: { cancellation.cancel(); tunnel?.close() }
        } catch {
            tunnel?.close()
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
        if detail.localizedCaseInsensitiveContains("handshake timed out") {
            return "MySQL handshake/authentication timed out at \(host):\(port). The half-open connection was closed; check the server and connection timeout."
        }
        if detail.localizedCaseInsensitiveContains("connectTimeout") {
            return "DNS/TCP connection timed out at \(host):\(port). Check the address, firewall and network."
        }
        if detail.localizedCaseInsensitiveContains("access denied") || detail.contains("1045") {
            return "MySQL authentication failed at \(host):\(port). Check the database username, password and account permissions. \(underlying.localizedDescription)"
        }
        if detail.localizedCaseInsensitiveContains("ssl") || detail.localizedCaseInsensitiveContains("certificate") || detail.localizedCaseInsensitiveContains("TLS") {
            return "TLS handshake failed at \(host):\(port). Check the CA, server name and client certificate. No unencrypted retry was attempted. \(underlying.localizedDescription)"
        }
        if detail.localizedCaseInsensitiveContains("DNS") || detail.localizedCaseInsensitiveContains("getaddrinfo") {
            return "DNS resolution failed for \(host). Check the host name and network. \(underlying.localizedDescription)"
        }
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
    private let commands: MySQLCommandQueue
    private let runtime: DatabaseEventLoopRuntime
    private let tunnel: SSHTunnel?
    private let queryTimeout: Int
    private let cancellationLock = NSLock()
    private var cancellationVersion = 0
    private func generation() -> Int { cancellationLock.lock(); defer { cancellationLock.unlock() }; return cancellationVersion }
    private func markCancellation() { cancellationLock.lock(); cancellationVersion += 1; cancellationLock.unlock() }
    private func checkGeneration(_ value: Int) throws { if value != generation() { throw CancellationError() } }
    init(connection: MySQLConnection, commands: MySQLCommandQueue, runtime: DatabaseEventLoopRuntime, tunnel: SSHTunnel? = nil, queryTimeout: Int = 0) {
        self.connection = connection; self.commands = commands; self.runtime = runtime; self.tunnel = tunnel; self.queryTimeout = queryTimeout
    }

    func query(_ sql: String) async throws -> QueryResult {
        let clock = ContinuousClock()
        let start = clock.now
        let previewSQL = try SQLPreview.query(sql)
        let response = try await commands.query(previewSQL, rowLimit: SQLPreview.rowLimit, byteLimit: 16 * 1024 * 1024, timeout: queryTimeout)
        let rows = response.rows
        let columns = response.columns.map(\.name)
        var nullCells = Set<CellAddress>()
        var binaryCells: [CellAddress: Data] = [:]
        let values = rows.enumerated().map { rowIndex, row in
            row.values.enumerated().map { columnIndex, buffer -> String in
                if buffer == nil { nullCells.insert(CellAddress(row: rowIndex, column: columnIndex)) }
                // Positional access preserves distinct values when columns have duplicate names.
                let definition = row.columnDefinitions[columnIndex]
                let data = MySQLData(type: definition.columnType, format: row.format, buffer: buffer, isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED))
                if definition.characterSet == 63, [.blob, .tinyBlob, .mediumBlob, .longBlob, .string, .varString, .varchar, .geometry, .bit].contains(definition.columnType), let buffer,
                   let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                    binaryCells[CellAddress(row: rowIndex, column: columnIndex)] = Data(bytes)
                }
                return Self.display(data)
            }
        }
        let elapsed = start.duration(to: clock.now)
        let message = columns.isEmpty ? "\(response.affectedRows) affected row(s)" : values.count == SQLPreview.rowLimit ? "\(values.count) row(s) · 1,000-row preview limit" : "\(values.count) row(s)"
        return QueryResult(columns: columns, rows: values, elapsed: elapsed,
                           message: message + (response.byteLimitReached ? " · 16 MB preview budget reached; select fewer/smaller columns" : ""),
                           nullCells: nullCells, isTruncated: response.byteLimitReached || values.count == SQLPreview.rowLimit, retainedBytes: response.retainedBytes + binaryCells.values.reduce(0) { $0 + $1.count }, affectedRows: columns.isEmpty ? response.affectedRows : nil, binaryCells: binaryCells)
    }

    func export(_ sql: String, to url: URL, format: TransferFormat, progress: @escaping @Sendable (Int) -> Void) async throws -> Int {
        guard let target = SQLCompletion.references(sql, database: "").first?.table else { throw UpdateFailure("Export requires a selected table.") }
        let writer = try StreamingExport(url: url, format: format, target: target, progress: progress)
        let response = try await commands.query(sql, timeout: queryTimeout, rowConsumer: { try writer.append($0) })
        return try writer.finish(columns: response.columns.map(\.name))
    }

    func schemas() async throws -> [String] {
        let version = generation()
        do {
            return Self.normalizedNames(try await firstColumn(of: "SHOW DATABASES"))
        } catch let showError {
            try checkGeneration(version)
            if showError is DatabaseSessionLost { throw showError }
            do {
                return Self.normalizedNames(try await firstColumn(of: "SELECT `SCHEMA_NAME` FROM `information_schema`.`SCHEMATA` ORDER BY `SCHEMA_NAME`"))
            } catch let informationSchemaError {
                try checkGeneration(version)
                if informationSchemaError is DatabaseSessionLost { throw informationSchemaError }
                throw MySQLMetadataFailure(
                    object: "数据库",
                    attempts: [showError.localizedDescription, informationSchemaError.localizedDescription]
                )
            }
        }
    }

    func tables(in schema: String) async throws -> [String] {
        let version = generation()
        let quoted = try SQLIdentifier.quote(schema)
        do {
            return Self.normalizedNames(try await firstColumn(of: "SHOW FULL TABLES FROM \(quoted)"))
        } catch let showError {
            try checkGeneration(version)
            if showError is DatabaseSessionLost { throw showError }
            do {
                let literal = try SQLStringLiteral.quote(schema)
                let sql = "SELECT `TABLE_NAME` FROM `information_schema`.`TABLES` WHERE `TABLE_SCHEMA` = \(literal) AND `TABLE_TYPE` IN ('BASE TABLE', 'VIEW') ORDER BY `TABLE_NAME`"
                return Self.normalizedNames(try await firstColumn(of: sql))
            } catch let informationSchemaError {
                try checkGeneration(version)
                if informationSchemaError is DatabaseSessionLost { throw informationSchemaError }
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
        let rows = try await commands.query(sql, timeout: queryTimeout).rows
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
        let version = generation()
        let qualified = "\(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))"
        let columns = try await columns(in: table)
        try checkGeneration(version)
        let schema = try SQLStringLiteral.quote(table.schema)
        let name = try SQLStringLiteral.quote(table.name)
        let indexes = try await query("""
        SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, COLLATION, CARDINALITY, SUB_PART, INDEX_TYPE, INDEX_COMMENT
        FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(name)
        ORDER BY INDEX_NAME, SEQ_IN_INDEX
        """)
        try checkGeneration(version)
        let foreignKeys = try await query("""
        SELECT CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
        FROM information_schema.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(name) AND REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY CONSTRAINT_NAME, ORDINAL_POSITION
        """)
        try checkGeneration(version)
        let create = try await query("SHOW CREATE TABLE \(qualified)")
        try checkGeneration(version)
        return TableStructure(columns: columns, indexes: indexes, foreignKeys: foreignKeys, createSQL: create.rows.first?.dropFirst().first ?? "")
    }

    func close() async { try? await connection.close().get(); tunnel?.close() }
    func cancel() async { try? await connection.channel.close().get(); tunnel?.close() }
    func cancelQuery() async throws { markCancellation(); try await commands.cancelQuery() }

    private func firstColumn(of sql: String) async throws -> [String] {
        let rows = try await commands.query(sql, timeout: queryTimeout).rows
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

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }; return try await transform(value)
    }
}

final class DatabaseEventLoopRuntime: @unchecked Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    deinit { group.shutdownGracefully { _ in } }
}
