import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [ConnectionProfile]
    @Published var selectedProfileID: UUID?
    @Published var password = ""
    @Published var schemas: [DatabaseSchema] = []
    @Published var selectedTable: DatabaseTable?
    @Published var selectedDatabase = ""
    @Published var tableColumns: [String: [TableColumn]] = [:]
    @Published var sql = "SELECT VERSION() AS version;"
    @Published var result = QueryResult.empty
    @Published var isConnected = false
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var connectedProfileID: UUID?
    @Published var connectingProfileID: UUID?
    @Published var schemaLoadState: MetadataLoadState = .idle

    private let profileStore: ProfileStore
    private let keychain: PasswordStoring
    private let driver: any DatabaseDriver
    private var session: (any DatabaseSession)?
    private var connectionAttemptID: UUID?
    private var resultTable: DatabaseTable?

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
        if connectedProfileID == id || connectingProfileID == id { disconnect() }
        Task { try? keychain.deletePassword(for: id) }
        profiles.removeAll { $0.id == id }
        if profiles.isEmpty { profiles = [.local] }
        selectedProfileID = profiles.first?.id; saveProfiles(); loadPassword()
    }

    func saveProfiles() { profileStore.save(profiles) }

    func selectProfile(_ id: UUID?) {
        selectedProfileID = id; loadPassword()
    }

    func connect(to profileID: UUID? = nil) {
        if let profileID { selectProfile(profileID) }
        guard let profile = selectedProfile else { return }
        let attemptID = UUID()
        connectionAttemptID = attemptID
        connectingProfileID = profile.id
        connectedProfileID = nil
        isConnected = false
        isRunning = true
        errorMessage = nil
        schemas = []
        tableColumns = [:]
        schemaLoadState = .loading
        Task {
            do {
                let previousSession = session
                session = nil
                await previousSession?.close()
                try keychain.save(password, for: profile.id)
                let newSession = try await driver.connect(profile: profile, password: password)
                guard connectionAttemptID == attemptID else {
                    await newSession.close()
                    return
                }
                session = newSession
                connectedProfileID = profile.id
                connectingProfileID = nil
                isConnected = true
                await loadSchemas()
            } catch {
                guard connectionAttemptID == attemptID else { return }
                connectingProfileID = nil
                connectedProfileID = nil
                schemaLoadState = .failed(error.localizedDescription)
                show(error)
            }
            if connectionAttemptID == attemptID { isRunning = false }
        }
    }

    func disconnect() {
        connectionAttemptID = nil
        connectingProfileID = nil
        connectedProfileID = nil
        isConnected = false
        isRunning = false
        schemas = []
        schemaLoadState = .idle
        result = .empty
        resultTable = nil
        let sessionToClose = session
        session = nil
        Task { await sessionToClose?.close() }
    }

    func loadSchemas() async {
        schemaLoadState = .loading
        do {
            let names = try await requireSession().schemas()
            schemas = names.map { DatabaseSchema(name: $0) }
            if selectedDatabase.isEmpty || !names.contains(selectedDatabase) {
                selectedDatabase = selectedProfile?.database.nonEmpty ?? names.first ?? ""
            }
            schemaLoadState = .loaded
        } catch {
            schemas = []
            schemaLoadState = .failed(error.localizedDescription)
            show(error)
        }
    }

    func loadTables(in schema: String, force: Bool = false) async {
        guard let index = schemas.firstIndex(where: { $0.name == schema }) else { return }
        if !force, schemas[index].tableLoadState == .loaded || schemas[index].tableLoadState == .loading { return }
        schemas[index].tableLoadState = .loading
        do {
            let names = try await requireSession().tables(in: schema)
            guard let current = schemas.firstIndex(where: { $0.name == schema }) else { return }
            schemas[current].tables = names.map { DatabaseTable(schema: schema, name: $0) }
            schemas[current].tableLoadState = .loaded
        } catch {
            guard let current = schemas.firstIndex(where: { $0.name == schema }) else { return }
            schemas[current].tables = []
            schemas[current].tableLoadState = .failed(error.localizedDescription)
            show(error)
        }
    }

    func browse(_ table: DatabaseTable) {
        selectedTable = table
        selectedDatabase = table.schema
        Task { await loadColumns(in: table) }
        do { sql = "SELECT * FROM \(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name)) LIMIT 200;" }
        catch { show(error); return }
        runQuery(sourceTable: table)
    }

    func runCurrentQuery() {
        runQuery(sourceTable: nil)
    }

    private func runQuery(sourceTable: DatabaseTable?) {
        let normalized = SQLInputNormalizer.normalize(sql)
        if normalized != sql { sql = normalized }
        let statement = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { return }
        isRunning = true; errorMessage = nil
        Task {
            do {
                if !selectedDatabase.isEmpty {
                    _ = try await requireSession().query("USE \(try SQLIdentifier.quote(selectedDatabase));")
                }
                result = try await requireSession().query(statement)
                resultTable = sourceTable
            }
            catch { resultTable = nil; show(error) }
            isRunning = false
        }
    }

    func loadColumns(in table: DatabaseTable, force: Bool = false) async {
        if !force, tableColumns[table.id] != nil { return }
        do { tableColumns[table.id] = try await requireSession().columns(in: table) }
        catch { show(error) }
    }

    func insertWhereTemplate() {
        guard let table = selectedTable else { return }
        let columns = tableColumns[table.id] ?? []
        guard let column = columns.first(where: \.isPrimaryKey) ?? columns.first else { return }
        let suffix = " WHERE `\(column.name.replacingOccurrences(of: "`", with: "``"))` = ''"
        var statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while statement.last == ";" { statement.removeLast() }
        sql = statement + suffix + ";"
    }

    func updateCell(row: Int, column: Int, value: String) {
        guard let table = resultTable,
              result.rows.indices.contains(row), result.columns.indices.contains(column),
              hasUsablePrimaryKey(for: table) else { return }
        let columns = result.columns
        let values = result.rows[row]
        let refreshSQL = sql
        Task {
            do {
                let target = try SQLIdentifier.quote(columns[column])
                let predicate = try primaryKeyPredicate(for: table, columns: columns, values: values)
                let sql = "UPDATE \(try qualified(table)) SET \(target) = \(try literal(value)) WHERE \(predicate) LIMIT 1;"
                _ = try await requireSession().query(sql)
                result = try await requireSession().query(refreshSQL)
            } catch { show(error) }
        }
    }

    func deleteRow(_ row: Int) {
        guard let table = resultTable, result.rows.indices.contains(row), hasUsablePrimaryKey(for: table) else { return }
        let columns = result.columns
        let values = result.rows[row]
        let refreshSQL = sql
        Task {
            do {
                let predicate = try primaryKeyPredicate(for: table, columns: columns, values: values)
                let sql = "DELETE FROM \(try qualified(table)) WHERE \(predicate) LIMIT 1;"
                _ = try await requireSession().query(sql)
                result = try await requireSession().query(refreshSQL)
            } catch { show(error) }
        }
    }

    var canMutateSelectedTable: Bool {
        guard let table = resultTable else { return false }
        return hasUsablePrimaryKey(for: table)
    }

    private func primaryKeys(for table: DatabaseTable) -> [TableColumn] { tableColumns[table.id]?.filter(\.isPrimaryKey) ?? [] }
    private func hasUsablePrimaryKey(for table: DatabaseTable) -> Bool {
        let keys = primaryKeys(for: table)
        return !keys.isEmpty && keys.allSatisfy { result.columns.contains($0.name) }
    }
    private func primaryKeyPredicate(for table: DatabaseTable, columns: [String], values: [String]) throws -> String {
        try primaryKeys(for: table).map { key in
            let index = columns.firstIndex(of: key.name)!
            return "\(try SQLIdentifier.quote(key.name)) = \(try literal(values[index]))"
        }.joined(separator: " AND ")
    }
    private func qualified(_ table: DatabaseTable) throws -> String { "\(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))" }
    private func literal(_ value: String) throws -> String { value == "NULL" ? "NULL" : try SQLStringLiteral.quote(value) }

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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
