import AppKit
import XCTest
@testable import LuckySQL

@MainActor final class GridLayoutTests: XCTestCase {
    func testVisibleTextFitsCellAndTracksColumnResize() throws {
        let fixture = GridFixture(result: result())
        let column = fixture.table.tableColumns[0]
        let cell = try fixture.cell(for: column, row: 0)
        cell.frame = NSRect(x: 0, y: 0, width: 180, height: fixture.table.rowHeight)
        cell.needsLayout = true
        cell.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(cell.textField)
        XCTAssertEqual(text.stringValue, "42")
        assertTextFits(text, in: cell)
        let initial = text.frame

        cell.setFrameSize(NSSize(width: 360, height: fixture.table.rowHeight))
        cell.needsLayout = true
        cell.layoutSubtreeIfNeeded()
        assertTextFits(text, in: cell)
        XCTAssertEqual(text.frame.width - initial.width, 180, accuracy: 0.5)
        XCTAssertEqual(text.frame.minX, initial.minX, accuracy: 0.5)
        XCTAssertEqual(text.frame.midY, initial.midY, accuracy: 0.5)

        cell.setFrameSize(NSSize(width: column.minWidth, height: fixture.table.rowHeight))
        cell.needsLayout = true
        cell.layoutSubtreeIfNeeded()
        assertTextFits(text, in: cell)
    }

    func testReorderedColumnsDisplayTheirSourceValues() throws {
        let fixture = GridFixture(result: result())
        fixture.table.moveColumn(2, toColumn: 0)
        let expected = ["中文😀 value", "42", "customer"]
        for (displayIndex, value) in expected.enumerated() {
            let column = fixture.table.tableColumns[displayIndex]
            let cell = try fixture.cell(for: column, row: 0)
            cell.frame = NSRect(x: 0, y: 0, width: column.width, height: fixture.table.rowHeight)
            cell.needsLayout = true
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.textField?.stringValue, value)
            assertTextFits(try XCTUnwrap(cell.textField), in: cell)
        }
    }

    func testNullAndLongValuesRetainPreviewAndTooltip() throws {
        let longValue = String(repeating: "中文😀", count: 400)
        let result = QueryResult(columns: ["value"], rows: [[longValue], ["NULL"]], elapsed: .zero,
                                 message: "Fixture", nullCells: [CellAddress(row: 1, column: 0)])
        let fixture = GridFixture(result: result)
        let column = fixture.table.tableColumns[0]
        let longCell = try fixture.cell(for: column, row: 0)
        XCTAssertEqual(longCell.textField?.stringValue, String(repeating: "中文😀", count: 128) + "…")
        XCTAssertEqual(longCell.toolTip, String(repeating: "中文😀", count: 250) + "…")
        XCTAssertEqual(longCell.textField?.textColor, .labelColor)

        let nullCell = try fixture.cell(for: column, row: 1)
        XCTAssertEqual(nullCell.textField?.stringValue, "NULL")
        XCTAssertEqual(nullCell.textField?.textColor, .tertiaryLabelColor)
    }

    private func assertTextFits(_ text: NSTextField, in cell: NSTableCellView,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(text.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(text.frame.height, 0, file: file, line: line)
        XCTAssertEqual(text.frame.minX, 8, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(cell.bounds.maxX - text.frame.maxX, 8, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(text.frame.midY, cell.bounds.midY, accuracy: 0.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(text.frame.minY, cell.bounds.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(text.frame.maxY, cell.bounds.maxY, file: file, line: line)
        if let font = text.font {
            XCTAssertGreaterThanOrEqual(text.frame.height, ceil(font.ascender - font.descender), file: file, line: line)
        }
    }

    private func result() -> QueryResult {
        QueryResult(columns: ["id", "name", "value"], rows: [["42", "customer", "中文😀 value"]], elapsed: .zero, message: "Fixture")
    }
}

@MainActor private final class GridFixture {
    let coordinator: DataGrid.Coordinator
    let scroll: NSScrollView
    let table: NSTableView

    init(result: QueryResult) {
        let grid = DataGrid(result: result)
        let coordinator = DataGrid.Coordinator(grid)
        let scroll = grid.makeScroll(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        self.coordinator = coordinator
        self.scroll = scroll
        self.table = scroll.documentView as! NSTableView
        table.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
    }

    func cell(for column: NSTableColumn, row: Int) throws -> NSTableCellView {
        try XCTUnwrap(coordinator.tableView(table, viewFor: column, row: row) as? NSTableCellView)
    }
}
