import Foundation

/// Tolerant completion scopes, built from lexical tokens rather than SQL text
/// matching. Strings/comments never become sources; unfinished groups end at EOF.
struct SQLScope {
    struct Source {
        let alias: String
        let columns: [TableColumn]
        let label: String
    }
    private let tokens: [SQLToken]
    private let catalog: SQLCompletionCatalog
    private var closes: [Int: Int] = [:]
    private var parents: [Int: Int] = [:]
    init(sql: String, catalog: SQLCompletionCatalog) {
        tokens = SQLTools.tokens(sql).filter { $0.kind != .comment && $0.kind != .whitespace }
        self.catalog = catalog
        var stack: [Int] = []
        for i in tokens.indices {
            if tokens[i].text == "(" { parents[i] = stack.last ?? -1; stack.append(i) }
            if tokens[i].text == ")", let open = stack.popLast() { closes[open] = i }
        }
        for open in stack { closes[open] = tokens.count }
    }
    func sources(at caret: Int) -> [Source] {
        let containing = closes.keys.filter { tokens[$0].range.location < caret && (closes[$0] == tokens.count || tokens[closes[$0]!].range.location >= caret) }
            .sorted(by: >)
        let scopes = containing.filter { open in
            let first = open + 1
            return first < tokens.count && ["SELECT", "WITH"].contains(tokens[first].text.uppercased())
        } + [-1]
        var visible: [Source] = [], seen = Set<String>()
        var inherited: [Int: [String: [TableColumn]]] = [:]
        var ctes: [String: [TableColumn]] = [:]
        for open in scopes.reversed() {
            inherited[open] = ctes
            ctes = commonTables(in: (open + 1)..<(closes[open] ?? tokens.count), inherited: ctes, depth: 0)
        }
        for open in scopes {
            let range = (open + 1)..<(closes[open] ?? tokens.count)
            for source in sources(in: range, inherited: inherited[open] ?? [:], depth: 0) where seen.insert(source.alias.lowercased()).inserted { visible.append(source) }
        }
        return visible
    }
    private func identifiers(_ range: Range<Int>) -> [String] {
        range.filter { isIdentifier(tokens[$0]) }.map { unquote(tokens[$0].text) }
    }
    private func commonTables(in range: Range<Int>, inherited: [String: [TableColumn]], depth: Int) -> [String: [TableColumn]] {
        guard depth < 16 else { return inherited }
        var ctes = inherited, i = range.lowerBound
        if i < range.upperBound, tokens[i].text.uppercased() == "WITH" {
            i += 1
            if i < range.upperBound, tokens[i].text.uppercased() == "RECURSIVE" { i += 1 }
            while i < range.upperBound, isIdentifier(tokens[i]) {
                let name = unquote(tokens[i].text); i += 1
                var explicit: [String] = []
                if i < range.upperBound, tokens[i].text == "(", let end = closes[i] {
                    explicit = identifiers((i + 1)..<end); i = end + 1
                }
                guard i + 1 < range.upperBound, tokens[i].text.uppercased() == "AS", tokens[i + 1].text == "(", let end = closes[i + 1] else { break }
                let columns = explicit.isEmpty ? outputs(in: (i + 2)..<end, inherited: ctes, depth: depth + 1) : explicit.map(derived)
                ctes[name.lowercased()] = columns
                i = end + 1
                if i < range.upperBound, tokens[i].text == "," { i += 1 } else { break }
            }
        }
        return ctes
    }
    private func sources(in range: Range<Int>, inherited: [String: [TableColumn]], depth: Int) -> [Source] {
        guard depth < 16 else { return [] }
        let ctes = commonTables(in: range, inherited: inherited, depth: depth)
        var i = range.lowerBound, result: [Source] = [], inFrom = false
        while i < range.upperBound {
            if tokens[i].text == "(", let end = closes[i] { i = end + 1; continue }
            let keyword = tokens[i].text.uppercased()
            if ["WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "UNION", "SET", "VALUES"].contains(keyword) { inFrom = false }
            guard ["FROM", "JOIN", "UPDATE", "INTO"].contains(keyword) || (inFrom && keyword == ",") else { i += 1; continue }
            if keyword == "FROM" { inFrom = true }
            i += 1
            guard i < range.upperBound else { break }
            var columns: [TableColumn] = [], name = "", label = "derived table"
            if tokens[i].text == "(", let end = closes[i] {
                columns = outputs(in: (i + 1)..<end, inherited: ctes, depth: depth + 1); i = end + 1
            } else if isIdentifier(tokens[i]) {
                name = unquote(tokens[i].text); i += 1
                var schema = catalog.database
                var qualified = false
                if i + 1 < range.upperBound, tokens[i].text == ".", isIdentifier(tokens[i + 1]) {
                    schema = name; name = unquote(tokens[i + 1].text); i += 2; qualified = true
                }
                columns = (!qualified ? ctes[name.lowercased()] : nil) ?? catalog.columns[DatabaseTable(schema: schema, name: name).id, default: []]
                label = !qualified && ctes[name.lowercased()] != nil ? "CTE \(name)" : "\(schema).\(name)"
            } else { continue }
            if i < range.upperBound, tokens[i].text.uppercased() == "AS" { i += 1 }
            if i < range.upperBound, isIdentifier(tokens[i]) { name = unquote(tokens[i].text); i += 1 }
            if !name.isEmpty { result.append(Source(alias: name, columns: columns, label: label)) }
        }
        return result
    }
    private func outputs(in range: Range<Int>, inherited: [String: [TableColumn]], depth: Int) -> [TableColumn] {
        guard depth < 16 else { return [] }
        let sources = sources(in: range, inherited: inherited, depth: depth + 1)
        var i = range.lowerBound
        while i < range.upperBound, tokens[i].text.uppercased() != "SELECT" { i += 1 }
        guard i < range.upperBound else { return [] }; i += 1
        if i < range.upperBound, tokens[i].text.uppercased() == "DISTINCT" { i += 1 }
        var groups: [[SQLToken]] = [], current: [SQLToken] = []
        while i < range.upperBound {
            if tokens[i].text.uppercased() == "FROM" { break }
            if tokens[i].text == "," { groups.append(current); current = []; i += 1; continue }
            if tokens[i].text == "(", let end = closes[i] {
                current += Array(tokens[i..<min(end + 1, range.upperBound)]); i = end + 1; continue
            }
            current.append(tokens[i]); i += 1
        }
        if !current.isEmpty { groups.append(current) }
        return groups.flatMap { group -> [TableColumn] in
            if group.count == 1, group[0].text == "*" { return sources.flatMap(\.columns) }
            if group.count == 3, group[1].text == ".", group[2].text == "*" {
                return sources.first { $0.alias.caseInsensitiveCompare(unquote(group[0].text)) == .orderedSame }?.columns ?? []
            }
            if let index = group.lastIndex(where: { $0.text.uppercased() == "AS" }), index + 1 < group.count, isIdentifier(group[index + 1]) {
                return [derived(unquote(group[index + 1].text))]
            }
            if let last = group.last, isIdentifier(last), group.count == 1 || group.count == 3 && group[1].text == "." || group.count > 1 && group[group.count - 2].text != "." {
                return [derived(unquote(last.text))]
            }
            return []
        }
    }
    private func derived(_ name: String) -> TableColumn { TableColumn(name: name, dataType: "derived column", isNullable: true, isPrimaryKey: false, defaultValue: nil, extra: "") }
    private func isIdentifier(_ token: SQLToken) -> Bool { token.kind == .word || token.kind == .identifier }
    private func unquote(_ text: String) -> String { text.hasPrefix("`") && text.hasSuffix("`") ? String(text.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`") : text }
}
