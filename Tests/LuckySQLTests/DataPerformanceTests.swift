import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LuckySQL

@MainActor final class DataPerformanceTests: XCTestCase {
    private var previousAccessibilityEnabled = false
    func testBrowseDraftEditsDoNotPublishWorkspaceChanges() async throws {
        let fixture = try DataPerformanceFixture()
        defer { fixture.close() }
        let model = fixture.model
        try await waitUntil { !model.isLoadingPassword }
        var modelChanges = 0, workspaceChanges = 0, draftChanges = 0
        let subscriptions = [
            model.objectWillChange.sink { modelChanges += 1 },
            fixture.workspaces.objectWillChange.sink { workspaceChanges += 1 },
            model.browseDraft.objectWillChange.sink { draftChanges += 1 }
        ]
        model.browseOptions.filterColumn = "name"
        model.browseOptions.filterOperator = .equals
        for index in 0..<100 { model.browseOptions.filterValue = "customer \(index)" }
        model.browseDraft.options.pageSize = 500
        model.browseDraft.options.selectedColumns = ["id", "name"]
        XCTAssertEqual(model.browseOptions, model.browseDraft.options)
        XCTAssertTrue(model.hasPendingFilter)
        XCTAssertEqual(modelChanges, 0, "Filter drafts must not invalidate the sidebar or result grids")
        XCTAssertEqual(workspaceChanges, 0, "Filter drafts must not invalidate the workspace shell")
        XCTAssertGreaterThan(draftChanges, 0)
        withExtendedLifetime(subscriptions) {}
    }

