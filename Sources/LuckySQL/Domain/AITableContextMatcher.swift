import Foundation

/// Prompt text can nominate existing catalog entries, never invent SQL identifiers.
enum AITableContextMatcher {
    static func matchingTables(in catalog: [DatabaseTableSummary], prompt: String, limit: Int = 12) -> [DatabaseTable] {
        guard limit > 0 else { return [] }
        let prompt = normalized(bounded(prompt, bytes: 16 * 1024))
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let mentions = identifierMentions(prompt)
        let terms = semanticTerms(prompt)
        var scored: [(index: Int, score: Int, table: DatabaseTable)] = []
        var seen = Set<DatabaseTable>()
        for (index, summary) in catalog.enumerated() {
            guard seen.insert(summary.table).inserted else { continue }
            let name = normalized(summary.table.name), schema = normalized(summary.table.schema)
            var score = 0
            if mentions.qualified.contains(schema + "\0" + name) { score = 10_000 }
            else if mentions.bare.contains(name) { score = 8_000 }
            else if name.unicodeScalars.contains(where: isHan), containsHanName(name, in: prompt) { score = 7_500 }
            if score == 0 && !terms.isEmpty {
                let comment = normalized(bounded(summary.comment, bytes: 2048))
                let commentTerms = semanticTerms(comment)
                score = terms.intersection(commentTerms).reduce(0) { total, term in
                    total + (term.unicodeScalars.contains(where: isHan) ? 12 : 20)
                }
            }
            if score > 0 { scored.append((index, score, summary.table)) }
        }
        return scored.sorted {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }.prefix(limit).map(\.table)
    }

    private struct Mentions {
        var bare = Set<String>()
        var qualified = Set<String>()
    }
    private enum Token { case identifier(String), dot, separator }

    private static func identifierMentions(_ text: String) -> Mentions {
        let scalars = Array(text.unicodeScalars)
        var tokens: [Token] = [], index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "`" || scalar == "\"" || scalar == "'" {
                let quote = scalar
                var value = String.UnicodeScalarView(), closed = false
                index += 1
                while index < scalars.count {
                    if scalars[index] == quote {
                        if index + 1 < scalars.count && scalars[index + 1] == quote {
                            value.append(quote); index += 2; continue
                        }
                        closed = true; index += 1; break
                    }
                    value.append(scalars[index]); index += 1
                }
                if closed { tokens.append(.identifier(String(value))) }
                else { tokens.append(.separator) }
            } else if isIdentifierScalar(scalar) {
                let start = index, han = isHan(scalar)
                index += 1
                while index < scalars.count && isIdentifierScalar(scalars[index]) && isHan(scalars[index]) == han { index += 1 }
                tokens.append(.identifier(String(String.UnicodeScalarView(scalars[start..<index]))))
            } else {
                if scalar == "." { tokens.append(.dot) }
                else if !CharacterSet.whitespacesAndNewlines.contains(scalar) { tokens.append(.separator) }
                index += 1
            }
        }
        var result = Mentions(), qualifiedIndices = Set<Int>()
        if tokens.count >= 3 {
            for position in 2..<tokens.count {
                if case .identifier(let schema) = tokens[position - 2], case .dot = tokens[position - 1],
                   case .identifier(let name) = tokens[position] {
                    result.qualified.insert(schema + "\0" + name)
                    qualifiedIndices.insert(position - 2); qualifiedIndices.insert(position)
                }
            }
        }
        for (position, token) in tokens.enumerated() where !qualifiedIndices.contains(position) {
            if case .identifier(let name) = token { result.bare.insert(name) }
        }
        return result
    }

    private static let ignoredEnglish: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "count", "data", "database", "for", "from", "get",
        "group", "i", "in", "is", "it", "list", "me", "my", "need", "of", "on", "or", "please", "query", "records",
        "select", "show", "sql", "statistics", "table", "tables", "that", "the", "these", "this", "to", "use", "want", "what", "which", "with"
    ]
    private static let ignoredChinese = [
        "帮我", "查询", "数据", "统计", "这张表", "那张表", "哪个表", "什么表", "是什么", "请问", "请帮", "需要", "相关", "一下",
        "信息", "记录", "主表", "明细", "类型", "状态", "时间", "金额", "用于", "系统", "管理", "字段", "是哪", "什么", "如何", "怎么"
    ]

    /// Bound work independently of catalog size. Bigrams capture Chinese noun
    /// overlap without requiring a language model or a full-text search service.
    private static func semanticTerms(_ text: String) -> Set<String> {
        var text = text
        for ignored in ignoredChinese { text = text.replacingOccurrences(of: ignored, with: " ") }
        var result = Set<String>(), run = String.UnicodeScalarView(), runIsHan = false
        func flush() {
            guard !run.isEmpty, result.count < 128 else { run.removeAll(keepingCapacity: true); return }
            let value = String(run)
            if runIsHan {
                let scalars = Array(run)
                if scalars.count >= 2 {
                    for index in 1..<scalars.count where result.count < 128 {
                        result.insert(String(String.UnicodeScalarView(scalars[(index - 1)...index])))
                    }
                }
            } else if value.utf8.count >= 3 && value.utf8.count <= 64 && !ignoredEnglish.contains(value) {
                result.insert(value)
            }
            run.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            guard result.count < 128 else { break }
            if isIdentifierScalar(scalar) {
                let han = isHan(scalar)
                if !run.isEmpty && han != runIsHan { flush() }
                runIsHan = han; run.append(scalar)
            } else { flush() }
        }
        flush()
        return result
    }

    private static func containsHanName(_ name: String, in text: String) -> Bool {
        guard !name.isEmpty else { return false }
        var remainder = text.startIndex..<text.endIndex
        while let range = text.range(of: name, options: .literal, range: remainder) {
            let before = range.lowerBound == text.startIndex ? nil : text[..<range.lowerBound].unicodeScalars.last
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound...].unicodeScalars.first
            if before.map({ !isIdentifierScalar($0) || isHan($0) }) ?? true,
               after.map({ !isIdentifierScalar($0) || isHan($0) }) ?? true { return true }
            remainder = range.upperBound..<text.endIndex
        }
        return false
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
    }
    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value) ||
        (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
    }
    private static func normalized(_ value: String) -> String { value.lowercased(with: Locale(identifier: "en_US_POSIX")) }
    private static func bounded(_ value: String, bytes: Int) -> String { String(decoding: value.utf8.prefix(bytes), as: UTF8.self) }
}
