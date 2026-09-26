import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LuckySQL

@MainActor final class WorkspaceSwitchingTests: XCTestCase {
    func testSwitchRetainsNativeViewsScrollSelectionAndFocus() async throws {
        let suite = "WorkspaceSwitching.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspaces = ConnectionWorkspaces(defaults: defaults) { store in
            AppModel(profileStore: ProfileStore(defaults: defaults), keychain: SwitchingPasswords(), workspaceStore: store)
        }
        let firstID = workspaces.selectedID
        let first = workspaces.active
        first.sql = "SELECT 'first';"
        first.queryTabs[0].result = QueryResult(columns: ["id", "value"], rows: (0..<1000).map { [String($0), "row \($0)"] }, elapsed: .zero, message: "1000 rows")
        workspaces.newWorkspace()
        let secondID = workspaces.selectedID
        let second = workspaces.active
        second.sql = "SELECT 'second';"
        workspaces.selectedID = firstID
        let host = NSHostingView(rootView: ConnectionWorkspacesView(workspaces: workspaces).frame(width: 1100, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); workspaces.flush(); defaults.removePersistentDomain(forName: suite) }
        try await settle(host)
        let cache = try XCTUnwrap(descendants(WorkspacePaneContainer.self, in: host).first)
        XCTAssertEqual(cache.subviews.count, 1, "Unvisited workspaces should not build native views")
        let editor = try XCTUnwrap(descendants(CodeTextView.self, in: cache).first)
        let grid = try XCTUnwrap(descendants(CopyableTableView.self, in: cache).first)
        grid.selectRowIndexes(IndexSet(integer: 50), byExtendingSelection: false)
        grid.scrollRowToVisible(200)
        let scrollY = grid.enclosingScrollView?.contentView.bounds.minY
        editor.setSelectedRange(NSRange(location: 7, length: 7))
        window.makeFirstResponder(editor)

        workspaces.selectedID = secondID
        try await settle(host)
        XCTAssertTrue(editor.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(cache.subviews.count, 2)
        let otherEditor = try XCTUnwrap(descendants(CodeTextView.self, in: cache).first { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertFalse(otherEditor === editor)
        XCTAssertEqual(otherEditor.string, second.sql)
        window.makeFirstResponder(otherEditor)

        workspaces.selectedID = firstID
        try await settle(host)
        XCTAssertTrue(descendants(WorkspacePaneContainer.self, in: host).first === cache)
        XCTAssertTrue(descendants(CodeTextView.self, in: cache).first { !$0.isHiddenOrHasHiddenAncestor } === editor)
        XCTAssertTrue(descendants(CopyableTableView.self, in: cache).first === grid)
        XCTAssertEqual(grid.selectedRowIndexes, IndexSet(integer: 50))
        XCTAssertEqual(grid.enclosingScrollView?.contentView.bounds.minY, scrollY)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 7))
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText("'updated'", replacementRange: editor.selectedRange())
        XCTAssertEqual(first.sql, "SELECT 'updated';")
        XCTAssertEqual(second.sql, "SELECT 'second';")

        if let path = ProcessInfo.processInfo.environment["LUCKYSQL_SWITCH_CAPTURE"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        workspaces.selectedID = secondID
        try await settle(host)
        window.makeFirstResponder(otherEditor)
        first.newQuery(sql: "SELECT 'background';")
        try await settle(host)
        XCTAssertTrue(window.firstResponder === otherEditor, "Hidden editors must not steal keyboard focus")
        workspaces.close(firstID)
        try await settle(host)
        XCTAssertEqual(cache.subviews.count, 1, "Closing a workspace releases its cached pane")
        XCTAssertFalse(otherEditor.isHiddenOrHasHiddenAncestor)
    }

    func testBackgroundUpdatesDoNotInvalidateWorkspaceShell() async throws {
        let suite = "WorkspaceObservation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspaces = ConnectionWorkspaces(defaults: defaults) { store in
            AppModel(profileStore: ProfileStore(defaults: defaults), keychain: SwitchingPasswords(), workspaceStore: store)
        }
        defer { workspaces.flush(); defaults.removePersistentDomain(forName: suite) }
        let background = workspaces.active
        workspaces.newWorkspace()
        // Let initial asynchronous password loading finish before observing updates.
        try await Task.sleep(for: .milliseconds(100))
        var updates = 0
        let subscription = workspaces.objectWillChange.sink { updates += 1 }
        background.busyStage = "Loading results"
        background.schemas = [DatabaseSchema(name: "background")]
        XCTAssertEqual(updates, 0)
        workspaces.active.busyStage = "Loading results"
        XCTAssertEqual(updates, 1)
        background.isRunning = true
        XCTAssertTrue(workspaces.isBusy)
        XCTAssertEqual(updates, 2, "Global operation guards must still update")
        background.isRunning = false
        XCTAssertEqual(updates, 3)
        withExtendedLifetime(subscription) {}
    }

    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
    }
    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
}

private actor SwitchingPasswords: PasswordStoring {
    func password(for profileID: UUID) -> String? { nil }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
