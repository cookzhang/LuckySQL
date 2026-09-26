import AppKit
import SwiftUI

/// A warm query tab keeps its native table, columns, selection and scroll position.
/// Keep this host mounted even for empty tabs so switching through one doesn't
/// discard the other results. The cache is bounded and drops obsolete snapshots.
struct QueryDataGrid: NSViewRepresentable {
    let grid: DataGrid
    let tabID: UUID
    let results: [UUID: UUID]

    func makeNSView(context: Context) -> QueryGridContainer { QueryGridContainer() }
    func updateNSView(_ view: QueryGridContainer, context: Context) {
        view.display(grid, tabID: tabID, results: results)
    }
}

@MainActor final class QueryGridContainer: NSView {
    private struct Entry {
        let scroll: NSScrollView
        let coordinator: DataGrid.Coordinator
    }
    private var entries: [UUID: Entry] = [:]
    private var recent: [UUID] = []
    private let capacity = 8

    func display(_ grid: DataGrid, tabID: UUID, results: [UUID: UUID]) {
        for id in Array(entries.keys) {
            guard let entry = entries[id] else { continue }
            if results[id] == nil || (id != tabID && results[id] != entry.coordinator.parent.result.id) {
                remove(id)
            }
        }
        if grid.result.columns.isEmpty {
            remove(tabID)
            for view in subviews { view.removeFromSuperview() }
            return
        }
        if let entry = entries[tabID], entry.coordinator.parent.gridID != grid.gridID { remove(tabID) }
        let entry: Entry
        if let cached = entries[tabID] {
            grid.updateScroll(coordinator: cached.coordinator)
            entry = cached
        } else {
            let coordinator = DataGrid.Coordinator(grid)
            entry = Entry(scroll: grid.makeScroll(coordinator: coordinator), coordinator: coordinator)
            entries[tabID] = entry
        }
        recent.removeAll { $0 == tabID }
        recent.append(tabID)
        if entry.scroll.superview !== self {
            for view in subviews { view.removeFromSuperview() }
            entry.scroll.frame = bounds
            entry.scroll.autoresizingMask = [.width, .height]
            addSubview(entry.scroll)
        }
        while entries.count > capacity, let oldest = recent.first { remove(oldest) }
    }

    private func remove(_ id: UUID) {
        if let entry = entries.removeValue(forKey: id) {
            entry.coordinator.rememberScroll()
            entry.scroll.removeFromSuperview()
        }
        recent.removeAll { $0 == id }
    }
}
