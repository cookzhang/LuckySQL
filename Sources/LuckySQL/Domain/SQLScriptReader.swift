import Foundation

actor SQLScriptReader {
    struct Statement: Sendable { let sql: String; let line: Int; let bytesRead: Int }
    private enum State { case normal, quote(UInt8), lineComment, blockComment }
    private let handle: FileHandle
    private var buffer = Data(), bufferIndex = 0
    private var lineBytes: [UInt8] = [], lineIndex = 0
    private var delimiter = Array(";".utf8), state = State.normal
    private var current = Data(), line = 1, startLine = 1, readBytes = 0
    private var noBackslashEscapes = false
    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    func setSQLMode(_ mode: String) { noBackslashEscapes = mode.uppercased().split(separator: ",").contains("NO_BACKSLASH_ESCAPES") }
    private func byte() throws -> UInt8? {
        if bufferIndex == buffer.count {
            buffer = try handle.read(upToCount: 64 * 1024) ?? Data(); bufferIndex = 0
            if buffer.isEmpty { return nil }
        }
        let value = buffer[bufferIndex]; bufferIndex += 1; readBytes += 1; return value
    }
    private func nextLine() throws -> Bool {
        lineBytes = []; lineIndex = 0
        while let c = try byte() {
            lineBytes.append(c)
            if c == 10 { break }
            guard lineBytes.count <= 16 * 1024 * 1024 else { throw UpdateFailure("SQL script line \(line) exceeds the 16 MiB statement limit.") }
        }
        return !lineBytes.isEmpty
    }
    func next() throws -> Statement? {
        while true {
            if lineIndex == lineBytes.count {
                guard try nextLine() else {
                    switch state {
                    case .quote, .blockComment: throw UpdateFailure("Unclosed quote/comment at script line \(startLine).")
                    default: return try finish()
                    }
                }
                if case .normal = state, let text = String(bytes: lineBytes, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("DELIMITER ") {
                    guard !containsSQL(current) else { throw UpdateFailure("DELIMITER must begin a new statement at line \(line).") }
                    let parts = text.split(whereSeparator: \.isWhitespace)
                    guard parts.count == 2, parts[1].utf8.count <= 16, !parts[1].isEmpty else { throw UpdateFailure("Invalid DELIMITER at line \(line).") }
                    delimiter = Array(parts[1].utf8); current = Data(); line += 1; startLine = line; lineIndex = lineBytes.count; continue
                }
            }
            let c = lineBytes[lineIndex]; lineIndex += 1; current.append(c)
            let next = lineIndex < lineBytes.count ? lineBytes[lineIndex] : nil
            switch state {
            case .normal:
                if c == 39 || c == 34 || c == 96 { state = .quote(c) }
                else if c == 35 { state = .lineComment }
                else if c == 45, next == 45, lineIndex + 1 == lineBytes.count || lineBytes[lineIndex + 1] <= 32 { state = .lineComment }
                else if c == 47, next == 42 { state = .blockComment; current.append(42); lineIndex += 1 }
                else if current.count >= delimiter.count, current.suffix(delimiter.count).elementsEqual(delimiter) {
                    current.removeLast(delimiter.count)
                    if let statement = try finish() { return statement }
                }
            case .quote(let quote):
                if c == 92, !noBackslashEscapes, let next { current.append(next); lineIndex += 1; if next == 10 { line += 1 } }
                else if c == quote {
                    if next == quote { current.append(quote); lineIndex += 1 } else { state = .normal }
                }
            case .lineComment: if c == 10 { state = .normal }
            case .blockComment:
                if c == 42, next == 47 { current.append(47); lineIndex += 1; state = .normal }
            }
            if c == 10 { line += 1 }
            guard current.count <= 16 * 1024 * 1024 else { throw UpdateFailure("Statement at line \(startLine) exceeds 16 MiB. Split oversized statements.") }
        }
    }
    private func containsSQL(_ data: Data) -> Bool {
        SQLTools.tokens(String(decoding: data, as: UTF8.self)).contains { $0.kind != .comment && $0.kind != .whitespace }
    }
    private func finish() throws -> Statement? {
        guard !current.isEmpty else { startLine = line; return nil }
        defer { current = Data(); startLine = line }
        guard let sql = String(data: current, encoding: .utf8) else { throw UpdateFailure("Script must be UTF-8; invalid encoding at line \(startLine).") }
        guard containsSQL(current) else { return nil }
        return Statement(sql: sql, line: startLine, bytesRead: readBytes)
    }
}
