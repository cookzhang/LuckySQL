import Foundation

/// Bound native layout work without changing the full value used for copying.
/// Split at UTF-16 boundaries, keeping surrogate pairs on the preceding page.
enum CellValuePage {
    static let size = 8192
    static func count(_ value: String) -> Int { max(1, ((value as NSString).length + size - 1) / size) }
    static func text(_ value: String, page: Int) -> String {
        let source = value as NSString
        func boundary(_ offset: Int) -> Int {
            let index = min(source.length, max(0, offset))
            if index > 0 && index < source.length && (0xDC00...0xDFFF).contains(source.character(at: index)) { return index + 1 }
            return index
        }
        let start = boundary(max(0, page) * size)
        let end = boundary((max(0, page) + 1) * size)
        return source.substring(with: NSRange(location: start, length: end - start))
    }
}
