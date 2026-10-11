import XCTest
@testable import LuckySQL

@MainActor final class ConnectionActivationTests: XCTestCase {
    func testRestoredTabConnectsItsOwnProfileOnceAndWarmSwitchKeepsTable() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.close() }
        let saved = fixture.makeWorkspaces()
        saved.newWorkspace()
        saved.active.selectProfile(fixture.second.id)
        saved.flush()

        let workspaces = fixture.makeWorkspaces()
        let second = workspaces.entries[1]
        for _ in 0..<5 { workspaces.select(second.id) }
        try await waitUntil { second.model.isConnected && !second.model.isRunning }
        XCTAssertEqual(second.model.connectedProfileID, fixture.second.id)
        var connections = await fixture.driver.connections
        XCTAssertEqual(connections, [fixture.second.id])
        XCTAssertFalse(workspaces.entries[0].model.isConnected)

        let table = DatabaseTable(schema: "shop", name: "orders")
        second.model.browse(table)
        try await waitUntil { !second.model.isRunning }
        let resultID = second.model.browseResult.id
        workspaces.select(workspaces.entries[0].id)
        try await waitUntil { workspaces.active.isConnected && !workspaces.active.isRunning }
        workspaces.select(second.id)
        XCTAssertEqual(workspaces.active.selectedTable, table)
        XCTAssertEqual(workspaces.active.section, .data)
        XCTAssertEqual(workspaces.active.browseResult.id, resultID)
        connections = await fixture.driver.connections
        XCTAssertEqual(connections, [fixture.second.id, fixture.first.id])
    }

    func testMissingPasswordOpensTheSelectedProfileWithoutChoosingAgain() async throws {
        let fixture = try ActivationFixture(password: nil)
        defer { fixture.close() }
        let workspaces = fixture.makeWorkspaces()
        workspaces.newWorkspace()
        workspaces.active.selectProfile(fixture.second.id)
        workspaces.select(workspaces.selectedID)
        try await waitUntil { workspaces.active.connectionDraft != nil }
        let draft = try XCTUnwrap(workspaces.active.connectionDraft)
        XCTAssertEqual(draft.profile.id, fixture.second.id)
        XCTAssertFalse(draft.isNew)
        workspaces.select(workspaces.selectedID)
        XCTAssertTrue(workspaces.active.connectionDraft === draft)
        let connections = await fixture.driver.connections
        XCTAssertTrue(connections.isEmpty)
    }

    func testSelectingBusyTabDoesNotReconnectOrCancelItsOperation() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.close() }
        let workspaces = fixture.makeWorkspaces()
        let entry = workspaces.entries[0]
        entry.model.isRunning = true
        workspaces.newWorkspace()
        workspaces.select(entry.id)
        XCTAssertTrue(workspaces.active === entry.model)
        XCTAssertTrue(entry.model.isRunning)
        let connections = await fixture.driver.connections
        XCTAssertTrue(connections.isEmpty)
        entry.model.isRunning = false
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw UpdateFailure("Connection activation did not finish") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor private final class ActivationFixture {
    let suite = "ConnectionActivation.\(UUID())"
    let defaults: UserDefaults
    let first = ConnectionProfile(name: "First", database: "shop")
    let second = ConnectionProfile(name: "Second", database: "shop")
    let driver = ActivationDriver()
    let password: String?
    var workspaces: [ConnectionWorkspaces] = []
    init(password: String? = "fixture") throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.password = password
        ProfileStore(defaults: defaults).save([first, second])
    }
    func makeWorkspaces() -> ConnectionWorkspaces {
        let result = ConnectionWorkspaces(defaults: defaults) { [defaults, driver, password] store in
            AppModel(profileStore: ProfileStore(defaults: defaults), keychain: ActivationPasswords(value: password),
                     driver: driver, workspaceStore: store)
        }
        workspaces.append(result)
        return result
    }
    func close() {
        for group in workspaces {
            for entry in group.entries { entry.model.disconnect() }
            group.flush()
        }
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor ActivationPasswords: PasswordStoring {
    let value: String?
    init(value: String?) { self.value = value }
    func password(for profileID: UUID) -> String? { value }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}

private actor ActivationDriver: DatabaseDriver {
    var connections: [UUID] = []
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession {
        connections.append(profile.id)
        return ActivationSession()
    }
}

private actor ActivationSession: DatabaseSession {
    func schemas() -> [String] { ["shop"] }
    func tables(in schema: String) -> [String] { ["orders"] }
    func columns(in table: DatabaseTable) -> [TableColumn] { [] }
    func query(_ sql: String) -> QueryResult {
        QueryResult(columns: ["id"], rows: [["1"]], elapsed: .zero, message: "")
    }
    func close() {}
}
