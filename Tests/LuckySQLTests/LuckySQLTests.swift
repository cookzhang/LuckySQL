import Foundation
import XCTest
@testable import LuckySQL

@MainActor
final class LuckySQLTests: XCTestCase {
    func testIdentifierQuoting() throws {
        XCTAssertEqual(try SQLIdentifier.quote("orders"), "`orders`")
        XCTAssertEqual(try SQLIdentifier.quote("odd`name"), "`odd``name`")
        XCTAssertThrowsError(try SQLIdentifier.quote(""))
    }

    func testStringLiteralQuoting() throws {
        XCTAssertEqual(try SQLStringLiteral.quote("sales"), "'sales'")
        XCTAssertEqual(try SQLStringLiteral.quote("team's data"), "'team''s data'")
        XCTAssertThrowsError(try SQLStringLiteral.quote("bad\0name"))
    }

    func testSmartQuotesAreNormalized() {
        XCTAssertEqual(SQLInputNormalizer.normalize("WHERE name=‘Lucky’ AND title=“SQL”"), "WHERE name='Lucky' AND title=\"SQL\"")
    }

    func testConnectionLoadsSchemasAndTables() async throws {
        let suiteName = "LuckySQLTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = StubSession()
        let model = AppModel(
            profileStore: ProfileStore(defaults: defaults),
            keychain: StubPasswordStore(),
            driver: StubDriver(session: session), workspaceStore: WorkspaceStore(defaults: defaults)
        )

        model.connect()
        try await waitUntil { model.schemaLoadState == .loaded }

        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.schemas.map(\.name), ["information_schema", "shop"])

        await model.loadTables(in: "shop")

