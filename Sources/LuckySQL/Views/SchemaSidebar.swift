import AppKit
import SwiftUI

struct SchemaSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View { SchemaSidebarHost(model: model) }
}

/// Retain one hosting tree so AppModel's unrelated broadcasts stop at the
/// boundary, while the outline still observes its own metadata and rows.
private struct SchemaSidebarHost: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> SchemaSidebarContainer { SchemaSidebarContainer() }
    func updateNSView(_ view: SchemaSidebarContainer, context: Context) { view.show(model: model) }
}

@MainActor
private final class SchemaSidebarContainer: NSView {
    private var model: AppModel?
    private var host: NSHostingView<SchemaSidebarContent>?

    func show(model: AppModel) {
        guard self.model !== model else { return }
        host?.removeFromSuperview()
        let state = SchemaSidebarState(model: model)
        let host = NSHostingView(rootView: SchemaSidebarContent(model: model, state: state))
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        self.model = model
        self.host = host
    }
}

private struct SchemaSidebarContent: View {
    let model: AppModel
    @ObservedObject var state: SchemaSidebarState
    @State private var deletingProfile: ConnectionProfile?
    @State private var expandedConnections = Set<UUID>()
    @State private var expandedSchemas = Set<String>()
    @State private var search = ""
    @State private var favoritesOnly = false

