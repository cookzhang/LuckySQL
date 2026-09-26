import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LuckySQL

@MainActor final class QueryTabSwitchingTests: XCTestCase {
    func testWarmTabsReuseGridAndHighlightThroughAnEmptyTab() async throws {
        let suite = "QueryTabs.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: QueryTabPasswords(), workspaceStore: WorkspaceStore(defaults: defaults))
        defer { model.flushWorkspace(); defaults.removePersistentDomain(forName: suite) }
        let firstID = model.activeTabID
        model.sql = String(repeating: "SELECT 1; -- first\n", count: 500)
        model.queryTabs[0].result = result(columns: 40, prefix: "first")
        model.newQuery(sql: "SELECT 'second';")
        let secondID = model.activeTabID
        model.queryTabs[1].result = result(columns: 3, prefix: "second")
        model.newQuery()
        let emptyID = model.activeTabID
        model.selectTab(firstID)
        let host = NSHostingView(rootView: QueryWorkspaceView().environmentObject(model).frame(width: 1100, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle(host)
        let editor = try XCTUnwrap(find(CodeTextView.self, in: host))
        try await waitUntil { editor.analysis?.sql == editor.string }
        let grid = try XCTUnwrap(find(CopyableTableView.self, in: host))
        let coordinator = try XCTUnwrap(grid.delegate as? DataGrid.Coordinator)
        let reloads = coordinator.reloadCount
        grid.tableColumns[0].width = 239
        grid.moveColumn(0, toColumn: 2)
        grid.selectRowIndexes(IndexSet(integer: 400), byExtendingSelection: false)
        grid.scrollRowToVisible(400)
        editor.setSelectedRange(NSRange(location: 7, length: 1))
        let offset = grid.enclosingScrollView?.contentView.bounds.origin
        let colors = editor.colorPassCount
        XCTAssertNotNil(editor.analysis)

        model.selectTab(secondID); try await settle(host)
        let other = try XCTUnwrap(find(CopyableTableView.self, in: host))
        XCTAssertFalse(other === grid)
        XCTAssertEqual(other.numberOfColumns, 3)
        model.selectTab(emptyID); try await settle(host)
        XCTAssertNil(find(CopyableTableView.self, in: host))
        model.selectTab(firstID); try await settle(host)
        XCTAssertTrue(find(CopyableTableView.self, in: host) === grid)
        XCTAssertTrue(find(CodeTextView.self, in: host) === editor)
        XCTAssertEqual(coordinator.reloadCount, reloads, "A warm tab must not reload its result")
        XCTAssertEqual(editor.colorPassCount, colors, "Unchanged SQL must retain its highlight")
        XCTAssertEqual(grid.tableColumns[2].title, "column0")
        XCTAssertEqual(grid.tableColumns[2].width, 239)
        XCTAssertEqual(grid.selectedRowIndexes, IndexSet(integer: 400))
        XCTAssertEqual(grid.enclosingScrollView?.contentView.bounds.origin, offset)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 1))
        editor.insertText("2", replacementRange: editor.selectedRange())
        XCTAssertTrue(model.queryTabs[0].sql.hasPrefix("SELECT 2;"))
        XCTAssertEqual(model.queryTabs[1].sql, "SELECT 'second';")

        // A new result must refresh even when the same tab's native table is reused.
        model.queryTabs[0].result = result(columns: 2, prefix: "new")
        try await settle(host)
        XCTAssertTrue(find(CopyableTableView.self, in: host) === grid)
        XCTAssertEqual(grid.numberOfColumns, 2)
        XCTAssertEqual(coordinator.parent.result.rows[0][0], "new:0:0")
        XCTAssertEqual(coordinator.reloadCount, reloads + 1)
        model.closeTab(firstID); try await settle(host)
        XCTAssertNil(model.editorSessions.views[firstID.uuidString])
        XCTAssertTrue(find(CopyableTableView.self, in: host) === other)
    }

    func testRapidSwitchesPersistLatestDatabaseAndDocumentWithoutCrossTabEdits() async throws {
        let suite = "QueryTabPersistence.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = WorkspaceStore(defaults: defaults)
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: QueryTabPasswords(), workspaceStore: store)
        defer { model.flushWorkspace(); defaults.removePersistentDomain(forName: suite) }
        let firstID = model.activeTabID
        model.selectedDatabase = "first_db"
        model.newQuery(sql: "SELECT 2;")
        let secondID = model.activeTabID
        model.selectedDatabase = "second_db"
        for _ in 0..<10 { model.selectTab(firstID); model.selectTab(secondID) }
        model.updateSQL("SELECT 'late first edit';", in: firstID)
        XCTAssertEqual(model.sql, "SELECT 2;")
        XCTAssertEqual(model.selectedDatabase, "second_db")
        try await Task.sleep(for: .milliseconds(700))
        let saved = store.loadTabs()
        XCTAssertEqual(store.activeIndex(), 1)
        XCTAssertEqual(saved.map(\.database), ["first_db", "second_db"])
        XCTAssertEqual(saved.map(\.sql), ["SELECT 'late first edit';", "SELECT 2;"])
        var updates = 0
        let token = model.objectWillChange.sink { updates += 1 }
        model.selectTab(secondID)
        XCTAssertEqual(updates, 0, "Clicking the selected tab should do no work")
        withExtendedLifetime(token) {}
    }

    func testResultCacheIsBoundedAndReleasesObsoleteResults() async throws {
        let container = QueryGridContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        var results: [UUID: UUID] = [:]
        var weakTables: [WeakTable] = []
        for index in 0..<10 {
            let id = UUID(), snapshot = result(columns: 2, prefix: String(index))
            results[id] = snapshot.id
            container.display(DataGrid(result: snapshot, gridID: id.uuidString), tabID: id, results: results)
            weakTables.append(WeakTable(try XCTUnwrap(find(CopyableTableView.self, in: container))))
        }
        try await Task.sleep(for: .milliseconds(50)) // Let AppKit release autoreleased views.
        XCTAssertEqual(weakTables.filter { $0.table != nil }.count, 8)
        let empty = QueryResult.empty
        container.display(DataGrid(result: empty), tabID: UUID(), results: [:])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(weakTables.allSatisfy { $0.table == nil })
    }

    private func result(columns: Int, prefix: String) -> QueryResult {
        QueryResult(columns: (0..<columns).map { "column\($0)" }, rows: (0..<1000).map { row in (0..<columns).map { "\(prefix):\(row):\($0)" } }, elapsed: .zero, message: "1000 rows")
    }
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for asynchronous editor analysis")
                throw NSError(domain: "QueryTabSwitchingTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded(); host.window?.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded(); host.window?.displayIfNeeded()
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
    private struct WeakTable {
        weak var table: CopyableTableView?
        init(_ table: CopyableTableView) { self.table = table }
    }
}
private actor QueryTabPasswords: PasswordStoring {
    func password(for profileID: UUID) -> String? { nil }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
