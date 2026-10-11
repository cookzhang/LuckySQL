import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LuckySQL

/// Opt-in timing from a table selection to a visible native result cell.
/// The fixture query reports 10 ms; metadata and row strings are prebuilt.
@MainActor final class RenderingPerformanceTests: XCTestCase {
    func testTableSelectionToNativeFirstScreen() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["LUCKYSQL_RENDER_BENCHMARK"] else {
            throw XCTSkip("Set LUCKYSQL_RENDER_BENCHMARK to an output folder; use swift test -c release")
        }
        let samples = Int(environment["LUCKYSQL_BENCHMARK_SAMPLES"] ?? "10") ?? 10
        let fixture = try RenderingFixture(samples: samples)
        defer { fixture.close() }
        try await fixture.connect()
        let model = fixture.model
        model.section = .data
        let host = NSHostingView(rootView: WorkspacePane(model: model, sidebarVisible: .constant(true)))
        if environment["LUCKYSQL_RENDER_HOST_SIZING"] == "production" { host.sizingOptions = [] }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 850),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        if let outline = descendants(NSOutlineView.self, in: host).first {
            outline.expandItem(outline.item(atRow: 1), expandChildren: false)
            try await waitUntil {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                return outline.numberOfRows == 1002
            }
        }
        var measurements: [String: [Double]] = [:]
        var work: [[String: Any]] = []
        for width in [2, 40, 100] {
            for sample in 0..<samples {
                let table = fixture.tables[width]![sample]
                let before = descendants(CopyableTableView.self, in: host).first { !$0.isHiddenOrHasHiddenAncestor }
                let coordinator = before?.delegate as? DataGrid.Coordinator
                let cellRequests = coordinator?.cellRequests ?? 0
                let visibleRequests = coordinator?.visibleCellRequests ?? 0
                let reloads = coordinator?.reloadCount ?? 0
                var resultPublished: ContinuousClock.Instant?
                let subscription = model.$browseResult.dropFirst().sink { result in
                    if result.rows.first?.first == table.name { resultPublished = .now }
                }
                let start = ContinuousClock.now
                model.selectTable(table)
                measurements["\(width)-columns-selection-call-ms", default: []].append(ms(start.duration(to: .now)))
                try await waitUntil { !model.isRunning && model.browseResult.rows.first?.first == table.name }
                let ready = try XCTUnwrap(resultPublished)
                measurements["\(width)-columns-model-ready-ms", default: []].append(ms(start.duration(to: ready)))
                try await waitUntil {
                    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    guard let grid = self.descendants(CopyableTableView.self, in: host).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
                          let cell = grid.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NSTableCellView else { return false }
                    return cell.textField?.stringValue == table.name
                }
                let painted = ContinuousClock.now
                measurements["\(width)-columns-first-screen-ms", default: []].append(ms(start.duration(to: painted)))
                measurements["\(width)-columns-ready-to-draw-ms", default: []].append(ms(ready.duration(to: painted)))
                let grid = try XCTUnwrap(descendants(CopyableTableView.self, in: host).first { !$0.isHiddenOrHasHiddenAncestor })
                let updated = try XCTUnwrap(grid.delegate as? DataGrid.Coordinator)
                work.append(["columns": width, "sample": sample, "grid_reused": grid === before,
                             "reloads": updated.reloadCount - (updated === coordinator ? reloads : 0),
                             "cell_requests": updated.cellRequests - (updated === coordinator ? cellRequests : 0),
                             "visible_cell_requests": updated.visibleCellRequests - (updated === coordinator ? visibleRequests : 0)])
                XCTAssertEqual(model.browseResult.elapsed, .milliseconds(10))
                XCTAssertEqual(grid.numberOfRows, 100)
                withExtendedLifetime(subscription) {}
                await Task.yield()
            }
        }
        let output = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let report = measurements.mapValues { values -> [String: Any] in
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)] }
            return ["samples_ms": values, "p50_ms": percentile(0.5), "p95_ms": percentile(0.95)]
        }
        let sidebarRows = descendants(NSOutlineView.self, in: host).first?.numberOfRows ?? 0
        try JSONSerialization.data(withJSONObject: [
            "method": "WorkspacePane table selection through model completion and AppKit layout/drawing with an actual visible first-cell assertion; fixture query reports and sleeps 10 ms, metadata is cached; not physical presentation latency",
            "sidebar_tables": 1000, "sidebar_rows": sidebarRows,
            "host_sizing": environment["LUCKYSQL_RENDER_HOST_SIZING"] ?? "default",
            "measurements": report, "native_work": work
        ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("table-selection.json"))
    }

    private func descendants<V: NSView>(_ type: V.Type, in view: NSView) -> [V] {
        ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw UpdateFailure("Render benchmark did not settle") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

@MainActor private final class RenderingFixture {
    let model: AppModel
    let defaults: UserDefaults
    let suite = "LuckySQLRenderBenchmark.\(UUID())"
    let tables: [Int: [DatabaseTable]]
    init(samples: Int) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        tables = Dictionary(uniqueKeysWithValues: [2, 40, 100].map { width in
            (width, (0..<samples).map { DatabaseTable(schema: "bench", name: "table_\(width)_\($0)") })
        })
        let session = RenderingSession(tables: tables)
        let store = ProfileStore(defaults: defaults)
        store.save([ConnectionProfile(name: "Render fixture", host: "127.0.0.1", username: "fixture", database: "bench")])
        model = AppModel(profileStore: store, keychain: RenderingPasswords(), driver: RenderingDriver(session: session),
                         workspaceStore: WorkspaceStore(defaults: defaults))
        for (width, entries) in tables {
            for table in entries { model.tableColumns[table.id] = RenderingSession.columns(width: width, table: table) }
        }
    }
    func connect() async throws {
        model.connect()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isRunning || model.isLoadingPassword {
            guard ContinuousClock.now < deadline else { throw UpdateFailure("Render fixture did not connect") }
            try await Task.sleep(for: .milliseconds(1))
        }
        await model.loadTables(in: "bench")
        // Connection setup clears columns; make metadata independent of timing.
        for (width, entries) in tables {
            for table in entries { model.tableColumns[table.id] = RenderingSession.columns(width: width, table: table) }
        }
    }
    func close() {
        model.disconnect(); model.flushWorkspace(); defaults.removePersistentDomain(forName: suite)
    }
}

