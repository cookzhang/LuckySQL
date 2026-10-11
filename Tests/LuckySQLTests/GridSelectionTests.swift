import AppKit
import XCTest
@testable import LuckySQL

@MainActor final class GridSelectionTests: XCTestCase {
    func testContextMenuKeepsMultiSelectionAndRejectsEmptySpace() throws {
        let fixture = try SelectionFixture()
        defer { fixture.window.close() }
        let table = fixture.table
        table.selectRowIndexes(IndexSet([1, 3]), byExtendingSelection: false)
        table.activeRow = 3
        table.activeColumn = 1
        let context = try mouse(.rightMouseDown, row: 6, table: table)
        let menu = try XCTUnwrap(table.menu(for: context))
        fixture.coordinator.menuNeedsUpdate(menu)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([1, 3]))
        XCTAssertEqual(table.activeRow, 3)
        XCTAssertEqual(table.activeColumn, 1)
        XCTAssertEqual(menu.items.map(\.title), ["Copy Selected Rows (TSV)"])
        XCTAssertTrue(fixture.window.firstResponder === table)

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        _ = table.menu(for: context)
        fixture.coordinator.menuNeedsUpdate(menu)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 6))
        XCTAssertEqual(table.activeRow, 6)
        XCTAssertTrue(menu.items.contains { $0.title == "Copy Value" })
        let blank = try mouse(.rightMouseDown, row: 30, table: table)
        XCTAssertNil(table.menu(for: blank))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 6))
    }

    func testKeyboardRangeFocusCopyAndEscape() throws {
        let fixture = try SelectionFixture()
        defer { fixture.window.close() }
        let table = fixture.table
        let reloads = fixture.coordinator.reloadCount
        for _ in 0..<4 { try key(125, "\u{F701}", table: table) }
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 3))
        try key(125, "\u{F701}", table: table, modifiers: .shift)
        try key(125, "\u{F701}", table: table, modifiers: .shift)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integersIn: 3...5))
        XCTAssertEqual(table.activeRow, 5)
        try key(126, "\u{F700}", table: table, modifiers: .shift)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integersIn: 3...4))
        XCTAssertEqual(table.activeRow, 4)

        var cells = 0, rows = 0, previews = 0
        table.copyCell = { cells += 1 }
        table.copyRows = { rows += 1 }
        table.previewCell = { previews += 1 }
        try key(8, "c", table: table, modifiers: .command)
        XCTAssertEqual(rows, 1)
        XCTAssertEqual(cells, 0)
        try key(36, "\r", table: table)
        XCTAssertEqual(previews, 0, "A multi-row selection must not edit an arbitrary row")
        try key(53, "\u{1B}", table: table)
        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
        XCTAssertEqual(table.activeRow, -1)
        try key(125, "\u{F701}", table: table)
        XCTAssertEqual(table.numberOfSelectedRows, 1)
        try key(8, "c", table: table, modifiers: .command)
        try key(8, "c", table: table, modifiers: [.command, .shift])
        try key(76, "\r", table: table)
        XCTAssertEqual(cells, 1)
        XCTAssertEqual(rows, 2)
        XCTAssertEqual(previews, 1)
        XCTAssertEqual(fixture.coordinator.reloadCount, reloads)
        XCTAssertTrue(table.acceptsFirstMouse(for: nil))
    }

    private func mouse(_ type: NSEvent.EventType, row: Int, table: CopyableTableView,
                       modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let point = table.convert(NSPoint(x: 30, y: CGFloat(row) * (table.rowHeight + table.intercellSpacing.height) + 10), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: table.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func key(_ code: UInt16, _ text: String, table: CopyableTableView,
                     modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: table.window?.windowNumber ?? 0,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        table.keyDown(with: event)
    }
}

@MainActor private final class SelectionFixture {
    let window: NSWindow
    let coordinator: DataGrid.Coordinator
    let table: CopyableTableView
    init() throws {
        let grid = DataGrid(result: QueryResult(columns: ["id", "name"],
            rows: (0..<12).map { [String($0), "row \($0)"] }, elapsed: .zero, message: ""),
            inspect: { _, _ in }, quickFilter: { _, _ in }, delete: { _ in })
        coordinator = grid.makeCoordinator()
        let scroll = grid.makeScroll(coordinator: coordinator)
        table = try XCTUnwrap(scroll.documentView as? CopyableTableView)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        scroll.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.makeFirstResponder(table)
    }
}
