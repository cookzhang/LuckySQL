import Foundation

struct SQLExecutionPlan: Sendable {
    let sql: String
    let confirmation: Bool
    let error: String?

    static func prepare(_ source: String, selection: NSRange, all: Bool) -> SQLExecutionPlan {
        let sql = SQLTools.executable(source, selection: selection, all: all)
        let statements = SQLTools.statements(sql)
        if statements.isEmpty { return SQLExecutionPlan(sql: "", confirmation: false, error: nil) }
        if statements.count > 100 { return SQLExecutionPlan(sql: sql, confirmation: false, error: "Run at most 100 statements per batch. Use a streaming import tool for larger scripts.") }
        if SQLTools.tokens(sql).contains(where: { $0.kind == .word && $0.text.uppercased() == "DELIMITER" }) {
            return SQLExecutionPlan(sql: sql, confirmation: false, error: "DELIMITER scripts are not supported yet. Use a dedicated MySQL client for routine scripts.")
        }
        return SQLExecutionPlan(sql: sql, confirmation: SQLTools.requiresConfirmation(sql), error: nil)
    }
}
