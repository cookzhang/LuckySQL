import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [ConnectionProfile]
    @Published var selectedProfileID: UUID?
    @Published var password = ""
    @Published var schemas: [DatabaseSchema] = []
    @Published var selectedTable: DatabaseTable?
    @Published var sql = "SELECT VERSION() AS version;"
    @Published var result = QueryResult.empty
    @Published var isConnected = false
    @Published var isRunning = false
    @Published var errorMessage: String?

    private let profileStore: ProfileStore
    private let keychain: PasswordStoring
    private let driver: any DatabaseDriver
    private var session: (any DatabaseSession)?

    init(profileStore: ProfileStore? = nil, keychain: PasswordStoring = KeychainStore(), driver: any DatabaseDriver = MySQLDriver()) {
        let profileStore = profileStore ?? ProfileStore()
        self.profileStore = profileStore
        self.keychain = keychain
        self.driver = driver
        let saved = profileStore.load()
        profiles = saved
        selectedProfileID = saved.first?.id
        loadPassword()
    }

    var selectedProfile: ConnectionProfile? {
        get { profiles.first { $0.id == selectedProfileID } }
        set {
            guard let newValue, let index = profiles.firstIndex(where: { $0.id == newValue.id }) else { return }
            profiles[index] = newValue
        }
    }

    func addProfile() {
        let profile = ConnectionProfile(name: "New Connection")
        profiles.append(profile); selectedProfileID = profile.id; password = ""; saveProfiles()
    }

    func deleteSelectedProfile() {
        guard let id = selectedProfileID else { return }
        Task { try? keychain.deletePassword(for: id) }
        profiles.removeAll { $0.id == id }
        if profiles.isEmpty { profiles = [.local] }
        selectedProfileID = profiles.first?.id; saveProfiles(); loadPassword()
    }

    func saveProfiles() { profileStore.save(profiles) }

    func selectProfile(_ id: UUID?) {
        selectedProfileID = id; loadPassword()
    }

    func connect() {
        guard let profile = selectedProfile else { return }
        isRunning = true; errorMessage = nil
        Task {
            do {
                await session?.close()
                try keychain.save(password, for: profile.id)
                session = try await driver.connect(profile: profile, password: password)
                isConnected = true
                await loadSchemas()
            } catch { show(error) }
            isRunning = false
        }
    }

    func disconnect() {
        Task { await session?.close(); session = nil; isConnected = false; schemas = []; result = .empty }
    }

    func loadSchemas() async {
        do { schemas = try await requireSession().schemas().map { DatabaseSchema(name: $0) } }
        catch { show(error) }
    }

    func loadTables(in schema: String) {
        guard let index = schemas.firstIndex(where: { $0.name == schema }), !schemas[index].isLoaded else { return }
        Task {
            do {
                let names = try await requireSession().tables(in: schema)
                guard let current = schemas.firstIndex(where: { $0.name == schema }) else { return }
                schemas[current].tables = names.map { DatabaseTable(schema: schema, name: $0) }
                schemas[current].isLoaded = true
            } catch { show(error) }
        }
    }

    func browse(_ table: DatabaseTable) {
        selectedTable = table
        do { sql = "SELECT * FROM \(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name)) LIMIT 200;" }
        catch { show(error); return }
        runCurrentQuery()
    }

    func runCurrentQuery() {
        let statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { return }
        isRunning = true; errorMessage = nil
        Task {
            do { result = try await requireSession().query(statement) }
            catch { show(error) }
            isRunning = false
        }
    }

    private func requireSession() throws -> any DatabaseSession {
        guard let session else { throw DatabaseError.notConnected }
        return session
    }

    private func loadPassword() {
        guard let id = selectedProfileID else { password = ""; return }
        password = (try? keychain.password(for: id)) ?? ""
    }

    private func show(_ error: Error) { errorMessage = error.localizedDescription }
}
