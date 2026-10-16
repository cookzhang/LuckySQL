import XCTest
@testable import LuckySQL

final class AITableContextMatcherTests: XCTestCase {
    func testBareTableReplySelectsRealCatalogEntry() {
        let catalog = [summary("orders", comment: "订单主表"), summary("users", comment: "用户信息")]
        XCTAssertEqual(match(catalog, "orders"), [table("orders")])
        XCTAssertEqual(match(catalog, "订单表是 ORDERS"), [table("orders")])
        XCTAssertEqual(match(catalog, "查users表"), [table("users")])
        XCTAssertTrue(match(catalog, "invented_orders").isEmpty)
    }

    func testIdentifierBoundariesDoNotMatchSimilarNames() {
        let catalog = [summary("user"), summary("users"), summary("superusers"), summary("user_archive")]
        XCTAssertEqual(match(catalog, "users"), [table("users")])
        XCTAssertEqual(match(catalog, "user_archive"), [table("user_archive")])
        XCTAssertTrue(match(catalog, "endusers").isEmpty)
    }

    func testQualifiedAndQuotedNamesUseTheirRealSchemaAndSpelling() {
        let catalog = [summary("Orders", schema: "shop"), summary("Orders", schema: "archive"), summary("order logs", schema: "shop")]
        for prompt in ["SHOP.ORDERS", "`shop`.`orders`", "\"shop\" . \"orders\""] {
            XCTAssertEqual(match(catalog, prompt), [table("Orders", schema: "shop")])
        }
        XCTAssertEqual(match(catalog, "'shop'.'order logs'"), [table("order logs", schema: "shop")])
        XCTAssertEqual(match(catalog, "archive.orders"), [table("Orders", schema: "archive")])
    }

    func testQuotedIdentifierDoesNotExposeItsIndividualWords() {
        let catalog = [summary("user"), summary("user logs"), summary("order`archive")]
        XCTAssertEqual(match(catalog, "`user logs`"), [table("user logs")])
        XCTAssertEqual(match(catalog, "`order``archive`"), [table("order`archive")])
    }

    func testChineseCommentSemanticsFindMeaningfulTablesWithoutGenericMatches() {
        let catalog = [summary("t_101", comment: "订单主表，保存买家订单"),
                       summary("t_102", comment: "用户信息，保存用户资料"),
                       summary("t_103", comment: "数据统计查询记录表")]
        XCTAssertEqual(match(catalog, "统计每天订单数量"), [table("t_101")])
        XCTAssertEqual(match(catalog, "查询用户资料"), [table("t_102")])
        XCTAssertTrue(match(catalog, "查询表数据统计").isEmpty)
    }

    func testExplicitNameRanksBeforeCommentAndLimitIsStable() {
        let catalog = [summary("t_101", comment: "订单列表"), summary("orders", comment: "订单列表"), summary("t_102", comment: "订单列表")]
        XCTAssertEqual(match(catalog, "订单表 orders", limit: 1), [table("orders")])
        XCTAssertEqual(match(catalog, "订单表", limit: 2), [table("t_101"), table("orders")])
    }

    func testEmptyNegativeLimitDuplicatesAndRequestedLimitAreBounded() {
        let catalog = (0..<20).map { summary("orders_\($0)", comment: "订单记录") }
        XCTAssertTrue(match(catalog, "  \n").isEmpty)
        XCTAssertTrue(match(catalog, "订单", limit: 0).isEmpty)
        XCTAssertTrue(match(catalog, "订单", limit: -1).isEmpty)
        XCTAssertEqual(match(catalog, "订单", limit: 3).count, 3)
        XCTAssertEqual(match(catalog, "订单").count, 12)
        XCTAssertEqual(match([catalog[0], catalog[0]], "orders_0"), [catalog[0].table])
    }

    func testPromptAfterSixteenKiBIsNotUsedAndUnicodePrefixIsSafe() {
        let catalog = [summary("orders")]
        XCTAssertTrue(match(catalog, String(repeating: " ", count: 16 * 1024) + "orders").isEmpty)
        XCTAssertTrue(match(catalog, String(repeating: "🙂", count: 4095) + "界orders").isEmpty)
    }

    func testKnownChineseTableNamesCanAppearInsideChineseRequests() {
        let catalog = [summary("订单"), summary("用户")]
        XCTAssertEqual(match(catalog, "请查订单表"), [table("订单")])
    }

    private func summary(_ name: String, schema: String = "shop", comment: String = "") -> DatabaseTableSummary {
        DatabaseTableSummary(table: table(name, schema: schema), comment: comment)
    }
    private func table(_ name: String, schema: String = "shop") -> DatabaseTable { DatabaseTable(schema: schema, name: name) }
    private func match(_ catalog: [DatabaseTableSummary], _ prompt: String, limit: Int = 12) -> [DatabaseTable] {
        AITableContextMatcher.matchingTables(in: catalog, prompt: prompt, limit: limit)
    }
}
