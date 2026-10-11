import AppKit
import SwiftUI

/// Native menu items keep column choices out of SwiftUI's closed-control layout.
struct BrowseFilterColumnPicker: NSViewRepresentable {
    let columns: [String]
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setAccessibilityLabel(NSLocalizedString("Column", comment: ""))
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectColumn(_:))
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        button.isEnabled = context.environment.isEnabled
        if coordinator.columnNames != columns {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let allRows = menu.addItem(withTitle: NSLocalizedString("All rows", comment: ""), action: nil, keyEquivalent: "")
            allRows.representedObject = ""
            for name in columns {
                let item = menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
                item.representedObject = name
            }
            button.menu = menu
            coordinator.columnNames = columns
        }
        let index = selection.isEmpty ? 0 : columns.firstIndex(of: selection).map { $0 + 1 }
        if let index { button.selectItem(at: index) }
        else { button.select(nil) }
    }

    final class Coordinator: NSObject {
        var parent: BrowseFilterColumnPicker
        var columnNames: [String]?

        init(_ parent: BrowseFilterColumnPicker) { self.parent = parent }

        @objc func selectColumn(_ sender: NSPopUpButton) {
            guard sender.isEnabled, let name = sender.selectedItem?.representedObject as? String,
                  parent.selection != name else { return }
            parent.selection = name
        }
    }
}

/// Build the potentially large projection menu only when it is opened.
struct BrowseVisibleColumnsMenu: NSViewRepresentable {
    let columns: [TableColumn]
    @Binding var selection: Set<String>
    let apply: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.autoenablesItems = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setAccessibilityLabel(NSLocalizedString("Columns", comment: ""))
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        menu.addItem(withTitle: NSLocalizedString("Columns", comment: ""), action: nil, keyEquivalent: "")
        button.menu = menu
        context.coordinator.button = button
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: BrowseVisibleColumnsMenu
        weak var button: NSPopUpButton?

        init(_ parent: BrowseVisibleColumnsMenu) { self.parent = parent }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            // A pull-down uses its first item as the button title.
            menu.addItem(withTitle: NSLocalizedString("Columns", comment: ""), action: nil, keyEquivalent: "")
            let all = menu.addItem(withTitle: NSLocalizedString("All columns", comment: ""),
                                   action: #selector(selectAll), keyEquivalent: "")
            all.target = self
            for column in parent.columns {
                let item = menu.addItem(withTitle: column.name, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column.name
                item.state = parent.selection.isEmpty || parent.selection.contains(column.name) || column.isPrimaryKey ? .on : .off
                item.isEnabled = !column.isPrimaryKey
            }
        }

        @objc func selectAll() {
            guard button?.isEnabled == true else { return }
            parent.selection = []
            parent.apply()
        }

        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard button?.isEnabled == true, let name = sender.representedObject as? String,
                  let column = parent.columns.first(where: { $0.name == name }), !column.isPrimaryKey else { return }
            var selected = parent.selection
            if selected.isEmpty { selected = Set(parent.columns.map(\.name)) }
            if selected.contains(name) { selected.remove(name) }
            else { selected.insert(name) }
            parent.selection = selected
            parent.apply()
        }
    }
}