private actor RenderingPasswords: PasswordStoring {
    func password(for profileID: UUID) -> String? { "fixture" }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
private struct RenderingDriver: DatabaseDriver {
    let session: RenderingSession
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { session }
}
private actor RenderingSession: DatabaseSession {
    let results: [(DatabaseTable, QueryResult)]
    init(tables: [Int: [DatabaseTable]]) {
        results = tables.flatMap { width, entries in
            entries.map { table in
                (table, QueryResult(columns: Self.columns(width: width, table: table).map(\.name),
                                    rows: (0..<101).map { row in (0..<width).map { column in
                    column == 0 ? table.name : "\(row):\(column) 中文😀 " + String(repeating: "x", count: 128)
                } }, elapsed: .milliseconds(10), message: "Fixture 10 ms"))
            }
        }
    }
    func query(_ sql: String) async throws -> QueryResult {
        guard let result = results.first(where: { sql.contains("`\($0.0.name)`") })?.1 else { throw UpdateFailure("Unknown fixture table") }
        try await Task.sleep(for: .milliseconds(10))
        return result
    }
    func schemas() -> [String] { ["bench"] }
    func tables(in schema: String) -> [String] {
        results.map { $0.0.name }.sorted() + (results.count..<1000).map { "unused_\($0)" }
    }
    func columns(in table: DatabaseTable) -> [LuckySQL.TableColumn] {
        let width = results.first(where: { $0.0 == table })?.1.columns.count ?? 2
        return Self.columns(width: width, table: table)
    }
    nonisolated static func columns(width: Int, table: DatabaseTable) -> [LuckySQL.TableColumn] {
        (0..<width).map { index in
            LuckySQL.TableColumn(name: "\(table.name)_column_\(index)", dataType: index == 0 ? "bigint" : "varchar(200)",
                                 isNullable: false, isPrimaryKey: index == 0, defaultValue: nil, extra: "")
        }
    }
    func close() {}
}
