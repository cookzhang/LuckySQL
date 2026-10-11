import Combine
import Foundation

/// Only metadata that changes the outline's hierarchy belongs to this object.
/// Query results, filter drafts and table selection must not rebuild the List.
@MainActor
final class SchemaSidebarState: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile]
    @Published private(set) var schemas: [DatabaseSchema]
    @Published private(set) var favorites: Set<String>
    @Published private(set) var connectedProfileID: UUID?
    @Published private(set) var connectingProfileID: UUID?
    @Published private(set) var schemaLoadState: MetadataLoadState
    let activity: SchemaSidebarActivity
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel) {
        profiles = model.profiles
        schemas = model.schemas
        favorites = model.favorites
        connectedProfileID = model.connectedProfileID
        connectingProfileID = model.connectingProfileID
        schemaLoadState = model.schemaLoadState
        activity = SchemaSidebarActivity(model: model)
        observe(model.$profiles, at: \.profiles)
        observe(model.$schemas, at: \.schemas)
        observe(model.$favorites, at: \.favorites)
        observe(model.$connectedProfileID, at: \.connectedProfileID)
        observe(model.$connectingProfileID, at: \.connectingProfileID)
        observe(model.$schemaLoadState, at: \.schemaLoadState)
    }

    func isFavorite(_ table: DatabaseTable) -> Bool {
        favorites.contains("\(connectedProfileID?.uuidString ?? "")/\(table.id)")
    }

    private func observe<P: Publisher>(_ publisher: P, at keyPath: ReferenceWritableKeyPath<SchemaSidebarState, P.Output>) where P.Output: Equatable, P.Failure == Never {
        publisher.removeDuplicates().dropFirst().sink { [weak self] value in
            self?[keyPath: keyPath] = value
        }.store(in: &subscriptions)
    }
}

/// Keep operation progress confined to the controls that need to be disabled.
@MainActor
final class SchemaSidebarActivity: ObservableObject {
    @Published private(set) var isRunning: Bool
    private var subscription: AnyCancellable?

    init(model: AppModel) {
        isRunning = model.isRunning
        subscription = model.$isRunning.removeDuplicates().dropFirst().sink { [weak self] in
            self?.isRunning = $0
        }
    }
}

/// Selection changes publish only for the old and new table rows; metadata
/// loaded for another table leaves this row's disclosure state untouched.
@MainActor
final class SchemaTableState: ObservableObject {
    struct Snapshot: Equatable {
        var columns: [TableColumn]?
        var isSelected: Bool
        var isFavorite: Bool
    }

    @Published private(set) var snapshot: Snapshot
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel, table: DatabaseTable) {
        snapshot = Snapshot(columns: model.tableColumns[table.id], isSelected: model.selectedTable == table,
                            isFavorite: model.isFavorite(table))
        observe(model.$selectedTable.map { $0 == table }, at: \.isSelected)
        observe(model.$tableColumns.map { $0[table.id] }, at: \.columns)
        observe(Publishers.CombineLatest(model.$favorites, model.$connectedProfileID).map { favorites, profileID in
            favorites.contains("\(profileID?.uuidString ?? "")/\(table.id)")
        }, at: \.isFavorite)
    }

    private func observe<P: Publisher>(_ publisher: P, at keyPath: WritableKeyPath<Snapshot, P.Output>) where P.Output: Equatable, P.Failure == Never {
        publisher.removeDuplicates().dropFirst().sink { [weak self] value in
            self?.snapshot[keyPath: keyPath] = value
        }.store(in: &subscriptions)
    }
}
