import AppKit
import SwiftUI

/// Table changes pass through an empty loading state. Retain the native grid
/// across that state so matching columns do not need to be built again.
struct BrowseDataGrid: NSViewRepresentable {
    let grid: DataGrid

    func makeNSView(context: Context) -> BrowseGridContainer { BrowseGridContainer() }
    func updateNSView(_ view: BrowseGridContainer, context: Context) { view.display(grid) }
}

@MainActor final class BrowseGridContainer: NSView {
    private struct Entry {
        let scroll: NSScrollView
        let coordinator: DataGrid.Coordinator
    }
    private var entry: Entry?

    func display(_ grid: DataGrid) {
        guard !grid.result.columns.isEmpty else {
            entry?.scroll.isHidden = true
            entry?.coordinator.suspend()
            return
        }
        let current: Entry
        if let entry {
            entry.scroll.frame = bounds
            grid.updateScroll(coordinator: entry.coordinator)
            current = entry
        } else {
            let coordinator = DataGrid.Coordinator(grid)
            current = Entry(scroll: grid.makeScroll(coordinator: coordinator), coordinator: coordinator)
            entry = current
        }
        if current.scroll.superview !== self {
            current.scroll.frame = bounds
            current.scroll.autoresizingMask = [.width, .height]
            addSubview(current.scroll)
        }
        current.scroll.isHidden = false
    }
}
