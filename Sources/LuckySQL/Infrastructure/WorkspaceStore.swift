import Foundation

@MainActor
final class WorkspaceStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    struct Draft: Codable { let title: String; let sql: String; let database: String }
    func loadTabs() -> [QueryTab] {
        let drafts: [Draft] = read("workspace.drafts.v1") ?? []
        return drafts.map { QueryTab(title: $0.title, sql: $0.sql, database: $0.database) }
    }
    func saveTabs(_ tabs: [QueryTab]) { write(tabs.map { Draft(title: $0.title, sql: $0.sql, database: $0.database) }, key: "workspace.drafts.v1") }
    func activeIndex() -> Int { defaults.integer(forKey: "workspace.activeIndex.v1") }
    func saveActiveIndex(_ index: Int) { defaults.set(index, forKey: "workspace.activeIndex.v1") }
    func loadHistory() -> [QueryHistoryEntry] { read("workspace.history.v1") ?? [] }
    func saveHistory(_ entries: [QueryHistoryEntry]) { write(Array(entries.prefix(100)), key: "workspace.history.v1") }
    func loadFavorites() -> Set<String> { Set(defaults.stringArray(forKey: "workspace.favorites.v1") ?? []) }
    func saveFavorites(_ values: Set<String>) { defaults.set(Array(values), forKey: "workspace.favorites.v1") }
    private func read<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func write<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
