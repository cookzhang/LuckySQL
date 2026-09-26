import AppKit
import SwiftUI

/// Keep native editors, grids and sidebar state alive while switching connections.
/// Only the selected pane is visible; the toolbar and sheets stay in one SwiftUI shell.
struct WorkspaceContentCache: NSViewRepresentable {
    let entries: [ConnectionWorkspaces.Entry]
    let selectedID: UUID
    @Binding var sidebarVisible: Bool

    func makeNSView(context: Context) -> WorkspacePaneContainer { WorkspacePaneContainer() }
    func updateNSView(_ view: WorkspacePaneContainer, context: Context) {
        view.select(selectedID, entries: entries, sidebarVisible: $sidebarVisible)
    }
}

@MainActor final class WorkspacePaneContainer: NSView {
    private struct CachedPane {
        let host: NSHostingView<WorkspacePane>
        weak var responder: NSView?
    }
    private var panes: [UUID: CachedPane] = [:]
    private var selectedID: UUID?

    func select(_ id: UUID, entries: [ConnectionWorkspaces.Entry], sidebarVisible: Binding<Bool>) {
        let liveIDs = Set(entries.map(\.id))
        if selectedID != id, let previous = selectedID, let pane = panes[previous] {
            if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: pane.host) {
                panes[previous]?.responder = responder
                (responder as? CodeTextView)?.dismissCompletions()
                window?.makeFirstResponder(nil)
            }
            pane.host.isHidden = true
        }
        for removed in Set(panes.keys).subtracting(liveIDs) {
            panes.removeValue(forKey: removed)?.host.removeFromSuperview()
        }
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if panes[id] == nil {
            let host = NSHostingView(rootView: WorkspacePane(model: entry.model, sidebarVisible: sidebarVisible))
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            panes[id] = CachedPane(host: host)
        }
        let changed = selectedID != id
        selectedID = id
        guard let pane = panes[id] else { return }
        pane.host.isHidden = false
        if changed, let responder = pane.responder, !responder.isHiddenOrHasHiddenAncestor {
            window?.makeFirstResponder(responder)
        }
    }
}

struct WorkspacePane: View {
    @ObservedObject var model: AppModel
    @Binding var sidebarVisible: Bool

    var body: some View {
        WorkspaceSplitView(sidebarVisible: $sidebarVisible) {
            SchemaSidebar()
        } detail: {
            VStack(spacing: 0) {
                switch model.section {
                case .query:
                    QueryWorkspaceView()
                        .background(SplitLayoutPersistence())
                case .data: TableBrowserView()
                case .structure: StructureView()
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(model.isConnected ? .green : .secondary).frame(width: 6, height: 6)
                    Text(LocalizedStringKey(model.isConnected ? "Connected" : "Disconnected"))
                    if let profile = model.profiles.first(where: { $0.id == model.connectedProfileID }) { Text(profile.host + ":" + String(profile.port)).foregroundStyle(.secondary) }
                    Spacer()
                    if model.isLoadingPassword { ProgressView().controlSize(.mini); Text("Loading saved password…") }
                    else if model.isRunning {
                        ProgressView().controlSize(.mini)
                        Text(model.busyStage.isEmpty ? "Working…" : model.busyStage).lineLimit(1)
                        if let start = model.busySince { Text(start, style: .timer).monospacedDigit() }
                    }
                    else if let notice = model.passwordNotice { Text(notice).lineLimit(1).help(notice).foregroundStyle(.secondary) }
                    else { Text("MySQL workspace").foregroundStyle(.secondary) }
                }.font(.caption).padding(.horizontal, 12).frame(height: 28).background(.bar)
            }
        }
        .environmentObject(model)
    }
}
