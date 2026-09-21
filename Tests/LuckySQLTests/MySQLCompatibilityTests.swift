import Foundation
import MySQLNIO
import NIOCore
import XCTest
@testable import LuckySQL

final class MySQLCompatibilityTests: XCTestCase {
    private let legacy: MySQLProtocol.CapabilityFlags = [.CLIENT_PROTOCOL_41]
    private var modern: MySQLProtocol.CapabilityFlags { [.CLIENT_PROTOCOL_41, .CLIENT_DEPRECATE_EOF] }

    func testLegacyMetadataEOFDoesNotCompleteResult() throws {
        let command = MySQLTextQuery("SELECT 'hello'")
        try begin(command, capabilities: legacy)
        try feed([0xfe, 0, 0, 2, 0], to: command, capabilities: legacy)
        XCTAssertFalse(command.isComplete)
        try feed([5] + Array("hello".utf8), to: command, capabilities: legacy)
        try feed([0xfe, 0, 0, 2, 0], to: command, capabilities: legacy)
        XCTAssertTrue(command.isComplete)
        XCTAssertEqual(command.rows.first?.column("value")?.string, "hello")
    }

    func testModernResultHasNoMetadataEOF() throws {
        let command = MySQLTextQuery("SELECT 'hello'")
        try begin(command, capabilities: modern)
        try feed([5] + Array("hello".utf8), to: command, capabilities: modern)
        try feed([0xfe, 0, 0, 2, 0, 0, 0], to: command, capabilities: modern)
        XCTAssertTrue(command.isComplete)
        XCTAssertEqual(command.rows.first?.column("value")?.string, "hello")
    }

    func testEmptyResultsKeepColumnDefinitions() throws {
        for capabilities in [legacy, modern] {
            let command = MySQLTextQuery("SELECT 1 WHERE FALSE")
            try begin(command, capabilities: capabilities)
            if !capabilities.contains(.CLIENT_DEPRECATE_EOF) {
                try feed([0xfe, 0, 0, 2, 0], to: command, capabilities: capabilities)
            }
            let end: [UInt8] = capabilities.contains(.CLIENT_DEPRECATE_EOF) ? [0xfe, 0, 0, 2, 0, 0, 0] : [0xfe, 0, 0, 2, 0]
            try feed(end, to: command, capabilities: capabilities)
            XCTAssertTrue(command.isComplete)
            XCTAssertEqual(command.columns.map(\.name), ["value"])
            XCTAssertTrue(command.rows.isEmpty)
        }
    }

    func testEmptyStringNullAndLargeLengthEncodedFEAreRows() throws {
        let command = MySQLTextQuery("SELECT value")
        try begin(command, capabilities: modern)
        try feed([0], to: command, capabilities: modern)
        try feed([0xfb], to: command, capabilities: modern)
        let largeValue = [UInt8](repeating: 65, count: 0x1000000)
        try feed([0xfe, 0, 0, 0, 1, 0, 0, 0, 0] + largeValue, to: command, capabilities: modern)
        XCTAssertFalse(command.isComplete)
        XCTAssertEqual(command.rows.count, 3)
        XCTAssertEqual(command.rows[0].column("value")?.string, "")
        XCTAssertNil(command.rows[1].column("value")?.buffer)
        XCTAssertEqual(command.rows[2].column("value")?.buffer?.readableBytes, largeValue.count)
    }

    func testModernTerminatorWithInfoIgnoresUnnegotiatedSessionTracking() throws {
        let command = MySQLTextQuery("SELECT 1")
        let serverFlags = modern.union([.CLIENT_SESSION_TRACK])
        try begin(command, capabilities: serverFlags)
        try feed([0xfe, 0, 0, 2, 0, 0, 0] + Array("query completed".utf8), to: command, capabilities: serverFlags)
        XCTAssertTrue(command.isComplete)
    }

