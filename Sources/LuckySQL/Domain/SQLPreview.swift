import Foundation

enum SQLPreview {
    static let rowLimit = 1_000

    /// Limit the outer result, not each subquery. A derived-table wrapper would
    /// reject duplicate column names and can change ordering/locking semantics.
    static func query(_ sql: String) throws -> String {
        let tokens = SQLTools.tokens(sql).filter { $0.kind != .whitespace && $0.kind != .comment && $0.text != ";" }
        guard let first = tokens.first else { return sql }
        let firstWord = first.text.uppercased()
        guard ["SELECT", "WITH", "("].contains(firstWord) else { return sql }
        var depth = 0
        var outer: [SQLToken] = []
        for token in tokens {
            if token.text == "(" { depth += 1 }
            else if token.text == ")" { depth -= 1 }
            else if depth == 0 { outer.append(token) }
        }
        // WITH may introduce an UPDATE/DELETE, which must not be changed.
        if firstWord == "WITH" {
            guard let command = outer.first(where: { ["SELECT", "UPDATE", "DELETE", "INSERT", "REPLACE"].contains($0.text.uppercased()) }),
                  command.text.uppercased() == "SELECT" else { return sql }
        }
        if firstWord == "(", !tokens.contains(where: { $0.text.uppercased() == "SELECT" }) { return sql }
        // SELECT INTO has side effects and does not return a preview result.
        if outer.contains(where: { $0.kind == .keyword && $0.text.uppercased() == "INTO" }) { return sql }
        if SQLTools.tokens(sql).contains(where: { $0.kind == .comment && $0.text.hasPrefix("/*!") }) {
            throw PreviewError.unsupportedLimit
        }
        if let index = outer.indices.first(where: { outer[$0].kind == .keyword && outer[$0].text.uppercased() == "LIMIT" && ($0 == 0 || outer[$0 - 1].text != ".") }) {
            var countIndex = index + 1
            if countIndex + 1 < outer.count, outer[countIndex + 1].text == "," { countIndex += 2 }
            guard countIndex < outer.count, outer[countIndex].kind == .number,
                  let count = UInt64(outer[countIndex].text) else { throw PreviewError.unsupportedLimit }
            if count <= rowLimit { return sql }
            return (sql as NSString).replacingCharacters(in: outer[countIndex].range, with: String(rowLimit))
        }
        let suffixIndex = outer.indices.first { index in
            let token = outer[index]
            return token.kind != .identifier && ["FOR", "LOCK", "PROCEDURE"].contains(token.text.uppercased()) && (index == 0 || outer[index - 1].text != ".")
        }
        let suffix = suffixIndex.map { outer[$0] }
        let position = suffix?.range.location ?? NSMaxRange(tokens.last!.range)
        return (sql as NSString).replacingCharacters(in: NSRange(location: position, length: 0), with: "\nLIMIT \(rowLimit)\n")
    }

    enum PreviewError: LocalizedError {
        case unsupportedLimit
        var errorDescription: String? { "Cannot safely apply the 1,000-row preview limit. Use a literal outer LIMIT and remove executable SQL comments." }
    }
}
