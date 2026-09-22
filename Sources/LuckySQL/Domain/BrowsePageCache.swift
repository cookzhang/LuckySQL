import Foundation

struct BrowsePageKey: Hashable {
    let table: DatabaseTable
    var options: TableBrowseOptions
}

/// Session-scoped, short-lived previews, never a durable copy of database data.
struct BrowsePageCache {
    struct Entry {
        let result: QueryResult
        let sql: String
        let date: Date
        let cost: Int
    }
    private var pages: [BrowsePageKey: Entry] = [:]
    private var order: [BrowsePageKey] = []
    private(set) var bytes = 0
    let byteLimit: Int
    let pageLimit: Int
    let lifetime: TimeInterval
    init(byteLimit: Int = 16 * 1024 * 1024, pageLimit: Int = 8, lifetime: TimeInterval = 30) {
        self.byteLimit = byteLimit; self.pageLimit = pageLimit; self.lifetime = lifetime
    }
    mutating func value(for key: BrowsePageKey, now: Date = Date()) -> Entry? {
        guard let page = pages[key] else { return nil }
        guard now.timeIntervalSince(page.date) < lifetime else { remove(key); return nil }
        order.removeAll { $0 == key }; order.append(key)
        return page
    }
    mutating func insert(_ result: QueryResult, sql: String, for key: BrowsePageKey, now: Date = Date()) {
        remove(key)
        // Wire payload is a lower bound; include array/string and NULL-set overhead.
        let cost = result.retainedBytes + result.rows.reduce(0) { $0 + $1.count * 32 } + result.nullCells.count * 32 + result.columns.count * 64
        guard !result.isTruncated, cost <= byteLimit else { return }
        pages[key] = Entry(result: result, sql: sql, date: now, cost: cost); order.append(key); bytes += cost
        while bytes > byteLimit || order.count > pageLimit { remove(order[0]) }
    }
    private mutating func remove(_ key: BrowsePageKey) {
        if let entry = pages.removeValue(forKey: key) { bytes -= entry.cost }
        order.removeAll { $0 == key }
    }
    mutating func removeAll() { pages = [:]; order = []; bytes = 0 }
}