    func testNativeFilterTypingPreservesGridSidebarAndHiddenSQL() async throws {
        let fixture = try DataPerformanceFixture()
        defer { fixture.close() }
        let model = fixture.model
        try await fixture.connect()
        await model.loadTables(in: "shop")
        model.sql = String(repeating: "SELECT 'retained SQL'; -- draft\n", count: 500)
        model.queryTabs[0].result = QueryResult(columns: ["sql_result"], rows: (0..<500).map { [String($0)] }, elapsed: .zero, message: "SQL")
        let (host, window) = makeWindow(WorkspacePane(model: model, sidebarVisible: .constant(true)))
        defer { closeWindow(window) }
        try await settle(host)
        let sqlEditor = try XCTUnwrap(descendants(CodeTextView.self, in: host).first)
        try await waitUntil { sqlEditor.analysis?.sql == sqlEditor.string }
        let sqlGrid = try XCTUnwrap(descendants(CopyableTableView.self, in: host).first)
        let sqlCoordinator = try XCTUnwrap(sqlGrid.delegate as? DataGrid.Coordinator)
        sqlEditor.setSelectedRange(NSRange(location: 7, length: 4))
        sqlGrid.selectRowIndexes(IndexSet(integer: 40), byExtendingSelection: false)
        let sqlReloads = sqlCoordinator.reloadCount
        model.browse(fixture.orders)
        try await waitUntil { !model.isRunning }
        model.browseOptions.pageSize = 500
        model.refreshData(resetPage: true)
        try await waitUntil { !model.isRunning }
        model.browseOptions.filterColumn = "name"
        try await settle(host)
        let sidebar = try XCTUnwrap(descendants(NSOutlineView.self, in: host).first)
        let sidebarRows = sidebar.numberOfRows
        let grid = try XCTUnwrap(descendants(CopyableTableView.self, in: host).first { !$0.isHiddenOrHasHiddenAncestor })
        let coordinator = try XCTUnwrap(grid.delegate as? DataGrid.Coordinator)
        let field = try filterField(in: host)
        grid.selectRowIndexes(IndexSet(integer: 250), byExtendingSelection: false)
        grid.scrollRowToVisible(250)
        try await settle(host)
        let scrollOrigin = grid.enclosingScrollView?.contentView.bounds.origin
        let reloads = coordinator.reloadCount
        let sqlColors = sqlEditor.colorPassCount
        let queries = await fixture.session.queries.count
        var modelChanges = 0, workspaceChanges = 0
        let subscriptions = [model.objectWillChange.sink { modelChanges += 1 },
                             fixture.workspaces.objectWillChange.sink { workspaceChanges += 1 }]
        let fieldEditor = try beginEditing(field, window: window)
        for character in "customer 中文😀" {
            fieldEditor.insertText(String(character), replacementRange: fieldEditor.selectedRange())
            await Task.yield()
        }
        try await settle(host)
        XCTAssertEqual(model.browseOptions.filterValue, "customer 中文😀")
        XCTAssertTrue(model.hasPendingFilter)
        XCTAssertTrue(accessibilityElements(in: host).contains { accessibilityText($0) == "Filter changes not applied" }, accessibilityDump(in: host))
        XCTAssertEqual(modelChanges, 0)
        XCTAssertEqual(workspaceChanges, 0)
        XCTAssertEqual(coordinator.reloadCount, reloads)
        XCTAssertEqual(sqlCoordinator.reloadCount, sqlReloads)
        XCTAssertEqual(sqlEditor.colorPassCount, sqlColors)
        XCTAssertEqual(sqlEditor.selectedRange(), NSRange(location: 7, length: 4))
        XCTAssertEqual(sqlGrid.selectedRowIndexes, IndexSet(integer: 40))
        XCTAssertTrue(sqlEditor.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(grid.selectedRowIndexes, IndexSet(integer: 250))
        XCTAssertEqual(grid.enclosingScrollView?.contentView.bounds.origin, scrollOrigin)
        XCTAssertTrue(descendants(NSOutlineView.self, in: host).first === sidebar)
        XCTAssertEqual(sidebar.numberOfRows, sidebarRows)
        let afterTyping = await fixture.session.queries.count
        XCTAssertEqual(afterTyping, queries, "Typing must only update the draft")

        model.selectTable(fixture.orders)
        try await settle(host)
        XCTAssertEqual(modelChanges, 0, "Selecting the loaded table again must do no work")
        XCTAssertEqual(workspaceChanges, 0)
        XCTAssertEqual(coordinator.reloadCount, reloads)
        XCTAssertEqual(model.browseOptions.filterValue, "customer 中文😀", "Repeated table selection must retain the pending filter")
        let afterSelection = await fixture.session.queries.count
        XCTAssertEqual(afterSelection, queries)
        withExtendedLifetime(subscriptions) {}
    }

    func testNativeApplyReturnResetAndPageSizeUseDraftSnapshot() async throws {
        let fixture = try DataPerformanceFixture()
        defer { fixture.close() }
        try await fixture.connect()
        let model = fixture.model
        model.browse(fixture.orders)
        try await waitUntil { !model.isRunning }
        model.browseOptions.filterColumn = "name"
        model.browseOptions.filterOperator = .equals
        let (host, window) = makeWindow(TableBrowserView().environmentObject(model))
        defer { closeWindow(window) }
        try await settle(host)
        var field = try filterField(in: host)
        var editor = try beginEditing(field, window: window)
        editor.insertText("O'Reilly", replacementRange: editor.selectedRange())
        try await settle(host)
        try press("Apply", in: host)
        try await waitUntil { !model.isRunning && model.appliedBrowseOptions.filterValue == "O'Reilly" }
        var queries = await fixture.session.queries
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries.last?.contains("WHERE `name` = 'O''Reilly'") == true)
        XCTAssertFalse(model.hasPendingFilter)
        try await settle(host)
        XCTAssertFalse(accessibilityElements(in: host).contains { accessibilityText($0) == "Filter changes not applied" })

        field = try filterField(in: host)
        editor = try beginEditing(field, window: window)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("return value", replacementRange: editor.selectedRange())
        editor.doCommand(by: NSSelectorFromString("insertNewline:"))
        try await waitUntil { !model.isRunning && model.appliedBrowseOptions.filterValue == "return value" }
        queries = await fixture.session.queries
        XCTAssertEqual(queries.count, 3)
        XCTAssertTrue(queries.last?.contains("WHERE `name` = 'return value'") == true)
        try await settle(host)
        try press("Reset", in: host)
        try await waitUntil { !model.isRunning && model.appliedBrowseOptions.filterColumn.isEmpty }
        queries = await fixture.session.queries
        XCTAssertEqual(queries.count, 4)
        XCTAssertFalse(queries.last?.contains("WHERE") == true)
        XCTAssertEqual(model.browseOptions.filterValue, "")
        XCTAssertFalse(model.hasPendingFilter)

        try await settle(host)
        let rowsPicker = try XCTUnwrap(descendants(NSPopUpButton.self, in: host).first {
            Set($0.itemTitles) == Set(["100", "200", "500"])
        })
        let menu = try XCTUnwrap(rowsPicker.menu)
        let rowCountIndex = menu.indexOfItem(withTitle: "200")
        XCTAssertNotEqual(rowCountIndex, -1)
        menu.performActionForItem(at: rowCountIndex)
        try await waitUntil { !model.isRunning && model.appliedBrowseOptions.pageSize == 200 }
        queries = await fixture.session.queries
        XCTAssertEqual(queries.count, 5, "A picker action must issue exactly one request")
        XCTAssertTrue(queries.last?.contains("LIMIT 201 OFFSET 0") == true)
        XCTAssertEqual(model.browseResult.rows.count, 200)
    }