    func testStatementOKAndServerError() throws {
        let command = MySQLTextQuery("UPDATE example SET value = 1")
        try feed([0, 1, 0, 2, 0, 0, 0], to: command, capabilities: modern)
        XCTAssertTrue(command.isComplete)
        let failed = MySQLTextQuery("invalid")
        let error: [UInt8] = [0xff, 0x28, 0x04, 0x23] + Array("42000syntax error".utf8)
        XCTAssertThrowsError(try feed(error, to: failed, capabilities: legacy))
    }

    func testPreviewLimitStillDrainsAllPackets() throws {
        let command = MySQLTextQuery("SELECT value", rowLimit: 1)
        try begin(command, capabilities: modern)
        try feed([1, 65], to: command, capabilities: modern)
        try feed([1, 66], to: command, capabilities: modern)
        try feed([0xfe, 0, 0, 2, 0, 0, 0], to: command, capabilities: modern)
        XCTAssertTrue(command.isComplete)
        XCTAssertEqual(command.rows.count, 1)
        XCTAssertEqual(command.rowCount, 2)
    }

    private func begin(_ command: MySQLTextQuery, capabilities: MySQLProtocol.CapabilityFlags) throws {
        try feed([1], to: command, capabilities: capabilities)
        var definition: [UInt8] = []
        for string in ["def", "", "", "", "value", ""] {
            definition.append(UInt8(string.utf8.count))
            definition += string.utf8
        }
        definition += [0x0c, 33, 0, 255, 0, 0, 0, 0xfd, 0, 0, 0, 0, 0]
        try feed(definition, to: command, capabilities: capabilities)
    }

    private func feed(_ bytes: [UInt8], to command: MySQLTextQuery, capabilities: MySQLProtocol.CapabilityFlags) throws {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        var packet = MySQLPacket(payload: buffer)
        _ = try command.handle(packet: &packet, capabilities: capabilities)
    }

