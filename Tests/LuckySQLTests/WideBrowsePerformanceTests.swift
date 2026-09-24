import AppKit
import SwiftUI
import XCTest
@testable import LuckySQL

@MainActor final class WideBrowsePerformanceTests: XCTestCase {
    func testWideSummariesFullValueAndNativeFirstScreen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["LUCKYSQL_WIDE_BENCHMARK"], let port = env["LUCKYSQL_TEST_PORT"].flatMap(Int.init), let password = env["LUCKYSQL_TEST_PASSWORD"] else { throw XCTSkip("Opt-in wide browse benchmark") }
        let driver = MySQLDriver(), profile = ConnectionProfile(host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", database: "luckysql")
        let session = try await driver.connect(profile: profile, password: password)
        let table = DatabaseTable(schema: "luckysql", name: "wide_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let target = "`luckysql`.`\(table.name)`", name = "WideBench.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)), profiles = ProfileStore(defaults: defaults)
        profiles.save([profile])
        let model = AppModel(profileStore: profiles, keychain: WidePassword(password), driver: driver, workspaceStore: WorkspaceStore(defaults: defaults))
        let host = NSHostingView(rootView: DataGrid(result: .empty).frame(width: 1280, height: 800))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close(); model.disconnect(); model.flushWorkspace(); defaults.removePersistentDomain(forName: name) }
        do {
            _ = try await session.query("CREATE TABLE \(target) (id INT PRIMARY KEY, name VARCHAR(80), body LONGTEXT, bytes LONGBLOB) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
            for id in 0..<20 { _ = try await session.query("INSERT INTO \(target) VALUES (\(id), '中文😀', REPEAT('x',3145728), X'00FF')") }
            model.connect(); try await settle(model)
            var ready: [Double] = [], painted: [Double] = []
            for index in 0..<30 {
                let start = ContinuousClock.now
                if index == 0 { model.browse(table) } else { model.refreshData() }
                try await settle(model)
                ready.append(ms(start.duration(to: .now)))
                XCTAssertEqual(model.browseResult.rows.count, 20)
                XCTAssertLessThan(model.browseResult.retainedBytes, 20_000)
                host.rootView = DataGrid(result: model.browseResult).frame(width: 1280, height: 800)
                await Task.yield(); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                painted.append(ms(start.duration(to: .now)))
            }
            let full = try await model.loadFullValue(row: 0, column: 2)
            XCTAssertEqual(full.rows[0][0].utf8.count, 3145728)
            let fullBytes = try await model.loadFullValue(row: 0, column: 3)
            XCTAssertEqual(fullBytes.binaryCells[CellAddress(row: 0, column: 0)], Data([0,255]))
            func distribution(_ values: [Double]) -> [String: Any] {
                let sorted = values.sorted()
                return ["samples_ms": values, "p50_ms": sorted[14], "p95_ms": sorted[28], "p99_ms": sorted[29]]
            }
            let output = URL(fileURLWithPath: folder); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["method": "20 rows each with 3 MiB LONGTEXT: browse request to complete summary snapshot, then native grid drawing; first sample includes metadata; warm server buffer; first row arrives as part of complete bounded snapshot", "summary_ready": distribution(ready), "first_screen_draw": distribution(painted), "retained_summary_bytes": model.browseResult.retainedBytes, "full_text_bytes": 3145728], options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("wide.json"))
            _ = try await session.query("DROP TABLE \(target)"); await session.close()
        } catch { _ = try? await session.query("DROP TABLE IF EXISTS \(target)"); await session.close(); throw error }
        withExtendedLifetime(driver) {}
    }
    private func settle(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while model.isRunning { guard ContinuousClock.now < deadline else { throw UpdateFailure("Wide browse did not settle") }; try await Task.sleep(for: .milliseconds(1)) }
    }
    private func ms(_ duration: Duration) -> Double { Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15 }
}
private actor WidePassword: PasswordStoring {
    let password: String
    init(_ password: String) { self.password = password }
    func password(for profileID: UUID) -> String? { password }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