    var body: some View {
        VStack(spacing: 0) {
            sidebarSearch
            Divider()
            SidebarBusyAppearance(activity: state.activity) {
                List {
                    ForEach(state.profiles) { profile in
                        DisclosureGroup(isExpanded: connectionExpansion(for: profile)) {
                            connectionContents(for: profile)
                        } label: {
                            SchemaConnectionLabel(model: model, profile: profile,
                                                  isConnected: state.connectedProfileID == profile.id,
                                                  isConnecting: state.connectingProfileID == profile.id,
                                                  activity: state.activity)
                                .contextMenu {
                                    SchemaConnectionMenu(model: model, profile: profile,
                                                         isConnected: state.connectedProfileID == profile.id,
                                                         activity: state.activity) { deletingProfile = profile }
                                }
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listRowSeparator(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            SchemaAddConnectionButton(model: model, activity: state.activity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { expandConnectedProfile(state.connectedProfileID) }
        .onChange(of: state.connectedProfileID) { _, profileID in
            expandConnectedProfile(profileID)
        }
        .confirmationDialog("Delete Connection?", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } })) {
            Button("Delete Connection", role: .destructive) { if let profile = deletingProfile { model.deleteProfile(profile.id) }; deletingProfile = nil }
        } message: { Text("Only the saved connection will be removed. Database data is unchanged.") }
    }

    private var sidebarSearch: some View {
        HStack(spacing: 8) {
            TextField("Filter loaded tables", text: $search)
                .textFieldStyle(.roundedBorder)
            Button { favoritesOnly.toggle() } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
            }
            .buttonStyle(.plain)
            .foregroundStyle(favoritesOnly ? .orange : .secondary)
            .help("Show favorite tables")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    @ViewBuilder
    private func connectionContents(for profile: ConnectionProfile) -> some View {
        if state.connectingProfileID == profile.id {
            Label("Connecting…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        } else if state.connectedProfileID == profile.id {
            switch state.schemaLoadState {
            case .idle, .loading:
                HStack { ProgressView().controlSize(.small); Text("Loading databases…") }
                    .foregroundStyle(.secondary)
            case .failed(let message):
                metadataError(message) { Task { await model.loadSchemas() } }
            case .loaded where state.schemas.isEmpty:
                Label("No visible databases", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
            case .loaded:
                ForEach(state.schemas) { schema in
                    DisclosureGroup(isExpanded: schemaExpansion(for: schema.name)) {
                        tableContents(for: schema)
                    } label: {
                        Label(schema.name, systemImage: "cylinder")
                            .lineLimit(1).truncationMode(.middle).help(schema.name)
                    }
                }
            }
        } else {
            Text("Expand to connect")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tableContents(for schema: DatabaseSchema) -> some View {
        switch schema.tableLoadState {
        case .idle:
            Text("Expand to load tables")
                .foregroundStyle(.secondary)
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Loading tables…") }
                .foregroundStyle(.secondary)
        case .failed(let message):
            metadataError(message) { Task { await model.loadTables(in: schema.name, force: true) } }
        case .loaded where schema.tables.isEmpty:
            Text("No tables or views")
                .foregroundStyle(.secondary)
        case .loaded:
            ForEach(schema.tables.filter { (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) && (!favoritesOnly || state.isFavorite($0)) }) { table in
                ObservedSchemaTableRow(model: model, table: table, activity: state.activity)
            }
        }
    }

    private func metadataError(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Unable to load", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Button("Retry", action: retry)
                .buttonStyle(.link)
        }
    }

    private func connectionExpansion(for profile: ConnectionProfile) -> Binding<Bool> {
        Binding {
            expandedConnections.contains(profile.id)
        } set: { expanded in
            if expanded {
                guard !model.isRunning else { return }
                expandedConnections = [profile.id]
                if state.connectedProfileID != profile.id && state.connectingProfileID != profile.id {
                    expandedSchemas.removeAll()
                    model.requestConnect(to: profile.id)
                }
            } else {
                expandedConnections.remove(profile.id)
            }
        }
    }

    private func schemaExpansion(for name: String) -> Binding<Bool> {
        Binding {
            expandedSchemas.contains(name)
        } set: { expanded in
            if expanded {
                expandedSchemas.insert(name)
                Task { await model.loadTables(in: name) }
            } else {
                expandedSchemas.remove(name)
            }
        }
    }

    private func expandConnectedProfile(_ profileID: UUID?) {
        guard let profileID else { return }
        expandedConnections = [profileID]
    }
}

private struct SchemaConnectionLabel: View {
    let model: AppModel
    let profile: ConnectionProfile
    let isConnected: Bool
    let isConnecting: Bool
    @ObservedObject var activity: SchemaSidebarActivity

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isConnected ? "bolt.horizontal.circle.fill" : "externaldrive.connected.to.line.below")
                .foregroundStyle(isConnected ? .green : .secondary)
            Text(profile.name).lineLimit(1)
            Spacer()
            Button { model.beginEditConnection(profile.id) } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain).help("Edit Connection…").disabled(activity.isRunning)
            if isConnecting { ProgressView().controlSize(.small) }
        }
    }
}

private struct SchemaConnectionMenu: View {
    let model: AppModel
    let profile: ConnectionProfile
    let isConnected: Bool
    @ObservedObject var activity: SchemaSidebarActivity
    let delete: () -> Void

    var body: some View {
        Button("Connect") { model.requestConnect(to: profile.id) }.disabled(isConnected)
        Button("Edit Connection…") { model.beginEditConnection(profile.id) }.disabled(activity.isRunning)
        Divider()
        Button("Delete Connection…", role: .destructive, action: delete).disabled(activity.isRunning)
    }
}

/// Indicate progress without broadcasting availability to every disclosure.
/// AppModel guards database actions; local menus and scrolling stay available.
private struct SidebarBusyAppearance<Content: View>: View {
    @ObservedObject var activity: SchemaSidebarActivity
    let content: Content

    init(activity: SchemaSidebarActivity, @ViewBuilder content: () -> Content) {
        self.activity = activity
        self.content = content()
    }

    var body: some View { content.opacity(activity.isRunning ? 0.6 : 1) }
}

private struct SchemaAddConnectionButton: View {
    let model: AppModel
    @ObservedObject var activity: SchemaSidebarActivity

    var body: some View {
        Button { model.beginNewConnection() } label: {
            Label("Add Connection…", systemImage: "plus.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(activity.isRunning)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }
}

private struct ObservedSchemaTableRow: View {
    let model: AppModel
    let table: DatabaseTable
    let activity: SchemaSidebarActivity
    @StateObject private var state: SchemaTableState

    init(model: AppModel, table: DatabaseTable, activity: SchemaSidebarActivity) {
        self.model = model
        self.table = table
        self.activity = activity
        _state = StateObject(wrappedValue: SchemaTableState(model: model, table: table))
    }

    var body: some View {
        SchemaTableRow(model: model, table: table, columns: state.snapshot.columns,
                       isSelected: state.snapshot.isSelected, isFavorite: state.snapshot.isFavorite,
                       isRunning: false, activity: activity)
    }
}

// Keep this disclosure row free of EquatableView: inside the nested List it
// can trigger a SwiftUI assertion when asynchronously loaded tables appear.
struct SchemaTableRow: View {
    let model: AppModel
    let table: DatabaseTable
    let columns: [TableColumn]?
    let isSelected: Bool
    let isFavorite: Bool
    let isRunning: Bool
    var activity: SchemaSidebarActivity? = nil
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded { tableStructure }
        } label: {
            tableButtons
        }
        .contextMenu {
            if let activity {
                ObservedSchemaTableMenu(model: model, table: table, isFavorite: isFavorite, activity: activity)
            } else {
                SchemaTableMenu(model: model, table: table, isFavorite: isFavorite, isRunning: isRunning)
            }
        }
    }

    private var tableButtons: some View {
        HStack {
            Button { model.selectTable(table) } label: {
                Label(table.name, systemImage: isFavorite ? "star.fill" : "tablecells")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(isRunning).help("Preview \(table.id)")
            Button("Browse", systemImage: "arrow.right.circle") { model.browse(table) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Browse rows")
                .disabled(isRunning)
        }
    }

    @ViewBuilder
    private var tableStructure: some View {
        if let columns {
            ForEach(columns) { column in
                HStack(spacing: 5) {
                    Image(systemName: column.isPrimaryKey ? "key.fill" : "rectangle.and.pencil.and.ellipsis")
                        .foregroundStyle(column.isPrimaryKey ? .orange : .secondary)
                    Text(column.name).lineLimit(1)
                    Spacer()
                    Text(column.dataType).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if column.isNullable { Text("NULL").font(.caption2).foregroundStyle(.tertiary) }
                }
                .help(columnHelp(column))
            }
        } else {
            HStack { ProgressView().controlSize(.small); Text("Loading columns…") }
                .task { await model.loadColumns(in: table) }
        }
    }

    private func columnHelp(_ column: TableColumn) -> String {
        var parts = [column.dataType]
        if let value = column.defaultValue { parts.append("default \(value)") }
        if !column.extra.isEmpty { parts.append(column.extra) }
        return parts.joined(separator: " · ")
    }
}

/// Observe availability at the menu, without rebuilding the disclosure row.
private struct ObservedSchemaTableMenu: View {
    let model: AppModel
    let table: DatabaseTable
    let isFavorite: Bool
    @ObservedObject var activity: SchemaSidebarActivity

    var body: some View {
        SchemaTableMenu(model: model, table: table, isFavorite: isFavorite, isRunning: activity.isRunning)
    }
}

private struct SchemaTableMenu: View {
    let model: AppModel
    let table: DatabaseTable
    let isFavorite: Bool
    let isRunning: Bool

    var body: some View {
        Button("Preview Data") { model.browse(table) }.disabled(isRunning)
        Button("Preview Structure") { model.showStructure(table) }.disabled(isRunning)
        Divider()
        Button(isFavorite ? "Remove Favorite" : "Add Favorite") { model.toggleFavorite(table) }
        Button("Copy Qualified Name") { model.copy("`\(table.schema.replacingOccurrences(of: "`", with: "``"))`.`\(table.name.replacingOccurrences(of: "`", with: "``"))`") }
    }
}
