import Foundation

struct TableSearchSnapshot: Equatable, Sendable {
    let schemas: [DatabaseSchema]
    let database: String
    let recent: [DatabaseTable]
}

struct TableSearchIndex: Sendable {
    struct Entry: Sendable { let table: DatabaseTable; let searchText: String }
    let entries: [Entry]
    init(_ snapshot: TableSearchSnapshot) {
        let available = snapshot.schemas.sorted {
            if ($0.name == snapshot.database) != ($1.name == snapshot.database) { return $0.name == snapshot.database }
            return $0.name < $1.name
        }.flatMap(\.tables)
        let availableSet = Set(available), recentSet = Set(snapshot.recent)
        entries = (snapshot.recent.filter { availableSet.contains($0) } + available.filter { !recentSet.contains($0) }).map {
            Entry(table: $0, searchText: Self.normalize($0.id))
        }
    }
    func search(_ query: String) -> [DatabaseTable] {
        let query = Self.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return query.isEmpty ? entries.map(\.table) : entries.filter { $0.searchText.contains(query) }.map(\.table)
    }
    private static func normalize(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
}