    func testLiveServerWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let password = environment["LUCKYSQL_TEST_PASSWORD"],
              let port = environment["LUCKYSQL_TEST_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Set LUCKYSQL_TEST_PORT and LUCKYSQL_TEST_PASSWORD to test a local MySQL server")
        }
        let driver = MySQLDriver()
        let profile = ConnectionProfile(name: "Integration", host: "127.0.0.1", port: port,
                                        username: environment["LUCKYSQL_TEST_USER"] ?? "luckysql", database: "")
        let session = try await driver.connect(profile: profile, password: password)
        do {
            let version = try await session.query("SELECT VERSION() AS version")
            print("Verified MySQL version: \(version.rows)")
            let schemas = try await session.schemas()
            XCTAssertTrue(schemas.contains("luckysql"))
            let charset = try await session.query("SELECT @@character_set_client, @@character_set_connection, @@character_set_results")
            XCTAssertEqual(charset.rows, [["utf8mb4", "utf8mb4", "utf8mb4"]])
            let table = DatabaseTable(schema: "luckysql", name: "compatibility_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
            let qualified = "`luckysql`.`\(table.name)`"
            _ = try await session.query("CREATE TABLE \(qualified) (id INT PRIMARY KEY, value VARCHAR(100) NULL) DEFAULT CHARSET=utf8mb4")
            do {
                let tables = try await session.tables(in: "luckysql")
                XCTAssertTrue(tables.contains(table.name))
                let columns = try await session.columns(in: table)
                XCTAssertEqual(columns.map(\.name), ["id", "value"])
                XCTAssertTrue(columns[0].isPrimaryKey)
                let structure = try await session.structure(in: table)
                XCTAssertEqual(structure.columns.count, 2)
                XCTAssertTrue(structure.createSQL.contains(table.name))
                XCTAssertTrue(structure.indexes.rows.contains(where: { $0.contains("PRIMARY") }))
                XCTAssertTrue(structure.foreignKeys.rows.isEmpty)
                let empty = try await session.query("SELECT * FROM \(qualified)")
                XCTAssertEqual(empty.columns, ["id", "value"])
                XCTAssertTrue(empty.rows.isEmpty)
                _ = try await session.query("INSERT INTO \(qualified) VALUES (1, '中文😀'), (2, NULL), (3, '')")
                let rows = try await session.query("SELECT * FROM \(qualified) ORDER BY id")
                XCTAssertEqual(rows.rows, [["1", "中文😀"], ["2", "NULL"], ["3", ""]])
                let bytes = try await session.query("SELECT HEX(value), CHAR_LENGTH(value) FROM \(qualified) WHERE id = 1")
                XCTAssertEqual(bytes.rows, [["E4B8ADE69687F09F9880", "3"]])
                let preencoded = try await session.query("SELECT CONVERT(0xE4B8ADE69687F09F9880 USING utf8mb4) AS value")
                XCTAssertEqual(preencoded.rows, [["中文😀"]])
                XCTAssertTrue(rows.isNull(row: 1, column: 1))
                XCTAssertFalse(rows.isNull(row: 2, column: 1))
                let duplicate = try await session.query("SELECT 1 AS same, 2 AS same, NULL AS missing, 'NULL' AS string_value")
                XCTAssertEqual(duplicate.rows, [["1", "2", "NULL", "NULL"]])
                XCTAssertEqual(duplicate.nullCells, [CellAddress(row: 0, column: 2)])
                _ = try await session.query("UPDATE \(qualified) SET value = 'updated' WHERE id = 1")
                _ = try await session.query("DELETE FROM \(qualified) WHERE id = 3")
                do {
                    _ = try await session.query("SELECT non_existent_column FROM \(qualified)")
                    XCTFail("Invalid query should throw")
                } catch { XCTAssertTrue(error.localizedDescription.contains("non_existent_column")) }
                // Consecutive requests after an empty result and after a server error
                // must still work: no protocol packets may be left unread.
                let remaining = try await session.query("SELECT * FROM \(qualified) ORDER BY id")
                XCTAssertEqual(remaining.rows, [["1", "updated"], ["2", "NULL"]])
                // Check both retained rows and server-side execution: FOUND_ROWS
                // must report 1,000, not all 1,205 rows drained by the client.
                _ = try await session.query("DELETE FROM \(qualified)")
                let values = (1...1205).map { "(\($0), 'row')" }.joined(separator: ",")
                _ = try await session.query("INSERT INTO \(qualified) VALUES \(values)")
                let limited = try await session.query("SELECT * FROM \(qualified) ORDER BY id")
                XCTAssertEqual(limited.rows.count, 1000)
                let serverCount = try await session.query("SELECT FOUND_ROWS()")
                XCTAssertEqual(serverCount.rows, [["1000"]])
                let offset = try await session.query("SELECT id FROM \(qualified) ORDER BY id LIMIT 20,5000")
                XCTAssertEqual(offset.rows.count, 1000)
                XCTAssertEqual(offset.rows.first, ["21"])
                let small = try await session.query("SELECT id FROM \(qualified) ORDER BY id LIMIT 2 OFFSET 1200")
                XCTAssertEqual(small.rows, [["1201"], ["1202"]])
                let nested = try await session.query("SELECT * FROM (SELECT id FROM \(qualified) LIMIT 3) s")
                XCTAssertEqual(nested.rows.count, 3)
                let union = try await session.query("SELECT id FROM \(qualified) UNION ALL SELECT id FROM \(qualified)")
                XCTAssertEqual(union.rows.count, 1000)
                let locked = try await session.query("SELECT * FROM \(qualified) FOR UPDATE")
                XCTAssertEqual(locked.rows.count, 1000)
                if version.rows.first?.first?.hasPrefix("8.") == true {
                    let cte = try await session.query("WITH c AS (SELECT * FROM \(qualified)) SELECT * FROM c")
                    XCTAssertEqual(cte.rows.count, 1000)
                }
            } catch {
                _ = try? await session.query("DROP TABLE \(qualified)")
                throw error
            }
            _ = try await session.query("DROP TABLE \(qualified)")
            await session.close()
        } catch {
            await session.close()
            throw error
        }
        withExtendedLifetime(driver) {}
    }
}
