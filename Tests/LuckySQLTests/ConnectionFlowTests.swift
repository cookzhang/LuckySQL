import Foundation
import XCTest
@testable import LuckySQL

@MainActor final class ConnectionFlowTests: XCTestCase {
    func testConnectionDraftValidatesAndDefaultsOptionalName() throws {
        let draft = ConnectionDraft(profile: ConnectionProfile(name: " ", host: " localhost ", username: " root "), isNew: true, password: " keep spaces ")
        draft.port = " 3307 "
        let profile = try draft.validatedProfile()
        XCTAssertEqual(profile.host, "localhost"); XCTAssertEqual(profile.username, "root")
        XCTAssertEqual(profile.name, "root@localhost"); XCTAssertEqual(profile.port, 3307)
        XCTAssertEqual(draft.password, " keep spaces ")
        for bad in ["", "0", "65536", "-1", "33.6", "abc"] {
            draft.port = bad; XCTAssertThrowsError(try draft.validatedProfile())
        }
        draft.port = "3306"; draft.profile.host = "bad host"
        XCTAssertThrowsError(try draft.validatedProfile())
    }

    func testCancellingNewOrEditedConnectionDoesNotChangeSavedProfiles() async throws {
        let (model, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        model.saveProfiles()
        let original = model.profiles, selected = model.selectedProfileID
        model.beginNewConnection()
        model.connectionDraft?.profile.host = "not-saved.invalid"
        model.cancelConnectionEditor()
        XCTAssertEqual(model.profiles, original)
        model.beginEditConnection(original[0].id)
        model.connectionDraft?.profile.name = "Do not save"
        model.connectionDraft?.password = "Do not save either"
        model.cancelConnectionEditor()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.profiles, original)
        XCTAssertEqual(model.selectedProfileID, selected)
        XCTAssertEqual(ProfileStore(defaults: defaults).load(), original)
    }

    func testInvalidFormDoesNotPersistOrConnect() throws {
        let (model, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let original = model.profiles
        model.beginNewConnection()
        let draft = try XCTUnwrap(model.connectionDraft); draft.port = "70000"
        model.submitConnection(draft)
        XCTAssertNotNil(draft.error)
        XCTAssertEqual(model.profiles, original); XCTAssertFalse(model.isRunning)
    }

    func testFailedConnectKeepsFormAndRetryDoesNotDuplicateProfile() async throws {
        let driver = ConnectionTestDriver()
        let (model, defaults, name) = try fixture(driver: driver)
        defer { defaults.removePersistentDomain(forName: name) }
        let originalCount = model.profiles.count
        model.beginNewConnection()
        let draft = try XCTUnwrap(model.connectionDraft)
        draft.profile.host = "localhost"; draft.password = "session-secret"
        model.submitConnection(draft)
        try await settle(model)
        XCTAssertNotNil(draft.error); XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.connectionDraft?.id, draft.id)
        XCTAssertEqual(draft.password, "session-secret")
        XCTAssertEqual(model.profiles.count, originalCount + 1)
        model.submitConnection(draft)
        try await settle(model)
        XCTAssertTrue(model.isConnected); XCTAssertNil(model.connectionDraft)
        XCTAssertEqual(model.profiles.count, originalCount + 1)
        let saved = try JSONEncoder().encode(ProfileStore(defaults: defaults).load())
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("session-secret"))
        model.disconnect()
    }

    func testLegacyEnvironmentIsIgnoredWithoutRemovingReadOnlyProtection() throws {
        let json = "{\"id\":\"550E8400-E29B-41D4-A716-446655440000\",\"name\":\"Legacy\",\"host\":\"localhost\",\"port\":3306,\"username\":\"root\",\"database\":\"\",\"environment\":\"Production\",\"readOnly\":true}"
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8))
        let draft = ConnectionDraft(profile: profile, isNew: false)
        XCTAssertEqual(try draft.validatedProfile().readOnly, true)
        let encoded = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        XCTAssertFalse(encoded.contains("environment")); XCTAssertFalse(encoded.contains("Production"))
    }

    func testDeletingLastConnectionStaysEmptyAfterReload() throws {
        let (model, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let id = try XCTUnwrap(model.profiles.first?.id)
        model.deleteProfile(id)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertTrue(ProfileStore(defaults: defaults).load().isEmpty)
        model.requestConnect()
        XCTAssertTrue(model.connectionDraft?.isNew == true)
    }

    func testMissingPasswordOpensEditorWithoutStartingConnection() async throws {
        let (model, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        model.requestConnect()
        for _ in 0..<100 {
            if model.connectionDraft != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.connectionDraft?.profile.id, model.selectedProfileID)
        XCTAssertFalse(model.connectionDraft?.isNew ?? true)
        XCTAssertFalse(model.isRunning); XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.errorMessage)
    }

    private func fixture(driver: ConnectionTestDriver = ConnectionTestDriver()) throws -> (AppModel, UserDefaults, String) {
        let name = "LuckySQLConnectionFlow.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (AppModel(profileStore: ProfileStore(defaults: defaults), keychain: ConnectionTestPasswords(), driver: driver, workspaceStore: WorkspaceStore(defaults: defaults)), defaults, name)
    }
    private func settle(_ model: AppModel) async throws {
        for _ in 0..<200 { if !model.isRunning { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Connection did not settle")
    }
}

private actor ConnectionTestPasswords: PasswordStoring {
    func password(for profileID: UUID) async throws -> String? { try await Task.sleep(for: .milliseconds(20)); return nil }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
private actor ConnectionTestDriver: DatabaseDriver {
    var attempts = 0
    func connect(profile: ConnectionProfile, password: String) throws -> any DatabaseSession {
        attempts += 1
        if attempts == 1 { throw DatabaseError.notConnected }
        return ConnectionTestSession()
    }
}
private actor ConnectionTestSession: DatabaseSession {
    func query(_ sql: String) -> QueryResult { .empty }
    func schemas() -> [String] { ["shop"] }
    func tables(in schema: String) -> [String] { [] }
    func columns(in table: DatabaseTable) -> [TableColumn] { [] }
    func close() {}
}
