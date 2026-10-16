import Foundation
import XCTest
@testable import LuckySQL

final class TableCommentMetadataTests: XCTestCase {
    func testSummarySQLIsBoundedAndReadsOnlySchemaMetadata() throws {
        let sql = try MySQLTableMetadata.summariesSQL(in: "sales' archive")
        XCTAssertTrue(sql.contains("SELECT `TABLE_NAME`, `TABLE_COMMENT`"))
        XCTAssertTrue(sql.contains("FROM `information_schema`.`TABLES`"))
        XCTAssertTrue(sql.contains("`TABLE_SCHEMA` = 'sales'' archive'"))
        XCTAssertTrue(sql.contains("`TABLE_TYPE` IN ('BASE TABLE', 'VIEW')"))
        XCTAssertTrue(sql.hasSuffix("ORDER BY `TABLE_NAME`\nLIMIT 201"))
    }

    func testCommentSQLQuotesSchemaAndTableIndependentlyOfSQLMode() throws {
        let table = DatabaseTable(schema: "sales\\archive", name: "orders'2026")
        let sql = try MySQLTableMetadata.commentSQL(for: table)
        XCTAssertTrue(sql.contains("`TABLE_SCHEMA` = CONVERT(X'73616c65735c61726368697665' USING utf8mb4)"))
        XCTAssertTrue(sql.contains("`TABLE_NAME` = 'orders''2026'"))
        XCTAssertTrue(sql.hasSuffix("LIMIT 1"))
        XCTAssertThrowsError(try MySQLTableMetadata.summariesSQL(in: "bad\0schema"))
        XCTAssertThrowsError(try MySQLTableMetadata.commentSQL(for: DatabaseTable(schema: "sales", name: "bad\0name")))
    }

    func testOptionalCommentReadPreservesFullDescriptionAndDistinguishesSQLNull() async throws {
        let table = DatabaseTable(schema: "sales", name: "orders")
        let description = "订单业务说明\n" + String(repeating: "包含已付款订单和退款规则。", count: 80)
        let comment = try await MySQLTableMetadata.readComment(for: table) { _ in
            QueryResult(columns: ["TABLE_COMMENT"], rows: [[description]], elapsed: .zero, message: "")
        }
        XCTAssertEqual(comment, description)
        let missing = try await MySQLTableMetadata.readComment(for: table) { _ in
            QueryResult(columns: ["TABLE_COMMENT"], rows: [["NULL"]], elapsed: .zero, message: "", nullCells: [CellAddress(row: 0, column: 0)])
        }
        XCTAssertEqual(missing, "")
        let literal = try await MySQLTableMetadata.readComment(for: table) { _ in
            QueryResult(columns: ["TABLE_COMMENT"], rows: [["NULL"]], elapsed: .zero, message: "")
        }
        XCTAssertEqual(literal, "NULL")
    }

    func testOptionalCommentPermissionFailureDoesNotDiscardExistingColumns() async throws {
        let table = DatabaseTable(schema: "sales", name: "orders")
        let column = TableColumn(name: "status", dataType: "INT", isNullable: false, isPrimaryKey: false,
                                 defaultValue: "0", extra: "", comment: "0=未付款，1=已付款，2=已退款")
        let comment = try await MySQLTableMetadata.readComment(for: table) { _ in throw UpdateFailure("Metadata access denied") }
        let structure = TableStructure(columns: [column], comment: comment)
        XCTAssertEqual(structure.comment, "")
        XCTAssertEqual(structure.columns.first?.comment, column.comment)
    }

    func testOptionalCommentDoesNotSwallowCancellationOrSessionLoss() async {
        let table = DatabaseTable(schema: "sales", name: "orders")
        do {
            _ = try await MySQLTableMetadata.readComment(for: table) { _ in throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await MySQLTableMetadata.readComment(for: table) { _ in throw DatabaseSessionLost() }
            XCTFail("Session loss must propagate")
        } catch { XCTAssertTrue(error is DatabaseSessionLost) }
    }

    func testDriverDefaultSummariesKeepTableIdentityWithoutReadingRows() async throws {
        let session = DefaultTableSummarySession()
        let summaries = try await session.tableSummaries(in: "sales")
        XCTAssertEqual(summaries.map(\.table), [DatabaseTable(schema: "sales", name: "orders"), DatabaseTable(schema: "sales", name: "客户")])
        XCTAssertTrue(summaries.allSatisfy { $0.comment.isEmpty })
        let queries = await session.queryCount
        XCTAssertEqual(queries, 0)
    }
}

private actor DefaultTableSummarySession: DatabaseSession {
    private(set) var queryCount = 0
    func query(_ sql: String) -> QueryResult { queryCount += 1; return .empty }
    func schemas() -> [String] { ["sales"] }
    func tables(in schema: String) -> [String] { ["orders", "客户"] }
    func columns(in table: DatabaseTable) -> [TableColumn] { [] }
    func close() {}
}
