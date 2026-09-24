import Foundation
import XCTest
@testable import LuckySQL

final class QueryAssistanceTests: XCTestCase {
    private func complete(_ marked: String) -> [String] {
        let caret = (marked as NSString).range(of: "|").location
        let column: (String) -> TableColumn = { TableColumn(name: $0, dataType: "int", isNullable: false, isPrimaryKey: false, defaultValue: nil, extra: "") }
        let catalog = SQLCompletionCatalog(schemas: [DatabaseSchema(name: "db", tables: [DatabaseTable(schema: "db", name: "users"), DatabaseTable(schema: "db", name: "orders")])], columns: ["db.users": [column("id"), column("name")], "db.orders": [column("order_id")]], database: "db")
        return SQLCompletion.request(sql: marked.replacingOccurrences(of: "|", with: ""), caret: caret, catalog: catalog, automatic: false)?.candidates ?? []
    }
    func testCTEAndDerivedOutputs() {
        XCTAssertEqual(complete("WITH q AS (SELECT id AS person, name FROM users) SELECT q.| FROM q"), ["name", "person"])
        XCTAssertEqual(complete("WITH q(a, b) AS (SELECT id, name FROM users) SELECT q.| FROM q"), ["a", "b"])
        XCTAssertEqual(complete("SELECT d.| FROM (SELECT id AS person FROM users) d"), ["person"])
        XCTAssertEqual(complete("SELECT d.| FROM (SELECT u.* FROM users u) d"), ["id", "name"])
    }
    func testInnerAliasShadowsOuterButDoesNotLeakBack() {
        XCTAssertEqual(complete("SELECT u.id FROM users u WHERE EXISTS (SELECT u.| FROM orders u)"), ["order_id"])
        XCTAssertEqual(complete("SELECT u.| FROM users u WHERE EXISTS (SELECT u.order_id FROM orders u)"), ["id", "name"])
        XCTAssertEqual(complete("SELECT u.id FROM users u WHERE EXISTS (SELECT u.| FROM orders o)"), ["id", "name"])
        XCTAssertEqual(complete("SELECT u.| FROM users u /* JOIN orders u */"), ["id", "name"])
    }
    func testCTEInheritedByNestedQueryAndCommaSources() {
        XCTAssertEqual(complete("WITH q AS (SELECT id AS person FROM users) SELECT 1 WHERE EXISTS (SELECT inner_q.| FROM q inner_q)"), ["person"])
        XCTAssertEqual(complete("SELECT o.| FROM users u, orders o WHERE u.id = o.order_id"), ["order_id"])
    }
    func testParameterTypesAndMarkerLexing() throws {
        XCTAssertEqual(SQLParameter.count(in: "SELECT ?, '?', `?`, /* ? */ ? -- ?\n"), 2)
        XCTAssertEqual(try SQLParameter(kind: .null, value: "NULL").literal(), "NULL")
        XCTAssertEqual(try SQLParameter(kind: .text, value: "NULL").literal(), "'NULL'")
        XCTAssertEqual(try SQLParameter(kind: .integer, value: "18446744073709551615").literal(), "18446744073709551615")
        XCTAssertThrowsError(try SQLParameter(kind: .integer, value: "1 OR 1=1").literal())
        XCTAssertThrowsError(try SQLParameter(kind: .binary, value: "ff0").literal())
        XCTAssertEqual(try SQLParameter(kind: .binary, value: "00ff").literal(), "X'00ff'")
    }
    func testSeekNullsCompositeKeysAndPrecision() throws {
        let columns = [TableColumn(name: "name", dataType: "varchar(30)", isNullable: true, isPrimaryKey: false, defaultValue: nil, extra: ""),
                       TableColumn(name: "id", dataType: "bigint unsigned", isNullable: false, isPrimaryKey: true, defaultValue: nil, extra: "")]
        let asc = try SeekPagination.predicate(columns: columns, values: [nil, "18446744073709551614"], descending: false)
        XCTAssertTrue(asc.contains("`name` IS NOT NULL")); XCTAssertTrue(asc.contains("`name` <=> NULL AND `id` > 18446744073709551614"))
        let desc = try SeekPagination.predicate(columns: columns, values: ["中文😀", "5"], descending: true)
        XCTAssertTrue(desc.contains("`name` < '中文😀' OR `name` IS NULL")); XCTAssertTrue(desc.contains("`id` < 5"))
    }
    func testFormatterKeepsAmbiguousSQLModeLiteralsUnchanged() {
        for sql in [#"SELECT 'a\' as x, 'FROM y'"#, #"SELECT "a\" FROM x"#] { XCTAssertEqual(SQLTools.format(sql), sql) }
    }
    func testLiveBoundValuesRoundTripAndDoNotBecomeSQL() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["LUCKYSQL_TEST_PASSWORD"], let port = env["LUCKYSQL_TEST_PORT"].flatMap(Int.init) else { throw XCTSkip("Configure the MySQL fixture") }
        let driver = MySQLDriver(), session = try await driver.connect(profile: ConnectionProfile(host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql"), password: password)
        do {
            let value = "中文😀\n'; DROP TABLE x; -- \\"
            let result = try await session.parameterized("SELECT ? AS text_value, ? AS n, ? AS nil_value, HEX(?) AS binary_value", parameters: [SQLParameter(kind: .text, value: value), SQLParameter(kind: .integer, value: "18446744073709551615"), SQLParameter(kind: .null), SQLParameter(kind: .binary, value: "00ff")])
            XCTAssertEqual(result.rows[0], [value, "18446744073709551615", "NULL", "00FF"])
            XCTAssertTrue(result.isNull(row: 0, column: 2)); await session.close()
        } catch { await session.close(); throw error }
        withExtendedLifetime(driver) {}
    }
}
