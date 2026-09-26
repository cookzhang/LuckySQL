import AppKit
import SwiftUI

/// AppKit virtualizes rows, supports keyboard selection, and lets users resize
/// and reorder columns without constructing a SwiftUI view for every cell.
struct DataGrid: NSViewRepresentable {
    let result: QueryResult
    var gridID = ""
    var primaryKeys: [String] = []
    var inspect: ((Int, Int) -> Void)?
    var sort: ((String) -> Void)?
    var quickFilter: ((Int, Int) -> Void)?
    var delete: ((Int) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView { makeScroll(coordinator: context.coordinator) }
    func makeScroll(coordinator: Coordinator) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.clipsToBounds = true; scroll.contentView.clipsToBounds = true
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let table = CopyableTableView()
        table.clipsToBounds = true
        table.delegate = coordinator; table.dataSource = coordinator
        table.rowHeight = 22; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true; table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.target = coordinator; table.doubleAction = #selector(Coordinator.preview)
        table.copyRows = { [weak coordinator] in coordinator?.copyRows() }
        table.copyCell = { [weak coordinator] in coordinator?.copyValue() }
        table.previewCell = { [weak coordinator] in coordinator?.preview() }
        let menu = NSMenu(); menu.delegate = coordinator; table.menu = menu
        table.setAccessibilityLabel("Database result grid")
        coordinator.table = table
        scroll.documentView = table
        coordinator.observeViewport(scroll.contentView)
        coordinator.reload()
        if !gridID.isEmpty { table.autosaveName = "LuckySQL.grid.\(gridID)"; table.autosaveTableColumns = true }
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) { updateScroll(coordinator: context.coordinator) }
    func updateScroll(coordinator: Coordinator) {
        let old = coordinator.parent.result
        let changed = old.id != result.id
        let changedGrid = coordinator.parent.gridID != gridID
        let selected = changed && !changedGrid ? coordinator.selectedKeys() : []
        if changedGrid { coordinator.rememberScroll() }
        coordinator.parent = self
        if changed || changedGrid { coordinator.reload(selection: changedGrid ? [] : selected, changedGrid: changedGrid) }
        if changedGrid, let table = coordinator.table {
            table.autosaveTableColumns = false
            table.autosaveName = gridID.isEmpty ? nil : "LuckySQL.grid.\(gridID)"
            table.autosaveTableColumns = !gridID.isEmpty
        }
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.rememberScroll() }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: DataGrid
        weak var table: NSTableView?
        private(set) var reloadCount = 0
        private(set) var cellRequests = 0
        private(set) var visibleCellRequests = 0
        private var viewportObserver: NSObjectProtocol?
        private var visibleColumns = IndexSet()
        private var viewportScheduled = false
        deinit { if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) } }
        func observeViewport(_ clip: NSClipView) {
            clip.postsBoundsChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.scheduleViewportRefresh() }
        }
        private func scheduleViewportRefresh() {
            guard !viewportScheduled else { return }; viewportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.viewportScheduled = false
                self.refreshVisibleColumns()
            }
        }
        private func columnsInViewport(_ table: NSTableView) -> IndexSet {
            IndexSet(table.tableColumns.indices.filter { index in
                let rect = table.rect(ofColumn: index), visible = table.visibleRect
                return rect.maxX >= visible.minX && rect.minX <= visible.maxX
            })
        }
        private func refreshVisibleColumns() {
            guard let table else { return }
            let next = columnsInViewport(table), added = next.subtracting(visibleColumns)
            visibleColumns = next
            let rows = table.rows(in: table.visibleRect)
            if !added.isEmpty, rows.location != NSNotFound, rows.length > 0 {
                table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<min(table.numberOfRows, NSMaxRange(rows))), columnIndexes: added)
            }
        }
        func tableViewColumnDidMove(_ notification: Notification) { table?.headerView?.needsDisplay = true; visibleColumns = []; scheduleViewportRefresh() }
        func tableViewColumnDidResize(_ notification: Notification) { visibleColumns = []; scheduleViewportRefresh() }
        private var columns: [String] = []
        private var keyIndices: [Int] = []
        private var displayCache: [CellAddress: (text: String, tooltip: String)] = [:]
        private var copyTask: Task<Void, Never>?
        private static var offsets: [String: NSPoint] = [:]
        init(_ parent: DataGrid) { self.parent = parent }
        func rememberScroll() {
            guard !parent.gridID.isEmpty, let scroll = table?.enclosingScrollView else { return }
            if Self.offsets.count > 64 { Self.offsets.removeAll() }
            Self.offsets[parent.gridID] = scroll.contentView.bounds.origin
        }
        func selectedKeys() -> [[String]] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { rowKey($0) }
        }
        private func rowKey(_ row: Int) -> [String]? {
            guard parent.result.rows.indices.contains(row) else { return nil }
            let indices = keyIndices
            guard !indices.isEmpty, parent.primaryKeys.isEmpty || indices.count == parent.primaryKeys.count else { return nil }
            return indices.flatMap { index -> [String] in
                guard parent.result.rows[row].indices.contains(index) else { return ["missing"] }
                return [parent.result.isNull(row: row, column: index) ? "null" : "value", parent.result.rows[row][index]]
            }
        }
        func reload(selection: [[String]] = [], changedGrid: Bool = false) {
            let interval = PerformanceTrace.signposter.beginInterval("Grid reload")
            defer { PerformanceTrace.signposter.endInterval("Grid reload", interval) }
            guard let table else { return }
            reloadCount += 1
            displayCache.removeAll(keepingCapacity: true)
            keyIndices = parent.primaryKeys.isEmpty ? Array(parent.result.columns.indices) : parent.primaryKeys.compactMap { parent.result.columns.firstIndex(of: $0) }
            let origin = changedGrid ? NSPoint.zero : table.enclosingScrollView?.contentView.bounds.origin ?? .zero
            let restored = Self.offsets[parent.gridID] ?? origin
            if columns != parent.result.columns {
                columns = parent.result.columns
                for column in table.tableColumns { table.removeTableColumn(column) }
                for (index, name) in parent.result.columns.enumerated() {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                    column.title = name; column.minWidth = 65; column.maxWidth = 1200
                    let sample = parent.result.rows.prefix(30).compactMap { $0.indices.contains(index) ? $0[index].prefix(40).count : nil }.max() ?? 0
                    column.width = CGFloat(min(320, max(100, max(name.count, min(sample, 40)) * 8 + 24)))
                    table.addTableColumn(column)
                }
            }
            table.reloadData()
            visibleColumns = columnsInViewport(table)
            let indices = selection.isEmpty ? [] : parent.result.rows.indices.filter { rowKey($0).map { key in selection.contains { $0 == key } } == true }
            table.selectRowIndexes(IndexSet(indices), byExtendingSelection: false)
            (table as? CopyableTableView)?.activeRow = table.selectedRow
            if let scroll = table.enclosingScrollView {
                let offset = NSPoint(x: min(restored.x, max(0, table.bounds.width - scroll.contentView.bounds.width)), y: min(restored.y, max(0, table.bounds.height - scroll.contentView.bounds.height)))
                scroll.contentView.scroll(to: offset); scroll.reflectScrolledClipView(scroll.contentView)
            }
            Self.offsets.removeValue(forKey: parent.gridID)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.result.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            cellRequests += 1
            guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }), parent.result.rows.indices.contains(row), parent.result.rows[row].indices.contains(column) else { return nil }
            // NSTableView virtualizes rows but asks for all 40+ columns even
            // when only a few are visible. Avoid offscreen TextKit cell layout.
            guard let tableColumn, let displayIndex = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
            let rect = tableView.rect(ofColumn: displayIndex), visible = tableView.visibleRect
            guard rect.maxX >= visible.minX, rect.minX <= visible.maxX else { return nil }
            visibleCellRequests += 1
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            if cell.textField == nil {
                let text = NSTextField(labelWithString: "")
                text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                text.lineBreakMode = .byTruncatingTail
                text.maximumNumberOfLines = 1
                text.usesSingleLineMode = true
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text); cell.textField = text; cell.identifier = identifier
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            let value = parent.result.rows[row][column]
            let isNull = parent.result.isNull(row: row, column: column)
            let address = CellAddress(row: row, column: column)
            let display: (text: String, tooltip: String)
            if let cached = displayCache[address] { display = cached }
            else {
                display = CellDisplayPreview.make(value, isNull: isNull)
                if displayCache.count >= 2048 { displayCache.removeAll(keepingCapacity: true) }
                displayCache[address] = display
            }
            cell.textField?.stringValue = display.text
            cell.textField?.textColor = isNull ? .tertiaryLabelColor : .labelColor
            cell.toolTip = display.tooltip
            return cell
        }
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            parent.sort?(tableColumn.title)
        }
        private var cell: (row: Int, column: Int)? {
            guard let table = table as? CopyableTableView else { return nil }
            let row = table.selectedRowIndexes.contains(table.activeRow) ? table.activeRow : table.selectedRow
            let visibleColumn = max(0, min(table.activeColumn, table.tableColumns.count - 1))
            guard parent.result.rows.indices.contains(row), table.tableColumns.indices.contains(visibleColumn),
                  let column = Int(table.tableColumns[visibleColumn].identifier.rawValue), parent.result.columns.indices.contains(column) else { return nil }
            return (row, column)
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard cell != nil else { return }
            func item(_ title: String, _ action: Selector) { let item = menu.addItem(withTitle: NSLocalizedString(title, comment: ""), action: action, keyEquivalent: ""); item.target = self }
            if parent.inspect != nil { item("Preview / Edit Value…", #selector(preview)) }
            item("Copy Value", #selector(copyValue)); item("Copy Selected Rows (TSV)", #selector(copyRows))
            if parent.quickFilter != nil { item("Filter by This Value", #selector(filter)) }
            if parent.delete != nil { menu.addItem(.separator()); item("Delete Row…", #selector(deleteRow)) }
        }
        @objc func preview() { if let cell { parent.inspect?(cell.row, cell.column) } }
        @objc func filter() { if let cell { parent.quickFilter?(cell.row, cell.column) } }
        @objc func deleteRow() { if let cell { parent.delete?(cell.row) } }
        @objc func copyValue() { if let cell { copy(parent.result.rows[cell.row][cell.column]) } }
        @objc func copyRows() {
            guard let table else { return }
            let indices = table.selectedRowIndexes.isEmpty ? IndexSet(integer: max(0, table.clickedRow)) : table.selectedRowIndexes
            let order = table.tableColumns.compactMap { Int($0.identifier.rawValue) }
            let snapshot = parent.result
            copyTask?.cancel()
            let changeCount = NSPasteboard.general.changeCount
            copyTask = Task { [weak self] in
                let text = await Task.detached(priority: .userInitiated) {
                    let rows = indices.filter { snapshot.rows.indices.contains($0) }.map { row in order.map { snapshot.rows[row][$0] } }
                    return ResultExport.csv(QueryResult(columns: order.map { snapshot.columns[$0] }, rows: rows, elapsed: .zero, message: ""), separator: "\t")
                }.value
                guard !Task.isCancelled, NSPasteboard.general.changeCount == changeCount else { return }
                self?.copy(text)
            }
        }
        private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    }
}

enum CellDisplayPreview {
    /// Bound UTF-16 work even when one grapheme contains thousands of combining
    /// marks. A Character-count limit alone cannot protect native cell layout.
    static func make(_ value: String, isNull: Bool) -> (text: String, tooltip: String) {
        let units = Array(value.utf16.prefix(1001))
        func prefix(_ limit: Int) -> String {
            var end = min(limit, units.count)
            if end > 0, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            return String(decoding: units[..<end], as: UTF16.self) + (units.count > limit ? "…" : "")
        }
        let singleLine = prefix(512).replacingOccurrences(of: "\r\n", with: " ↵ ")
            .replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: " ↵ ")
            .replacingOccurrences(of: "\t", with: " ⇥ ")
        return (isNull ? "NULL" : singleLine, prefix(1000))
    }
}

final class CopyableTableView: NSTableView {
    var copyRows: (() -> Void)?
    var copyCell: (() -> Void)?
    var previewCell: (() -> Void)?
    var activeColumn = 0 { didSet { invalidateCell(column: oldValue, row: activeRow); invalidateCell(column: activeColumn, row: activeRow) } }
    var activeRow = -1 { didSet { invalidateCell(column: activeColumn, row: oldValue); invalidateCell(column: activeColumn, row: activeRow) } }
    private func invalidateCell(column: Int, row: Int) {
        guard tableColumns.indices.contains(column), row >= 0, row < numberOfRows else { return }
        setNeedsDisplay(frameOfCell(atColumn: column, row: row))
    }
    override func mouseDown(with event: NSEvent) {
        activeColumn = max(0, column(at: convert(event.locationInWindow, from: nil)))
        activeRow = row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        activeColumn = max(0, column(at: point))
        let row = row(at: point)
        activeRow = row
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let row = selectedRowIndexes.contains(activeRow) ? activeRow : selectedRow
        guard row >= 0, tableColumns.indices.contains(activeColumn) else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: frameOfCell(atColumn: activeColumn, row: row).insetBy(dx: 1, dy: 1)); path.lineWidth = 2; path.stroke()
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { if event.modifierFlags.contains(.shift) { copyRows?() } else { copyCell?() }; return }
        if event.keyCode == 123 || event.keyCode == 124 { activeColumn = max(0, min(tableColumns.count - 1, activeColumn + (event.keyCode == 123 ? -1 : 1))); scrollColumnToVisible(activeColumn); return }
        if event.keyCode == 36 || event.keyCode == 49 { previewCell?(); return }
        super.keyDown(with: event)
        activeRow = selectedRow
    }
}
