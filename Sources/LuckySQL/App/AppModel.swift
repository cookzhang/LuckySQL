import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [ConnectionProfile]
    @Published var selectedProfileID: UUID?
    @Published var password = ""
    @Published var isLoadingPassword = false
    @Published var schemas: [DatabaseSchema] = []
    @Published var selectedTable: DatabaseTable?
    @Published var selectedDatabase = ""
    @Published var tableColumns: [String: [TableColumn]] = [:]
    @Published var section: WorkspaceSection = .query
    @Published var queryTabs: [QueryTab]
    @Published var activeTabID: UUID
    @Published var browseResult = QueryResult.empty
    @Published var browseOptions = TableBrowseOptions()
    @Published var hasNextPage = false
    @Published var structure = TableStructure()
    @Published var structureState: MetadataLoadState = .idle
    @Published var history: [QueryHistoryEntry]
    @Published var favorites: Set<String>
    @Published var showHistory = false
    @Published var isConnected = false
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var connectedProfileID: UUID?
    @Published var connectingProfileID: UUID?
    @Published var schemaLoadState: MetadataLoadState = .idle
    @Published var pendingSQL: String?
    private var pendingExecution: (sql: String, database: String, tabID: UUID)?
    private let profileStore: ProfileStore
    private let workspaceStore: WorkspaceStore
    private let keychain: PasswordStoring
    private let driver: any DatabaseDriver
    private var session: (any DatabaseSession)?
    private var connectionAttemptID: UUID?
    private var previewID = UUID()
    private var resultTable: DatabaseTable?
    private var lastBrowseSQL = ""
    private var draftSaveTask: Task<Void, Never>?
    private var passwordLoadTask: Task<Void, Never>?

    init(profileStore: ProfileStore? = nil, keychain: PasswordStoring = KeychainStore(), driver: any DatabaseDriver = MySQLDriver(), workspaceStore: WorkspaceStore? = nil) {
        let profileStore = profileStore ?? ProfileStore()
        let workspaceStore = workspaceStore ?? WorkspaceStore()
        self.profileStore = profileStore; self.workspaceStore = workspaceStore
        self.keychain = keychain; self.driver = driver
        let savedProfiles = profileStore.load()
        profiles = savedProfiles; selectedProfileID = savedProfiles.first?.id
        let saved = workspaceStore.loadTabs()
        let tabs = saved.isEmpty ? [QueryTab(title: "Query 1", sql: "SELECT VERSION() AS version;", database: "")] : saved
        let activeIndex = max(0, min(workspaceStore.activeIndex(), tabs.count - 1))
        queryTabs = tabs; activeTabID = tabs[activeIndex].id; selectedDatabase = tabs[activeIndex].database
        history = workspaceStore.loadHistory(); favorites = workspaceStore.loadFavorites()
        loadPassword()
    }
    var activeTabIndex: Int { queryTabs.firstIndex { $0.id == activeTabID } ?? 0 }
    var sql: String {
        get { queryTabs[activeTabIndex].sql }
        set {
            queryTabs[activeTabIndex].sql = newValue
            draftSaveTask?.cancel()
            draftSaveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.saveWorkspace()
            }
        }
    }
    var sqlSelection: NSRange {
        get { queryTabs[activeTabIndex].selection }
        set { queryTabs[activeTabIndex].selection = newValue }
    }
    var result: QueryResult { section == .query ? queryTabs[activeTabIndex].result : browseResult }
    var completionWords: [String] {
        Array(Set(schemas.flatMap { $0.tables.map(\.name) } + (selectedTable.flatMap { tableColumns[$0.id] } ?? []).map(\.name) + Array(SQLTools.keywords))).sorted()
    }
    var selectedProfile: ConnectionProfile? {
        get { profiles.first { $0.id == selectedProfileID } }
        set {
            guard let newValue, let index = profiles.firstIndex(where: { $0.id == newValue.id }) else { return }
            profiles[index] = newValue
        }
    }
    func saveWorkspace() {
        queryTabs[activeTabIndex].database = selectedDatabase
        workspaceStore.saveTabs(queryTabs)
        workspaceStore.saveActiveIndex(activeTabIndex)
    }
    func newQuery(sql text: String = "", title: String? = nil) {
        saveWorkspace()
        let tab = QueryTab(title: title ?? "Query \(queryTabs.count + 1)", sql: text, database: selectedDatabase)
        queryTabs.append(tab); activeTabID = tab.id; section = .query; saveWorkspace()
    }
    func selectTab(_ id: UUID) {
        guard queryTabs.contains(where: { $0.id == id }) else { return }
        saveWorkspace(); activeTabID = id; selectedDatabase = queryTabs[activeTabIndex].database; section = .query
        workspaceStore.saveActiveIndex(activeTabIndex)
    }
    func closeTab(_ id: UUID) {
        guard !isRunning else { return }
        queryTabs.removeAll { $0.id == id }
        if queryTabs.isEmpty { queryTabs = [QueryTab(title: "Query 1", sql: "", database: selectedDatabase)] }
        if activeTabID == id { activeTabID = queryTabs[0].id; selectedDatabase = queryTabs[0].database }
        saveWorkspace()
    }
    func toggleFavorite(_ table: DatabaseTable) {
        let key = favoriteKey(table)
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
        workspaceStore.saveFavorites(favorites)
    }
    func isFavorite(_ table: DatabaseTable) -> Bool { favorites.contains(favoriteKey(table)) }
    private func favoriteKey(_ table: DatabaseTable) -> String { "\(connectedProfileID?.uuidString ?? "")/\(table.id)" }
    func clearHistory() { history = []; workspaceStore.saveHistory([]) }
    func addProfile() {
        let profile = ConnectionProfile(name: "New Connection")
        profiles.append(profile); selectedProfileID = profile.id; loadPassword(); saveProfiles()
    }
    func deleteSelectedProfile() {
        guard let id = selectedProfileID else { return }
        if connectedProfileID == id || connectingProfileID == id { disconnect() }
        Task { try? await keychain.deletePassword(for: id) }
        profiles.removeAll { $0.id == id }
        if profiles.isEmpty { profiles = [.local] }
        selectedProfileID = profiles.first?.id; saveProfiles(); loadPassword()
    }
    func saveProfiles() { profileStore.save(profiles) }
    func selectProfile(_ id: UUID?) { selectedProfileID = id; loadPassword() }
    func connect(to profileID: UUID? = nil) {
        guard !isRunning else { return }
        if let profileID { selectProfile(profileID) }
        guard let profile = selectedProfile else { return }
        let attemptID = UUID(); connectionAttemptID = attemptID
        connectingProfileID = profile.id; connectedProfileID = nil
        isConnected = false; isRunning = true; errorMessage = nil
        resetMetadata(); schemaLoadState = .loading
        Task {
            do {
                await passwordLoadTask?.value
                guard connectionAttemptID == attemptID else { return }
                let password = self.password
                let previousSession = session; session = nil
                await previousSession?.close()
                let newSession = try await driver.connect(profile: profile, password: password)
                guard connectionAttemptID == attemptID else { await newSession.close(); return }
                do { try await keychain.save(password, for: profile.id) }
                catch { await newSession.close(); throw error }
                guard connectionAttemptID == attemptID else { await newSession.close(); return }
                session = newSession; connectedProfileID = profile.id; connectingProfileID = nil; isConnected = true
                await loadSchemas()
            } catch {
                guard connectionAttemptID == attemptID else { return }
                connectingProfileID = nil; connectedProfileID = nil
                schemaLoadState = .failed(error.localizedDescription); show(error)
            }
            if connectionAttemptID == attemptID { isRunning = false }
        }
    }
    func disconnect() {
        let wasRunning = isRunning
        saveWorkspace(); connectionAttemptID = nil; previewID = UUID()
        connectingProfileID = nil; connectedProfileID = nil; isConnected = false; isRunning = false
        resetMetadata(); schemaLoadState = .idle; pendingSQL = nil; pendingExecution = nil
        let old = session; session = nil
        Task { if wasRunning { await old?.cancel() } else { await old?.close() } }
    }
    private func resetMetadata() {
        schemas = []; tableColumns = [:]; selectedTable = nil
        browseResult = .empty; resultTable = nil; structure = TableStructure(); structureState = .idle
        for index in queryTabs.indices { queryTabs[index].result = .empty; queryTabs[index].results = [] }
    }
    func loadSchemas() async {
        let epoch = connectionAttemptID
        schemaLoadState = .loading
        do {
            let names = try await requireSession().schemas()
            guard epoch == connectionAttemptID else { return }
            schemas = names.map { DatabaseSchema(name: $0) }
            if !names.contains(selectedDatabase) {
                let preferred = selectedProfile?.database ?? ""
                let system = Set(["information_schema", "mysql", "performance_schema", "sys"])
                selectedDatabase = names.contains(preferred) ? preferred : names.first(where: { !system.contains($0) }) ?? names.first ?? ""
            }
            schemaLoadState = .loaded
        } catch { if epoch == connectionAttemptID { schemaLoadState = .failed(error.localizedDescription); show(error) } }
    }
    func loadTables(in schema: String, force: Bool = false) async {
        guard let index = schemas.firstIndex(where: { $0.name == schema }) else { return }
        if !force, schemas[index].tableLoadState == .loaded || schemas[index].tableLoadState == .loading { return }
        let epoch = connectionAttemptID
        schemas[index].tableLoadState = .loading
        do {
            let names = try await requireSession().tables(in: schema)
            guard epoch == connectionAttemptID, let current = schemas.firstIndex(where: { $0.name == schema }) else { return }
            schemas[current].tables = names.map { DatabaseTable(schema: schema, name: $0) }
            schemas[current].tableLoadState = .loaded
        } catch {
            guard epoch == connectionAttemptID, let current = schemas.firstIndex(where: { $0.name == schema }) else { return }
            schemas[current].tableLoadState = .failed(error.localizedDescription); show(error)
        }
    }
    func loadColumns(in table: DatabaseTable, force: Bool = false) async {
        if !force, tableColumns[table.id] != nil { return }
        let epoch = connectionAttemptID
        do {
            let columns = try await requireSession().columns(in: table)
            if epoch == connectionAttemptID { tableColumns[table.id] = columns }
        } catch { if epoch == connectionAttemptID { show(error) } }
    }
    func browse(_ table: DatabaseTable) {
        guard !isRunning else { return }
        if selectedTable != table { browseOptions = TableBrowseOptions(); structureState = .idle; structure = TableStructure() }
        selectedTable = table; section = .data; refreshData()
    }
    func refreshData(resetPage: Bool = false) {
        guard !isRunning, let table = selectedTable else { return }
        if resetPage { browseOptions.page = 0 }
        isRunning = true; errorMessage = nil; resultTable = nil
        let epoch = connectionAttemptID; let request = UUID(); previewID = request
        Task {
            defer { if epoch == connectionAttemptID { isRunning = false } }
            do {
                let session = try requireSession()
                let columns = try await session.columns(in: table)
                guard epoch == connectionAttemptID, previewID == request else { return }
                tableColumns[table.id] = columns
                let query = try browseOptions.query(for: table, primaryKeys: columns.filter(\.isPrimaryKey).map(\.name))
                let rows = try await session.query(query)
                guard epoch == connectionAttemptID, previewID == request else { return }
                lastBrowseSQL = query; resultTable = table; acceptBrowseResult(rows)
            } catch { if epoch == connectionAttemptID { show(error) } }
        }
    }
    private func acceptBrowseResult(_ rows: QueryResult) {
        hasNextPage = rows.rows.count > browseOptions.pageSize
        browseResult = QueryResult(columns: rows.columns, rows: Array(rows.rows.prefix(browseOptions.pageSize)), elapsed: rows.elapsed,
                                   message: "\(min(rows.rows.count, browseOptions.pageSize)) row(s)",
                                   nullCells: Set(rows.nullCells.filter { $0.row < browseOptions.pageSize }))
    }
    func nextPage(_ delta: Int) {
        guard !isRunning, (delta < 0 ? browseOptions.page > 0 : hasNextPage) else { return }
        browseOptions.page += delta; refreshData()
    }
    func sortData(column: String) {
        guard !isRunning else { return }
        if browseOptions.sortColumn == column { browseOptions.descending.toggle() }
        else { browseOptions.sortColumn = column; browseOptions.descending = false }
        refreshData(resetPage: true)
    }
    func showStructure(_ table: DatabaseTable? = nil) {
        guard !isRunning else { return }
        if let table, table != selectedTable {
            selectedTable = table; browseOptions = TableBrowseOptions(); browseResult = .empty; resultTable = nil
        }
        guard let table = selectedTable else { return }
        section = .structure; structureState = .loading; isRunning = true
        let epoch = connectionAttemptID
        Task {
            defer { if epoch == connectionAttemptID { isRunning = false } }
            do {
                let details = try await requireSession().structure(in: table)
                guard epoch == connectionAttemptID else { return }
                structure = details; tableColumns[table.id] = details.columns; structureState = .loaded
            } catch { if epoch == connectionAttemptID { structureState = .failed(error.localizedDescription); show(error) } }
        }
    }
    func changeSection(_ value: WorkspaceSection) {
        if value == .structure { showStructure() }
        else if value == .data, let table = selectedTable {
            if resultTable != table { browse(table) } else { section = value }
        } else { section = value }
    }
    func runCurrentQuery(all: Bool = false) {
        guard isConnected, !isRunning else { return }
        section = .query; saveWorkspace()
        let statement = SQLTools.executable(sql, selection: sqlSelection, all: all)
        guard !SQLTools.statements(statement).isEmpty else { return }
        guard SQLTools.statements(statement).count <= 100 else { errorMessage = "Run at most 100 statements per batch. Use a streaming import tool for larger scripts."; return }
        if SQLTools.tokens(statement).contains(where: { $0.kind == .word && $0.text.uppercased() == "DELIMITER" }) {
            errorMessage = "DELIMITER scripts are not supported yet. Use a dedicated MySQL client for routine scripts."; return
        }
        let request = (statement, selectedDatabase, activeTabID)
        if SQLTools.requiresConfirmation(statement) { pendingExecution = request; pendingSQL = statement }
        else { execute(request) }
    }
    func confirmExecution() {
        guard let request = pendingExecution else { return }
        pendingSQL = nil; pendingExecution = nil; execute(request)
    }
    func cancelExecution() { pendingSQL = nil; pendingExecution = nil }
    private func execute(_ request: (sql: String, database: String, tabID: UUID)) {
        guard !isRunning, isConnected else { return }
        isRunning = true; errorMessage = nil
        let epoch = connectionAttemptID
        let connectionName = profiles.first { $0.id == connectedProfileID }?.name ?? ""
        if let index = queryTabs.firstIndex(where: { $0.id == request.tabID }) { queryTabs[index].results = []; queryTabs[index].result = .empty }
        Task {
            defer { if epoch == connectionAttemptID { isRunning = false } }
            do {
                let session = try requireSession()
                if !request.database.isEmpty { _ = try await session.query("USE \(try SQLIdentifier.quote(request.database));") }
                for statement in SQLTools.statements(request.sql) {
                    guard epoch == connectionAttemptID else { return }
                    let result = try await session.query(statement.sql.trimmingCharacters(in: .whitespacesAndNewlines))
                    guard epoch == connectionAttemptID, let index = queryTabs.firstIndex(where: { $0.id == request.tabID }) else { return }
                    queryTabs[index].results.append(result); queryTabs[index].result = result
                    record(statement.sql, database: request.database, connection: connectionName, outcome: result.message)
                }
            } catch {
                if epoch == connectionAttemptID {
                    record(request.sql, database: request.database, connection: connectionName, outcome: "Error: \(error.localizedDescription)"); show(error)
                }
            }
        }
    }
    private func record(_ sql: String, database: String, connection: String, outcome: String) {
        history.insert(QueryHistoryEntry(date: Date(), sql: sql, database: database, connection: connection, outcome: outcome), at: 0)
        history = Array(history.prefix(100)); workspaceStore.saveHistory(history)
    }
    func explainQuery() {
        let statement = SQLTools.executable(sql, selection: sqlSelection)
        guard !statement.isEmpty, !SQLTools.requiresConfirmation(statement) else { errorMessage = "Choose a SELECT statement to explain."; return }
        newQuery(sql: "EXPLAIN " + statement, title: "Explain"); runCurrentQuery()
    }
    func insertWhereTemplate() {
        guard let table = selectedTable else { return }
        do {
            let column = tableColumns[table.id]?.first(where: \.isPrimaryKey) ?? tableColumns[table.id]?.first
            guard let column else { return }
            newQuery(sql: "SELECT * FROM \(try qualified(table))\nWHERE \(try SQLIdentifier.quote(column.name)) = ''\nLIMIT 100;", title: table.name)
        } catch { show(error) }
    }
    func generateInsert() {
        guard let table = selectedTable else { return }
        let columns = (tableColumns[table.id] ?? []).filter { !$0.extra.contains("auto_increment") && !$0.extra.uppercased().contains("GENERATED") }
        do {
            let names = try columns.map { try SQLIdentifier.quote($0.name) }.joined(separator: ", ")
            let values = columns.map { $0.defaultValue == nil && $0.isNullable ? "NULL" : "DEFAULT" }.joined(separator: ", ")
            newQuery(sql: "-- Review values before running. DEFAULT uses the server default.\nINSERT INTO \(try qualified(table)) (\(names))\nVALUES (\(values));", title: "Insert · \(table.name)")
        } catch { show(error) }
    }
    func updateCell(row: Int, column: Int, value: String, isNull: Bool = false) {
        guard !isRunning, let table = resultTable, canMutateSelectedTable, canEditColumn(column),
              browseResult.rows.indices.contains(row), browseResult.columns.indices.contains(column) else { return }
        do {
            let target = try SQLIdentifier.quote(browseResult.columns[column])
            let predicate = try primaryKeyPredicate(for: table, row: row)
            let value = isNull ? "NULL" : try SQLStringLiteral.quote(value)
            mutate("UPDATE \(try qualified(table)) SET \(target) = \(value) WHERE \(predicate) LIMIT 1;")
        } catch { show(error) }
    }
    func deleteRow(_ row: Int) {
        guard !isRunning, let table = resultTable, canMutateSelectedTable, browseResult.rows.indices.contains(row) else { return }
        do { mutate("DELETE FROM \(try qualified(table)) WHERE \(try primaryKeyPredicate(for: table, row: row)) LIMIT 1;") }
        catch { show(error) }
    }
    private func mutate(_ sql: String) {
        isRunning = true
        let epoch = connectionAttemptID; let refreshSQL = lastBrowseSQL
        Task {
            defer { if epoch == connectionAttemptID { isRunning = false } }
            do {
                let session = try requireSession()
                _ = try await session.query(sql)
                let result = try await session.query(refreshSQL)
                if epoch == connectionAttemptID { acceptBrowseResult(result) }
            } catch { if epoch == connectionAttemptID { show(error) } }
        }
    }
    var canMutateSelectedTable: Bool {
        guard section == .data, let table = resultTable, table == selectedTable else { return false }
        let keys = tableColumns[table.id]?.filter(\.isPrimaryKey) ?? []
        return !keys.isEmpty && keys.allSatisfy { browseResult.columns.contains($0.name) && !isBinary($0.dataType) }
    }
    func canEditColumn(_ index: Int) -> Bool {
        guard canMutateSelectedTable, let table = resultTable, browseResult.columns.indices.contains(index) else { return false }
        guard let column = tableColumns[table.id]?.first(where: { $0.name == browseResult.columns[index] }) else { return false }
        return !isBinary(column.dataType) && !column.extra.uppercased().contains("GENERATED")
    }
    private func isBinary(_ type: String) -> Bool {
        let type = type.lowercased()
        return ["blob", "binary", "geometry", "point", "polygon", "linestring", "bit("].contains { type.contains($0) }
    }
    private func primaryKeyPredicate(for table: DatabaseTable, row: Int) throws -> String {
        try (tableColumns[table.id] ?? []).filter(\.isPrimaryKey).map { key in
            guard let index = browseResult.columns.firstIndex(of: key.name) else { throw DatabaseError.invalidIdentifier(key.name) }
            return "\(try SQLIdentifier.quote(key.name)) = \(try SQLStringLiteral.quote(browseResult.rows[row][index]))"
        }.joined(separator: " AND ")
    }
    private func qualified(_ table: DatabaseTable) throws -> String { "\(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))" }
    private func requireSession() throws -> any DatabaseSession {
        guard let session else { throw DatabaseError.notConnected }; return session
    }
    private func loadPassword() {
        guard let id = selectedProfileID else { passwordLoadTask?.cancel(); password = ""; isLoadingPassword = false; return }
        password = ""; isLoadingPassword = true
        passwordLoadTask?.cancel()
        passwordLoadTask = Task { [weak self, keychain] in
            let saved = try? await keychain.password(for: id)
            guard let self, self.selectedProfileID == id, !Task.isCancelled else { return }
            // Never overwrite a password the user entered while a system
            // authorization dialog was open.
            if self.password.isEmpty { self.password = saved ?? "" }
            self.isLoadingPassword = false
        }
    }
    private func show(_ error: Error) { errorMessage = error.localizedDescription }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    func openSQLFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "sql") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { errorMessage = "SQL files above 2 MB require a streaming import tool."; return }
            newQuery(sql: try String(contentsOf: url, encoding: .utf8), title: url.lastPathComponent)
            queryTabs[activeTabIndex].fileURL = url
        } catch { show(error) }
    }
    func saveSQLFile() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = queryTabs[activeTabIndex].fileURL?.lastPathComponent ?? "query.sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try sql.write(to: url, atomically: true, encoding: .utf8); queryTabs[activeTabIndex].fileURL = url; queryTabs[activeTabIndex].title = url.lastPathComponent; saveWorkspace() }
        catch { show(error) }
    }
    func exportResult(json: Bool) {
        let value = result
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(section == .data ? selectedTable?.name ?? "data" : "result").\(json ? "json" : "csv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (json ? ResultExport.json(value) : ResultExport.csv(value)).write(to: url, atomically: true, encoding: .utf8) }
        catch { show(error) }
    }
}
