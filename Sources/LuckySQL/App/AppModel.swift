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
    @Published var isRunning = false {
        didSet { if isRunning && !oldValue { busySince = Date() }; if !isRunning { busySince = nil; busyStage = "" } }
    }
    @Published var busySince: Date?
    @Published var busyStage = ""
    @Published var executingTabID: UUID?
    @Published var isCancelling = false
    @Published var showTableFinder = false
    @Published var recentTables: [DatabaseTable] = []
    @Published var renamingTab: UUID?
    @Published var closingTab: UUID?
    @Published var resultBudgetNote: String?
    let editorSessions = EditorSessions()
    private var cancelRequested = false
    private var columnsTasks: [String: Task<[TableColumn], Error>] = [:]
    private var structureCache: [String: TableStructure] = [:]
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
    private var completionTask: Task<Void, Never>?
    private var completionFailures = Set<String>()

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
            scheduleCompletionMetadata()
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
    var completionCatalog: SQLCompletionCatalog {
        SQLCompletionCatalog(schemas: schemas, columns: tableColumns, database: selectedDatabase)
    }
    func scheduleCompletionMetadata() {
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.isConnected else { return }
            await self.loadCompletionMetadata()
        }
    }
    func loadCompletionMetadata() async {
        guard isConnected, !isRunning else { return }
        let epoch = connectionAttemptID
        let database = selectedDatabase
        if !database.isEmpty { await loadTables(in: database) }
        let source = sql, selection = sqlSelection
        let analysis = await Task.detached(priority: .utility) {
            let statement = SQLTools.executable(source, selection: selection)
            return (SQLCompletion.references(statement, database: database), SQLTools.tokens(statement))
        }.value
        guard !Task.isCancelled, epoch == connectionAttemptID, !isRunning else { return }
        let references = analysis.0
        for name in Set(references.map { $0.table.schema }) {
            guard !Task.isCancelled, epoch == connectionAttemptID else { return }
            await loadTables(in: name)
        }
        // Also load a qualified schema as soon as the user types schema.
        let tokens = analysis.1
        for schema in schemas where tokens.contains(where: { $0.text == schema.name || $0.text == "`\(schema.name)`" }) {
            guard !Task.isCancelled, epoch == connectionAttemptID else { return }
            await loadTables(in: schema.name)
        }
        for reference in references {
            guard !Task.isCancelled, epoch == connectionAttemptID else { return }
            let table = reference.table
            guard tableColumns[table.id] == nil, !completionFailures.contains(table.id),
                  schemas.contains(where: { $0.tables.contains(table) }) else { continue }
            do {
                let columns = try await cachedColumns(in: table)
                if epoch == connectionAttemptID { tableColumns[table.id] = columns }
            } catch { if epoch == connectionAttemptID { completionFailures.insert(table.id) } }
        }
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
    func flushWorkspace() { saveWorkspace(); workspaceStore.flush() }
    func renameTab(_ id: UUID, title: String) {
        guard let index = queryTabs.firstIndex(where: { $0.id == id }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        queryTabs[index].title = String(title.prefix(80)); saveWorkspace()
    }
    func requestCloseTab(_ id: UUID) {
        guard !isRunning, let tab = queryTabs.first(where: { $0.id == id }) else { return }
        if tab.isDirty { closingTab = id } else { closeTab(id) }
    }
    func cycleTab(_ direction: Int) { selectTab(queryTabs[(activeTabIndex + direction + queryTabs.count) % queryTabs.count].id) }
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
        editorSessions.remove(id)
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
                recentTables = (try? JSONDecoder().decode([DatabaseTable].self, from: UserDefaults.standard.data(forKey: "recentTables.\(profile.id)") ?? Data())) ?? []
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
        completionTask?.cancel(); completionFailures = []
        columnsTasks = [:]; structureCache = [:]; recentTables = []
        executingTabID = nil; cancelRequested = false; isCancelling = false
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
            tableColumns = [:]; structureCache = [:]; columnsTasks = [:]; completionFailures = []
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
        if force {
            for table in schemas[index].tables { tableColumns.removeValue(forKey: table.id); structureCache.removeValue(forKey: table.id); columnsTasks.removeValue(forKey: table.id) }
        }
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
            let columns = try await cachedColumns(in: table, force: force)
            if epoch == connectionAttemptID { tableColumns[table.id] = columns }
        } catch { if epoch == connectionAttemptID { show(error) } }
    }
    private func cachedColumns(in table: DatabaseTable, force: Bool = false) async throws -> [TableColumn] {
        if !force, let value = tableColumns[table.id] { return value }
        if let task = columnsTasks[table.id] { return try await task.value }
        let session = try requireSession(), epoch = connectionAttemptID
        let task = Task { try await session.columns(in: table) }
        columnsTasks[table.id] = task
        do {
            let value = try await task.value
            if epoch == connectionAttemptID { columnsTasks.removeValue(forKey: table.id); tableColumns[table.id] = value }
            return value
        } catch { if epoch == connectionAttemptID { columnsTasks.removeValue(forKey: table.id) }; throw error }
    }
    func loadAllTablesForSearch() async {
        for name in schemas.map(\.name) {
            guard !Task.isCancelled, isConnected, !isRunning else { return }
            await loadTables(in: name)
        }
    }
    func browse(_ table: DatabaseTable) {
        guard !isRunning else { return }
        if selectedTable != table { browseOptions = TableBrowseOptions(); structureState = .idle; structure = TableStructure(); browseResult = .empty }
        selectedTable = table; section = .data; refreshData()
        recentTables.removeAll { $0 == table }; recentTables.insert(table, at: 0); recentTables = Array(recentTables.prefix(15))
        if let id = connectedProfileID, let data = try? JSONEncoder().encode(recentTables) { UserDefaults.standard.set(data, forKey: "recentTables.\(id)") }
    }
    func refreshData(resetPage: Bool = false, forceMetadata: Bool = false) {
        guard !isRunning, let table = selectedTable else { return }
        if resetPage { browseOptions.page = 0 }
        isRunning = true; errorMessage = nil; resultTable = nil
        let epoch = connectionAttemptID; let request = UUID(); previewID = request
        Task {
            defer { if epoch == connectionAttemptID { isRunning = false } }
            do {
                let session = try requireSession()
                busyStage = NSLocalizedString("Loading table metadata", comment: "")
                if forceMetadata { structureCache.removeValue(forKey: table.id) }
                let columns = try await cachedColumns(in: table, force: forceMetadata)
                guard epoch == connectionAttemptID, previewID == request else { return }
                tableColumns[table.id] = columns
                let query = try browseOptions.query(for: table, primaryKeys: columns.filter(\.isPrimaryKey).map(\.name))
                busyStage = NSLocalizedString("Loading table data", comment: "")
                let rows = try await session.query(query)
                guard epoch == connectionAttemptID, previewID == request else { return }
                lastBrowseSQL = query; resultTable = table; acceptBrowseResult(rows)
            } catch { if epoch == connectionAttemptID { show(error) } }
        }
    }
    private func acceptBrowseResult(_ rows: QueryResult) {
        hasNextPage = rows.rows.count > browseOptions.pageSize
        browseResult = QueryResult(columns: rows.columns, rows: Array(rows.rows.prefix(browseOptions.pageSize)), elapsed: rows.elapsed,
                                   message: rows.isTruncated ? rows.message : "\(min(rows.rows.count, browseOptions.pageSize)) row(s)",
                                   nullCells: Set(rows.nullCells.filter { $0.row < browseOptions.pageSize }), isTruncated: rows.isTruncated, retainedBytes: rows.retainedBytes)
        trimResultMemory(preserving: browseResult.id)
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
    func showStructure(_ table: DatabaseTable? = nil, force: Bool = false) {
        guard !isRunning else { return }
        if let table, table != selectedTable {
            selectedTable = table; browseOptions = TableBrowseOptions(); browseResult = .empty; resultTable = nil
        }
        guard let table = selectedTable else { return }
        if !force, let cached = structureCache[table.id] { structure = cached; structureState = .loaded; section = .structure; return }
        section = .structure; structureState = .loading; isRunning = true
        let epoch = connectionAttemptID
        Task {
            defer { if epoch == connectionAttemptID { isRunning = false } }
            do {
                let details = try await requireSession().structure(in: table)
                guard epoch == connectionAttemptID else { return }
                if structureCache.count >= 32 { structureCache.removeAll() }
                structure = details; structureCache[table.id] = details; tableColumns[table.id] = details.columns; structureState = .loaded
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
        let source = sql, selection = sqlSelection, database = selectedDatabase, tab = activeTabID, epoch = connectionAttemptID
        if source.utf16.count > 32_768 {
            isRunning = true; busyStage = NSLocalizedString("Analyzing SQL", comment: "")
            Task {
                let plan = await Task.detached(priority: .userInitiated) { SQLExecutionPlan.prepare(source, selection: selection, all: all) }.value
                guard epoch == connectionAttemptID else { return }
                isRunning = false; submit(plan, database: database, tab: tab)
            }
        } else { submit(SQLExecutionPlan.prepare(source, selection: selection, all: all), database: database, tab: tab) }
    }
    private func submit(_ plan: SQLExecutionPlan, database: String, tab: UUID) {
        if let error = plan.error { errorMessage = error; return }
        guard !plan.sql.isEmpty else { return }
        let request = (plan.sql, database, tab)
        if isReadOnly && plan.confirmation {
            errorMessage = "Read-only protection blocks statements that can change data or server state. Use a server-side read-only account for a security boundary."; return
        }
        if plan.confirmation { pendingExecution = request; pendingSQL = plan.sql }
        else { execute(request) }
    }
    func confirmExecution() {
        guard let request = pendingExecution else { return }
        guard !isReadOnly else { cancelExecution(); errorMessage = "Read-only protection is enabled."; return }
        pendingSQL = nil; pendingExecution = nil; execute(request)
    }
    func cancelExecution() { pendingSQL = nil; pendingExecution = nil }
    var isReadOnly: Bool { profiles.first(where: { $0.id == connectedProfileID })?.readOnly == true }
    var isProduction: Bool { profiles.first(where: { $0.id == connectedProfileID })?.environment == "Production" }
    var connectionLabel: String {
        guard let profile = profiles.first(where: { $0.id == connectedProfileID }) else { return "" }
        return "\(NSLocalizedString(profile.environment ?? "Development", comment: "")) · \(profile.name) · \(profile.host):\(profile.port)" + (isReadOnly ? " · " + NSLocalizedString("READ ONLY", comment: "") : "")
    }
    func cancelCurrentQuery() {
        guard executingTabID != nil, !isCancelling, let session else { return }
        cancelRequested = true; isCancelling = true; busyStage = NSLocalizedString("Cancelling current query", comment: "")
        let epoch = connectionAttemptID
        Task {
            do { try await session.cancelQuery() }
            catch { if epoch == connectionAttemptID { show(error) } }
            if epoch == connectionAttemptID { isCancelling = false }
        }
    }
    private func execute(_ request: (sql: String, database: String, tabID: UUID)) {
        guard !isRunning, isConnected else { return }
        isRunning = true; errorMessage = nil
        cancelRequested = false; executingTabID = request.tabID; busyStage = NSLocalizedString("Preparing query", comment: "")
        let epoch = connectionAttemptID
        let connectionName = profiles.first { $0.id == connectedProfileID }?.name ?? ""
        Task {
            defer {
                if epoch == connectionAttemptID {
                    if cancelRequested { record(request.sql, database: request.database, connection: connectionName, outcome: "Cancellation requested · batch stopped; committed writes are not rolled back") }
                    isRunning = false; executingTabID = nil
                }
            }
            do {
                let session = try requireSession()
                if !request.database.isEmpty { _ = try await session.query("USE \(try SQLIdentifier.quote(request.database));") }
                let statements = await Task.detached { SQLTools.statements(request.sql).map { (sql: $0.sql, writes: SQLTools.requiresConfirmation($0.sql)) } }.value
                var receivedResult = false
                for (number, statement) in statements.enumerated() {
                    guard epoch == connectionAttemptID, !cancelRequested else { return }
                    busyStage = String(format: NSLocalizedString("Executing statement %ld/%ld · previous result retained until ready", comment: ""), number + 1, statements.count)
                    let result = try await session.query(statement.sql.trimmingCharacters(in: .whitespacesAndNewlines))
                    guard epoch == connectionAttemptID, !cancelRequested, let index = queryTabs.firstIndex(where: { $0.id == request.tabID }) else { return }
                    if !receivedResult { queryTabs[index].results = []; receivedResult = true }
                    queryTabs[index].results.append(result); queryTabs[index].result = result
                    trimResultMemory(preserving: result.id)
                    if statement.writes { tableColumns = [:]; structureCache = [:]; completionFailures = [] }
                    record(statement.sql, database: request.database, connection: connectionName, outcome: result.message)
                }
            } catch {
                if epoch == connectionAttemptID {
                    if !cancelRequested { record(request.sql, database: request.database, connection: connectionName, outcome: "Error: \(error.localizedDescription)"); show(error) }
                }
            }
        }
    }
    func trimResultMemory(preserving id: UUID) {
        var unique: [UUID: Int] = [browseResult.id: browseResult.retainedBytes]
        for tab in queryTabs { for result in tab.results + [tab.result] { unique[result.id] = result.retainedBytes } }
        var bytes = unique.values.reduce(0, +)
        guard bytes > 64 * 1024 * 1024 else { return }
        for index in queryTabs.indices {
            for old in queryTabs[index].results + [queryTabs[index].result] where old.id != id {
                guard bytes > 64 * 1024 * 1024 else { return }
                guard let size = unique.removeValue(forKey: old.id) else { continue }
                bytes -= size
                queryTabs[index].results.removeAll { $0.id == old.id }
                if queryTabs[index].result.id == old.id { queryTabs[index].result = queryTabs[index].results.last ?? .empty }
                resultBudgetNote = "Older result previews were released to keep the workspace within its 64 MB data budget. SQL drafts are unchanged."
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
        guard !isReadOnly, !browseResult.isTruncated, section == .data, let table = resultTable, table == selectedTable else { return false }
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
    func copyResult(separator: String) {
        let snapshot = result
        Task {
            let text = await Task.detached(priority: .userInitiated) { ResultExport.csv(snapshot, separator: separator) }.value
            copy(text)
        }
    }
    func formatSQL() {
        let source = sql, id = activeTabID
        Task {
            let formatted = await Task.detached(priority: .userInitiated) { SQLTools.format(source) }.value
            guard let index = queryTabs.firstIndex(where: { $0.id == id }), queryTabs[index].sql == source else { return }
            queryTabs[index].sql = formatted; saveWorkspace()
        }
    }
    func openSQLFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "sql") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 2_000_000 else { throw SQLFileTooLarge() }
                    return try String(contentsOf: url, encoding: .utf8)
                }.value
                newQuery(sql: text, title: url.lastPathComponent)
                queryTabs[activeTabIndex].fileURL = url; queryTabs[activeTabIndex].savedSQL = text
            } catch { show(error) }
        }
    }
    func saveSQLFile() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = queryTabs[activeTabIndex].fileURL?.lastPathComponent ?? "query.sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = sql, id = activeTabID
        Task {
            do {
                try await Task.detached(priority: .utility) { try source.write(to: url, atomically: true, encoding: .utf8) }.value
                if let index = queryTabs.firstIndex(where: { $0.id == id }) {
                    queryTabs[index].fileURL = url; queryTabs[index].title = url.lastPathComponent; queryTabs[index].savedSQL = source; saveWorkspace()
                }
            } catch { show(error) }
        }
    }
    func exportResult(json: Bool) {
        let value = result
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(section == .data ? selectedTable?.name ?? "data" : "result").\(json ? "json" : "csv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await Task.detached(priority: .utility) { try (json ? ResultExport.json(value) : ResultExport.csv(value)).write(to: url, atomically: true, encoding: .utf8) }.value }
            catch { show(error) }
        }
    }
}

private struct SQLFileTooLarge: LocalizedError {
    var errorDescription: String? { "SQL files above 2 MB require a streaming import tool." }
}
