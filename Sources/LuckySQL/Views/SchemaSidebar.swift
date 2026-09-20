import SwiftUI

struct SchemaSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var expandedConnections = Set<UUID>()
    @State private var expandedSchemas = Set<String>()

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
                        if model.connectingProfileID == profile.id {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
        }
        .navigationTitle("Connections")
        .safeAreaInset(edge: .bottom) {
            Button {
                openSettings()
            } label: {
                Label("Add Connection…", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
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
                .disabled(!model.isConnected)
            }
        }
        .onAppear { expandConnectedProfile(model.connectedProfileID) }
        .onChange(of: model.connectedProfileID) { _, profileID in
            expandConnectedProfile(profileID)
        }
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
            ForEach(schema.tables) { table in
                DisclosureGroup {
                    tableStructure(for: table)
                } label: {
                    HStack {
                        Label(table.name, systemImage: "tablecells")
                        Spacer()
                        Button("Browse", systemImage: "arrow.right.circle") { model.browse(table) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .help("Browse rows")
                    }
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
                expandedConnections = [profile.id]
                if model.connectedProfileID != profile.id && model.connectingProfileID != profile.id {
                    expandedSchemas.removeAll()
                    model.connect(to: profile.id)
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
