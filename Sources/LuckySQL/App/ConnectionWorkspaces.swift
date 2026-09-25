import SwiftUI
import Combine

/// Each workspace owns its session, cancellation barrier, caches and SQL drafts.
/// Tabs within a workspace deliberately share transactions and temporary tables.
@MainActor final class ConnectionWorkspaces: ObservableObject {
    struct Entry: Identifiable {
        let id: UUID
        let model: AppModel
        let namespace: String
    }
    private struct Saved: Codable, Equatable { let namespace: String; let profileID: UUID? }
    private let defaults: UserDefaults
    private let makeModel: @MainActor (WorkspaceStore) -> AppModel
    private var saveTask: Task<Void, Never>?
    private var lastSaved: [Saved] = []
    private var subscriptions: [UUID: AnyCancellable] = [:]
    var isBusy: Bool { entries.contains { $0.model.isRunning } }
    var hasPendingGridChanges: Bool { entries.contains { !$0.model.gridChanges.isEmpty } }
    @Published var entries: [Entry]
    @Published var selectedID: UUID { didSet { persist() } }
    var active: AppModel { entries.first(where: { $0.id == selectedID })!.model }
    init(defaults: UserDefaults = .standard, makeModel: @escaping @MainActor (WorkspaceStore) -> AppModel = { AppModel(workspaceStore: $0) }) {
        self.defaults = defaults; self.makeModel = makeModel
        let saved = defaults.data(forKey: "connection.workspaces.v1").flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        let restored = saved.isEmpty ? [Saved(namespace: "", profileID: nil)] : saved
        let restoredEntries = restored.map { item in
            let model = makeModel(WorkspaceStore(defaults: defaults, namespace: item.namespace))
            if let id = item.profileID, model.profiles.contains(where: { $0.id == id }) { model.selectProfile(id) }
            return Entry(id: UUID(), model: model, namespace: item.namespace)
        }
        entries = restoredEntries
        selectedID = restoredEntries[min(max(0, defaults.integer(forKey: "connection.workspace.selected")), restoredEntries.count - 1)].id
        for entry in entries { configure(entry.model) }
        persist()
    }
    private func persist() {
        let saved = entries.map { Saved(namespace: $0.namespace, profileID: $0.model.selectedProfileID) }
        if saved != lastSaved, let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: "connection.workspaces.v1"); lastSaved = saved
        }
        defaults.set(entries.firstIndex { $0.id == selectedID } ?? 0, forKey: "connection.workspace.selected")
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }; self?.persist()
        }
    }
    private func configure(_ model: AppModel) {
        if let entry = entries.first(where: { $0.model === model }) {
            subscriptions[entry.id] = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send(); self?.scheduleSave() }
        }
        model.profilesDidChange = { [weak self, weak model] in
            guard let self else { return }
            for entry in self.entries where entry.model !== model { entry.model.reloadProfiles() }
        }
        model.openConnectionWorkspace = { [weak self] profile in self?.open(profile) }
    }
    func open(_ profile: ConnectionProfile) {
        if let entry = entries.first(where: { ($0.model.connectedProfileID ?? $0.model.connectingProfileID ?? $0.model.selectedProfileID) == profile.id }) {
            selectedID = entry.id
            if !entry.model.isConnected && !entry.model.isRunning { entry.model.requestConnect() }
            return
        }
        let model = makeModel(WorkspaceStore(defaults: defaults, namespace: profile.id.uuidString))
        model.selectProfile(profile.id)
        let id = UUID(); entries.append(Entry(id: id, model: model, namespace: profile.id.uuidString)); selectedID = id
        configure(model)
        model.requestConnect()
    }
    func newWorkspace() {
        let id = UUID(), namespace = UUID().uuidString
        let model = makeModel(WorkspaceStore(defaults: defaults, namespace: namespace))
        entries.append(Entry(id: id, model: model, namespace: namespace)); selectedID = id; configure(model)
    }
    func close(_ id: UUID) {
        guard entries.count > 1, let entry = entries.first(where: { $0.id == id }) else { return }
        entry.model.flushWorkspace(); entry.model.disconnect()
        subscriptions.removeValue(forKey: id)
        entries.removeAll { $0.id == id }
        if selectedID == id { selectedID = entries[0].id }
        persist()
    }
    func flush() { saveTask?.cancel(); persist(); for entry in entries { entry.model.flushWorkspace() } }
}

struct ConnectionWorkspacesView: View {
    @ObservedObject var workspaces: ConnectionWorkspaces
    @State private var pendingClose: UUID?
    var body: some View {
        ContentView(workspaceTabs: AnyView(workspaceTabs))
            .environmentObject(workspaces.active).id(workspaces.selectedID)
        .confirmationDialog("Discard staged changes and close workspace?", isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } })) {
            Button("Discard and Close", role: .destructive) { if let id = pendingClose { workspaces.close(id) }; pendingClose = nil }
        } message: { Text("SQL drafts are saved. Uncommitted grid changes in this workspace will be discarded.") }
    }

    private var workspaceTabs: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(workspaces.entries) { entry in
                        WorkspaceConnectionTab(model: entry.model, selected: workspaces.selectedID == entry.id,
                                               select: { workspaces.selectedID = entry.id },
                                               close: { if entry.model.gridChanges.isEmpty { workspaces.close(entry.id) } else { pendingClose = entry.id } }, canClose: workspaces.entries.count > 1)
                    }
                }
            }
            Button { workspaces.newWorkspace() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).padding(.horizontal, 12).help("New Workspace")
                .accessibilityLabel("New Workspace")
        }
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

}
private struct WorkspaceConnectionTab: View {
    @ObservedObject var model: AppModel
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    let canClose: Bool
    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 4) {
                    if model.isRunning { ProgressView().controlSize(.mini) }
                    else { Circle().fill(model.isConnected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6) }
                    Text(model.profiles.first(where: { $0.id == model.connectedProfileID })?.name ?? model.selectedProfile?.name ?? "Workspace").lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 200)

                }
            }.buttonStyle(.plain)
            if canClose { Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).disabled(model.isRunning) }
        }
        .font(.system(size: 12, weight: selected ? .medium : .regular))
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 12).frame(height: 34)
        .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
        .overlay(alignment: .top) { if selected { Color.accentColor.frame(height: 2) } }
        .overlay(alignment: .trailing) { Divider().padding(.vertical, 8) }
        .help(model.connectionLabel)

    }
}
