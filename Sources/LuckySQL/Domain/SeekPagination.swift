import Foundation

enum SeekPagination {
    /// Lexicographic seek matches MySQL's NULL ordering and retains integer and
    /// decimal precision. String comparison uses the column's server collation.
    static func predicate(columns: [TableColumn], values: [String?], descending: Bool) throws -> String {
        guard !columns.isEmpty, columns.count == values.count else { throw UpdateFailure("Missing pagination identity.") }
        var equal: [String] = [], branches: [String] = []
        for (column, value) in zip(columns, values) {
            let name = try SQLIdentifier.quote(column.name)
            let literal = try value.map { try SQLTypedValue.literal($0, type: column.dataType) }
            let comparison: String
            if let literal {
                comparison = descending ? "(\(name) < \(literal) OR \(name) IS NULL)" : "\(name) > \(literal)"
            } else { comparison = descending ? "FALSE" : "\(name) IS NOT NULL" }
            branches.append("(" + (equal + [comparison]).joined(separator: " AND ") + ")")
            equal.append("\(name) <=> \(literal ?? "NULL")")
        }
        return "(" + branches.joined(separator: " OR ") + ")"
    }
}

enum SQLTypedValue {
    static func literal(_ value: String, type: String) throws -> String {
        let type = type.lowercased()
        if ["tinyint", "smallint", "mediumint", "int", "bigint", "decimal", "numeric", "float", "double", "real", "year"].contains(where: { type.hasPrefix($0) }) {
            guard value.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw UpdateFailure("Invalid numeric value.") }
            return value
        }
        return try SQLStringLiteral.quote(value)
    }
}
