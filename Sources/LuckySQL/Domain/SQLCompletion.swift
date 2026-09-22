import Foundation

struct SQLCompletionCatalog: Sendable {
    var schemas: [DatabaseSchema] = []
    var columns: [String: [TableColumn]] = [:]
    var database = ""
}

struct SQLCompletionRequest: Sendable {
    var range: NSRange
    var candidates: [String]
    var caret: Int
    var prefix = ""
    var details: [String: String] = [:]
}

enum SQLCompletion {
    struct Reference: Equatable, Sendable {
        let table: DatabaseTable
        let alias: String?
    }

    static func references(_ sql: String, database: String) -> [Reference] {
        let tokens = SQLTools.tokens(sql).filter { $0.kind != .whitespace && $0.kind != .comment }
        var result: [Reference] = []
        for index in tokens.indices where ["FROM", "JOIN", "UPDATE", "INTO"].contains(tokens[index].text.uppercased()) {
            var i = index + 1
            guard i < tokens.count, isIdentifier(tokens[i]) else { continue }
            var schema = database
            var name = unquote(tokens[i].text)
            i += 1
            if i + 1 < tokens.count, tokens[i].text == ".", isIdentifier(tokens[i + 1]) {
                schema = name; name = unquote(tokens[i + 1].text); i += 2
            }
            if i < tokens.count, tokens[i].text.uppercased() == "AS" { i += 1 }
            let alias = i < tokens.count && isIdentifier(tokens[i]) ? unquote(tokens[i].text) : nil
            result.append(Reference(table: DatabaseTable(schema: schema, name: name), alias: alias))
        }
        return result
    }

    static func request(sql: String, caret: Int, catalog: SQLCompletionCatalog, automatic: Bool) -> SQLCompletionRequest? {
        let ns = sql as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        let before = ns.substring(to: caret)
        let scanned = SQLTools.tokens(before)
        if let last = scanned.last, last.kind == .comment || last.kind == .string { return nil }
        var range = NSRange(location: caret, length: 0)
        var prefix = ""
        var quoted = false
        if let token = scanned.last, NSMaxRange(token.range) == caret,
           [.word, .keyword, .identifier].contains(token.kind) {
            range = token.range
            quoted = token.kind == .identifier
            prefix = quoted ? String(token.text.dropFirst()).replacingOccurrences(of: "``", with: "`") : token.text
            if quoted, token.text.count > 1, token.text.hasSuffix("`") { return nil }
        }
        let left = SQLTools.tokens(ns.substring(to: range.location)).filter { $0.kind != .whitespace && $0.kind != .comment }
        let afterDot = left.last?.text == "."
        if automatic && !afterDot && prefix.count < 2 { return nil }
        // Temporarily close an identifier being typed so it does not swallow
        // the FROM/JOIN clauses following the caret during reference discovery.
        let wholeToken = SQLTools.tokens(sql).first { $0.range.location == range.location }
        let hasClosingQuote = quoted && (wholeToken?.text.count ?? 0) > 1 && wholeToken?.text.hasSuffix("`") == true
        let referenceSQL = quoted && !hasClosingQuote ? ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: "`") : sql
        let statement = SQLTools.executable(referenceSQL, selection: NSRange(location: caret, length: 0))
        let refs = references(statement, database: catalog.database)
        var names: [String] = []
        var keywords: [String] = []
        if afterDot, left.count >= 2 {
            let qualifier = unquote(left[left.count - 2].text)
            if let schema = catalog.schemas.first(where: { $0.name.caseInsensitiveCompare(qualifier) == .orderedSame }) {
                names = schema.tables.map(\.name)
            } else {
                let matching = refs.filter { ($0.alias ?? $0.table.name).caseInsensitiveCompare(qualifier) == .orderedSame }
                names = matching.flatMap { catalog.columns[$0.table.id, default: []].map(\.name) }
                if matching.isEmpty {
                    names = catalog.schemas.flatMap(\.tables).filter { $0.name.caseInsensitiveCompare(qualifier) == .orderedSame }
                        .flatMap { catalog.columns[$0.id, default: []].map(\.name) }
                }
            }
        } else {
            let tableContext = ["FROM", "JOIN", "UPDATE", "INTO"].contains(left.last?.text.uppercased() ?? "")
            names = catalog.schemas.map(\.name) + catalog.schemas.filter { catalog.database.isEmpty || $0.name == catalog.database }.flatMap { $0.tables.map(\.name) }
            if !tableContext {
                names += refs.flatMap { catalog.columns[$0.table.id, default: []].map(\.name) }
                keywords = Array(SQLTools.keywords)
            }
        }
        let matching = names.filter { $0.lowercased().hasPrefix(prefix.lowercased()) }.map { name -> String in
            let simple = name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }
            return quoted || !simple || SQLTools.keywords.contains(name.uppercased()) ? "`" + name.replacingOccurrences(of: "`", with: "``") + "`" : name
        }
        let words = keywords.filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
        let candidates = Array(Set(matching)).sorted() + Array(Set(words).subtracting(matching)).sorted()
        guard !candidates.isEmpty else { return nil }
        if let wholeToken, (quoted && hasClosingQuote) || (!quoted && (wholeToken.kind == .word || wholeToken.kind == .keyword)) {
            range = wholeToken.range
        }
        var details: [String: String] = [:]
        for candidate in candidates.prefix(100) {
            let name = candidate.replacingOccurrences(of: "`", with: "")
            if words.contains(candidate) { details[candidate] = "SQL keyword" }
            else if catalog.schemas.contains(where: { $0.name == name }) { details[candidate] = "Database" }
            else if let table = catalog.schemas.flatMap(\.tables).first(where: { $0.name == name }) { details[candidate] = table.schema + " · table" }
            else if let ref = refs.first(where: { catalog.columns[$0.table.id, default: []].contains(where: { $0.name == name }) }),
                    let column = catalog.columns[ref.table.id]?.first(where: { $0.name == name }) { details[candidate] = ref.table.name + " · " + column.dataType }
        }
        return SQLCompletionRequest(range: range, candidates: Array(candidates.prefix(100)), caret: caret, prefix: prefix, details: details)
    }

    private static func isIdentifier(_ token: SQLToken) -> Bool { token.kind == .word || token.kind == .identifier }
    private static func unquote(_ value: String) -> String {
        value.hasPrefix("`") ? String(value.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`") : value
    }
}
