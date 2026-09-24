import MySQLNIO

/// A COM_QUERY response decoder supporting both legacy EOF and modern OK terminators.
/// MySQLNIO 1.8's simpleQuery treats the legacy column-metadata EOF as the end of
/// the whole result, leaving unread rows on the connection (MySQL 5.6 / early 5.7).
final class MySQLTextQuery: MySQLCommand {
    private enum State {
        case ready, columns(UInt64), metadataEOF, rows, done
    }

    private let sql: String
    private let rowLimit: Int?
    private let byteLimit: Int?
    private(set) var retainedBytes = 0
    private(set) var byteLimitReached = false
    private var state = State.ready
    private let rowConsumer: ((MySQLRow) throws -> Void)?
    private var consumerError: Error?
    private(set) var columns: [MySQLProtocol.ColumnDefinition41] = []
    private(set) var rows: [MySQLRow] = []
    private(set) var rowCount = 0
    private(set) var affectedRows: UInt64 = 0
    var isComplete: Bool {
        if case .done = state { return true }
        return false
    }

    init(_ sql: String, rowLimit: Int? = nil, byteLimit: Int? = nil, rowConsumer: ((MySQLRow) throws -> Void)? = nil) { self.sql = sql; self.rowLimit = rowLimit; self.byteLimit = byteLimit; self.rowConsumer = rowConsumer }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        .init(response: [try .encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)])
    }

    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        // MySQLNIO passes the server's flags, including features the client did
        // not request (such as session tracking). Decode only negotiated flags.
        let capabilities = capabilities.intersection(.clientDefault)
        if packet.isError {
            state = .done
            throw MySQLError.server(try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities))
        }
        switch state {
        case .ready:
            if packet.isOK {
                affectedRows = try packet.decode(MySQLProtocol.OK_Packet.self, capabilities: capabilities).affectedRows
                state = .done
                return .init(done: true, error: consumerError)
            }
            let response = try packet.decode(MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities)
            guard response.columnCount > 0 else { throw MySQLError.protocolError }
            state = .columns(response.columnCount)
        case .columns(let count):
            columns.append(try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities))
            if UInt64(columns.count) == count {
                state = capabilities.contains(.CLIENT_DEPRECATE_EOF) ? .rows : .metadataEOF
            }
        case .metadataEOF:
            // With CLIENT_PROTOCOL_41 a legacy EOF is exactly five bytes.
            guard packet.isEOF, packet.payload.readableBytes == 5 else { throw MySQLError.protocolError }
            state = .rows
        case .rows:
            // Modern OK terminators can include trailing information. A real
            // 0xfe-prefixed text field is at least 0x1000000 bytes long; legacy
            // EOF packets, in contrast, are always shorter than nine bytes.
            let terminatorLimit = capabilities.contains(.CLIENT_DEPRECATE_EOF) ? 0xFFFFFF : 9
            if packet.isEOF, packet.payload.readableBytes < terminatorLimit {
                if capabilities.contains(.CLIENT_DEPRECATE_EOF) {
                    _ = try packet.decode(MySQLProtocol.OK_Packet.self, capabilities: capabilities)
                } else {
                    guard packet.payload.readableBytes == 5 else { throw MySQLError.protocolError }
                }
                state = .done
                return .init(done: true, error: consumerError)
            }
            if let rowConsumer {
                rowCount += 1
                if consumerError == nil {
                    let data = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: columns.count)
                    do { try rowConsumer(MySQLRow(format: .text, columnDefinitions: columns, values: data.values)) }
                    catch { consumerError = error }
                }
                return .init()
            }
            let bytes = packet.payload.readableBytes
            // Keep a contiguous prefix, never silently skip an oversized row and
            // then display later rows. Continue draining to preserve protocol sync.
            if let byteLimit, bytes > byteLimit - retainedBytes { byteLimitReached = true }
            if byteLimitReached || (rowLimit != nil && rows.count >= rowLimit!) { rowCount += 1; return .init() }
            let data = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: columns.count)
            rowCount += 1
            if rowLimit == nil || rows.count < rowLimit! {
                rows.append(MySQLRow(format: .text, columnDefinitions: columns, values: data.values))
                retainedBytes += bytes
            }
        case .done:
            throw MySQLError.protocolError
        }
        return .init()
    }
}

extension MySQLConnection {
    func textQuery(_ sql: String, rowLimit: Int? = nil, byteLimit: Int? = nil, rowConsumer: ((MySQLRow) throws -> Void)? = nil) async throws -> MySQLTextQuery {
        let command = MySQLTextQuery(sql, rowLimit: rowLimit, byteLimit: byteLimit, rowConsumer: rowConsumer)
        // Command state is written only on the connection event loop and read
        // by the caller only after send's completion future has resolved.
        try await send(command, logger: logger).get()
        return command
    }
}
