import Foundation
import MySQLNIO

enum TransferFormat: String, CaseIterable, Sendable { case csv = "CSV", json = "JSON", sql = "SQL" }

/// Invoked serially by the database event loop. Writes bounded chunks directly;
/// no row array grows with table size. Slow disk writes apply backpressure.
final class StreamingExport: @unchecked Sendable {
    private let handle: FileHandle
    private let format: TransferFormat
    private let target: DatabaseTable
    private var pending = Data()
    private var columns: [String] = []
    private var started = false
    private var lastProgress = ContinuousClock.now
    private(set) var count = 0
    private let progress: @Sendable (Int) -> Void
    init(url: URL, format: TransferFormat, target: DatabaseTable, progress: @escaping @Sendable (Int) -> Void) throws {
        self.format = format; self.progress = progress; self.target = target
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw UpdateFailure("Could not create export file.") }
        handle = try FileHandle(forWritingTo: url)
    }
    deinit { try? handle.close() }
    func append(_ row: MySQLRow) throws {
        if !started { try begin(columns: row.columnDefinitions.map(\.name)) }
        let binaryTypes: [MySQLProtocol.DataType] = [.blob, .tinyBlob, .mediumBlob, .longBlob, .string, .varString, .varchar, .geometry, .bit]
        let binary = row.columnDefinitions.map { $0.characterSet == 63 && binaryTypes.contains($0.columnType) }
        let values: [Any] = row.values.enumerated().map { index, buffer in
            guard let buffer, let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) else { return NSNull() }
            if binary[index] { return "0x" + bytes.map { String(format: "%02X", $0) }.joined() }
            return String(decoding: bytes, as: UTF8.self)
        }
        switch format {
        case .csv: try write(values.map { $0 is NSNull ? "\\N" : Self.csv($0 as! String) }.joined(separator: ",") + "\n")
        case .json:
            if count > 0 { try write(",\n") }
            try appendData(JSONSerialization.data(withJSONObject: values, options: [.fragmentsAllowed]))
        case .sql:
            let literals = row.values.enumerated().map { index, buffer -> String in
                guard let buffer, let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) else { return "NULL" }
                // Raw bytes are emitted as hex. This retains binary/text values
                // independently of SQL mode and connection escaping rules.
                let hex = "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
                return binary[index] ? hex : "CONVERT(\(hex) USING utf8mb4)"
            }
            let names = try columns.map(SQLIdentifier.quote).joined(separator: ", ")
            try write("INSERT INTO \(try SQLIdentifier.quote(target.schema)).\(try SQLIdentifier.quote(target.name)) (\(names)) VALUES (\(literals.joined(separator: ", ")));\n")
        }
        count += 1
        if lastProgress.duration(to: .now) >= .milliseconds(100) { progress(count); lastProgress = .now }
    }
    func begin(columns: [String]) throws {
        guard !started else { return }; started = true; self.columns = columns
        switch format {
        case .csv: try write(columns.map(Self.csv).joined(separator: ",") + "\n")
        case .json:
            try write("{\"columns\":"); try appendData(JSONSerialization.data(withJSONObject: columns)); try write(",\"rows\":[\n")
        case .sql: try write("-- Data for \(target.id.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")). Values are raw hexadecimal bytes. Statements are not automatically transactional.\n")
        }
    }
    func finish(columns: [String]) throws -> Int {
        try begin(columns: columns)
        if format == .json { try write("\n]}\n") }
        try flush(); try handle.synchronize(); try handle.close(); progress(count); return count
    }
    private func write(_ text: String) throws { try appendData(Data(text.utf8)) }
    private func appendData(_ data: Data) throws { pending.append(data); if pending.count >= 64 * 1024 { try flush() } }
    private func flush() throws { if !pending.isEmpty { try handle.write(contentsOf: pending); pending = Data() } }
    private static func csv(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}
