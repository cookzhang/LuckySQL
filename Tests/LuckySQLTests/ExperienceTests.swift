import AppKit
import SwiftUI
import XCTest
@testable import LuckySQL

final class ExperienceTests: XCTestCase {
    @MainActor func testCloseShortcutOnlyTargetsQueryTabsInWorkspaceWindows() {
        let workspace = NSWindow(), settings = NSWindow()
        WorkspaceWindows.windows.add(workspace)
        defer { WorkspaceWindows.windows.remove(workspace) }
        XCTAssertTrue(WorkspaceWindows.closesQueryTab(in: workspace, section: .query))
        XCTAssertFalse(WorkspaceWindows.closesQueryTab(in: workspace, section: .data))
        XCTAssertFalse(WorkspaceWindows.closesQueryTab(in: settings, section: .query))
    }
    func testLargeDocumentIncrementalAnalysis() async {
        let source = String(repeating: "SELECT id, full_name FROM demo_customers WHERE id = 1;\n", count: 38_462)
        let clock = ContinuousClock(), baselineStart = clock.now
        let fullCount = SQLTools.tokens(source).count
        let baseline = baselineStart.duration(to: clock.now)
        let service = SQLAnalysisService()
        _ = await service.analyze(source, document: "large-document")
        let editStart = clock.now
        let result = await service.analyze(source + "SELECT 2", document: "large-document")
        let incremental = editStart.duration(to: clock.now)
        XCTAssertEqual(result.tokens.count, fullCount + 3)
        XCTAssertEqual(result.tokens.suffix(3).map(\.text), ["SELECT", " ", "2"])
        XCTAssertEqual(result.lineStarts.count, 38_463)
        print("SQL analysis benchmark (not end-to-end input latency): \(source.utf8.count) bytes; full scanner \(baseline); cached tail edit \(incremental)")
    }
    func testIncrementalAnalysisMatchesFullScannerAcrossBoundaryEdits() async {
        let service = SQLAnalysisService(), document = UUID().uuidString
        let variants = ["SELECT 1;\nSELECT '中文😀';", "SELECT 12;\nSELECT '中文😀';", "SELECT 12;\nSELECT '中文😀;", "SELECT 12;\nSELECT '中文😀'; -- text", "SELECT 12;\nSELECT '中文😀'; /* text", "SELECT 12;\nSELECT '中文😀'; /* text */\nSELECT 5", "-- SELECT 12;\nSELECT 5", "", "SELECT `😀列` FROM `表`;\n"]
        for sql in variants {
            let analyzed = await service.analyze(sql, document: document)
            let expected = SQLTools.tokens(sql)
            XCTAssertEqual(analyzed.tokens.map(\.text), expected.map(\.text))
            XCTAssertEqual(analyzed.tokens.map(\.range), expected.map(\.range))
            XCTAssertEqual(analyzed.tokens.map(\.kind), expected.map(\.kind))
            XCTAssertEqual(analyzed.lineStarts.count, sql.filter { $0 == "\n" }.count + 1)
            for offset in 0...(sql as NSString).length {
                XCTAssertEqual(analyzed.line(at: offset), (sql as NSString).substring(to: offset).filter { $0 == "\n" }.count + 1)
            }
        }
    }

    func testSharedCompletionAnalysisKeepsAbsoluteUTF16ReplacementRange() async throws {
        let prefix = "SELECT '😀';\n"
        let sql = prefix + "SELECT cu FROM customers c;"
        let caret = (sql as NSString).range(of: "cu FROM").location + 2
        let catalog = SQLCompletionCatalog(schemas: [DatabaseSchema(name: "shop", tables: [DatabaseTable(schema: "shop", name: "customers")])], database: "shop")
        let result = await SQLAnalysisService().completion(sql, document: "test", caret: caret, catalog: catalog, automatic: true)
        let request = try XCTUnwrap(result)
        XCTAssertTrue(request.candidates.contains("customers"))
        XCTAssertEqual((sql as NSString).substring(with: request.range), "cu")
        XCTAssertEqual(request.caret, caret)
        XCTAssertEqual(request.details["customers"], "shop · table")
    }

