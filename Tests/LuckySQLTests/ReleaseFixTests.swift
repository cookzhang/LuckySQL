import Foundation
import Security
import XCTest
@testable import LuckySQL

final class ReleaseFixTests: XCTestCase {
    func testLargeCellPagesPreserveEveryScalar() {
        let value = String(repeating: "a", count: 8191) + "😀" + String(repeating: "中文é😀", count: 5000)
        let pages = (0..<CellValuePage.count(value)).map { CellValuePage.text(value, page: $0) }
        XCTAssertEqual(pages.joined(), value)
        XCTAssertTrue(pages.allSatisfy { ($0 as NSString).length <= CellValuePage.size + 1 })
        XCTAssertEqual(CellValuePage.text("", page: 0), "")
    }

    func testRecoveryPersistsIdentifierOnlyAndSurvivesStoreRecreation() async throws {
        let name = "Recovery.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let id = UUID(), backend = RotatingPasswords()
        await backend.deny(id)
        let store = RecoveringPasswordStore(store: backend, defaults: defaults)
        try await store.save("secret-unique", for: id)
        let reloaded = RecoveringPasswordStore(store: backend, defaults: defaults)
        let password = try await reloaded.password(for: id)
        XCTAssertEqual(password, "secret-unique")
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: name)).contains("secret-unique"))
        try await reloaded.deletePassword(for: id)
        XCTAssertNil(defaults.string(forKey: "passwordRecord.\(id.uuidString)"))
    }
    func testFailedRecoveryDoesNotPublishRecord() async throws {
        let name = "Recovery.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let id = UUID(), backend = RotatingPasswords()
        await backend.denyAll()
        do { try await RecoveringPasswordStore(store: backend, defaults: defaults).save("secret", for: id); XCTFail("Expected failure") }
        catch { XCTAssertNil(defaults.string(forKey: "passwordRecord.\(id.uuidString)")) }
    }
    func testChecksumRejectsWrongFilenameAndMalformedDigest() throws {
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(try UpdateService.parseChecksum(Data("\(digest)  app.zip\n".utf8), filename: "app.zip"), digest)
        for source in ["\(digest) wrong.zip", "123 app.zip", "\(digest) app.zip extra", "\(String(repeating: "z", count: 64)) app.zip"] {
            XCTAssertThrowsError(try UpdateService.parseChecksum(Data(source.utf8), filename: "app.zip"))
        }
    }

    @MainActor func testWritesInvalidateBrowseSnapshotAndRefreshOnReturn() async throws {
        for verb in ["UPDATE t SET value = 'new'", "INSERT INTO t VALUES (2, 'new')", "DELETE FROM t WHERE id = 1"] {
            let (model, session, defaults, name) = try fixture()
            defer { defaults.removePersistentDomain(forName: name); model.disconnect() }
            model.connect(); try await settle(model)
            model.browse(DatabaseTable(schema: "test", name: "t")); try await settle(model)
            XCTAssertEqual(model.browseResult.rows[0][1], "old")
            model.newQuery(sql: verb); model.runCurrentQuery(); model.confirmExecution(); try await settle(model)
            XCTAssertTrue(model.browseIsStale)
            model.changeSection(.data); try await settle(model)
            XCTAssertEqual(model.browseResult.rows[0][1], "new")
            XCTAssertFalse(model.browseIsStale)
            let writes = await session.writes; XCTAssertEqual(writes, 1)
        }
    }
    @MainActor func testBrowseCancellationRetainsConnectionAndSnapshot() async throws {
        let (model, session, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); model.disconnect() }
        model.connect(); try await settle(model)
        model.browse(DatabaseTable(schema: "test", name: "t")); try await settle(model)
        let result = model.browseResult.id
        await session.setSlow(true)
        model.refreshData(); try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.canCancelOperation)
        model.cancelCurrentQuery(); try await settle(model)
        XCTAssertTrue(model.isConnected); XCTAssertEqual(model.browseResult.id, result)
        XCTAssertNotNil(model.browseError)
        let cancelled = await session.cancellations; XCTAssertEqual(cancelled, 1)
    }
    @MainActor func testFailedPageKeepsDisplayedPageAndOptions() async throws {
        let (model, session, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); model.disconnect() }
        model.connect(); try await settle(model)
        model.browse(DatabaseTable(schema: "test", name: "t")); try await settle(model)
        let result = model.browseResult.id
        await session.setFail(true)
        model.hasNextPage = true; model.nextPage(1); try await settle(model)
        XCTAssertEqual(model.appliedBrowseOptions.page, 0)
        XCTAssertEqual(model.browseOptions.page, 0)
        XCTAssertEqual(model.browseResult.id, result)
        XCTAssertNotNil(model.browseError)
    }
    @MainActor func testGridConflictAndUnchangedValueNeverSilentlyOverwrite() async throws {
        let (model, session, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); model.disconnect() }
        model.connect(); try await settle(model)
        model.browse(DatabaseTable(schema: "test", name: "t")); try await settle(model)
        model.updateCell(row: 0, column: 1, value: "old"); try await settle(model)
        var writes = await session.writes; XCTAssertEqual(writes, 0)
        await session.setConflict()
        model.updateCell(row: 0, column: 1, value: "mine"); try await settle(model)
        writes = await session.writes; XCTAssertEqual(writes, 1)
        XCTAssertFalse(model.mutationSucceeded); XCTAssertTrue(model.browseIsStale)
        let sql = await session.lastWrite; XCTAssertTrue(sql.contains("BINARY `value` <=> BINARY 'old'"))
    }
    @MainActor func testUnknownWriteOutcomeStillBlocksManualReplay() async throws {
        let (model, session, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); model.disconnect() }
        model.connect(); try await settle(model)
        model.browse(DatabaseTable(schema: "test", name: "t")); try await settle(model)
        await session.setFail(true)
        model.updateCell(row: 0, column: 1, value: "new"); try await settle(model)
        XCTAssertFalse(model.mutationSucceeded)
        XCTAssertTrue(model.browseIsStale)
        XCTAssertFalse(model.canEditColumn(1))
        XCTAssertTrue(model.mutationNotice?.contains("outcome is unknown") == true)
    }
    @MainActor func testCanonicalUnicodeDifferenceIsStillARealEdit() async throws {
        let (model, _, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); model.disconnect() }
        model.connect(); try await settle(model)
        model.browse(DatabaseTable(schema: "test", name: "t")); try await settle(model)
        var rows = model.browseResult.rows; rows[0][1] = "é"
        model.browseResult = QueryResult(columns: model.browseResult.columns, rows: rows, elapsed: .zero, message: "Unicode fixture")
        try model.stageCell(row: 0, column: 1, value: SQLParameter(kind: .text, value: "e\u{301}"))
        XCTAssertEqual(model.gridChanges.count, 1)
    }
    @MainActor func testStagedRevertAndDisconnectRetainBoundDrafts() async throws {
        let (model, _, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); model.disconnect() }
        model.connect(); try await settle(model)
        model.browse(DatabaseTable(schema: "test", name: "t")); try await settle(model)
        try model.stageCell(row: 0, column: 1, value: SQLParameter(kind: .text, value: "pending"))
        XCTAssertEqual(model.gridChanges.count, 1)
        try model.stageCell(row: 0, column: 1, value: SQLParameter(kind: .text, value: "old"))
        XCTAssertTrue(model.gridChanges.isEmpty)
        try model.stageCell(row: 0, column: 1, value: SQLParameter(kind: .text, value: "pending"))
        model.disconnect()
        XCTAssertEqual(model.gridChanges.count, 1)
        XCTAssertFalse(model.canCommitGridChanges)
        model.connect(); try await settle(model)
        XCTAssertTrue(model.canCommitGridChanges)
    }

    @MainActor func testIndependentModelsDoNotShareBusyStateOrCancellation() async throws {
        let (a, sessionA, defaultsA, nameA) = try fixture()
        let (b, sessionB, defaultsB, nameB) = try fixture()
        defer { defaultsA.removePersistentDomain(forName: nameA); defaultsB.removePersistentDomain(forName: nameB); a.disconnect(); b.disconnect() }
        a.connect(); b.connect(); try await settle(a); try await settle(b)
        await sessionA.setSlow(true)
        a.newQuery(sql: "SELECT 1"); a.runCurrentQuery()
        b.browse(DatabaseTable(schema: "test", name: "t")); try await settle(b)
        XCTAssertTrue(a.isRunning); XCTAssertFalse(b.isRunning); XCTAssertEqual(b.browseResult.rows.count, 1)
        a.cancelCurrentQuery(); try await settle(a)
        let bCancelled = await sessionB.cancellations; XCTAssertEqual(bCancelled, 0)
        XCTAssertTrue(b.isConnected)
    }
    @MainActor func testWorkspaceRegistryRestoresEveryDraftAndSelection() throws {
        let name = "Registry.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let make: @MainActor (WorkspaceStore) -> AppModel = { store in
            AppModel(profileStore: ProfileStore(defaults: defaults), keychain: RotatingPasswords(), driver: FixDriver(session: FixSession()), workspaceStore: store)
        }
        let first = ConnectionWorkspaces(defaults: defaults, makeModel: make)
        first.active.newQuery(sql: "SELECT 'first'")
        first.newWorkspace(); first.active.newQuery(sql: "SELECT 'second'"); first.flush()
        let restored = ConnectionWorkspaces(defaults: defaults, makeModel: make)
        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertEqual(restored.active.sql, "SELECT 'second'")
        XCTAssertTrue(restored.entries[0].model.queryTabs.contains { $0.sql == "SELECT 'first'" })
        restored.entries[0].model.isRunning = true; XCTAssertTrue(restored.isBusy)
        restored.entries[0].model.isRunning = false
    }

    @MainActor func testConnectionDraftNamespacesAreIndependent() throws {
        let name = "Workspace.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let a = WorkspaceStore(defaults: defaults, namespace: "a"), b = WorkspaceStore(defaults: defaults, namespace: "b")
        a.saveTabs([QueryTab(title: "A", sql: "SELECT 1", database: "a")])
        b.saveTabs([QueryTab(title: "B", sql: "SELECT 2", database: "b")]); a.flush(); b.flush()
        XCTAssertEqual(WorkspaceStore(defaults: defaults, namespace: "a").loadTabs().first?.sql, "SELECT 1")
        XCTAssertEqual(WorkspaceStore(defaults: defaults, namespace: "b").loadTabs().first?.sql, "SELECT 2")
    }
    @MainActor func testLargeFieldsUseSummariesAndCannotBeWrittenBack() async throws {
        let (model, session, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); model.disconnect() }
        await session.setLargeColumn()
        model.connect(); try await settle(model)
        model.browse(DatabaseTable(schema: "test", name: "t")); try await settle(model)
        let sql = await session.lastRead
        XCTAssertTrue(sql.contains("LEFT(`value`, 256) AS `value`"))
        XCTAssertEqual(model.browseResult.deferredColumns, ["value"])
        XCTAssertFalse(model.canEditColumn(1))
        let full = try await model.loadFullValue(row: 0, column: 1)
        XCTAssertFalse(full.isTruncated)
        let fullSQL = await session.lastRead
        XCTAssertTrue(fullSQL.contains("SELECT `value` FROM `test`.`t` WHERE BINARY `id` <=> BINARY '1' LIMIT 2"))
    }

    @MainActor private func fixture() throws -> (AppModel, FixSession, UserDefaults, String) {
        let name = "Fixes.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name)), session = FixSession()
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: RotatingPasswords(), driver: FixDriver(session: session), workspaceStore: WorkspaceStore(defaults: defaults))
        return (model, session, defaults, name)
    }
    @MainActor private func settle(_ model: AppModel) async throws {
        for _ in 0..<300 { if !model.isRunning { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Operation did not settle")
    }
}
private actor RotatingPasswords: PasswordStoring {
    var denied: Set<UUID> = [], allDenied = false
    var values: [UUID: String] = [:]
    func deny(_ id: UUID) { denied.insert(id) }
    func denyAll() { allDenied = true }
    func save(_ password: String, for id: UUID) throws {
        if allDenied { throw KeychainError(errSecInteractionNotAllowed) }
        values[id] = password
    }
    func password(for id: UUID) throws -> String? {
        if denied.contains(id) || allDenied { throw KeychainError(errSecAuthFailed) }
        return values[id]
    }
    func deletePassword(for id: UUID) { values.removeValue(forKey: id) }
}
private struct FixDriver: DatabaseDriver {
    let session: FixSession
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { session }
}
private actor FixSession: DatabaseSession {
    var value = "old", writes = 0, cancellations = 0, slow = false, fail = false, conflict = false, lastWrite = "", lastRead = "", largeColumn = false
    func setSlow(_ value: Bool) { slow = value }
    func setFail(_ value: Bool) { fail = value }
    func setLargeColumn() { largeColumn = true }
    func setConflict() { conflict = true }
    func query(_ sql: String) async throws -> QueryResult {
        if sql.hasPrefix("USE ") { return .empty }
        if slow {
            while cancellations == 0 { try await Task.sleep(for: .milliseconds(5)) }
            slow = false; throw CancellationError()
        }
        if fail { throw UpdateFailure("Test network failure") }
        if ["UPDATE", "INSERT", "DELETE"].contains(where: { sql.hasPrefix($0) }) {
            writes += 1; lastWrite = sql; value = "new"
            return QueryResult(columns: [], rows: [], elapsed: .zero, message: "", affectedRows: conflict ? 0 : 1)
        }
        lastRead = sql
        return QueryResult(columns: ["id", "value"], rows: [["1", value]], elapsed: .zero, message: "")
    }
    func schemas() -> [String] { ["test"] }
    func tables(in schema: String) -> [String] { ["t"] }
    func columns(in table: DatabaseTable) -> [TableColumn] {
        [TableColumn(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true, defaultValue: nil, extra: ""),
         TableColumn(name: "value", dataType: largeColumn ? "longtext" : "varchar(50)", isNullable: true, isPrimaryKey: false, defaultValue: nil, extra: "")]
    }
    func close() {}
    func cancelQuery() { cancellations += 1 }
}
