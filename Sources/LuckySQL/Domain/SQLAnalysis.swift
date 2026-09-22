import Foundation

/// Immutable analysis shared by highlighting and completion; all scanning runs off the UI actor.
struct SQLAnalysis: Sendable {
    let sql: String
    let tokens: [SQLToken]
    let lineStarts: [Int]

    func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(1, low)
    }
}

actor SQLAnalysisService {
    static let shared = SQLAnalysisService()
    private var cache: [String: SQLAnalysis] = [:]
    private var order: [String] = []

    func completion(_ sql: String, document: String, caret: Int, catalog: SQLCompletionCatalog, automatic: Bool) -> SQLCompletionRequest? {
        guard !Task.isCancelled else { return nil }
        let analysis = analyze(sql, document: document)
        let separators = analysis.tokens.filter { $0.kind == .symbol && $0.text == ";" }
        let start = separators.last(where: { NSMaxRange($0.range) < caret }).map { NSMaxRange($0.range) } ?? 0
        let end = separators.first(where: { $0.range.location >= caret }).map { NSMaxRange($0.range) } ?? (sql as NSString).length
        guard caret >= start, caret <= end else { return nil }
        let statement = (sql as NSString).substring(with: NSRange(location: start, length: end - start))
        guard var request = SQLCompletion.request(sql: statement, caret: caret - start, catalog: catalog, automatic: automatic) else { return nil }
        request.range.location += start; request.caret = caret
        return request
    }

    func analyze(_ sql: String, document: String) -> SQLAnalysis {
        // Cancelled requests can wait in the actor mailbox while an earlier
        // large document is scanned. Discard them before doing more CPU work.
        guard !Task.isCancelled else { return SQLAnalysis(sql: sql, tokens: [], lineStarts: [0]) }
        if let cached = cache[document], cached.sql == sql { return cached }
        var tokens: [SQLToken]
        if let old = cache[document] {
            let a = Array(old.sql.utf16), b = Array(sql.utf16)
            var common = 0
            while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
            // Restart before the edit, including its preceding token: inserting a quote,
            // slash or dash can change token boundaries arbitrarily far to the right.
            let index = max(0, (old.tokens.firstIndex { NSMaxRange($0.range) >= common } ?? old.tokens.count) - 1)
            let start = index < old.tokens.count ? old.tokens[index].range.location : 0
            tokens = Array(old.tokens.prefix(index))
            tokens += SQLTools.tokens((sql as NSString).substring(from: min(start, b.count))).map {
                SQLToken(kind: $0.kind, range: NSRange(location: $0.range.location + start, length: $0.range.length), text: $0.text)
            }
        } else { tokens = SQLTools.tokens(sql) }
        var lines = [0]
        for (index, unit) in sql.utf16.enumerated() where unit == 10 { lines.append(index + 1) }
        let result = SQLAnalysis(sql: sql, tokens: tokens, lineStarts: lines)
        cache[document] = result
        order.removeAll { $0 == document }; order.append(document)
        while order.count > 8 { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }
}