    @MainActor func testTabUndoManagersAreIndependent() {
        let first = CodeTextView(), second = CodeTextView()
        first.allowsUndo = true; second.allowsUndo = true
        first.undoManager?.groupsByEvent = false; second.undoManager?.groupsByEvent = false
        first.undoManager?.beginUndoGrouping()
        first.insertText("SELECT 1", replacementRange: NSRange(location: 0, length: 0))
        first.undoManager?.endUndoGrouping()
        second.undoManager?.beginUndoGrouping()
        second.insertText("SELECT 2", replacementRange: NSRange(location: 0, length: 0))
        second.undoManager?.endUndoGrouping()
        XCTAssertFalse(first.undoManager === second.undoManager)
        first.undoManager?.undo()
        XCTAssertEqual(first.string, "")
        XCTAssertEqual(second.string, "SELECT 2")
    }

    @MainActor func testGridRefreshKeepsReorderedColumnsWidthsAndPrimaryKeySelection() throws {
        let old = QueryResult(columns: ["id", "name"], rows: [["1", "A"], ["2", "B"]], elapsed: .zero, message: "")
        let coordinator = DataGrid.Coordinator(DataGrid(result: old, primaryKeys: ["id"]))
        let table = NSTableView(); table.dataSource = coordinator; table.delegate = coordinator; coordinator.table = table
        coordinator.reload()
        table.tableColumns[0].width = 237
        table.moveColumn(0, toColumn: 1)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let selected = coordinator.selectedKeys()
        let refreshed = QueryResult(columns: old.columns, rows: [["2", "Updated"], ["1", "A"]], elapsed: .zero, message: "")
        coordinator.parent = DataGrid(result: refreshed, primaryKeys: ["id"])
        coordinator.reload(selection: selected)
        XCTAssertEqual(table.tableColumns.map(\.title), ["name", "id"])
        XCTAssertEqual(table.tableColumns[1].width, 237)
        XCTAssertEqual(table.selectedRow, 0)
    }

    @MainActor func testEditorUndoSurvivesDetachingFromWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let coordinator = SQLTextEditor.Coordinator(SQLTextEditor(text: .constant("")))
        editor.delegate = coordinator; editor.allowsUndo = true
        editor.undoManager?.groupsByEvent = false
        window.contentView?.addSubview(editor)
        editor.undoManager?.beginUndoGrouping()
        editor.insertText("SELECT 1", replacementRange: NSRange(location: 0, length: 0))
        editor.undoManager?.endUndoGrouping()
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.delegate = nil; editor.removeFromSuperview()
        window.contentView?.addSubview(editor); editor.delegate = coordinator
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "")
    }

    @MainActor func testCellPreviewUsesActiveRowInsideMultipleSelection() {
        let result = QueryResult(columns: ["id", "value"], rows: [["1", "first"], ["2", "second"]], elapsed: .zero, message: "")
        var inspected: CellAddress?
        let coordinator = DataGrid.Coordinator(DataGrid(result: result, inspect: { inspected = CellAddress(row: $0, column: $1) }))
        let table = CopyableTableView(); table.dataSource = coordinator; table.delegate = coordinator; table.allowsMultipleSelection = true
        coordinator.table = table; coordinator.reload()
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        table.activeRow = 1; table.activeColumn = 1
        coordinator.preview()
        XCTAssertEqual(inspected, CellAddress(row: 1, column: 1))
    }

    @MainActor func testOrderedBackgroundPersistenceCanFlushAndReload() throws {
        let name = "LuckySQLExperience.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WorkspaceStore(defaults: defaults)
        for value in 0..<20 { store.saveTabs([QueryTab(title: "\(value)", sql: String(repeating: "SELECT 1;\n", count: 1000), database: "shop")]) }
        store.flush()
        XCTAssertEqual(WorkspaceStore(defaults: defaults).loadTabs().first?.title, "19")
    }

    func testExistingProfilesDecodeWithoutNewOptionalSafetyFields() throws {
        let data = Data("{\"id\":\"550E8400-E29B-41D4-A716-446655440000\",\"name\":\"old\",\"host\":\"localhost\",\"port\":3306,\"username\":\"root\",\"database\":\"\"}".utf8)
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertNil(profile.readOnly)
    }
}
