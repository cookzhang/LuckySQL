import Foundation

/// Immutable analysis shared by highlighting and completion; all scanning runs off the UI actor.
struct SQLAnalysis: Sendable {
    let sql: String
    let tokens: [SQLToken]
    let lineStarts: [Int]
    var scannedUTF16 = 0

    func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(1, low)
    }
}

/// A coalesced edit in AppKit UTF-16 coordinates, relative to the original text.
struct SQLTextEdit: Sendable {
    let original: String
    var range: NSRange
    var replacementLength: Int
    mutating func append(range next: NSRange, replacementLength count: Int) {
        let delta = replacementLength - range.length
        let insertedEnd = range.location + replacementLength
        let start = next.location <= range.location ? next.location : next.location >= insertedEnd ? next.location - delta : range.location
        let end = NSMaxRange(next) <= range.location ? NSMaxRange(next) : NSMaxRange(next) >= insertedEnd ? NSMaxRange(next) - delta : NSMaxRange(range)
        let merged = NSUnionRange(range, NSRange(location: start, length: max(0, end - start)))
        replacementLength = merged.length + delta + count - next.length
        range = merged
    }
}

extension Array {
    func partitionIndex(_ predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high { let mid = (low + high) / 2; if predicate(self[mid]) { high = mid } else { low = mid + 1 } }
        return low
    }
}

actor SQLAnalysisService {
    static let shared = SQLAnalysisService()
    private var cache: [String: SQLAnalysis] = [:]
    private var order: [String] = []

    func completion(_ sql: String, document: String, caret: Int, catalog: SQLCompletionCatalog, automatic: Bool) -> SQLCompletionRequest? {
        guard !Task.isCancelled else { return nil }
        let analysis = analyze(sql, document: document)
        guard !Task.isCancelled else { return nil }
        let pivot = analysis.tokens.partitionIndex { NSMaxRange($0.range) >= caret }
        let start = analysis.tokens[..<pivot].last { $0.kind == .symbol && $0.text == ";" }.map { NSMaxRange($0.range) } ?? 0
        let end = analysis.tokens[pivot...].first { $0.range.location >= caret && $0.kind == .symbol && $0.text == ";" }.map { NSMaxRange($0.range) } ?? (sql as NSString).length
        guard caret >= start, caret <= end else { return nil }
        let statement = (sql as NSString).substring(with: NSRange(location: start, length: end - start))
        guard var request = SQLCompletion.request(sql: statement, caret: caret - start, catalog: catalog, automatic: automatic) else { return nil }
        request.range.location += start; request.caret = caret
        return request
    }

    func analyze(_ sql: String, document: String, edit hint: SQLTextEdit? = nil) -> SQLAnalysis {
        let interval = PerformanceTrace.signposter.beginInterval("SQL analysis")
        defer { PerformanceTrace.signposter.endInterval("SQL analysis", interval) }
        // Cancelled requests can wait in the actor mailbox while an earlier
        // large document is scanned. Discard them before doing more CPU work.
        guard !Task.isCancelled else { return SQLAnalysis(sql: sql, tokens: [], lineStarts: [0]) }
        if let cached = cache[document], (cached.sql as NSString).isEqual(to: sql) { return cached }
        var tokens: [SQLToken], lines: [Int], scanned = 0
        if let old = cache[document] {
            let edit: SQLTextEdit
            if let hint, (hint.original as NSString).isEqual(to: old.sql),
               hint.range.location >= 0, NSMaxRange(hint.range) <= (old.sql as NSString).length,
               (old.sql as NSString).length - hint.range.length + hint.replacementLength == (sql as NSString).length {
                edit = hint
            } else {
                // External replacement, or a request overtook a debounced edit.
                let a = Array(old.sql.utf16), b = Array(sql.utf16)
                var prefix = 0, suffix = 0
                while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
                while suffix < min(a.count, b.count) - prefix, a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
                edit = SQLTextEdit(original: old.sql, range: NSRange(location: prefix, length: a.count - prefix - suffix), replacementLength: b.count - prefix - suffix)
            }
            let delta = edit.replacementLength - edit.range.length
            let index = max(0, old.tokens.partitionIndex { NSMaxRange($0.range) >= edit.range.location } - 2)
            let start = index < old.tokens.count ? old.tokens[index].range.location : 0
            var reuse = old.tokens.count
            let changed = SQLTools.tokens(sql, from: start) { token in
                if Task.isCancelled { return true }
                guard token.range.location >= edit.range.location + edit.replacementLength else { return false }
                let position = token.range.location - delta
                let candidate = old.tokens.partitionIndex { $0.range.location >= position }
                guard candidate < old.tokens.count else { return false }
                let previous = old.tokens[candidate]
                guard previous.range.location == position, previous.kind == token.kind, previous.text == token.text else { return false }
                reuse = candidate + 1
                return true
            }
            scanned = (changed.last.map { NSMaxRange($0.range) } ?? start) - start
            tokens = Array(old.tokens.prefix(index))
            tokens.append(contentsOf: changed)
            if delta == 0 { tokens.append(contentsOf: old.tokens[reuse...]) }
            else { tokens.append(contentsOf: old.tokens[reuse...].map { SQLToken(kind: $0.kind, range: NSRange(location: $0.range.location + delta, length: $0.range.length), text: $0.text) }) }
            let first = old.lineStarts.partitionIndex { $0 > edit.range.location }
            let last = old.lineStarts.partitionIndex { $0 > NSMaxRange(edit.range) }
            lines = Array(old.lineStarts[..<first])
            let replacement = (sql as NSString).substring(with: NSRange(location: edit.range.location, length: edit.replacementLength))
            for (offset, unit) in replacement.utf16.enumerated() where unit == 10 { lines.append(edit.range.location + offset + 1) }
            lines.append(contentsOf: old.lineStarts[last...].map { $0 + delta })
        } else {
            tokens = SQLTools.tokens(sql, stopAfter: { _ in Task.isCancelled })
            scanned = (sql as NSString).length; lines = [0]
            for (index, unit) in sql.utf16.enumerated() where unit == 10 { lines.append(index + 1) }
        }
        let result = SQLAnalysis(sql: sql, tokens: tokens, lineStarts: lines, scannedUTF16: scanned)
        guard !Task.isCancelled else { return result }
        cache[document] = result
        order.removeAll { $0 == document }; order.append(document)
        func cost() -> Int { cache.values.reduce(0) { $0 + ($1.sql as NSString).length * 2 + $1.tokens.count * 64 + $1.lineStarts.count * 8 } }
        while order.count > 1 && (order.count > 8 || cost() > 96 * 1024 * 1024) { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }
}
