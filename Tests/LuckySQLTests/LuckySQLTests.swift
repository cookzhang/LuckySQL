import Foundation
import XCTest
@testable import LuckySQL

@MainActor
final class LuckySQLTests: XCTestCase {
    func testIdentifierQuoting() throws {
        XCTAssertEqual(try SQLIdentifier.quote("orders"), "`orders`")
        XCTAssertEqual(try SQLIdentifier.quote("odd`name"), "`odd``name`")
        XCTAssertThrowsError(try SQLIdentifier.quote(""))
    }

    func testStringLiteralQuoting() throws {
        XCTAssertEqual(try SQLStringLiteral.quote("sales"), "'sales'")
        XCTAssertEqual(try SQLStringLiteral.quote("team's data"), "'team''s data'")
        XCTAssertThrowsError(try SQLStringLiteral.quote("bad\0name"))
    }

    func testConnectionLoadsSchemasAndTables() async throws {
        let suiteName = "LuckySQLTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = StubSession()
        let model = AppModel(
            profileStore: ProfileStore(defaults: defaults),
            keychain: StubPasswordStore(),
            driver: StubDriver(session: session)
        )

        model.connect()
        try await waitUntil { model.schemaLoadState == .loaded }

        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.schemas.map(\.name), ["information_schema", "shop"])

        await model.loadTables(in: "shop")

        XCTAssertEqual(model.schemas.first(where: { $0.name == "shop" })?.tables.map(\.name), ["customers", "orders"])
        XCTAssertEqual(model.schemas.first(where: { $0.name == "shop" })?.tableLoadState, .loaded)
        model.disconnect()
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - started > timeoutNanoseconds {
                XCTFail("Timed out waiting for asynchronous state change")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor StubSession: DatabaseSession {
    func query(_ sql: String) async throws -> QueryResult { .empty }
    func schemas() async throws -> [String] { ["information_schema", "shop"] }
    func tables(in schema: String) async throws -> [String] {
        schema == "shop" ? ["customers", "orders"] : []
    }
    func close() async {}
}

private struct StubDriver: DatabaseDriver {
    let session: StubSession

    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession {
        session
    }
}

private final class StubPasswordStore: PasswordStoring {
    private var passwords: [UUID: String] = [:]

    func save(_ password: String, for profileID: UUID) throws { passwords[profileID] = password }
    func password(for profileID: UUID) throws -> String? { passwords[profileID] }
    func deletePassword(for profileID: UUID) throws { passwords[profileID] = nil }
}
