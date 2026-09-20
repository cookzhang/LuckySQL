import AppKit
import SwiftUI

/// AppKit virtualizes rows, supports keyboard selection, and lets users resize
/// and reorder columns without constructing a SwiftUI view for every cell.
struct DataGrid: NSViewRepresentable {
    let result: QueryResult
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
        let menu = NSMenu(); menu.delegate = context.coordinator; table.menu = menu
        table.setAccessibilityLabel("Database result grid")
        context.coordinator.table = table
        scroll.documentView = table
        context.coordinator.reload()
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let changed = context.coordinator.parent.result.id != result.id
        context.coordinator.parent = self
        if changed { context.coordinator.reload() }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: DataGrid
        weak var table: NSTableView?
        init(_ parent: DataGrid) { self.parent = parent }
        func reload() {
            guard let table else { return }
            if table.tableColumns.map(\.title) != parent.result.columns {
                for column in table.tableColumns { table.removeTableColumn(column) }
                for (index, name) in parent.result.columns.enumerated() {
                    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                    column.title = name; column.minWidth = 65; column.maxWidth = 1200
                    let sample = parent.result.rows.prefix(30).compactMap { $0.indices.contains(index) ? $0[index].count : nil }.max() ?? 0
                    column.width = CGFloat(min(320, max(100, max(name.count, min(sample, 40)) * 8 + 24)))
                    table.addTableColumn(column)
                }
            }
            table.deselectAll(nil); table.reloadData()
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
            cell.textField?.stringValue = isNull ? "NULL" : value
            cell.textField?.textColor = isNull ? .tertiaryLabelColor : .labelColor
            cell.toolTip = String(value.prefix(1000))
            return cell
        }
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            parent.sort?(tableColumn.title)
        }
        private var cell: (row: Int, column: Int)? {
            guard let table, table.clickedRow >= 0, table.clickedColumn >= 0,
                  let column = Int(table.tableColumns[table.clickedColumn].identifier.rawValue),
                  parent.result.rows.indices.contains(table.clickedRow), parent.result.columns.indices.contains(column) else { return nil }
            return (table.clickedRow, column)
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard cell != nil else { return }
            func item(_ title: String, _ action: Selector) { let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self }
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
            let rows = indices.filter { parent.result.rows.indices.contains($0) }.map { parent.result.rows[$0] }
            copy(ResultExport.csv(QueryResult(columns: parent.result.columns, rows: rows, elapsed: .zero, message: ""), separator: "\t"))
        }
        private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    }
}

private final class CopyableTableView: NSTableView {
    var copyRows: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copyRows?(); return }
        super.keyDown(with: event)
    }
}
