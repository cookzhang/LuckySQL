import Foundation
import XCTest
@testable import LuckySQL

@MainActor final class LiveWorkspaceTests: XCTestCase {
    func testParallelSessionsCancellationAndReadOnlyChange() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["LUCKYSQL_TEST_PORT"].flatMap(Int.init), let password = env["LUCKYSQL_TEST_PASSWORD"] else { throw XCTSkip("Configure isolated MySQL fixture") }
        let driver = MySQLDriver(), suite = "LiveWorkspaces.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var first = ConnectionProfile(name: "A", host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", database: "luckysql")
        let second = ConnectionProfile(name: "B", host: first.host, port: port, username: first.username, database: first.database)
        let profiles = ProfileStore(defaults: defaults); profiles.save([first, second])
        let a = AppModel(profileStore: profiles, keychain: WorkspacePassword(password), driver: driver, workspaceStore: WorkspaceStore(defaults: defaults, namespace: "a"))
        let b = AppModel(profileStore: profiles, keychain: WorkspacePassword(password), driver: driver, workspaceStore: WorkspaceStore(defaults: defaults, namespace: "b"))
        defer { a.disconnect(); b.disconnect(); a.flushWorkspace(); b.flushWorkspace(); defaults.removePersistentDomain(forName: suite) }
        a.selectProfile(first.id); b.selectProfile(second.id)
        a.connect(); b.connect(); try await settle(a); try await settle(b)
        XCTAssertTrue(a.isConnected); XCTAssertTrue(b.isConnected)
        a.newQuery(sql: "SELECT SLEEP(10)"); a.runCurrentQuery()
        try await Task.sleep(for: .milliseconds(100)); XCTAssertTrue(a.isRunning)
        b.newQuery(sql: "SELECT 123"); b.runCurrentQuery(); try await settle(b)
        XCTAssertEqual(b.result.rows, [["123"]]); XCTAssertTrue(a.isRunning)
        a.cancelCurrentQuery(); try await settle(a)
        XCTAssertTrue(a.isConnected); XCTAssertTrue(b.isConnected)
        a.newQuery(sql: "SELECT 1"); a.runCurrentQuery(); try await settle(a)
        XCTAssertEqual(a.result.rows, [["1"]])
        first.readOnly = true; profiles.save([first, second]); a.reloadProfiles(); b.reloadProfiles()
        XCTAssertTrue(a.isReadOnly); XCTAssertFalse(b.isReadOnly)
        a.newQuery(sql: "CREATE TABLE should_never_be_created (id INT)"); a.runCurrentQuery()
        XCTAssertFalse(a.isRunning)
        XCTAssertTrue(a.errorMessage != nil)
        a.disconnect()
        b.newQuery(sql: "SELECT 456"); b.runCurrentQuery(); try await settle(b)
        XCTAssertEqual(b.result.rows, [["456"]])
        withExtendedLifetime(driver) {}
    }
    func testImportCancellationRollsBackAndKeepsMainSession() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["LUCKYSQL_TEST_PORT"].flatMap(Int.init), let password = env["LUCKYSQL_TEST_PASSWORD"] else { throw XCTSkip("Configure isolated MySQL fixture") }
        let driver = MySQLDriver(), profile = ConnectionProfile(host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", database: "luckysql")
        let session = try await driver.connect(profile: profile, password: password)
        let table = DatabaseTable(schema: "luckysql", name: "cancel_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let target = "`luckysql`.`\(table.name)`", suite = "CancelImport.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), profiles = ProfileStore(defaults: defaults)
        profiles.save([profile])
        let model = AppModel(profileStore: profiles, keychain: WorkspacePassword(password), driver: driver, workspaceStore: WorkspaceStore(defaults: defaults))
        let csv = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { model.disconnect(); model.flushWorkspace(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: csv) }
        do {
            _ = try await session.query("CREATE TABLE \(target) (id INT PRIMARY KEY, value INT) ENGINE=InnoDB")
            _ = try await session.query("CREATE TRIGGER `luckysql`.`tr_\(table.name)` BEFORE INSERT ON \(target) FOR EACH ROW SET NEW.value = SLEEP(0.02)")
            try ("id,value\n" + (0..<1200).map { "\($0),1\n" }.joined()).write(to: csv, atomically: true, encoding: .utf8)
            model.connect(); try await settle(model)
            model.importCSV(at: csv, table: table, mapping: ["id", "value"], separator: 44, latin1: false, header: true)
            try await Task.sleep(for: .milliseconds(300)); XCTAssertTrue(model.isRunning)
            model.cancelCurrentQuery(); try await settle(model)
            XCTAssertTrue(model.transferStatus.contains("rolled back"), model.transferStatus)
            let count = try await session.query("SELECT COUNT(*) FROM \(target)"); XCTAssertEqual(count.rows, [["0"]])
            XCTAssertTrue(model.isConnected)
            model.newQuery(sql: "SELECT 1"); model.runCurrentQuery(); try await settle(model)
            XCTAssertEqual(model.result.rows, [["1"]])
            _ = try await session.query("DROP TABLE \(target)"); await session.close()
        } catch { _ = try? await session.query("DROP TABLE IF EXISTS \(target)"); await session.close(); throw error }
        withExtendedLifetime(driver) {}
    }
    private func settle(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while model.isRunning { guard ContinuousClock.now < deadline else { throw UpdateFailure("Workspace operation timed out") }; try await Task.sleep(for: .milliseconds(5)) }
    }
}
private actor WorkspacePassword: PasswordStoring {
    let password: String
    init(_ password: String) { self.password = password }
    func password(for profileID: UUID) -> String? { password }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
