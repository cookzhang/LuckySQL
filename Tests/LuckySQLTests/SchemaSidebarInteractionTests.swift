import AppKit
import SwiftUI
import XCTest
@testable import LuckySQL

@MainActor final class SchemaSidebarInteractionTests: XCTestCase {
    func testNativeSelectionKeyboardAndExternalNavigationStayInSync() async throws {
        let suite = "LuckySQLTableSelection.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let session = SidebarInteractionSession(names: ["customers", "orders", "products"])
        let profiles = ProfileStore(defaults: defaults)
        profiles.save([ConnectionProfile(name: "Selection fixture", database: "shop")])
        let model = AppModel(profileStore: profiles, keychain: SidebarInteractionPasswords(),
                             driver: SidebarInteractionDriver(session: session),
                             workspaceStore: WorkspaceStore(defaults: defaults))
        let host = NSHostingView(rootView: SchemaSidebar().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close(); model.isRunning = false; model.disconnect(); model.flushWorkspace()
            defaults.removePersistentDomain(forName: suite)
        }
        model.connect()
        try await waitUntil { !model.isRunning && model.schemaLoadState == .loaded }
        try await settle(host)
        let outline = try XCTUnwrap(findOutline(in: host))
        outline.expandItem(outline.item(atRow: 1))
        try await waitUntil { model.schemas.first?.tableLoadState == .loaded }
        try await settle(host)
        XCTAssertEqual(outline.numberOfRows, 5)
        window.makeFirstResponder(outline)
        outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try await settle(host)
        XCTAssertEqual(model.selectedTable?.name, "customers")
        XCTAssertEqual(model.section, .query)
        var reads = await session.reads
        XCTAssertEqual(reads.queries, 0)
        XCTAssertEqual(reads.columns, 0)

        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125))
        outline.keyDown(with: down)
        try await settle(host)
        XCTAssertEqual(model.selectedTable?.name, "orders")
        XCTAssertEqual(outline.selectedRow, 3)

        model.changeSection(.data)
        try await waitUntil { !model.isRunning }
        try await settle(host)
        outline.keyDown(with: down)
        try await waitUntil { !model.isRunning && model.selectedTable?.name == "products" }
        try await settle(host)
        XCTAssertEqual(model.section, .data)
        XCTAssertEqual(model.browseResult.rows, [["1"]])
        reads = await session.reads
        XCTAssertEqual(reads.queries, 2)
        outline.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        try await settle(host)
        let afterReselect = await session.reads
        XCTAssertEqual(afterReselect.queries, reads.queries)

        model.isRunning = true
        try await settle(host)
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
            isARepeat: false, keyCode: 126))
        outline.keyDown(with: up)
        try await settle(host)
        XCTAssertEqual(model.selectedTable?.name, "products")
        XCTAssertEqual(outline.selectedRow, 4, "Rejected selections must keep the highlight on the displayed table")
        model.isRunning = false
        model.browse(DatabaseTable(schema: "shop", name: "customers"))
        try await waitUntil { !model.isRunning }
        try await settle(host)
        XCTAssertEqual(outline.selectedRow, 2, "Navigation outside the list must update the native selection")
        XCTAssertTrue(findOutline(in: host) === outline)
        outline.keyDown(with: up)
        try await settle(host)
        XCTAssertEqual(outline.selectedRow, 2, "Connection and database headings are not table selections")

        model.showStructure()
        try await waitUntil { !model.isRunning }
        try await settle(host)
        let beforeStructureSwitch = await session.reads.queries
        outline.keyDown(with: down)
        try await waitUntil { !model.isRunning && model.selectedTable?.name == "orders" }
        try await settle(host)
        XCTAssertEqual(model.section, .structure)
        let afterStructureSwitch = await session.reads.queries
        XCTAssertEqual(afterStructureSwitch, beforeStructureSwitch, "Structure navigation must not fetch table data")
        outline.expandItem(outline.item(atRow: 3))
        try await settle(host)
        XCTAssertEqual(outline.numberOfRows, 6)
        outline.keyDown(with: down)
        try await waitUntil { !model.isRunning && model.selectedTable?.name == "products" }
        try await settle(host)
        XCTAssertEqual(outline.selectedRow, 5, "Keyboard navigation must skip expanded column details")
        outline.collapseItem(outline.item(atRow: 1))
        try await settle(host)
        XCTAssertEqual(model.selectedTable?.name, "products", "Hiding rows must retain the displayed table")
        outline.expandItem(outline.item(atRow: 1))
        try await settle(host)
        XCTAssertEqual(outline.selectedRow, 5)
    }

    func testBusyTableContextMenuKeepsLocalActionsAvailable() async throws {
        let suite = "LuckySQLSidebarInteraction.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let session = SidebarInteractionSession()
        let profile = ConnectionProfile(name: "Sidebar fixture", database: "shop")
        let profiles = ProfileStore(defaults: defaults)
        profiles.save([profile])
        let model = AppModel(profileStore: profiles, keychain: SidebarInteractionPasswords(),
                             driver: SidebarInteractionDriver(session: session),
                             workspaceStore: WorkspaceStore(defaults: defaults))
        let host = NSHostingView(rootView: SchemaSidebar().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close()
            model.isRunning = false
            model.disconnect()
            model.flushWorkspace()
            defaults.removePersistentDomain(forName: suite)
        }

        model.connect()
        try await waitUntil { !model.isRunning && model.schemaLoadState == .loaded }
        try await settle(host)
        let outline = try XCTUnwrap(findOutline(in: host))
        XCTAssertEqual(outline.numberOfRows, 2)
        outline.expandItem(outline.item(atRow: 1))
        try await waitUntil { model.schemas.first?.tableLoadState == .loaded }
        try await settle(host)
        XCTAssertEqual(outline.numberOfRows, 3)

        let idle = try await openMenu(at: 2, in: outline, window: window)
        XCTAssertEqual(idle["Preview Data"], true)
        XCTAssertEqual(idle["Preview Structure"], true)
        XCTAssertEqual(idle["Add Favorite"], true)
        XCTAssertEqual(idle["Copy Qualified Name"], true)

        model.isRunning = true
        try await settle(host)
        let busy = try await openMenu(at: 2, in: outline, window: window)
        XCTAssertEqual(busy["Preview Data"], false)
        XCTAssertEqual(busy["Preview Structure"], false)
        XCTAssertEqual(busy["Add Favorite"], true, "A running query must keep local favorite changes available")
        XCTAssertEqual(busy["Copy Qualified Name"], true, "Copying a table name must remain available during a query")
        let reads = await session.reads
        XCTAssertEqual(reads.queries, 0)
        XCTAssertEqual(reads.columns, 0, "Opening the menu must not load metadata")
    }

    private func openMenu(at row: Int, in outline: NSOutlineView, window: NSWindow) async throws -> [String: Bool] {
        let point = outline.convert(NSPoint(x: 150, y: outline.rect(ofRow: row).midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menuOpened = expectation(description: "Native table context menu opened")
        let snapshot = SidebarMenuSnapshot()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                              object: nil, queue: nil) { notification in
            guard let menu = notification.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                guard !snapshot.isTracking else { return }
                snapshot.isTracking = true
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        snapshot.items = menu.items.filter { !$0.isSeparatorItem }.reduce(into: [:]) { $0[$1.title] = $1.isEnabled }
                        menu.cancelTracking()
                        menuOpened.fulfill()
                    }
                }
                RunLoop.main.add(timer, forMode: .eventTracking)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.sendEvent(event)
        await fulfillment(of: [menuOpened], timeout: 2)
        XCTAssertFalse(snapshot.items.isEmpty)
        return snapshot.items
    }

    private func findOutline(in view: NSView) -> NSOutlineView? {
        (view as? NSOutlineView) ?? view.subviews.lazy.compactMap { self.findOutline(in: $0) }.first
    }

    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw UpdateFailure("Sidebar interaction fixture did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor private final class SidebarMenuSnapshot {
    var isTracking = false
    var items: [String: Bool] = [:]
}

private struct SidebarInteractionDriver: DatabaseDriver {
    let session: SidebarInteractionSession
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { session }
}

private actor SidebarInteractionPasswords: PasswordStoring {
    func password(for profileID: UUID) -> String? { "fixture" }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}

private actor SidebarInteractionSession: DatabaseSession {
    let names: [String]
    init(names: [String] = ["orders"]) { self.names = names }
    var reads = (queries: 0, columns: 0)
    func query(_ sql: String) -> QueryResult {
        reads.queries += 1
        return QueryResult(columns: ["id"], rows: [["1"]], elapsed: .zero, message: "Fixture")
    }
    func schemas() -> [String] { ["shop"] }
    func tables(in schema: String) -> [String] { names }
    func columns(in table: DatabaseTable) -> [LuckySQL.TableColumn] {
        reads.columns += 1
        return [TableColumn(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true,
                            defaultValue: nil, extra: "")]
    }
    func close() {}
}
