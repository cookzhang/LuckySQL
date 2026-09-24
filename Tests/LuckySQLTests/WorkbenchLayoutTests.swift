import AppKit
import SwiftUI
import XCTest
@testable import LuckySQL

@MainActor final class WorkbenchLayoutTests: XCTestCase {
    func testFixedSizeSQLAndDataLayouts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["LUCKYSQL_LAYOUT_ACCEPTANCE"] else { throw XCTSkip("Opt-in native layout capture") }
        let suite = "LayoutAcceptance.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let profile = ConnectionProfile(name: "Acceptance · 中文😀", host: "fixture.invalid", username: "fixture", database: "fixture")
        let profiles = ProfileStore(defaults: defaults); profiles.save([profile])
        let workspaces = ConnectionWorkspaces(defaults: defaults) { store in AppModel(profileStore: profiles, keychain: LayoutPasswords(), driver: LayoutDriver(), workspaceStore: store) }
        let model = workspaces.active
        model.selectProfile(profile.id); model.connect()
        try await settle(model)
        model.newQuery(sql: (1...60).map { "SELECT \($0), '中文😀', NULL; -- line \($0)" }.joined(separator: "\n"))
        model.runCurrentQuery(); try await settle(model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ConnectionWorkspacesView(workspaces: workspaces).frame(width: 1280, height: 800))
        window.contentView = host; window.orderFront(nil)
        defer { window.close(); model.disconnect(); model.flushWorkspace(); defaults.removePersistentDomain(forName: suite) }
        let output = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var geometry: [[String: Any]] = []
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 960, height: 640)] {
            for section in [WorkspaceSection.query, .data] {
                if section == .data { model.browse(DatabaseTable(schema: "fixture", name: "same_long_prefix_中文😀_orders")); try await settle(model) }
                else { model.changeSection(.query) }
                host.rootView = ConnectionWorkspacesView(workspaces: workspaces).frame(width: size.width, height: size.height)
                window.setContentSize(size)
                try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let grids = descendants(CopyableTableView.self, in: host)
                let editors = descendants(CodeTextView.self, in: host)
                let grid = try XCTUnwrap(grids.first)
                let visibleRows = grid.rows(in: grid.visibleRect)
                XCTAssertGreaterThan(visibleRows.length, 5)
                let sqlLines = editors.first.map { editor in Int(editor.visibleRect.height / max(1, editor.font.map { $0.ascender - $0.descender + $0.leading } ?? 16)) } ?? 0
                geometry.append(["width":size.width,"height":size.height,"section":section == .query ? "SQL" : "Data","grid_visible_rows_including_partial":visibleRows.length,"grid_visible_columns_including_partial":grid.tableColumns.indices.filter { grid.rect(ofColumn: $0).intersects(grid.visibleRect) }.count,"sql_line_capacity_estimate":sqlLines,"grid_rect":NSStringFromRect(grid.visibleRect)])
            // cacheDisplay omits some composited SwiftUI/header layers. These
            // optional images are diagnostics, never native visual sign-off.
            if ProcessInfo.processInfo.environment["LUCKYSQL_CAPTURE_DIAGNOSTIC_IMAGES"] == "1" {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("workbench-\(section == .query ? "sql" : "data")-\(Int(size.width))x\(Int(size.height)).png"))
            }
            }
        }
        try JSONSerialization.data(withJSONObject: ["method":"Actual ConnectionWorkspacesView/ContentView native hosting at exact logical content size, 2x backing; synthetic database session; excludes system title bar. SQL line capacity is geometric, visible grid range can include partial rows/columns.","geometry":geometry], options:[.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("layout.json"))
    }
    private func settle(_ model: AppModel) async throws {
        for _ in 0..<1000 { if !model.isRunning { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw UpdateFailure("Layout fixture did not settle")
    }
    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) } }
}
private struct LayoutDriver: DatabaseDriver { func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { LayoutSession() } }
private actor LayoutPasswords: PasswordStoring {
    func password(for profileID: UUID) -> String? { "fixture" }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
private actor LayoutSession: DatabaseSession {
    func schemas() -> [String] { ["fixture"] }
    func tables(in schema: String) -> [String] { ["same_long_prefix_中文😀_orders", "same_long_prefix_中文😀_customers"] }
    func columns(in table: DatabaseTable) -> [LuckySQL.TableColumn] { [] }
    func query(_ sql: String) -> QueryResult { QueryResult(columns: ["id", "中文😀_name", "nullable", "long_column_name_精确小数", "multiline"], rows: (1...100).map { [String($0), "English 中文 😀", "NULL", "1234567890.12345678", "line 1\nline 2"] }, elapsed: .milliseconds(1), message: "100 rows", nullCells: Set((0..<100).map { CellAddress(row: $0, column: 2) })) }
    func close() {}
}
