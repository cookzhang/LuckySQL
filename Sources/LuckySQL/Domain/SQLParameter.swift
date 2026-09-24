import Foundation

struct SQLParameter: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case text = "Text", integer = "Integer", decimal = "Decimal", boolean = "Boolean", binary = "Hex bytes", null = "NULL" }
    var id = UUID()
    var kind: Kind = .text
    var value = ""
    func literal() throws -> String {
        switch kind {
        case .text: return try SQLStringLiteral.quote(value)
        case .integer:
            guard Int64(value) != nil || UInt64(value) != nil else { throw UpdateFailure("Invalid 64-bit integer.") }
            return value
        case .decimal: return try SQLTypedValue.literal(value, type: "decimal")
        case .boolean:
            guard ["true", "false", "0", "1"].contains(value.lowercased()) else { throw UpdateFailure("Boolean must be true, false, 0 or 1.") }
            return ["true", "1"].contains(value.lowercased()) ? "TRUE" : "FALSE"
        case .binary:
            guard value.count % 2 == 0, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw UpdateFailure("Hex bytes need pairs of hexadecimal digits.") }
            return "X'\(value)'"
        case .null: return "NULL"
        }
    }
    static func count(in sql: String) -> Int { SQLTools.tokens(sql).filter { $0.kind == .symbol && $0.text == "?" }.count }
}

extension DatabaseSession {
    /// Server-side parameter binding through PREPARE/EXECUTE, compatible with
    /// legacy MySQL text-result framing. User values never enter the SQL source.
    func parameterized(_ sql: String, parameters: [SQLParameter], shouldCancel: @Sendable () async -> Bool = { Task.isCancelled }) async throws -> QueryResult {
        guard SQLTools.statements(sql).count == 1, SQLParameter.count(in: sql) == parameters.count else { throw UpdateFailure("Parameter count must match one SQL statement.") }
        let literals = try parameters.map { parameter -> String in
            let literal = try parameter.literal()
            // MySQL 5.6 EXECUTE interprets unsigned integer user variables as
            // signed LONG_LONG. DECIMAL retains all UInt64 digits on that path.
            if parameter.kind == .integer, Int64(parameter.value) == nil { return "CAST(\(literal) AS DECIMAL(20,0))" }
            return literal
        }
        let previewSource = try SQLPreview.query(sql)
        let name = "luckysql_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let variables = literals.indices.map { "@\(name)_\($0)" }
        if await shouldCancel() { throw CancellationError() }
        let source = "@" + name + "_source"
        _ = try await query("SET \(source) = \(try SQLStringLiteral.quote(previewSource));")
        do {
            if await shouldCancel() { throw CancellationError() }
            _ = try await query("PREPARE `\(name)` FROM \(source);")
            if await shouldCancel() { throw CancellationError() }
            if !literals.isEmpty { _ = try await query("SET " + zip(variables, literals).map { "\($0) = \($1)" }.joined(separator: ", ") + ";") }
            if await shouldCancel() { throw CancellationError() }
            let result = try await query("EXECUTE `\(name)`" + (variables.isEmpty ? "" : " USING " + variables.joined(separator: ", ")) + ";")
            _ = try? await query("DEALLOCATE PREPARE `\(name)`;")
            _ = try? await query("SET \(source) = NULL;")
            if !variables.isEmpty { _ = try? await query("SET " + variables.map { "\($0) = NULL" }.joined(separator: ", ") + ";") }
            return result
        } catch {
            _ = try? await query("DEALLOCATE PREPARE `\(name)`;")
            _ = try? await query("SET \(source) = NULL;")
            if !variables.isEmpty { _ = try? await query("SET " + variables.map { "\($0) = NULL" }.joined(separator: ", ") + ";") }
            throw error
        }
    }
}
