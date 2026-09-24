import SwiftUI

struct SchemaSidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var deletingProfile: ConnectionProfile?
    @State private var expandedConnections = Set<UUID>()
    @State private var expandedSchemas = Set<String>()
    @State private var search = ""
    @State private var favoritesOnly = false

    var body: some View {
        List {
            ForEach(model.profiles) { profile in
                DisclosureGroup(isExpanded: connectionExpansion(for: profile)) {
                    connectionContents(for: profile)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: connectionIcon(for: profile.id))
                            .foregroundStyle(connectionColor(for: profile.id))
                        Text(profile.name)
                            .lineLimit(1)
                        Spacer()
                        Button { model.beginEditConnection(profile.id) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).help("Edit Connection…").disabled(model.isRunning)
                        if model.connectingProfileID == profile.id {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .contextMenu {
                    Button("Connect") { model.requestConnect(to: profile.id) }.disabled(model.connectedProfileID == profile.id)
                    Button("Edit Connection…") { model.beginEditConnection(profile.id) }.disabled(model.isRunning)
                    Divider()
                    Button("Delete Connection…", role: .destructive) { deletingProfile = profile }.disabled(model.isRunning)
                }
            }
        }
        .navigationTitle("Connections")
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                TextField("Filter loaded tables", text: $search).textFieldStyle(.roundedBorder)
                Button { favoritesOnly.toggle() } label: { Image(systemName: favoritesOnly ? "star.fill" : "star") }
                    .buttonStyle(.borderless).foregroundStyle(favoritesOnly ? .orange : .secondary).help("Show favorite tables")
            }.padding(10).background(.bar)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.beginNewConnection()
            } label: {
                Label("Add Connection…", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .disabled(model.isRunning)
            .padding(10)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await model.loadSchemas()
                        for schema in model.schemas where expandedSchemas.contains(schema.name) {
                            await model.loadTables(in: schema.name)
                        }
                    }
                }
                .disabled(!model.isConnected || model.isRunning)
            }
        }
        .onAppear { expandConnectedProfile(model.connectedProfileID) }
        .onChange(of: model.connectedProfileID) { _, profileID in
            expandConnectedProfile(profileID)
        }
        .confirmationDialog("Delete Connection?", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } })) {
            Button("Delete Connection", role: .destructive) { if let profile = deletingProfile { model.deleteProfile(profile.id) }; deletingProfile = nil }
        } message: { Text("Only the saved connection will be removed. Database data is unchanged.") }
    }

    @ViewBuilder
    private func connectionContents(for profile: ConnectionProfile) -> some View {
        if model.connectingProfileID == profile.id {
            Label("Connecting…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        } else if model.connectedProfileID == profile.id {
            switch model.schemaLoadState {
            case .idle, .loading:
                HStack { ProgressView().controlSize(.small); Text("Loading databases…") }
                    .foregroundStyle(.secondary)
            case .failed(let message):
                metadataError(message) { Task { await model.loadSchemas() } }
            case .loaded where model.schemas.isEmpty:
                Label("No visible databases", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
            case .loaded:
                ForEach(model.schemas) { schema in
                    DisclosureGroup(isExpanded: schemaExpansion(for: schema.name)) {
                        tableContents(for: schema)
                    } label: {
                        Label(schema.name, systemImage: "cylinder")
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
            ForEach(schema.tables.filter { (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) && (!favoritesOnly || model.isFavorite($0)) }) { table in
                DisclosureGroup {
                    tableStructure(for: table)
                } label: {
                    HStack {
                        Button { model.selectTable(table) } label: {
                            Label(table.name, systemImage: model.isFavorite(table) ? "star.fill" : "tablecells")
                                .foregroundStyle(model.selectedTable == table ? Color.accentColor : .primary)
                        }.buttonStyle(.plain).disabled(model.isRunning).help("Preview \(table.id)")
                        Spacer()
                        Button("Browse", systemImage: "arrow.right.circle") { model.browse(table) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .help("Browse rows")
                    }
                }
                .contextMenu {
                    Button("Preview Data") { model.browse(table) }.disabled(model.isRunning)
                    Button("Preview Structure") { model.showStructure(table) }.disabled(model.isRunning)
                    Divider()
                    Button(model.isFavorite(table) ? "Remove Favorite" : "Add Favorite") { model.toggleFavorite(table) }
                    Button("Copy Qualified Name") { model.copy("`\(table.schema.replacingOccurrences(of: "`", with: "``"))`.`\(table.name.replacingOccurrences(of: "`", with: "``"))`") }
                }
            }
        }
    }

    @ViewBuilder
    private func tableStructure(for table: DatabaseTable) -> some View {
        if let columns = model.tableColumns[table.id] {
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
                if model.connectedProfileID != profile.id && model.connectingProfileID != profile.id {
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

    private func connectionIcon(for id: UUID) -> String {
        if model.connectedProfileID == id { return "bolt.horizontal.circle.fill" }
        return "externaldrive.connected.to.line.below"
    }

    private func connectionColor(for id: UUID) -> Color {
        model.connectedProfileID == id ? .green : .secondary
    }

    private func expandConnectedProfile(_ profileID: UUID?) {
        guard let profileID else { return }
        expandedConnections = [profileID]
    }
}
