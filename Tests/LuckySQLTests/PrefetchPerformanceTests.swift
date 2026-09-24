import Foundation
import XCTest
@testable import LuckySQL

@MainActor final class PrefetchPerformanceTests: XCTestCase {
    func testLiveReusablePrefetchAndForegroundLatency() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["LUCKYSQL_BROWSE_BENCHMARK"], let port = env["LUCKYSQL_TEST_PORT"].flatMap(Int.init), let password = env["LUCKYSQL_TEST_PASSWORD"] else { throw XCTSkip("Opt-in prefetch benchmark") }
        let real = MySQLDriver()
        let profile = ConnectionProfile(host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", database: "luckysql")
        var setupProfile = profile; setupProfile.port = env["LUCKYSQL_SETUP_PORT"].flatMap(Int.init) ?? port
        let setup = try await real.connect(profile: setupProfile, password: password)
        let table = DatabaseTable(schema: "luckysql", name: "prefetch_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let qualified = "`luckysql`.`\(table.name)`"
        do {
            _ = try await setup.query("CREATE TABLE \(qualified) (id INT PRIMARY KEY, value VARCHAR(80)) ENGINE=InnoDB")
            let digits = "(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)"
            _ = try await setup.query("INSERT INTO \(qualified) SELECT a.n+10*b.n+100*c.n+1000*d.n, 'fixture' FROM \(digits) a CROSS JOIN \(digits) b CROSS JOIN \(digits) c CROSS JOIN \(digits) d")
            var report: [String: Any] = [:]
            let samples = Int(env["LUCKYSQL_BENCHMARK_SAMPLES"] ?? "30") ?? 30
            for enabled in [false, true] {
                let counters = PrefetchCounters(), driver = CountingPreviewDriver(real: real, counters: counters, enabled: enabled)
                let name = "PrefetchBench.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
                let profiles = ProfileStore(defaults: defaults); profiles.save([profile])
                let model = AppModel(profileStore: profiles, keychain: PrefetchPassword(password), driver: driver, workspaceStore: WorkspaceStore(defaults: defaults))
                defer { model.disconnect(); model.flushWorkspace(); defaults.removePersistentDomain(forName: name) }
                model.connect(); try await settle(model); XCTAssertTrue(model.isConnected)
                model.browse(table); try await settle(model)
                if enabled { try await Task.sleep(for: .seconds(2)) }
                var timings: [Double] = []
                for index in 0..<samples {
                    if enabled { try await Task.sleep(for: .milliseconds(700)) }
                    let start = ContinuousClock.now
                    model.nextPage(1); try await settle(model)
                    let duration = start.duration(to: .now)
                    timings.append(Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15)
                    XCTAssertEqual(model.browseResult.rows.first?.first, String((index+1)*100))
                }
                let sorted = timings.sorted(), counts = await counters.snapshot()
                report[enabled ? "prefetch-700ms-reading-dwell" : "foreground-only-immediate"] = ["samples_ms": timings, "p50_ms": sorted[Int(ceil(Double(samples)*0.5))-1], "p95_ms": sorted[Int(ceil(Double(samples)*0.95))-1], "p99_ms": sorted[Int(ceil(Double(samples)*0.99))-1], "main_connections": counts.0, "prefetch_connections": counts.1]
                if enabled { XCTAssertEqual(counts.1, 1, "Idle prefetch connection should be reused") }
                else { XCTAssertEqual(counts.1, 0) }
                // Arbitrary SQL disables speculative connections without switching
                // the foreground session, preserving session variables/transactions.
                model.newQuery(sql: "SELECT 1"); model.runCurrentQuery(); try await settle(model)
                let before = await counters.snapshot().1
                model.changeSection(.data); try await settle(model); try await Task.sleep(for: .milliseconds(500))
                let after = await counters.snapshot().1; XCTAssertEqual(before, after)
                model.disconnect()
            }
            try JSONSerialization.data(withJSONObject: ["method": "AppModel next-page action to accepted complete snapshot, excludes GUI paint and intentional reading dwell; cache hit measured only after prefetch had time to complete", "rtt_ms": env["LUCKYSQL_RTT_MS"] ?? "0", "results": report], options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output + ".prefetch.json"))
            _ = try await setup.query("DROP TABLE \(qualified)"); await setup.close()
        } catch { _ = try? await setup.query("DROP TABLE IF EXISTS \(qualified)"); await setup.close(); throw error }
        withExtendedLifetime(real) {}
    }
    private func settle(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while model.isRunning { guard ContinuousClock.now < deadline else { throw UpdateFailure("Model did not settle") }; try await Task.sleep(for: .milliseconds(1)) }
    }
}
private actor PrefetchCounters {
    var main = 0, preview = 0
    func connected(preview: Bool) { if preview { self.preview += 1 } else { main += 1 } }
    func snapshot() -> (Int,Int) { (main,preview) }
}
private struct CountingPreviewDriver: DatabaseDriver {
    let real: MySQLDriver, counters: PrefetchCounters, enabled: Bool
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession {
        await counters.connected(preview: false); return try await real.connect(profile: profile, password: password)
    }
    func connectPreview(profile: ConnectionProfile, password: String) async throws -> (any DatabaseSession)? {
        guard enabled else { return nil }; await counters.connected(preview: true)
        return try await real.connect(profile: profile, password: password)
    }
}
private actor PrefetchPassword: PasswordStoring {
    let value: String
    init(_ value: String) { self.value = value }
    func password(for profileID: UUID) -> String? { value }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
