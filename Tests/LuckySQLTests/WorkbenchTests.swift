import AppKit
import SwiftUI
import XCTest
@testable import LuckySQL

final class WorkbenchTests: XCTestCase {
    func testTokenizerDoesNotColorCommentsInsideStrings() {
        let sql = "SELECT 'it''s -- not a comment', `from`, 42; # comment\n/* SELECT */"
        let tokens = SQLTools.tokens(sql)
        XCTAssertEqual(tokens.filter { $0.kind == .string }.map(\.text), ["'it''s -- not a comment'"])
        XCTAssertEqual(tokens.filter { $0.kind == .keyword }.map(\.text), ["SELECT"])
        XCTAssertEqual(tokens.filter { $0.kind == .comment }.count, 2)
        XCTAssertEqual(tokens.filter { $0.kind == .number }.map(\.text), ["42"])
    }
    func testStatementSplittingAndUTF16Selection() {
        let sql = "SELECT '中文😀;'; -- ignored ;\nSELECT 'it\\'s; fine'; /* ; */ SELECT 3;"
        let statements = SQLTools.statements(sql)
        XCTAssertEqual(statements.count, 3)
        let selection = (sql as NSString).range(of: "SELECT 3")
        XCTAssertEqual(SQLTools.executable(sql, selection: selection), "SELECT 3")
        XCTAssertTrue(SQLTools.executable(sql, selection: NSRange(location: selection.location, length: 0)).contains("SELECT 3"))
        XCTAssertEqual(SQLTools.executable(sql, selection: selection, all: true), sql)
        XCTAssertTrue(SQLTools.statements("-- only a comment\n/* ... */").isEmpty)
        XCTAssertEqual(SQLTools.statements("SELECT 5--2;").count, 1)
    }
    func testWriteConfirmationCannotBeHiddenInCommentsOrCTEs() {
        XCTAssertFalse(SQLTools.requiresConfirmation("-- query\nSELECT 'DELETE'; SHOW TABLES;"))
        XCTAssertTrue(SQLTools.requiresConfirmation("SELECT 1; DROP TABLE a;"))
        XCTAssertTrue(SQLTools.requiresConfirmation("WITH a AS (SELECT 1) DELETE FROM b;"))
        XCTAssertTrue(SQLTools.requiresConfirmation("SELECT 1 INTO OUTFILE '/tmp/output';"))
        XCTAssertTrue(SQLTools.requiresConfirmation("/*!50000 DROP TABLE a */ SELECT 1;"))
    }
    func testFormatterPreservesValuesAndCommentBoundaries() {
        let sql = "select 'select; -- string', `where` from x --comment\nwhere n = 1;"
        let formatted = SQLTools.format(sql)
        XCTAssertTrue(formatted.contains("'select; -- string'"))
        XCTAssertTrue(formatted.contains("`where`"))
        XCTAssertTrue(formatted.contains("\nFROM"))
        let commented = SQLTools.format("select 1 -- comment\nfrom x")
        XCTAssertTrue(commented.contains("-- comment\n"))
        XCTAssertEqual(SQLTools.statements(formatted).count, 1)
    }
    func testBrowseQueryIsPagedQuotedAndStable() throws {
        var options = TableBrowseOptions()
        options.page = 2; options.pageSize = 100
        options.filterColumn = "customer`name"; options.filterOperator = .contains; options.filterValue = "O'Reilly"
        options.sortColumn = "created_at"; options.descending = true
        let query = try options.query(for: DatabaseTable(schema: "shop", name: "orders"), primaryKeys: ["id"])
        XCTAssertEqual(query, "SELECT * FROM `shop`.`orders` WHERE LOCATE('O''Reilly', `customer``name`) > 0 ORDER BY `created_at` DESC, `id` DESC LIMIT 101 OFFSET 200;")
        options.filterOperator = .isNull
        XCTAssertTrue(try options.query(for: DatabaseTable(schema: "shop", name: "orders"), primaryKeys: []).contains("WHERE `customer``name` IS NULL"))
        XCTAssertTrue(try SQLStringLiteral.quote("\\'; DROP TABLE x;").hasPrefix("CONVERT(X'"))
    }
    func testExportsRetainDuplicateColumnsNullAndMultilineValues() throws {
        let result = QueryResult(columns: ["same", "same"], rows: [["NULL", "NULL"], ["a,b", "a\"b\nc"]], elapsed: .zero, message: "", nullCells: [CellAddress(row: 0, column: 0)])
        let data = try XCTUnwrap(try ResultExport.json(result).data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[Any]])
        XCTAssertTrue(rows[0][0] is NSNull); XCTAssertEqual(rows[0][1] as? String, "NULL")
        XCTAssertEqual(ResultExport.csv(result), "same,same\r\nNULL,NULL\r\n\"a,b\",\"a\"\"b\nc\"\r\n")
    }
    @MainActor
    func testHighlightUsesLayoutColorsWithoutMutatingSQL() throws {
        let sql = "SELECT 'text', 42 -- comment"
        let editor = NSTextView()
        editor.string = sql
        let coordinator = SQLTextEditor.Coordinator(SQLTextEditor(text: .constant(sql)))
        coordinator.highlight(editor)
        XCTAssertEqual(editor.string, sql)
        let attributes = try XCTUnwrap(editor.layoutManager?.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil))
        XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .systemBlue)
        let stringAttributes = try XCTUnwrap(editor.layoutManager?.temporaryAttributes(atCharacterIndex: 8, effectiveRange: nil))
        XCTAssertEqual(stringAttributes[.foregroundColor] as? NSColor, .systemRed)
    }
    @MainActor
    func testWorkspaceRoundtrip() throws {
        let name = "WorkbenchTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        store.saveTabs([QueryTab(title: "Draft", sql: "SELECT '中文';", database: "shop")])
        XCTAssertEqual(store.loadTabs().first?.sql, "SELECT '中文';")
        XCTAssertEqual(store.loadTabs().first?.database, "shop")
        store.saveFavorites(["connection/shop.orders"])
        XCTAssertEqual(store.loadFavorites(), ["connection/shop.orders"])
    }
}
