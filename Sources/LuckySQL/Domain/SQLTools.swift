import Foundation

enum SQLTokenKind { case keyword, string, identifier, number, comment, word, symbol, whitespace }
struct SQLToken {
    let kind: SQLTokenKind
    let range: NSRange
    let text: String
}

enum SQLTools {
    static let keywords = Set("SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER CROSS ON AS AND OR NOT NULL INSERT INTO VALUES UPDATE SET DELETE CREATE ALTER DROP TRUNCATE TABLE DATABASE SCHEMA USE SHOW ORDER BY GROUP HAVING LIMIT OFFSET DISTINCT UNION ALL CASE WHEN THEN ELSE END IS IN LIKE ASC DESC BETWEEN EXISTS EXPLAIN DESCRIBE WITH RECURSIVE PRIMARY KEY FOREIGN REFERENCES INDEX UNIQUE DEFAULT AUTO_INCREMENT INT BIGINT VARCHAR TEXT DATETIME TIMESTAMP DECIMAL COUNT SUM AVG MIN MAX COALESCE IF IFNULL NOW VERSION BEGIN COMMIT ROLLBACK START TRANSACTION REPLACE VIEW PROCEDURE FUNCTION TRIGGER EVENT GRANT REVOKE ANALYZE OPTIMIZE TRUE FALSE ENGINE CHARACTER COLLATE ADD CHANGE MODIFY RENAME TO CONSTRAINT UNSIGNED ENUM JSON BOOLEAN DATE FLOAT DOUBLE AS SELECT DATABASES FULL COLUMNS STATUS PROCESSLIST VARIABLES".split(separator: " ").map(String.init))

    // A single scanner gives highlighting and statement selection identical
    // quote/comment boundaries, including MySQL escapes and UTF-16 selections.
    static func tokens(_ sql: String) -> [SQLToken] {
        let input = Array(sql.utf16)
        let ns = sql as NSString
        var output: [SQLToken] = []
        var i = 0
        func space(_ c: UInt16) -> Bool { c == 32 || (9...13).contains(c) }
        func word(_ c: UInt16) -> Bool { c >= 128 || (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95 || c == 36 }
        while i < input.count {
            let start = i
            let c = input[i]
            var kind: SQLTokenKind = .symbol
            if space(c) {
                kind = .whitespace; i += 1
                while i < input.count && space(input[i]) { i += 1 }
            } else if c == 39 || c == 34 || c == 96 {
                kind = c == 96 ? .identifier : .string
                i += 1
                while i < input.count {
                    if input[i] == 92 { i = min(i + 2, input.count); continue }
                    if input[i] == c {
                        i += 1
                        if i < input.count && input[i] == c { i += 1; continue }
                        break
                    }
                    i += 1
                }
            } else if c == 35 || (c == 45 && i + 1 < input.count && input[i + 1] == 45 && (i + 2 == input.count || space(input[i + 2]))) {
                kind = .comment
                while i < input.count && input[i] != 10 { i += 1 }
            } else if c == 47 && i + 1 < input.count && input[i + 1] == 42 {
                kind = .comment; i += 2
                while i + 1 < input.count && !(input[i] == 42 && input[i + 1] == 47) { i += 1 }
                i = min(i + 2, input.count)
            } else if word(c) {
                i += 1
                while i < input.count && word(input[i]) { i += 1 }
                let value = ns.substring(with: NSRange(location: start, length: i - start))
                kind = keywords.contains(value.uppercased()) ? .keyword : ((48...57).contains(c) ? .number : .word)
            } else { i += 1 }
            let range = NSRange(location: start, length: i - start)
            output.append(SQLToken(kind: kind, range: range, text: ns.substring(with: range)))
        }
        return output
    }

    static func statements(_ sql: String) -> [(sql: String, range: NSRange)] {
        var result: [(String, NSRange)] = []
        var start = 0
        let ns = sql as NSString
        let scanned = tokens(sql)
        for token in scanned where token.kind == .symbol && token.text == ";" {
            let range = NSRange(location: start, length: NSMaxRange(token.range) - start)
            let value = ns.substring(with: range)
            if containsStatement(value) { result.append((value, range)) }
            start = NSMaxRange(token.range)
        }
        if start < ns.length {
            let range = NSRange(location: start, length: ns.length - start)
            let value = ns.substring(with: range)
            if containsStatement(value) { result.append((value, range)) }
        }
        return result
    }

    private static func containsStatement(_ sql: String) -> Bool {
        tokens(sql).contains { $0.kind != .comment && $0.kind != .whitespace && $0.text != ";" }
    }

    static func executable(_ sql: String, selection: NSRange, all: Bool = false) -> String {
        let ns = sql as NSString
        if all { return sql }
        if selection.length > 0 && NSMaxRange(selection) <= ns.length { return ns.substring(with: selection) }
        let list = statements(sql)
        return list.first { selection.location < NSMaxRange($0.range) }?.sql ?? list.last?.sql ?? ""
    }

    static func requiresConfirmation(_ sql: String) -> Bool {
        // Read-only statements are allowlisted, rather than trying to enumerate
        // every write/admin command (including CTE writes and executable comments).
        statements(sql).contains { statement in
            let tokens = tokens(statement.sql)
            if tokens.contains(where: { $0.kind == .comment && $0.text.hasPrefix("/*!") }) { return true }
            guard let first = tokens.first(where: { $0.kind != .comment && $0.kind != .whitespace }) else { return false }
            let word = first.text.uppercased()
            if !["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN"].contains(word) { return true }
            let words = tokens.filter { $0.kind == .word || $0.kind == .keyword }.map { $0.text.uppercased() }
            return words.contains("OUTFILE") || words.contains("DUMPFILE") || words.contains("ANALYZE")
        }
    }

    static func format(_ sql: String) -> String {
        // Only change keyword case and whitespace; quoted strings and comments
        // are preserved verbatim. Not a full dialect-specific SQL formatter.
        var result = ""
        let lineStarts: Set<String> = ["SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "JOIN", "UNION", "VALUES", "SET"]
        for token in tokens(sql) {
            if token.kind == .whitespace {
                if !result.hasSuffix(" ") && !result.hasSuffix("\n") { result += " " }
            } else if token.kind == .keyword {
                let word = token.text.uppercased()
                if lineStarts.contains(word) && !result.isEmpty && !result.hasSuffix("\n") {
                    result = result.trimmingCharacters(in: .whitespaces) + "\n"
                }
                result += word
            } else {
                result += token.text
                if token.kind == .comment || token.text == ";" { result += "\n" }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ResultExport {
    static func csv(_ result: QueryResult, separator: String = ",") -> String {
        func quote(_ value: String) -> String {
            if value.contains(separator) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }
        return ([result.columns] + result.rows).map { $0.map(quote).joined(separator: separator) }.joined(separator: "\r\n") + "\r\n"
    }

    static func json(_ result: QueryResult) throws -> String {
        // Columns + rows retains duplicate column names and column order.
        let rows: [[Any]] = result.rows.enumerated().map { row, values in
            values.enumerated().map { column, value -> Any in result.isNull(row: row, column: column) ? NSNull() : value }
        }
        let data = try JSONSerialization.data(withJSONObject: ["columns": result.columns, "rows": rows], options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