    func testNativeColumnPickerAndProjectionMenuPreserveQuerySemantics() async throws {
        let fixture = try DataPerformanceFixture()
        defer { fixture.close() }
        try await fixture.connect()
        let model = fixture.model
        model.browse(fixture.orders)
        try await waitUntil { !model.isRunning }
        let (host, window) = makeWindow(TableBrowserView().environmentObject(model))
        defer { closeWindow(window) }
        try await settle(host)
        let before = await fixture.session.queries.count

        let columnPicker = try XCTUnwrap(descendants(NSPopUpButton.self, in: host).first {
            !$0.pullsDown && ($0.accessibilityLabel() == "Column" || Set($0.itemTitles) == Set(["All rows", "id", "name"]))
        })
        XCTAssertTrue(columnPicker.isEnabled)
        let filterNameIndex = try XCTUnwrap(columnPicker.menu?.items.firstIndex { $0.representedObject as? String == "name" })
        columnPicker.selectItem(at: filterNameIndex)
        XCTAssertTrue(columnPicker.sendAction(try XCTUnwrap(columnPicker.action), to: columnPicker.target))
        try await settle(host)
        XCTAssertEqual(model.browseOptions.filterColumn, "name")
        XCTAssertEqual(model.appliedBrowseOptions.filterColumn, "")
        XCTAssertTrue(model.hasPendingFilter)
        let afterPicker = await fixture.session.queries.count
        XCTAssertEqual(afterPicker, before, "Choosing a filter column must only update its draft")

        let columnsButton = try XCTUnwrap(descendants(NSPopUpButton.self, in: host).first {
            $0.pullsDown && ($0.accessibilityLabel() == "Columns" || $0.title == "Columns")
        })
        XCTAssertTrue(columnsButton.isEnabled)
        let menu = try XCTUnwrap(columnsButton.menu)
        try await openNativePopup(columnsButton)
        let primaryKey = try XCTUnwrap(menu.items.first { $0.representedObject as? String == "id" })
        let nameIndex = try XCTUnwrap(menu.items.firstIndex { $0.representedObject as? String == "name" })
        XCTAssertFalse(primaryKey.isEnabled, "Primary keys must remain selected for stable row identity")
        XCTAssertEqual(primaryKey.state, .on)
        XCTAssertTrue(menu.items[nameIndex].isEnabled)
        XCTAssertEqual(menu.items[nameIndex].state, .on)

        menu.performActionForItem(at: nameIndex)
        try await waitUntil { !model.isRunning && model.appliedBrowseOptions.selectedColumns == ["id"] }
        XCTAssertEqual(model.browseOptions.selectedColumns, ["id"])
        var queries = await fixture.session.queries
        XCTAssertEqual(queries.count, before + 1, "One projection toggle must issue exactly one query")
        let projectedSQL = try XCTUnwrap(queries.last)
        let projectedColumns = try XCTUnwrap(projectedSQL.components(separatedBy: " FROM ").first)
        XCTAssertTrue(projectedColumns.contains("`id`"))
        XCTAssertFalse(projectedColumns.contains("`name`"))

        try await settle(host)
        try await openNativePopup(columnsButton)
        let allIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "All columns" })
        menu.performActionForItem(at: allIndex)
        try await waitUntil { !model.isRunning && model.appliedBrowseOptions.selectedColumns.isEmpty }
        XCTAssertTrue(model.browseOptions.selectedColumns.isEmpty)
        queries = await fixture.session.queries
        XCTAssertEqual(queries.count, before + 2, "Restoring all columns must issue exactly one query")
        XCTAssertTrue(queries.last?.hasPrefix("SELECT * FROM `shop`.`orders`") == true)

        let idleDraft = model.browseOptions
        let idleQueries = queries.count
        model.isRunning = true
        defer { model.isRunning = false }
        try await settle(host)
        XCTAssertFalse(columnPicker.isEnabled)
        XCTAssertFalse(columnsButton.isEnabled)
        let filterIDIndex = try XCTUnwrap(columnPicker.menu?.items.firstIndex { $0.representedObject as? String == "id" })
        columnPicker.selectItem(at: filterIDIndex)
        XCTAssertTrue(columnPicker.sendAction(try XCTUnwrap(columnPicker.action), to: columnPicker.target))
        let blockedAllIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "All columns" })
        menu.performActionForItem(at: blockedAllIndex)
        try await settle(host)
        XCTAssertEqual(model.browseOptions, idleDraft, "Disabled native actions must not change the draft")
        let afterDisabledActions = await fixture.session.queries.count
        XCTAssertEqual(afterDisabledActions, idleQueries, "Disabled native actions must not start a query")
        model.isRunning = false
    }

    func testFailedFilterRestoresAppliedOptionsAndResult() async throws {
        let fixture = try DataPerformanceFixture()
        defer { fixture.close() }
        try await fixture.connect()
        let model = fixture.model
        model.browse(fixture.orders)
        try await waitUntil { !model.isRunning }
        model.browseOptions.filterColumn = "name"
        model.browseOptions.filterOperator = .equals
        model.browseOptions.filterValue = "accepted"
        model.refreshData(resetPage: true)
        try await waitUntil { !model.isRunning }
        let applied = model.appliedBrowseOptions, result = model.browseResult.id
        await fixture.session.failNextQuery()
        model.browseOptions.filterValue = "rejected"
        model.browseOptions.pageSize = 500
        model.refreshData(resetPage: true)
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.browseOptions, applied)
        XCTAssertEqual(model.appliedBrowseOptions, applied)
        XCTAssertEqual(model.browseResult.id, result)
        XCTAssertEqual(model.browseError, "Fixture filter failed")
        XCTAssertFalse(model.hasPendingFilter)

        let before = await fixture.session.queries.count
        model.browseIsStale = true
        model.selectTable(fixture.orders)
        try await waitUntil { !model.isRunning }
        let after = await fixture.session.queries.count
        XCTAssertEqual(after, before + 1, "A stale selected table must still refresh")
        XCTAssertFalse(model.browseIsStale)
    }

    func testGridQuickFilterUpdatesDraftControlsForValuesAndNulls() async throws {
        let fixture = try DataPerformanceFixture()
        defer { fixture.close() }
        try await fixture.connect()
        let model = fixture.model
        model.browse(fixture.orders)
        try await waitUntil { !model.isRunning }
        let (host, window) = makeWindow(TableBrowserView().environmentObject(model))
        defer { closeWindow(window) }
        try await settle(host)
        let grid = try XCTUnwrap(descendants(CopyableTableView.self, in: host).first)
        let coordinator = try XCTUnwrap(grid.delegate as? DataGrid.Coordinator)
        let quickFilter = try XCTUnwrap(coordinator.parent.quickFilter)
        quickFilter(0, 1)
        try await waitUntil { !model.isRunning && model.appliedBrowseOptions.filterOperator == .equals }
        try await settle(host)
        XCTAssertEqual(model.browseOptions.filterColumn, "name")
        XCTAssertEqual(model.browseOptions.filterValue, "customer 1")
        XCTAssertEqual(try filterField(in: host).stringValue, "customer 1")
        var queries = await fixture.session.queries
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries.last?.contains("WHERE `name` = 'customer 1'") == true)

        model.browseResult = QueryResult(columns: ["id", "name"], rows: [["1", "NULL"]], elapsed: .zero,
                                        message: "Null fixture", nullCells: [CellAddress(row: 0, column: 1)])
        try await settle(host)
        try XCTUnwrap(coordinator.parent.quickFilter)(0, 1)
        try await waitUntil { !model.isRunning && model.appliedBrowseOptions.filterOperator == .isNull }
        try await settle(host)
        XCTAssertFalse(try filterField(in: host).isEnabled)
        XCTAssertFalse(model.hasPendingFilter)
        queries = await fixture.session.queries
        XCTAssertEqual(queries.count, 3)
        XCTAssertTrue(queries.last?.contains("WHERE `name` IS NULL") == true)
    }

    func testRestoringCachedTablePageSizeDoesNotStartAnotherRequest() async throws {
        let fixture = try DataPerformanceFixture()
        defer { fixture.close() }
        try await fixture.connect()
        let model = fixture.model
        let (host, window) = makeWindow(TableBrowserView().environmentObject(model))
        defer { closeWindow(window) }
        model.browse(fixture.orders)
        try await waitUntil { !model.isRunning }
        model.browseOptions.pageSize = 200
        model.refreshData(resetPage: true)
        try await waitUntil { !model.isRunning }
        try await settle(host)
        model.browse(fixture.customers)
        try await waitUntil { !model.isRunning }
        try await settle(host)
        XCTAssertEqual(model.browseOptions.pageSize, 100)
        let before = await fixture.session.queries.count
        model.browse(fixture.orders)
        XCTAssertFalse(model.isRunning, "The cached table should be restored synchronously")
        try await settle(host)
        let after = await fixture.session.queries.count
        XCTAssertEqual(after, before, "Restoring page size must not call the picker action")
        XCTAssertEqual(model.browseOptions.pageSize, 200)
        XCTAssertEqual(model.appliedBrowseOptions.pageSize, 200)
        XCTAssertEqual(model.browseResult.rows.count, 200)
    }

    private func openNativePopup(_ button: NSPopUpButton) async throws {
        let menu = try XCTUnwrap(button.menu)
        let opened = expectation(description: "Native projection menu opened")
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                              object: menu, queue: nil) { _ in
            MainActor.assumeIsolated {
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        menu.cancelTracking()
                        opened.fulfill()
                    }
                }
                RunLoop.main.add(timer, forMode: .eventTracking)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        button.performClick(nil)
        await fulfillment(of: [opened], timeout: 2)
    }

    private func makeWindow<V: View>(_ view: V) -> (NSHostingView<V>, NSWindow) {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        previousAccessibilityEnabled = NSApplication.shared.accessibilityAttributeValue(attribute) as? Bool ?? false
        NSApplication.shared.accessibilitySetValue(true, forAttribute: attribute)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return (host, window)
    }

    private func closeWindow(_ window: NSWindow) {
        window.close()
        NSApplication.shared.accessibilitySetValue(previousAccessibilityEnabled,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    private func filterField(in view: NSView) throws -> NSTextField {
        try XCTUnwrap(descendants(NSTextField.self, in: view).first {
            !$0.isHiddenOrHasHiddenAncestor && $0.placeholderString == "Filter value"
        })
    }

    private func beginEditing(_ field: NSTextField, window: NSWindow) throws -> NSTextView {
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(field))
        return try XCTUnwrap(field.currentEditor() as? NSTextView)
    }

    private func press(_ label: String, in view: NSView) throws {
        let button = try XCTUnwrap(accessibilityElements(in: view).first {
            accessibilityText($0) == label && $0.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }, accessibilityDump(in: view))
        if let native = button as? NSButton { native.performClick(nil) }
        else {
            let frame = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            let window = try XCTUnwrap(view.window)
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            // macOS 15 native buttons synchronously track until mouse-up inside
            // sendEvent(down). Queue the release first so that loop can finish.
            NSApplication.shared.postEvent(up, atStart: true)
            window.sendEvent(down)
            // Newer SwiftUI buttons return immediately instead of tracking.
            if let pending = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                                             inMode: .default, dequeue: true) {
                window.sendEvent(pending)
            }
        }
    }

    private func accessibilityText(_ object: NSObject) -> String? {
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private func accessibilityElements(in view: NSView) -> [NSObject] {
        var result: [NSObject] = [], visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for name in ["accessibilityChildren", "accessibilityContents"] {
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] {
                    for case let child as NSObject in children { visit(child) }
                }
            }
            if let native = object as? NSView {
                for child in native.subviews where !child.isHiddenOrHasHiddenAncestor { visit(child) }
            }
        }
        visit(view)
        return result
    }

    private func accessibilityDump(in view: NSView) -> String {
        accessibilityElements(in: view).filter { accessibilityText($0) != nil }.prefix(25).map {
            "\(type(of: $0)): \(accessibilityText($0) ?? "<no text>")"
        }.joined(separator: "\n")
    }

    private func descendants<V: NSView>(_ type: V.Type, in view: NSView) -> [V] {
        ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded()
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Data workspace did not settle", file: file, line: line)
                throw UpdateFailure("Data workspace did not settle")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor private final class DataPerformanceFixture {
    let session: DataPerformanceSession
    let defaults: UserDefaults
    let suite: String
    let workspaces: ConnectionWorkspaces
    let orders = DatabaseTable(schema: "shop", name: "orders")
    let customers = DatabaseTable(schema: "shop", name: "customers")
    var model: AppModel { workspaces.active }
    init() throws {
        let suite = "LuckySQLDataPerformance.\(UUID())"
        self.suite = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.defaults = defaults
        let session = DataPerformanceSession()
        self.session = session
        workspaces = ConnectionWorkspaces(defaults: defaults) { store in
            AppModel(profileStore: ProfileStore(defaults: defaults), keychain: DataPerformancePasswords(),
                     driver: DataPerformanceDriver(session: session), workspaceStore: store)
        }
    }
    func connect() async throws {
        model.connect()
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isRunning || model.isLoadingPassword {
            guard ContinuousClock.now < deadline else { throw UpdateFailure("Fixture connection did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isConnected)
    }
    func close() {
        model.disconnect(); workspaces.flush()
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor DataPerformancePasswords: PasswordStoring {
    func password(for profileID: UUID) -> String? { "fixture" }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}

private struct DataPerformanceDriver: DatabaseDriver {
    let session: DataPerformanceSession
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { session }
}

private actor DataPerformanceSession: DatabaseSession {
    var queries: [String] = []
    private var shouldFail = false
    func failNextQuery() { shouldFail = true }
    func query(_ sql: String) throws -> QueryResult {
        queries.append(sql)
        if shouldFail { shouldFail = false; throw UpdateFailure("Fixture filter failed") }
        let start = sql.contains("`id` > 100") || sql.contains("OFFSET 100") ? 101 : 1
        return QueryResult(columns: ["id", "name"], rows: (start..<(start + 501)).map { [String($0), "customer \($0)"] }, elapsed: .zero, message: "Fixture rows")
    }
    func schemas() -> [String] { ["shop"] }
    func tables(in schema: String) -> [String] { ["orders", "customers"] }
    func columns(in table: DatabaseTable) -> [LuckySQL.TableColumn] {
        [LuckySQL.TableColumn(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true, defaultValue: nil, extra: ""),
         LuckySQL.TableColumn(name: "name", dataType: "varchar(100)", isNullable: true, isPrimaryKey: false, defaultValue: nil, extra: "")]
    }
    func close() {}
}
