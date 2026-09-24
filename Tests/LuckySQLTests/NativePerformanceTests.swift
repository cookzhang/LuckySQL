import AppKit
import SwiftUI
import XCTest
@testable import LuckySQL

/// Opt-in release benchmark of the actual NSViewRepresentable/TextKit path.
/// Timings end after AppKit layout/drawing, not physical display presentation.
final class NativePerformanceTests: XCTestCase {
    @MainActor func testNativeEditorInputAndGridDrawing() async throws {
        guard let folder = ProcessInfo.processInfo.environment["LUCKYSQL_NATIVE_BENCHMARK"] else { throw XCTSkip("Set LUCKYSQL_NATIVE_BENCHMARK to an output folder; use swift test -c release") }
        let output = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state = NativeBenchmarkState()
        let host = NSHostingView(rootView: NativeBenchmarkView(state: state).frame(width: 1280, height: 800))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        var measurements: [String: [Double]] = [:]
        var geometry: [[String: String]] = []
        let samples = Int(ProcessInfo.processInfo.environment["LUCKYSQL_BENCHMARK_SAMPLES"] ?? "30") ?? 30
        let kind = ProcessInfo.processInfo.environment["LUCKYSQL_BENCHMARK_KIND"]
        for singleLine in (ProcessInfo.processInfo.environment["LUCKYSQL_BENCHMARK_GRID_ONLY"] == "1" ? [] : kind == "single" ? [true] : kind == "multi" ? [false] : [false, true]) {
            state.sql = singleLine ? "SELECT '" + String(repeating: "中文😀abc ", count: 150_000) + "';" : String(repeating: "SELECT id, '中文😀' FROM table_name WHERE id > 42; -- note\n", count: 33_000)
            state.document = UUID().uuidString
            try await waitUntil { self.find(CodeTextView.self, in: host).map { ($0.string as NSString).isEqual(to: state.sql) } == true }
            let editor = try XCTUnwrap(find(CodeTextView.self, in: host))
            try await waitUntil { editor.analysis != nil }
            geometry.append(["kind": singleLine ? "single" : "multi", "host": NSStringFromRect(host.bounds), "editor": NSStringFromRect(editor.bounds), "visible": NSStringFromRect(editor.visibleRect), "clip": NSStringFromRect(editor.enclosingScrollView!.contentView.bounds), "utf8_bytes": String(state.sql.utf8.count)])
            for location in ["head", "middle", "tail"] {
                for sample in 0..<samples {
                    let length = (editor.string as NSString).length
                    var position = location == "head" ? 7 : location == "middle" ? length / 2 : length - 3
                    let ns = editor.string as NSString
                    if position < ns.length, (0xDC00...0xDFFF).contains(ns.character(at: position)) { position -= 1 }
                    editor.setSelectedRange(NSRange(location: position, length: 0))
                    editor.scrollRangeToVisible(editor.selectedRange())
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let start = ContinuousClock.now
                    if sample % 3 == 0 {
                        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                        editor.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
                    } else { editor.insertText("x", replacementRange: editor.selectedRange()) }
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    measurements["\(singleLine ? "single" : "multi")-\(location)-input-draw-ms", default: []].append(ms(start.duration(to: .now)))
                    let source = editor.string
                    do { try await waitUntil { editor.analysis.map { ($0.sql as NSString).isEqual(to: source) } == true } }
                    catch {
                        let failure: [String: Any] = ["single": singleLine, "location": location, "sample": sample, "marked": editor.hasMarkedText(), "text_matches_binding": (state.sql as NSString).isEqual(to: source), "source_utf16": (source as NSString).length, "analysis_utf16": editor.analysis.map { ($0.sql as NSString).length } ?? -1]
                        try JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted]).write(to: output.appendingPathComponent("failure.json"))
                        throw error
                    }
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    measurements["\(singleLine ? "single" : "multi")-\(location)-highlight-draw-ms", default: []].append(ms(start.duration(to: .now)))
                    try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("samples-checkpoint.json"))
                }
            }
        }
        state.showGrid = true
        state.result = QueryResult(columns: (0..<40).map { "column_\($0)" }, rows: (0..<1000).map { row in (0..<40).map { column in "\(row):\(column) 中文😀 " + String(repeating: "x", count: 256) } }, elapsed: .zero, message: "Native benchmark")
        try await waitUntil { self.find(CopyableTableView.self, in: host)?.numberOfRows == 1000 }
        let grid = try XCTUnwrap(find(CopyableTableView.self, in: host))
        grid.selectRowIndexes(IndexSet(integer: 500), byExtendingSelection: false)
        for _ in 0..<samples {
            let start = ContinuousClock.now
            state.result = QueryResult(columns: state.result.columns, rows: state.result.rows, elapsed: .zero, message: "Refresh")
            await Task.yield(); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            measurements["grid-no-pk-selected-refresh-draw-ms", default: []].append(ms(start.duration(to: .now)))
            XCTAssertTrue(grid.selectedRowIndexes.contains(500))
        }
        grid.scrollRowToVisible(500)
        let scroll = try XCTUnwrap(grid.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: grid.rect(ofColumn: 35).minX, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil { (grid.view(atColumn: 35, row: 500, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue.hasPrefix("500:35") == true }
        grid.moveColumn(35, toColumn: 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil { (grid.view(atColumn: 0, row: 500, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue.hasPrefix("500:35") == true }
        XCTAssertTrue(grid.selectedRowIndexes.contains(500))
        grid.moveColumn(0, toColumn: 35); grid.scrollRowToVisible(0)
        try await waitUntil { (grid.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue.hasPrefix("0:0") == true }
        XCTAssertEqual(grid.tableColumns[0].title, "column_0")
        grid.headerView?.needsDisplay = true
        try await Task.sleep(for: .milliseconds(350)) // Let AppKit column-move animations settle before capture.
        geometry.append(["kind": "grid", "visible": NSStringFromRect(grid.visibleRect), "frame": NSStringFromRect(grid.frame), "requests": String((grid.delegate as? DataGrid.Coordinator)?.cellRequests ?? -1), "visible_requests": String((grid.delegate as? DataGrid.Coordinator)?.visibleCellRequests ?? -1)])
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 960, height: 640)] {
            host.rootView = NativeBenchmarkView(state: state).frame(width: size.width, height: size.height)
            window.setContentSize(size); try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded(); grid.headerView?.display(); window.displayIfNeeded()
            // cacheDisplay omits some composited SwiftUI/header layers. These
            // optional images are diagnostics, never native visual sign-off.
            if ProcessInfo.processInfo.environment["LUCKYSQL_CAPTURE_DIAGNOSTIC_IMAGES"] == "1" {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("native-grid-\(Int(size.width))x\(Int(size.height)).png"))
            }
        }
        let report = measurements.mapValues { values -> [String: Any] in
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)] }
            return ["samples_ms": values, "p50_ms": percentile(0.5), "p95_ms": percentile(0.95), "p99_ms": percentile(0.99)]
        }
        let data = try JSONSerialization.data(withJSONObject: ["method": "Native TextKit input/IME composition through binding and AppKit drawing; highlight includes 80 ms debounce; not physical presentation latency", "os": ProcessInfo.processInfo.operatingSystemVersionString, "processors": ProcessInfo.processInfo.processorCount, "geometry": geometry, "measurements": report], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("native-performance.json"))
    }
    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw UpdateFailure("Native benchmark did not settle") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
}
@MainActor private final class NativeBenchmarkState: ObservableObject {
    @Published var sql = "SELECT 1;"
    @Published var document = UUID().uuidString
    @Published var showGrid = false
    @Published var result = QueryResult.empty
}
private struct NativeBenchmarkView: View {
    @ObservedObject var state: NativeBenchmarkState
    var body: some View {
        if state.showGrid { DataGrid(result: state.result) }
        else { SQLTextEditor(text: $state.sql, documentID: state.document) }
    }
}