        XCTAssertEqual(model.schemas.first(where: { $0.name == "shop" })?.tables.map(\.name), ["customers", "orders"])
        XCTAssertEqual(model.schemas.first(where: { $0.name == "shop" })?.tableLoadState, .loaded)
        model.disconnect()
    }

    func testBrowseResultCanUpdateByPrimaryKey() async throws {
        let suiteName = "LuckySQLTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = StubSession()
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: StubPasswordStore(), driver: StubDriver(session: session), workspaceStore: WorkspaceStore(defaults: defaults))
        model.connect()
        try await waitUntil { model.schemaLoadState == .loaded }
        let table = DatabaseTable(schema: "shop", name: "orders")
        model.browse(table)
        try await waitUntil { model.canMutateSelectedTable && model.result.rows.count == 1 }

        model.updateCell(row: 0, column: 1, value: "paid")
        try await waitUntil { await session.queries().contains(where: { $0.hasPrefix("UPDATE ") }) }
        let recordedQueries = await session.queries()
        let update = try XCTUnwrap(recordedQueries.first(where: { $0.hasPrefix("UPDATE ") }))
        XCTAssertEqual(update, "UPDATE `shop`.`orders` SET `status` = 'paid' WHERE `id` = '7' LIMIT 1;")
        model.disconnect()
    }

    func testBrowsePreservesDraftAndEditsRefreshBrowseSQL() async throws {
        let name = "LuckySQLTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = StubSession()
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: StubPasswordStore(), driver: StubDriver(session: session), workspaceStore: WorkspaceStore(defaults: defaults))
        model.connect(); try await waitUntil { model.isConnected && !model.isRunning }
        model.sql = "SELECT 'keep my draft';"
        model.browse(DatabaseTable(schema: "shop", name: "orders"))
        try await waitUntil { !model.isRunning && model.canMutateSelectedTable }
        XCTAssertEqual(model.sql, "SELECT 'keep my draft';")
        model.updateCell(row: 0, column: 1, value: "NULL")
        try await waitUntil { !model.isRunning }
        let queries = await session.queries()
        XCTAssertTrue(queries.contains("UPDATE `shop`.`orders` SET `status` = 'NULL' WHERE `id` = '7' LIMIT 1;"))
        XCTAssertTrue(queries.last?.hasPrefix("SELECT * FROM `shop`.`orders`") == true)
        model.disconnect()
    }

    func testTabsAndConfirmationKeepResultsSeparate() async throws {
        let name = "LuckySQLTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = StubSession()
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: StubPasswordStore(), driver: StubDriver(session: session), workspaceStore: WorkspaceStore(defaults: defaults))
        model.connect(); try await waitUntil { model.isConnected && !model.isRunning }
        let first = model.activeTabID
        model.sql = "SELECT 1; SELECT 2;"; model.runCurrentQuery(all: true)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.queryTabs[model.activeTabIndex].results.count, 2)
        model.newQuery(sql: "DELETE FROM orders;", title: "Write")
        XCTAssertTrue(model.result.rows.isEmpty)
        model.runCurrentQuery()
        XCTAssertNotNil(model.pendingSQL)
        var queries = await session.queries()
        XCTAssertFalse(queries.contains("DELETE FROM orders;"))
        model.cancelExecution()
        model.runCurrentQuery(); model.confirmExecution()
        try await waitUntil { !model.isRunning }
        queries = await session.queries()
        XCTAssertTrue(queries.contains("DELETE FROM orders;"))
        model.selectTab(first)
        XCTAssertEqual(model.sql, "SELECT 1; SELECT 2;")
        XCTAssertEqual(model.result.rows.count, 1)
        XCTAssertEqual(model.history.count, 3)
        model.disconnect()
    }

    func testPendingPasswordDoesNotBlockModelAndDisconnectCancelsConnect() async throws {
        let name = "LuckySQLTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let session = StubSession()
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: SlowPasswordStore(), driver: StubDriver(session: session), workspaceStore: WorkspaceStore(defaults: defaults))
        XCTAssertTrue(model.isLoadingPassword)
        model.connect(); model.disconnect()
        try await waitUntil { !model.isLoadingPassword }
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.isConnected)
    }

    func testFailedConnectionDoesNotOverwriteSavedPassword() async throws {
        let name = "LuckySQLTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SlowPasswordStore()
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: store, driver: FailingDriver(), workspaceStore: WorkspaceStore(defaults: defaults))
        model.connect(); try await waitUntil { !model.isRunning }
        XCTAssertNotNil(model.errorMessage)
        let writes = await store.writes
        XCTAssertEqual(writes, 0)
        model.disconnect()
    }

    func testCompletionLoadsReferencedTableWithoutBrowsing() async throws {
        let name = "LuckySQLTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: StubPasswordStore(), driver: StubDriver(session: StubSession()), workspaceStore: WorkspaceStore(defaults: defaults))
        model.connect(); try await waitUntil { model.isConnected && !model.isRunning }
        model.sql = "SELECT o. FROM orders o"
        await model.loadCompletionMetadata()
        XCTAssertNil(model.selectedTable)
        XCTAssertEqual(model.tableColumns["shop.orders"]?.map(\.name), ["id", "status"])
        let caret = (model.sql as NSString).range(of: "o.").location + 2
        XCTAssertEqual(SQLCompletion.request(sql: model.sql, caret: caret, catalog: model.completionCatalog, automatic: true)?.candidates, ["`status`", "id"])
        model.disconnect()
    }

    func testMetadataCacheCoalescesRequestsAndExplicitRefreshInvalidates() async throws {
        let name = "LuckySQLTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = WorkspaceStore(defaults: defaults)
        defer { store.flush(); defaults.removePersistentDomain(forName: name) }
        let session = StubSession()
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: StubPasswordStore(), driver: StubDriver(session: session), workspaceStore: store)
        model.connect(); try await waitUntil { model.isConnected && !model.isRunning }
        let table = DatabaseTable(schema: "shop", name: "orders")
        async let a: Void = model.loadColumns(in: table)
        async let b: Void = model.loadColumns(in: table)
        _ = await (a, b)
        var calls = await session.columnCalls
        XCTAssertEqual(calls, 1)
        model.browse(table); try await waitUntil { !model.isRunning }
        model.refreshData(); try await waitUntil { !model.isRunning }
        calls = await session.columnCalls; XCTAssertEqual(calls, 1)
        model.refreshData(forceMetadata: true); try await waitUntil { !model.isRunning }
        calls = await session.columnCalls; XCTAssertEqual(calls, 2)
        model.showStructure(); try await waitUntil { !model.isRunning }
        let count = await session.columnCalls
        model.changeSection(.query); model.showStructure()
        calls = await session.columnCalls; XCTAssertEqual(calls, count)
        model.disconnect()
    }

    func testReadOnlyBlocksWritesAndGridMutation() async throws {
        let name = "LuckySQLTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = WorkspaceStore(defaults: defaults)
        defer { store.flush(); defaults.removePersistentDomain(forName: name) }
        let session = StubSession()
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: StubPasswordStore(), driver: StubDriver(session: session), workspaceStore: store)
        model.profiles[0].readOnly = true
        model.connect(); try await waitUntil { model.isConnected && !model.isRunning }
        model.sql = "DELETE FROM orders;"; model.runCurrentQuery()
        XCTAssertNotNil(model.errorMessage); XCTAssertNil(model.pendingSQL)
        model.browse(DatabaseTable(schema: "shop", name: "orders")); try await waitUntil { !model.isRunning }
        XCTAssertFalse(model.canMutateSelectedTable)
        model.updateCell(row: 0, column: 1, value: "bad"); model.deleteRow(0)
        let queries = await session.queries()
        XCTAssertFalse(queries.contains(where: { $0.hasPrefix("DELETE") || $0.hasPrefix("UPDATE") }))
        XCTAssertFalse(model.connectionLabel.contains("Production")); XCTAssertTrue(model.connectionLabel.contains("READ ONLY"))
        XCTAssertTrue(model.connectionLabel.contains("127.0.0.1:3306"))
        model.disconnect()
    }

    func testWorkspacePreviewBudgetReleasesOldResultsNotDrafts() throws {
        let name = "LuckySQLTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = WorkspaceStore(defaults: defaults)
        defer { store.flush(); defaults.removePersistentDomain(forName: name) }
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: StubPasswordStore(), driver: StubDriver(session: StubSession()), workspaceStore: store)
        for index in 0..<6 {
            model.newQuery(sql: "SELECT \(index)")
            let result = QueryResult(columns: ["value"], rows: [["test"]], elapsed: .zero, message: "", retainedBytes: 16 * 1024 * 1024)
            model.queryTabs[model.activeTabIndex].result = result
            model.queryTabs[model.activeTabIndex].results = [result]
        }
        let current = model.result.id, drafts = model.queryTabs.map(\.sql)
        model.trimResultMemory(preserving: current)
        XCTAssertEqual(model.result.id, current)
        XCTAssertEqual(model.queryTabs.map(\.sql), drafts)
        XCTAssertLessThanOrEqual(model.queryTabs.reduce(0) { $0 + $1.results.reduce(0) { $0 + $1.retainedBytes } }, 64 * 1024 * 1024)
        XCTAssertNotNil(model.resultBudgetNote)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - started > timeoutNanoseconds {
                XCTFail("Timed out waiting for asynchronous state change")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - started > timeoutNanoseconds {
                XCTFail("Timed out waiting for asynchronous state change")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor StubSession: DatabaseSession {
    var columnCalls = 0
    private var recordedQueries: [String] = []
    func query(_ sql: String) async throws -> QueryResult {
        recordedQueries.append(sql)
        if sql.hasPrefix("SELECT") {
            return QueryResult(columns: ["id", "status"], rows: [["7", "new"]], elapsed: .zero, message: "1 row(s)")
        }
        return .empty
    }
    func queries() -> [String] { recordedQueries }
    func schemas() async throws -> [String] { ["information_schema", "shop"] }
    func tables(in schema: String) async throws -> [String] {
        schema == "shop" ? ["customers", "orders"] : []
    }
    func columns(in table: DatabaseTable) async throws -> [TableColumn] {
        columnCalls += 1
        try await Task.sleep(for: .milliseconds(10))
        return [TableColumn(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true, defaultValue: nil, extra: "auto_increment"),
         TableColumn(name: "status", dataType: "varchar(40)", isNullable: true, isPrimaryKey: false, defaultValue: nil, extra: "")]
    }
    func close() async {}
}

private struct StubDriver: DatabaseDriver {
    let session: StubSession

    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession {
        session
    }
}

private actor StubPasswordStore: PasswordStoring {
    private var passwords: [UUID: String] = [:]

    func save(_ password: String, for profileID: UUID) throws { passwords[profileID] = password }
    func password(for profileID: UUID) throws -> String? { passwords[profileID] }
    func deletePassword(for profileID: UUID) throws { passwords[profileID] = nil }
}

private actor SlowPasswordStore: PasswordStoring {
    var writes = 0
    func save(_ password: String, for profileID: UUID) { writes += 1 }
    func password(for profileID: UUID) async throws -> String? { try await Task.sleep(for: .milliseconds(100)); return "test" }
    func deletePassword(for profileID: UUID) {}
}
private struct FailingDriver: DatabaseDriver {
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { throw DatabaseError.notConnected }
}
