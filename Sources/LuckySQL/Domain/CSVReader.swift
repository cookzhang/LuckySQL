import Foundation

actor CSVReader {
    struct Field: Sendable { let value: String; let quoted: Bool }
    private let handle: FileHandle
    private let separator: UInt8
    private let encoding: String.Encoding
    private var buffer = Data(), position = 0, pushed: UInt8?
    private var first = true
    init(url: URL, separator: UInt8 = 44, latin1: Bool = false) throws {
        handle = try FileHandle(forReadingFrom: url); self.separator = separator; encoding = latin1 ? .isoLatin1 : .utf8
    }
    deinit { try? handle.close() }
    private func byte() throws -> UInt8? {
        if let c = pushed { pushed = nil; return c }
        if position == buffer.count {
            buffer = try handle.read(upToCount: 64 * 1024) ?? Data(); position = 0
            if first { first = false; if buffer.starts(with: [0xef, 0xbb, 0xbf]) { position = 3 } }
            if position == buffer.count { return nil }
        }
        let c = buffer[position]; position += 1; return c
    }
    func next() throws -> [Field]? {
        var row: [Field] = [], value = Data(), quoted = false, inQuotes = false, endedQuote = false, sawByte = false
        func field() throws -> Field {
            guard let text = String(data: value, encoding: encoding) else { throw UpdateFailure("CSV encoding is invalid. Select UTF-8 or Latin-1 explicitly.") }
            return Field(value: text, quoted: quoted)
        }
        while let c = try byte() {
            sawByte = true
            if inQuotes {
                if c == 34 {
                    if let next = try byte() {
                        if next == 34 { value.append(34) }
                        else { inQuotes = false; endedQuote = true; pushed = next }
                    } else { inQuotes = false; endedQuote = true }
                } else { value.append(c) }
            } else if c == separator {
                row.append(try field()); value = Data(); quoted = false; endedQuote = false
            } else if c == 10 || c == 13 {
                if c == 13, let next = try byte(), next != 10 { pushed = next }
                row.append(try field()); return row
            } else if c == 34 && value.isEmpty && !endedQuote {
                inQuotes = true; quoted = true
            } else {
                guard !endedQuote else { throw UpdateFailure("Unexpected bytes after a quoted CSV field.") }
                value.append(c)
            }
            guard value.count <= 16 * 1024 * 1024, row.count < 4096 else { throw UpdateFailure("CSV row exceeds supported field/count limits.") }
        }
        guard !inQuotes else { throw UpdateFailure("CSV ends inside a quoted field.") }
        if sawByte || !row.isEmpty { row.append(try field()); return row }
        return nil
    }
}
