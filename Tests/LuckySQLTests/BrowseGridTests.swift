import AppKit
import XCTest
@testable import LuckySQL

@MainActor final class BrowseGridTests: XCTestCase {
    func testLoadingStateRetainsNativeColumnsAndReleasesSnapshot() throws {
        let container = BrowseGridContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let gridID = "browse.\(UUID())"
        let first = result(prefix: "first")
        let owner = displayOwnedGrid(in: container, result: first, gridID: gridID)
        let table = try XCTUnwrap(find(CopyableTableView.self, in: container))
        let coordinator = try XCTUnwrap(table.delegate as? DataGrid.Coordinator)
        let firstColumn = table.tableColumns[0]
        firstColumn.width = 237
        table.moveColumn(0, toColumn: 2)
        table.selectRowIndexes(IndexSet(integer: 42), byExtendingSelection: false)
        XCTAssertNotNil(owner.value)

        container.display(DataGrid(result: .empty, gridID: gridID))
        XCTAssertTrue(find(CopyableTableView.self, in: container) === table)
        XCTAssertTrue(table.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(table.enclosingScrollView?.superview === container, "Loading should not migrate the native subtree out of its window")
        XCTAssertTrue(coordinator.parent.result.rows.isEmpty)
        XCTAssertTrue(coordinator.parent.result.columns.isEmpty)
        XCTAssertEqual(coordinator.parent.gridID, "")
        XCTAssertNil(coordinator.parent.inspect)
        XCTAssertNil(owner.value, "An empty browse must release outgoing callbacks and their snapshot")
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertEqual(table.numberOfColumns, 3)
        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
        let suspendedReloads = coordinator.reloadCount
        container.display(DataGrid(result: .empty, gridID: gridID))
        XCTAssertEqual(coordinator.reloadCount, suspendedReloads, "Repeated empty updates should do no work")

        let next = result(prefix: "next")
        container.display(DataGrid(result: next, gridID: gridID))
        XCTAssertTrue(find(CopyableTableView.self, in: container) === table)
        XCTAssertFalse(table.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(table.tableColumns[2] === firstColumn)
        XCTAssertEqual(firstColumn.width, 237)
        XCTAssertEqual(table.numberOfRows, 100)
        XCTAssertEqual(coordinator.parent.result.rows[0][0], "next:0:0")
        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
        let resumedReloads = coordinator.reloadCount
        container.display(DataGrid(result: next, gridID: gridID))
        XCTAssertEqual(coordinator.reloadCount, resumedReloads, "An unchanged snapshot should not reload")
    }

    func testChangingTablesReusesGridAndUpdatesColumnsAndAutosaveIdentity() throws {
        let container = BrowseGridContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let firstID = "first.\(UUID())", secondID = "second.\(UUID())"
        container.display(DataGrid(result: result(prefix: "first"), gridID: firstID))
        let table = try XCTUnwrap(find(CopyableTableView.self, in: container))
        let coordinator = try XCTUnwrap(table.delegate as? DataGrid.Coordinator)
        table.selectRowIndexes(IndexSet(integer: 42), byExtendingSelection: false)
        let next = QueryResult(columns: ["id", "name"], rows: [["1", "new table"]], elapsed: .zero, message: "")
        container.display(DataGrid(result: next, gridID: secondID))
        XCTAssertTrue(find(CopyableTableView.self, in: container) === table)
        XCTAssertEqual(table.tableColumns.map(\.title), ["id", "name"])
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
        XCTAssertEqual(table.autosaveName, "LuckySQL.grid.\(secondID)")
        XCTAssertTrue(table.autosaveTableColumns)
        XCTAssertEqual(coordinator.parent.gridID, secondID)
        XCTAssertEqual(coordinator.parent.result.rows, next.rows)
    }

    func testRenamedColumnsReuseNativeObjectsAndRestoreSourceOrder() throws {
        let container = BrowseGridContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        container.display(DataGrid(result: result(prefix: "first"), gridID: UUID().uuidString))
        let table = try XCTUnwrap(find(CopyableTableView.self, in: container))
        let coordinator = try XCTUnwrap(table.delegate as? DataGrid.Coordinator)
        let original = table.tableColumns
        original[0].width = 237
        table.moveColumn(2, toColumn: 0)
        container.display(DataGrid(result: .empty))

        var sortedColumn: String?
        let second = QueryResult(columns: ["order_id", "customer"], rows: [["42", "Alice"]], elapsed: .zero, message: "")
        container.display(DataGrid(result: second, gridID: UUID().uuidString, sort: { sortedColumn = $0 }))
        XCTAssertEqual(table.tableColumns.map(\.identifier.rawValue), ["0", "1"])
        XCTAssertEqual(table.tableColumns.map(\.title), second.columns)
        XCTAssertTrue(table.tableColumns[0] === original[0])
        XCTAssertTrue(table.tableColumns[1] === original[1])
        XCTAssertFalse(table.tableColumns.contains { $0 === original[2] })
        XCTAssertNotEqual(table.tableColumns[0].width, 237, "A different column resets its default width before autosave restoration")
        for (index, value) in second.rows[0].enumerated() {
            let cell = try XCTUnwrap(coordinator.tableView(table, viewFor: table.tableColumns[index], row: 0) as? NSTableCellView)
            XCTAssertEqual(cell.textField?.stringValue, value)
        }
        coordinator.tableView(table, didClick: table.tableColumns[1])
        XCTAssertEqual(sortedColumn, "customer")

        let third = QueryResult(columns: ["id", "name", "value", "extra"], rows: [["1", "Bob", "data", "new"]], elapsed: .zero, message: "")
        container.display(DataGrid(result: third, gridID: UUID().uuidString))
        XCTAssertEqual(table.tableColumns.map(\.identifier.rawValue), ["0", "1", "2", "3"])
        XCTAssertEqual(table.tableColumns.map(\.title), third.columns)
        XCTAssertTrue(table.tableColumns[0] === original[0])
        XCTAssertTrue(table.tableColumns[1] === original[1])
        XCTAssertEqual(table.numberOfRows, 1)
    }

    private func result(prefix: String) -> QueryResult {
        QueryResult(columns: ["id", "name", "value"], rows: (0..<100).map { row in
            (0..<3).map { "\(prefix):\(row):\($0)" }
        }, elapsed: .zero, message: "")
    }
    private func displayOwnedGrid(in container: BrowseGridContainer, result: QueryResult, gridID: String) -> WeakOwner {
        let owner = CallbackOwner()
        container.display(DataGrid(result: result, gridID: gridID, inspect: { [owner] _, _ in
            withExtendedLifetime(owner) {}
        }))
        return WeakOwner(value: owner)
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
    private final class CallbackOwner {}
    private struct WeakOwner { weak var value: CallbackOwner? }
}
