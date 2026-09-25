import Foundation

@MainActor
final class WorkspaceStore {
    private let defaults: UserDefaults
    private let encoder = WorkspaceEncoder()
    private var revision = 0
    private var committed: [String: Int] = [:]
    private var pending: [String: Any] = [:]
    private let namespace: String
    init(defaults: UserDefaults = .standard, namespace: String = "") { self.defaults = defaults; self.namespace = namespace }
    private func scoped(_ key: String) -> String { namespace.isEmpty ? key : "\(namespace).\(key)" }
    struct Draft: Codable, Sendable { let title: String; let sql: String; let database: String }
    func loadTabs() -> [QueryTab] {
        let drafts: [Draft] = read("workspace.drafts.v1") ?? []
        return drafts.map { QueryTab(title: $0.title, sql: $0.sql, database: $0.database) }
    }
    func saveTabs(_ tabs: [QueryTab]) { write(tabs.map { Draft(title: $0.title, sql: $0.sql, database: $0.database) }, key: "workspace.drafts.v1") }
    func activeIndex() -> Int { defaults.integer(forKey: scoped("workspace.activeIndex.v1")) }
    func saveActiveIndex(_ index: Int) { defaults.set(index, forKey: scoped("workspace.activeIndex.v1")) }
    func loadHistory() -> [QueryHistoryEntry] { read("workspace.history.v1") ?? [] }
    func saveHistory(_ entries: [QueryHistoryEntry]) { write(Array(entries.prefix(100)), key: "workspace.history.v1") }
    func loadFavorites() -> Set<String> { Set(defaults.stringArray(forKey: "workspace.favorites.v1") ?? []) }
    func saveFavorites(_ values: Set<String>) { defaults.set(Array(values), forKey: "workspace.favorites.v1") }
    private func read<T: Decodable>(_ key: String) -> T? {
        let key = scoped(key)
        if let value = pending[key] as? T { return value }
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    // Only encoding runs off-main. UserDefaults notifications can enter SwiftUI,
    // so a background write must never be part of a queue the main thread waits on.
    func flush() {
        for (key, value) in encoder.snapshot() { commit(value, key: key) }
    }
    private func commit(_ value: WorkspaceEncoder.Value, key: String) {
        guard value.revision > committed[key, default: 0] else { return }
        committed[key] = value.revision
        defaults.set(value.data, forKey: key)
    }
    private func write<T: Encodable & Sendable>(_ value: T, key: String) {
        let key = scoped(key)
        pending[key] = value
        revision += 1
        encoder.encode(value, key: key, revision: revision) { [weak self] encoded in
            self?.commit(encoded, key: key)
        }
    }
}

/// Mutable state is confined to queue. This queue never writes preferences or
/// waits for main-thread work; flush can safely join its encoding work.
private final class WorkspaceEncoder: @unchecked Sendable {
    struct Value: Sendable { let revision: Int; let data: Data }
    private let queue = DispatchQueue(label: "LuckySQL.workspace.encoding", qos: .utility)
    private var values: [String: Value] = [:]
    func encode<T: Encodable & Sendable>(_ value: T, key: String, revision: Int,
                                        completion: @escaping @MainActor @Sendable (Value) -> Void) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(value) else { return }
            let encoded = Value(revision: revision, data: data)
            values[key] = encoded
            DispatchQueue.main.async { completion(encoded) }
        }
    }
    func snapshot() -> [String: Value] { queue.sync { values } }
}
