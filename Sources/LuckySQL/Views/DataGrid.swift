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
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.clipsToBounds = true; scroll.contentView.clipsToBounds = true
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let table = CopyableTableView()
        table.clipsToBounds = true
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.rowHeight = 28; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true; table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.preview)
        table.copyRows = { [weak coordinator = context.coordinator] in coordinator?.copyRows() }
        table.copyCell = { [weak coordinator = context.coordinator] in coordinator?.copyValue() }
        table.previewCell = { [weak coordinator = context.coordinator] in coordinator?.preview() }
        let menu = NSMenu(); menu.delegate = context.coordinator; table.menu = menu
        table.setAccessibilityLabel("Database result grid")
        context.coordinator.table = table
        scroll.documentView = table
        context.coordinator.reload()
        if !gridID.isEmpty { table.autosaveName = "LuckySQL.grid.\(gridID)"; table.autosaveTableColumns = true }
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let old = context.coordinator.parent.result
        let changed = old.id != result.id
        let changedGrid = context.coordinator.parent.gridID != gridID
        let selected = context.coordinator.selectedKeys()
        if changedGrid { context.coordinator.rememberScroll() }
        context.coordinator.parent = self
        if changed || changedGrid { context.coordinator.reload(selection: changedGrid ? [] : selected, changedGrid: changedGrid) }
        if changedGrid, let table = context.coordinator.table {
            table.autosaveTableColumns = false
            table.autosaveName = gridID.isEmpty ? nil : "LuckySQL.grid.\(gridID)"
            table.autosaveTableColumns = !gridID.isEmpty
        }
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.rememberScroll() }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: DataGrid
        weak var table: NSTableView?
        private var columns: [String] = []
        private static var offsets: [String: NSPoint] = [:]
        init(_ parent: DataGrid) { self.parent = parent }
        func rememberScroll() {
            guard !parent.gridID.isEmpty, let scroll = table?.enclosingScrollView else { return }
            if Self.offsets.count > 64 { Self.offsets.removeAll() }
            Self.offsets[parent.gridID] = scroll.contentView.bounds.origin
        }
        func selectedKeys() -> Set<[String]> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { rowKey($0) })
        }
        private func rowKey(_ row: Int) -> [String]? {
            guard parent.result.rows.indices.contains(row) else { return nil }
            let indices = parent.primaryKeys.isEmpty ? Array(parent.result.columns.indices) : parent.primaryKeys.compactMap { parent.result.columns.firstIndex(of: $0) }
            guard !indices.isEmpty, parent.primaryKeys.isEmpty || indices.count == parent.primaryKeys.count else { return nil }
            return indices.flatMap { index -> [String] in
                guard parent.result.rows[row].indices.contains(index) else { return ["missing"] }
                return [parent.result.isNull(row: row, column: index) ? "null" : "value", parent.result.rows[row][index]]
            }
        }
        func reload(selection: Set<[String]> = [], changedGrid: Bool = false) {
            guard let table else { return }
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
            let indices = parent.result.rows.indices.filter { rowKey($0).map(selection.contains) == true }
            table.selectRowIndexes(IndexSet(indices), byExtendingSelection: false)
            if let scroll = table.enclosingScrollView {
                let offset = NSPoint(x: min(restored.x, max(0, table.bounds.width - scroll.contentView.bounds.width)), y: min(restored.y, max(0, table.bounds.height - scroll.contentView.bounds.height)))
                scroll.contentView.scroll(to: offset); scroll.reflectScrolledClipView(scroll.contentView)
            }
            Self.offsets.removeValue(forKey: parent.gridID)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.result.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }), parent.result.rows.indices.contains(row), parent.result.rows[row].indices.contains(column) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            if cell.textField == nil {
                let text = NSTextField(labelWithString: "")
                text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                text.lineBreakMode = .byTruncatingTail
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text); cell.textField = text; cell.identifier = identifier
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            }
            let value = parent.result.rows[row][column]
            let isNull = parent.result.isNull(row: row, column: column)
            cell.textField?.stringValue = isNull ? "NULL" : String(value.prefix(512)) + (value.utf16.count > 512 ? "…" : "")
            cell.textField?.textColor = isNull ? .tertiaryLabelColor : .labelColor
            cell.toolTip = String(value.prefix(1000))
            return cell
        }
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            parent.sort?(tableColumn.title)
        }
        private var cell: (row: Int, column: Int)? {
            guard let table = table as? CopyableTableView else { return nil }
            let row = table.selectedRow >= 0 ? table.selectedRow : table.clickedRow
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
            let rows = indices.filter { parent.result.rows.indices.contains($0) }.map { row in order.map { parent.result.rows[row][$0] } }
            copy(ResultExport.csv(QueryResult(columns: order.map { parent.result.columns[$0] }, rows: rows, elapsed: .zero, message: ""), separator: "\t"))
        }
        private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    }
}

private final class CopyableTableView: NSTableView {
    var copyRows: (() -> Void)?
    var copyCell: (() -> Void)?
    var previewCell: (() -> Void)?
    var activeColumn = 0 { didSet { needsDisplay = true } }
    override func mouseDown(with event: NSEvent) {
        activeColumn = max(0, column(at: convert(event.locationInWindow, from: nil)))
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        activeColumn = max(0, column(at: point))
        let row = row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard selectedRow >= 0, tableColumns.indices.contains(activeColumn) else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: frameOfCell(atColumn: activeColumn, row: selectedRow).insetBy(dx: 1, dy: 1)); path.lineWidth = 2; path.stroke()
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { if event.modifierFlags.contains(.shift) { copyRows?() } else { copyCell?() }; return }
        if event.keyCode == 123 || event.keyCode == 124 { activeColumn = max(0, min(tableColumns.count - 1, activeColumn + (event.keyCode == 123 ? -1 : 1))); scrollColumnToVisible(activeColumn); return }
        if event.keyCode == 36 || event.keyCode == 49 { previewCell?(); return }
        super.keyDown(with: event)
        needsDisplay = true
    }
}
