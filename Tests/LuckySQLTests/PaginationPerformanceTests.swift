import Foundation
import XCTest
@testable import LuckySQL

final class PaginationPerformanceTests: XCTestCase {
    func testLivePaginationPlansPrecisionAndLatency() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["LUCKYSQL_BROWSE_BENCHMARK"], let port = env["LUCKYSQL_TEST_PORT"].flatMap(Int.init), let password = env["LUCKYSQL_TEST_PASSWORD"] else { throw XCTSkip("Opt-in pagination benchmark") }
        let driver = MySQLDriver()
        let profile = ConnectionProfile(host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", database: "luckysql")
        var setupProfile = profile; setupProfile.port = env["LUCKYSQL_SETUP_PORT"].flatMap(Int.init) ?? port
        let setup = try await driver.connect(profile: setupProfile, password: password)
        let session = try await driver.connect(profile: profile, password: password)
        let table = "`luckysql`.`pagination_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))`"
        do {
            _ = try await setup.query("CREATE TABLE \(table) (id BIGINT UNSIGNED PRIMARY KEY, bucket INT NULL, name VARCHAR(80) COLLATE utf8mb4_general_ci, KEY cursor_idx(bucket,id), KEY name_idx(name,id)) ENGINE=InnoDB CHARACTER SET utf8mb4")
            let digits = "(SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)"
            _ = try await setup.query("INSERT INTO \(table) SELECT 18000000000000000000 + a.n+10*b.n+100*c.n+1000*d.n+10000*e.n, IF(a.n=0,NULL,a.n), CONCAT('name-',a.n,b.n,c.n,d.n,e.n) FROM \(digits) a CROSS JOIN \(digits) b CROSS JOIN \(digits) c CROSS JOIN \(digits) d CROSS JOIN \(digits) e")
            let columns = [TableColumn(name: "bucket", dataType: "int", isNullable: true, isPrimaryKey: false, defaultValue: nil, extra: ""), TableColumn(name: "id", dataType: "bigint unsigned", isNullable: false, isPrimaryKey: true, defaultValue: nil, extra: "")]
            let anchor = try await setup.query("SELECT bucket,id FROM \(table) ORDER BY bucket,id LIMIT 1 OFFSET 89999")
            let values = anchor.rows[0].enumerated().map { anchor.isNull(row: 0, column: $0.offset) ? nil : $0.element }
            let seek = try SeekPagination.predicate(columns: columns, values: values, descending: false)
            let queries = [
                "shallow-offset": "SELECT id,bucket,name FROM \(table) ORDER BY bucket,id LIMIT 100 OFFSET 0",
                "deep-offset": "SELECT id,bucket,name FROM \(table) ORDER BY bucket,id LIMIT 100 OFFSET 90000",
                "deep-seek": "SELECT id,bucket,name FROM \(table) WHERE \(seek) ORDER BY bucket,id LIMIT 100",
                "prefix": "SELECT id,bucket,name FROM \(table) WHERE name LIKE 'name-123%' ORDER BY name,id LIMIT 100",
                "contains": "SELECT id,bucket,name FROM \(table) WHERE LOCATE('123',name)>0 ORDER BY name,id LIMIT 100"
            ]
            let expected = try await session.query(queries["deep-offset"]!), actual = try await session.query(queries["deep-seek"]!)
            XCTAssertEqual(expected.rows, actual.rows)
            let nullAnchor = try await setup.query("SELECT bucket,id FROM \(table) ORDER BY bucket,id LIMIT 1 OFFSET 99")
            let nullSeek = try SeekPagination.predicate(columns: columns, values: [nil, nullAnchor.rows[0][1]], descending: false)
            let nullPage = try await session.query("SELECT id,bucket FROM \(table) WHERE \(nullSeek) ORDER BY bucket,id LIMIT 100")
            let nullOffset = try await session.query("SELECT id,bucket FROM \(table) ORDER BY bucket,id LIMIT 100 OFFSET 100")
            XCTAssertEqual(nullPage.rows, nullOffset.rows)
            let descendingAnchor = try await setup.query("SELECT bucket,id FROM \(table) ORDER BY bucket DESC,id DESC LIMIT 1 OFFSET 99")
            let descending = try SeekPagination.predicate(columns: columns, values: descendingAnchor.rows[0].map(Optional.some), descending: true)
            let descPage = try await session.query("SELECT id,bucket FROM \(table) WHERE \(descending) ORDER BY bucket DESC,id DESC LIMIT 100")
            let descOffset = try await session.query("SELECT id,bucket FROM \(table) ORDER BY bucket DESC,id DESC LIMIT 100 OFFSET 100")
            XCTAssertEqual(descPage.rows, descOffset.rows)
            var results: [String: Any] = [:]
            let samples = Int(env["LUCKYSQL_BENCHMARK_SAMPLES"] ?? "30") ?? 30
            for (name, sql) in queries.sorted(by: { $0.key < $1.key }) {
                let plan = try await setup.query("EXPLAIN " + sql)
                var times: [Double] = []
                for _ in 0..<samples {
                    let start = ContinuousClock.now; _ = try await session.query(sql)
                    let duration = start.duration(to: .now)
                    times.append(Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15)
                }
                let sorted = times.sorted()
                results[name] = ["query": sql, "samples_ms": times, "p50_ms": sorted[Int(ceil(Double(samples)*0.5))-1], "p95_ms": sorted[Int(ceil(Double(samples)*0.95))-1], "p99_ms": sorted[Int(ceil(Double(samples)*0.99))-1], "explain_columns": plan.columns, "explain_rows": plan.rows]
            }
            let version = try await setup.query("SELECT VERSION()")
            let report: [String: Any] = ["rows": 100000, "version": version.rows, "rtt_ms": env["LUCKYSQL_RTT_MS"] ?? "0", "method": "Request through complete MySQLSession decoding; first measured request retained, repeated warm server buffer pool. Not GUI paint time or cold disk latency.", "results": results]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: output))
            _ = try await setup.query("DROP TABLE \(table)"); await setup.close(); await session.close()
        } catch { _ = try? await setup.query("DROP TABLE IF EXISTS \(table)"); await setup.close(); await session.close(); throw error }
        withExtendedLifetime(driver) {}
    }
}
