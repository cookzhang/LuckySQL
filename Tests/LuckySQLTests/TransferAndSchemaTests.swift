import Foundation
import XCTest
@testable import LuckySQL

final class TransferAndSchemaTests: XCTestCase {
    func testScriptDelimiterPreservesRoutineQuotesCommentsAndLargeFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let large = String(repeating: "中😀", count: 320_000)
        let source = "-- fixture\nDELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT ';', '$$'; /* $$ */ SELECT 2; END$$\nDELIMITER ;\nSELECT '\(large)';\n" + String(repeating: "SELECT 1;\n", count: 101)
        try Data(source.utf8).write(to: url)
        let reader = try SQLScriptReader(url: url)
        let routine = try await reader.next()
        XCTAssertTrue(routine?.sql.contains("SELECT ';', '$$'") == true)
        let query = try await reader.next(); XCTAssertTrue(query?.sql.contains(large) == true)
        var count = 0
        while try await reader.next() != nil { count += 1 }
        XCTAssertEqual(count, 101)
    }
    func testCSVMultilineUnicodeNullAndEmptyRemainDistinct() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("a,b,c,d\r\n\"中文😀\nline\",\\N,\"\\N\",\"\"\r\n\"a\"\"b\",x,y,z\n".utf8).write(to: url)
        let reader = try CSVReader(url: url)
        _ = try await reader.next()
        let loaded = try await reader.next()
        let row = try XCTUnwrap(loaded)
        XCTAssertEqual(row.map(\.value), ["中文😀\nline", "\\N", "\\N", ""])
        XCTAssertFalse(row[1].quoted); XCTAssertTrue(row[2].quoted)
        let last = try await reader.next(); XCTAssertEqual(last?.first?.value, "a\"b")
    }
    func testMalformedCSVAndScriptFailClearly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("\"unterminated".utf8).write(to: url)
        do { _ = try await CSVReader(url: url).next(); XCTFail("Expected malformed CSV") } catch {}
        try Data("SELECT 'unterminated".utf8).write(to: url)
        do { _ = try await SQLScriptReader(url: url).next(); XCTFail("Expected malformed SQL") } catch {}
    }
    func testSchemaDiffQuotesNamesAndRetainsUnchangedColumns() throws {
        let column = TableColumn(name: "old", dataType: "int", isNullable: false, isPrimaryKey: true, defaultValue: nil, extra: "")
        var edited = ColumnDraft(column); edited.name = "new`name"
        let sql = try SchemaChange.columns(table: DatabaseTable(schema: "db", name: "t"), original: [column], desired: [edited], creating: false)
        XCTAssertTrue(sql.contains("CHANGE COLUMN `old` `new``name` int NOT NULL"))
        XCTAssertTrue(sql.contains("ADD PRIMARY KEY (`new``name`)"))
        var bad = ColumnDraft(); bad.name = "id"; bad.type = "INT; DROP TABLE t"
        XCTAssertThrowsError(try bad.definition())
    }
    func testGridChangeBindsOriginalNullAndBinaryRatherThanInterpolatingValues() throws {
        let change = GridChange(table: DatabaseTable(schema: "db", name: "t"), kind: .update,
                                before: ["id": SQLParameter(kind: .integer, value: "1"), "v": SQLParameter(kind: .null)],
                                values: ["v": SQLParameter(kind: .binary, value: "00ff")], label: "fixture")
        let statement = try change.statement()
        XCTAssertEqual(statement.parameters.map(\.kind), [.binary, .integer, .null])
        XCTAssertTrue(statement.sql.contains("BINARY `v` <=> BINARY ?")); XCTAssertFalse(statement.sql.contains("00ff"))
    }
}
