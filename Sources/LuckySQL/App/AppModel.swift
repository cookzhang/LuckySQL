import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    var profilesDidChange: (() -> Void)?
    var openConnectionWorkspace: ((ConnectionProfile) -> Void)?
    @Published var profiles: [ConnectionProfile]
    @Published var selectedProfileID: UUID?
    @Published var password = ""
    @Published var isLoadingPassword = false
    @Published var passwordNotice: String?
    @Published var connectionDraft: ConnectionDraft?
    private var sessionPasswords: [UUID: String] = [:]
    @Published var schemas: [DatabaseSchema] = []
    @Published var selectedTable: DatabaseTable?
    @Published var selectedDatabase = ""
    @Published var tableColumns: [String: [TableColumn]] = [:]
    @Published var section: WorkspaceSection = .query
    @Published var queryTabs: [QueryTab]
    @Published var activeTabID: UUID
    @Published var browseResult = QueryResult.empty
    @Published var browseOptions = TableBrowseOptions()
    @Published var appliedBrowseOptions = TableBrowseOptions()
    @Published var browseIsStale = false
    @Published var browseError: String?
    @Published var queryErrors: [UUID: String] = [:]
    private var tableBrowseOptions: [DatabaseTable: TableBrowseOptions] = [:]
    @Published private(set) var operationID: UUID?
    var canCancelOperation: Bool { operationID != nil && isRunning && !isCancelling }
    private func beginOperation() { operationID = UUID(); cancelRequested = false }
    private func endOperation() { operationID = nil; isCancelling = false }
    var hasPendingFilter: Bool {
        browseOptions.filterColumn != appliedBrowseOptions.filterColumn || browseOptions.filterOperator != appliedBrowseOptions.filterOperator || browseOptions.filterValue != appliedBrowseOptions.filterValue
    }
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
    private struct ExecutionRequest {
        let sql: String
        let database: String
        let tabID: UUID
        var parameters: [SQLParameter]? = nil
    }
    private var pendingExecution: ExecutionRequest?
    private let profileStore: ProfileStore
    private let workspaceStore: WorkspaceStore
    private let keychain: PasswordStoring
    private let driver: any DatabaseDriver
    private var session: (any DatabaseSession)?
    private var transferSession: (any DatabaseSession)?
    private var transferTask: Task<Void, Never>?
    @Published var transferStatus = ""
    @Published var showGridChanges = false
    @Published var showSchemaDesigner = false
    @Published var gridChanges: [GridChange] = []
    @Published var gridChangeStatus = ""
    @Published var gridCommitUnknown = false
    private var gridChangeProfileID: UUID?
    var canCommitGridChanges: Bool { isConnected && !isReadOnly && !isRunning && !gridCommitUnknown && !gridChanges.isEmpty && gridChangeProfileID == connectedProfileID }
    private var fullCellValues: [CellAddress: QueryResult] = [:]
    @Published var showTransfer = false
    @Published var importCommitUnknown = false
    private var connectionAttemptID: UUID?
    private var connectionTask: Task<Void, Never>?
    private var previewID = UUID()
    private var resultTable: DatabaseTable?
    private var lastBrowseSQL = ""
    private var draftSaveTask: Task<Void, Never>?
    private var passwordLoadTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var completionFailures = Set<String>()
    private var browsePages = BrowsePageCache()
    private var prefetchTask: Task<Void, Never>?
    private var prefetchSession: (any DatabaseSession)?
    private var prefetchBusy = false
    private var prefetchGeneration = UUID()
    private var allowsBrowsePrefetch = true
    private var previewCredentials: (profile: ConnectionProfile, password: String)?

    init(profileStore: ProfileStore? = nil, keychain: PasswordStoring = RecoveringPasswordStore(), driver: any DatabaseDriver = MySQLDriver(), workspaceStore: WorkspaceStore? = nil) {
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
            queryTabs[activeTabIndex].document.sql = newValue
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
        set { queryTabs[activeTabIndex].document.selection = newValue }
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
            guard !Task.isCancelled, epoch == connectionAttemptID, !isRunning else { return }
            await loadTables(in: name)
        }
        // Also load a qualified schema as soon as the user types schema.
        let tokens = analysis.1
        for schema in schemas where tokens.contains(where: { $0.text == schema.name || $0.text == "`\(schema.name)`" }) {
            guard !Task.isCancelled, epoch == connectionAttemptID, !isRunning else { return }
            await loadTables(in: schema.name)
        }
        for reference in references {
            guard !Task.isCancelled, epoch == connectionAttemptID, !isRunning else { return }
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
        if queryTabs[activeTabIndex].database != selectedDatabase { queryTabs[activeTabIndex].database = selectedDatabase }
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
    func beginNewConnection() {
        guard !isRunning else { return }
        connectionDraft = ConnectionDraft(profile: ConnectionProfile(name: ""), isNew: true)
    }
    func beginEditConnection(_ id: UUID) {
        guard !isRunning, let profile = profiles.first(where: { $0.id == id }) else { return }
        let cached = id == selectedProfileID && !isLoadingPassword ? password : sessionPasswords[id]
        let draft = ConnectionDraft(profile: profile, isNew: false, password: cached ?? "")
        connectionDraft = draft
        if let cached, !cached.isEmpty { return }
        draft.isLoadingPassword = true
        let revision = draft.passwordRevision
        Task { [weak self, weak draft, keychain] in
            let saved: String?
            do { saved = try await keychain.password(for: id) }
            catch { saved = nil }
            guard let self, let draft, self.connectionDraft?.id == draft.id else { return }
            if draft.passwordRevision == revision { draft.password = saved ?? cached ?? "" }
            if saved == nil { draft.notice = NSLocalizedString("Enter your password to connect. It is never stored as plain text.", comment: "") }
            draft.isLoadingPassword = false
        }
    }
    func cancelConnectionEditor() {
        guard !isRunning else { return }
        connectionDraft = nil
    }
    func submitConnection(_ draft: ConnectionDraft) {
        guard !isRunning, connectionDraft?.id == draft.id else { return }
        do {
            let profile = try draft.validatedProfile()
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
            else { profiles.append(profile) }
            passwordLoadTask?.cancel(); passwordLoadTask = nil; isLoadingPassword = false
            selectedProfileID = profile.id; password = draft.password; passwordNotice = nil
            draft.error = nil; saveProfiles(); connect()
        } catch { draft.error = error.localizedDescription }
    }
    /// UI entry point: missing credentials lead directly to the small editor.
    func requestConnect(to id: UUID? = nil) {
        if let id, let profile = profiles.first(where: { $0.id == id }),
           (connectedProfileID != nil || connectingProfileID != nil), id != (connectedProfileID ?? connectingProfileID),
           let openConnectionWorkspace { openConnectionWorkspace(profile); return }
        guard !isRunning else { return }
        guard let id = id ?? selectedProfileID else { beginNewConnection(); return }
        selectProfile(id)
        Task {
            await passwordLoadTask?.value
            guard selectedProfileID == id, !isRunning, connectionDraft == nil else { return }
            if password.isEmpty { beginEditConnection(id) }
            else { connect(to: id) }
        }
    }
    func deleteProfile(_ id: UUID) {
        guard !isRunning, profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id; deleteSelectedProfile()
    }
    func deleteSelectedProfile() {
        guard let id = selectedProfileID else { return }
        sessionPasswords.removeValue(forKey: id)
        if connectedProfileID == id || connectingProfileID == id { disconnect() }
        Task { try? await keychain.deletePassword(for: id) }
        profiles.removeAll { $0.id == id }
        selectedProfileID = profiles.first?.id; saveProfiles(); loadPassword()
    }
    func saveProfiles() { profileStore.save(profiles); profilesDidChange?() }
    func reloadProfiles() {
        profiles = profileStore.load()
        if let id = connectedProfileID ?? connectingProfileID, !profiles.contains(where: { $0.id == id }) { disconnect() }
        if let id = selectedProfileID, !profiles.contains(where: { $0.id == id }) { selectProfile(profiles.first?.id) }
    }
    func selectProfile(_ id: UUID?) {
        guard selectedProfileID != id else { return }
        if let old = selectedProfileID, !isLoadingPassword { sessionPasswords[old] = password }
        selectedProfileID = id; loadPassword()
    }
    func connect(to profileID: UUID? = nil) {
        guard !isRunning else { return }
        if let profileID { selectProfile(profileID) }
        guard let profile = selectedProfile else { return }
        let attemptID = UUID(); connectionAttemptID = attemptID
        connectingProfileID = profile.id; connectedProfileID = nil
        isConnected = false; isRunning = true; errorMessage = nil
        resetMetadata(); schemaLoadState = .loading
        let sshPassword = connectionDraft?.sshPassword ?? ""
        connectionTask = Task {
            do {
                await passwordLoadTask?.value
                guard connectionAttemptID == attemptID else { return }
                let password = self.password
                let previousSession = session; session = nil
                await previousSession?.close()
                let newSession: any DatabaseSession
                if !sshPassword.isEmpty { newSession = try await driver.connect(profile: profile, password: password, sshPassword: sshPassword) }
                else { newSession = try await driver.connect(profile: profile, password: password) }
                guard connectionAttemptID == attemptID else { await newSession.close(); return }
                sessionPasswords[profile.id] = password
                do {
                    try await keychain.save(password, for: profile.id)
                    if let ssh = profile.ssh, ssh.enabled, !sshPassword.isEmpty { try await keychain.save(sshPassword, for: ssh.secretID) }
                    if selectedProfileID == profile.id { passwordNotice = nil }
                } catch {
                    if selectedProfileID == profile.id {
                        passwordNotice = NSLocalizedString("Password kept for this session only; secure storage is unavailable. No authorization dialog will be shown.", comment: "")
                    }
                }
                guard connectionAttemptID == attemptID else { await newSession.close(); return }
                session = newSession; connectedProfileID = profile.id; connectingProfileID = nil; isConnected = true
                previewCredentials = (profile, password)
                recentTables = (try? JSONDecoder().decode([DatabaseTable].self, from: UserDefaults.standard.data(forKey: "recentTables.\(profile.id)") ?? Data())) ?? []
                await loadSchemas()
            } catch {
                guard connectionAttemptID == attemptID else { return }
                connectingProfileID = nil; connectedProfileID = nil
                schemaLoadState = .failed(error.localizedDescription); show(error)
            }
            if connectionAttemptID == attemptID {
                isRunning = false
                if let draft = connectionDraft, draft.profile.id == profile.id {
                    if isConnected { connectionDraft = nil }
                    else { draft.error = errorMessage; errorMessage = nil }
                }
            }
        }
    }
    func disconnect() {
        connectionTask?.cancel(); connectionTask = nil
        transferTask?.cancel(); transferTask = nil
        let transfer = transferSession; transferSession = nil; Task { await transfer?.cancel() }
        let wasRunning = isRunning
        saveWorkspace(); connectionAttemptID = nil; previewID = UUID()
        connectingProfileID = nil; connectedProfileID = nil; isConnected = false; isRunning = false
        resetMetadata(); schemaLoadState = .idle; pendingSQL = nil; pendingExecution = nil
        let old = session; session = nil
        Task { if wasRunning { await old?.cancel() } else { await old?.close() } }
    }
    private func resetMetadata() {
        previewCredentials = nil
        invalidateBrowsePages(); allowsBrowsePrefetch = true
        completionTask?.cancel(); completionFailures = []
        columnsTasks = [:]; structureCache = [:]; recentTables = []
        executingTabID = nil; cancelRequested = false; isCancelling = false
        schemas = []; tableColumns = [:]; selectedTable = nil
        tableBrowseOptions = [:]; fullCellValues = [:]; browseIsStale = false; browseError = nil; queryErrors = [:]; endOperation()
        browseResult = .empty; resultTable = nil; structure = TableStructure(); structureState = .idle
        for index in queryTabs.indices { queryTabs[index].result = .empty; queryTabs[index].results = [] }
    }
    func loadSchemas() async {
        let ownsOperation = operationID == nil
        if ownsOperation { isRunning = true; beginOperation() }
        let operation = operationID
        defer { if ownsOperation, operation == operationID { isRunning = false; endOperation() } }
        invalidateBrowsePages()
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
        let ownsOperation = operationID == nil
        if ownsOperation { isRunning = true; beginOperation() }
        let operation = operationID
        defer { if ownsOperation, operation == operationID { isRunning = false; endOperation() } }
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
        let ownsOperation = operationID == nil
        if ownsOperation { isRunning = true; beginOperation() }
        let operation = operationID
        defer { if ownsOperation, operation == operationID { isRunning = false; endOperation() } }
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
    func selectTable(_ table: DatabaseTable) {
        guard !isRunning else { return }
        if section == .structure { showStructure(table) }
        else if section == .data { browse(table) }
        else {
            if let previous = resultTable { tableBrowseOptions[previous] = appliedBrowseOptions }
            selectedTable = table; browseOptions = tableBrowseOptions[table] ?? TableBrowseOptions()
            Task { await loadColumns(in: table) }
        }
    }
    func browse(_ table: DatabaseTable) {
        guard !isRunning else { return }
        if selectedTable != table {
            if let previous = resultTable { tableBrowseOptions[previous] = appliedBrowseOptions }
            browseOptions = tableBrowseOptions[table] ?? TableBrowseOptions(); structureState = .idle; structure = TableStructure(); browseResult = .empty }
        selectedTable = table; section = .data; refreshData(useCache: true)
        recentTables.removeAll { $0 == table }; recentTables.insert(table, at: 0); recentTables = Array(recentTables.prefix(15))
        if let id = connectedProfileID, let data = try? JSONEncoder().encode(recentTables) { UserDefaults.standard.set(data, forKey: "recentTables.\(id)") }
    }
    func refreshData(resetPage: Bool = false, forceMetadata: Bool = false, useCache: Bool = false) {
        guard !isRunning, let table = selectedTable else { return }
        if resetPage { browseOptions.page = 0 }
        stopPrefetch(keepIdle: true)
        if !useCache || forceMetadata { browsePages.removeAll() }
        let options = browseOptions, key = BrowsePageKey(table: table, options: browseOptions)
        if useCache, let cached = browsePages.value(for: key) {
            errorMessage = nil; browseError = nil; browseIsStale = false; appliedBrowseOptions = options; lastBrowseSQL = cached.sql; resultTable = table
            acceptBrowseResult(cached.result)
            schedulePrefetch(for: key, rows: cached.result)
            return
        }
        isRunning = true; errorMessage = nil; browseError = nil; beginOperation()
        let epoch = connectionAttemptID; let request = UUID(); previewID = request
        Task {
            defer {
                if epoch == connectionAttemptID {
                    if cancelRequested {
                        browseOptions = appliedBrowseOptions
                        browseError = "Table request cancelled; previous snapshot retained."
                    }
                    isRunning = false; endOperation()
                }
            }
            do {
                let session = try requireSession()
                busyStage = NSLocalizedString("Loading table metadata", comment: "")
                if forceMetadata { structureCache.removeValue(forKey: table.id) }
                let columns = try await cachedColumns(in: table, force: forceMetadata)
                guard epoch == connectionAttemptID, previewID == request, !cancelRequested else { return }
                tableColumns[table.id] = columns
                let query = try browseQuery(for: key, columns: columns)
                busyStage = NSLocalizedString("Loading table data", comment: "")
                let rows = try await session.query(query)
                guard epoch == connectionAttemptID, previewID == request, !cancelRequested else { return }
                browsePages.insert(rows, sql: query, for: key)
                lastBrowseSQL = query; resultTable = table; appliedBrowseOptions = options; browseIsStale = false; acceptBrowseResult(rows)
                schedulePrefetch(for: key, rows: rows)
            } catch {
                if epoch == connectionAttemptID {
                    browseOptions = appliedBrowseOptions
                    browseError = cancelRequested ? "Table request cancelled; previous snapshot retained." : error.localizedDescription
                    if !cancelRequested { show(error) }
                }
            }
        }
    }
    private func browseQuery(for key: BrowsePageKey, columns: [TableColumn]) throws -> String {
        let keys = columns.filter(\.isPrimaryKey)
        var cursor: String?
        if key.options.page > 0, keys.count == 1,
           ["tinyint", "smallint", "mediumint", "int", "bigint"].contains(where: { keys[0].dataType.lowercased().hasPrefix($0) }),
           key.options.sortColumn.isEmpty || key.options.sortColumn == keys[0].name {
            var previous = key; previous.options.page -= 1
            if let page = browsePages.value(for: previous), page.result.rows.count >= key.options.pageSize,
               let column = page.result.columns.firstIndex(of: keys[0].name),
               !page.result.isNull(row: key.options.pageSize - 1, column: column) {
                cursor = page.result.rows[key.options.pageSize - 1][column]
            }
        }
        var compositePredicate: String?
        if cursor == nil, key.options.page > 0, !keys.isEmpty {
            var previous = key; previous.options.page -= 1
            var ordering = key.options.sortColumn.isEmpty ? [] : columns.filter { $0.name == key.options.sortColumn }
            ordering += keys.filter { key in !ordering.contains(where: { $0.name == key.name }) }
            if !ordering.contains(where: { isBinary($0.dataType) || isLargeColumn($0) }),
               let page = browsePages.value(for: previous), page.result.rows.count >= key.options.pageSize {
                let indices = ordering.compactMap { column in page.result.columns.firstIndex(of: column.name) }
                if indices.count == ordering.count {
                    let row = key.options.pageSize - 1
                    let values = indices.map { index -> String? in page.result.isNull(row: row, column: index) ? nil : page.result.rows[row][index] }
                    compositePredicate = try SeekPagination.predicate(columns: ordering, values: values, descending: key.options.descending)
                }
            }
        }
        let chosen = columns.filter { key.options.selectedColumns.isEmpty || key.options.selectedColumns.contains($0.name) || $0.isPrimaryKey }
        let needsProjection = !key.options.selectedColumns.isEmpty || chosen.contains(where: isLargeColumn)
        let projection = needsProjection ? try chosen.map { column in
            let name = try SQLIdentifier.quote(column.name)
            guard isLargeColumn(column), !column.isPrimaryKey else { return name }
            return isBinary(column.dataType) ? "HEX(LEFT(\(name), 128)) AS \(name)" : "LEFT(\(name), 256) AS \(name)"
        }.joined(separator: ", ") : "*"
        return try key.options.query(for: key.table, primaryKeys: keys.map(\.name), afterPrimaryKey: cursor, projection: projection, seekPredicate: compositePredicate)
    }
    private func stopPrefetch(keepIdle: Bool = false) {
        prefetchGeneration = UUID(); prefetchTask?.cancel(); prefetchTask = nil
        if keepIdle && !prefetchBusy { return }
        let old = prefetchSession; prefetchSession = nil; prefetchBusy = false
        if let old { Task { await old.cancel() } }
    }
    private func invalidateBrowsePages() { stopPrefetch(); browsePages.removeAll() }
    private func schedulePrefetch(for key: BrowsePageKey, rows: QueryResult) {
        guard allowsBrowsePrefetch, !rows.isTruncated, rows.rows.count > key.options.pageSize,
              let columns = tableColumns[key.table.id], columns.contains(where: \.isPrimaryKey),
              let credentials = previewCredentials else { return }
        // Use the actual connection endpoint/secret, not a profile being edited.
        let profile = credentials.profile, secret = credentials.password
        var next = key; next.options.page += 1
        guard browsePages.value(for: next) == nil, let query = try? browseQuery(for: next, columns: columns) else { return }
        let epoch = connectionAttemptID, generation = prefetchGeneration
        prefetchTask = Task { [weak self, driver] in
            do {
                // Do not compete with a fast sequence of clicks or table changes.
                try await Task.sleep(for: .milliseconds(180))
                guard let self, !Task.isCancelled, epoch == self.connectionAttemptID, generation == self.prefetchGeneration,
                      self.section == .data, !self.isRunning else { return }
                self.prefetchBusy = true
                let available = self.prefetchSession
                guard let reader = try await available.asyncValue(or: { try await driver.connectPreview(profile: profile, password: secret) }) else { self.prefetchBusy = false; return }
                guard !Task.isCancelled, epoch == self.connectionAttemptID, generation == self.prefetchGeneration else { await reader.close(); return }
                // A driver must never lend the transaction/session connection to prefetch.
                guard reader !== self.session else { return }
                self.prefetchSession = reader
                do {
                    let result = try await reader.query(query)
                    if !Task.isCancelled, epoch == self.connectionAttemptID, generation == self.prefetchGeneration {
                        self.browsePages.insert(result, sql: query, for: next)
                    }
                } catch {
                    if generation == self.prefetchGeneration { self.prefetchSession = nil; self.prefetchBusy = false }
                    await reader.close(); return
                }
                if generation == self.prefetchGeneration { self.prefetchBusy = false }
                else { await reader.close() }
            } catch { if let self, generation == self.prefetchGeneration { self.prefetchBusy = false } }
        }
    }
    private func acceptBrowseResult(_ rows: QueryResult) {
        hasNextPage = rows.rows.count > browseOptions.pageSize
        fullCellValues = [:]
        browseResult = QueryResult(columns: rows.columns, rows: Array(rows.rows.prefix(browseOptions.pageSize)), elapsed: rows.elapsed,
                                   message: rows.isTruncated ? rows.message : "\(min(rows.rows.count, browseOptions.pageSize)) row(s)",
                                   nullCells: Set(rows.nullCells.filter { $0.row < browseOptions.pageSize }), isTruncated: rows.isTruncated, retainedBytes: rows.retainedBytes,
                                   deferredColumns: Set((tableColumns[selectedTable?.id ?? ""] ?? []).filter { isLargeColumn($0) && !$0.isPrimaryKey }.map(\.name)).intersection(rows.columns),
                                   binaryCells: rows.binaryCells.filter { $0.key.row < browseOptions.pageSize })
        trimResultMemory(preserving: browseResult.id)
    }
    func nextPage(_ delta: Int) {
        guard !isRunning, (delta < 0 ? browseOptions.page > 0 : hasNextPage) else { return }
        browseOptions = appliedBrowseOptions; browseOptions.page += delta; refreshData(useCache: true)
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
            if let previous = resultTable { tableBrowseOptions[previous] = appliedBrowseOptions }
            selectedTable = table; browseOptions = tableBrowseOptions[table] ?? TableBrowseOptions(); browseResult = .empty; resultTable = nil
        }
        guard let table = selectedTable else { return }
        if !force, let cached = structureCache[table.id] { structure = cached; structureState = .loaded; section = .structure; return }
        section = .structure; structureState = .loading; isRunning = true; beginOperation()
        let epoch = connectionAttemptID
        Task {
            defer { if epoch == connectionAttemptID { isRunning = false; endOperation() } }
            do {
                let details = try await requireSession().structure(in: table)
                guard epoch == connectionAttemptID, !cancelRequested else { return }
                if structureCache.count >= 32 { structureCache.removeAll() }
                structure = details; structureCache[table.id] = details; tableColumns[table.id] = details.columns; structureState = .loaded
            } catch { if epoch == connectionAttemptID { structureState = .failed(error.localizedDescription); show(error) } }
        }
    }
    func changeSection(_ value: WorkspaceSection) {
        if isRunning { section = value; return }
        if value == .structure { showStructure() }
        else if value == .data, let table = selectedTable {
            if resultTable != table || browseIsStale { browse(table) } else { section = value }
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
    private func submit(_ plan: SQLExecutionPlan, database: String, tab: UUID, parameters: [SQLParameter]? = nil) {
        if let error = plan.error { errorMessage = error; return }
        guard !plan.sql.isEmpty else { return }
        let request = ExecutionRequest(sql: plan.sql, database: database, tabID: tab, parameters: parameters)
        if isReadOnly && plan.confirmation {
            errorMessage = "Read-only protection blocks statements that can change data or server state. Use a server-side read-only account for a security boundary."; return
        }
        if plan.confirmation { pendingExecution = request; pendingSQL = plan.sql }
        else { execute(request) }
    }
    func runParameterized(_ source: String, parameters: [SQLParameter]) {
        guard isConnected, !isRunning else { return }
        do {
            guard SQLTools.statements(source).count == 1, SQLParameter.count(in: source) == parameters.count else { throw UpdateFailure("Use one statement with matching ? placeholders.") }
            _ = try parameters.map { try $0.literal() }
            submit(SQLExecutionPlan.prepare(source, selection: NSRange(location: 0, length: 0), all: true), database: selectedDatabase, tab: activeTabID, parameters: parameters)
        } catch { show(error) }
    }
    func confirmExecution() {
        guard let request = pendingExecution else { return }
        guard !isReadOnly else { cancelExecution(); errorMessage = "Read-only protection is enabled."; return }
        pendingSQL = nil; pendingExecution = nil; execute(request)
    }
    func cancelExecution() { pendingSQL = nil; pendingExecution = nil }
    var isReadOnly: Bool { (profiles.first(where: { $0.id == connectedProfileID })?.readOnly ?? previewCredentials?.profile.readOnly) == true }
    var connectionLabel: String {
        guard let profile = previewCredentials?.profile ?? profiles.first(where: { $0.id == connectedProfileID }) else { return "" }
        return "\(profile.name) · \(profile.host):\(profile.port)" + (isReadOnly ? " · " + NSLocalizedString("READ ONLY", comment: "") : "")
    }
    func cancelCurrentQuery() {
        guard canCancelOperation, let operation = operationID, let session = transferSession ?? session else { return }
        if transferTask != nil && transferSession == nil { transferTask?.cancel() }
        cancelRequested = true; isCancelling = true; busyStage = NSLocalizedString("Cancelling current query", comment: "")
        let epoch = connectionAttemptID
        Task {
            guard epoch == connectionAttemptID, operationID == operation else { return }
            do { try await session.cancelQuery() }
            catch { if epoch == connectionAttemptID { show(error) } }
            if epoch == connectionAttemptID, operationID == operation { isCancelling = false }
        }
    }
    private func execute(_ request: ExecutionRequest) {
        // User SQL may change transactions, session variables or temporary tables.
        // From this point keep browsing on its original connection until reconnect.
        invalidateBrowsePages(); allowsBrowsePrefetch = false
        guard !isRunning, isConnected else { return }
        isRunning = true; errorMessage = nil
        beginOperation(); queryErrors.removeValue(forKey: request.tabID); executingTabID = request.tabID; busyStage = NSLocalizedString("Preparing query", comment: "")
        let epoch = connectionAttemptID
        let connectionName = profiles.first { $0.id == connectedProfileID }?.name ?? ""
        Task {
            defer {
                if epoch == connectionAttemptID {
                    if cancelRequested { record(request.sql, database: request.database, connection: connectionName, outcome: "Cancellation requested · batch stopped; committed writes are not rolled back") }
                    isRunning = false; executingTabID = nil; endOperation()
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
                    let result: QueryResult
                    if let parameters = request.parameters { result = try await session.parameterized(statement.sql, parameters: parameters, shouldCancel: { await MainActor.run { self.cancelRequested || epoch != self.connectionAttemptID } }) }
                    else { result = try await session.query(statement.sql.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    if epoch == connectionAttemptID, statement.writes { browseIsStale = true; structureCache = [:]; tableColumns = [:] }
                    guard epoch == connectionAttemptID, !cancelRequested, let index = queryTabs.firstIndex(where: { $0.id == request.tabID }) else { return }
                    if !receivedResult { queryTabs[index].results = []; receivedResult = true }
                    queryTabs[index].results.append(result); queryTabs[index].result = result
                    trimResultMemory(preserving: result.id)
                    if statement.writes {
                        browseIsStale = true; structureCache = [:]; completionFailures = []
                        tableColumns = [:]; columnsTasks = [:]
                        for schema in schemas.indices { schemas[schema].tableLoadState = .idle }
                    }
                    record(statement.sql, database: request.database, connection: connectionName, outcome: result.message)
                }
            } catch {
                if epoch == connectionAttemptID {
                    queryErrors[request.tabID] = cancelRequested ? "Query cancelled; previous results retained." : error.localizedDescription
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
            if browseResult.isNull(row: row, column: column) == isNull,
               (isNull || (browseResult.rows[row][column] as NSString).isEqual(to: value)) {
                mutationNotice = "No changes to save."; mutationSucceeded = true; return
            }
            let predicate = try snapshotPredicate(for: table, row: row)
            let value = isNull ? "NULL" : try SQLStringLiteral.quote(value)
            mutate("UPDATE \(try qualified(table)) SET \(target) = \(value) WHERE \(predicate) LIMIT 1;")
        } catch { show(error) }
    }
    func deleteRow(_ row: Int) {
        guard !isRunning, let table = resultTable, canMutateSelectedTable, browseResult.rows.indices.contains(row) else { return }
        do {
            guard tableColumns[table.id, default: []].allSatisfy({ browseResult.columns.contains($0.name) }) else { throw UpdateFailure("Load all columns before deleting a row so concurrent changes can be checked.") }
            let predicate = try browseResult.columns.enumerated().map { index, name in
                "BINARY \(try SQLIdentifier.quote(name)) <=> BINARY \(try gridValue(row: row, column: index).literal())"
            }.joined(separator: " AND ")
            mutate("DELETE FROM \(try qualified(table)) WHERE \(predicate) LIMIT 1;")
        } catch { mutationNotice = error.localizedDescription; mutationSucceeded = false }
    }
    @Published var mutationNotice: String?
    @Published var mutationSucceeded = false
    @Published var mutationInProgress = false
    private func mutate(_ sql: String) {
        invalidateBrowsePages()
        isRunning = true; mutationInProgress = true; mutationSucceeded = false; mutationNotice = nil
        let epoch = connectionAttemptID; let refreshSQL = lastBrowseSQL
        Task {
            defer { if epoch == connectionAttemptID { isRunning = false; mutationInProgress = false } }
            var written = false
            do {
                let session = try requireSession()
                let write = try await session.query(sql)
                guard epoch == connectionAttemptID else { return }
                guard write.affectedRows == 1 else {
                    mutationNotice = write.affectedRows == 0
                        ? "No row changed. The row was changed or deleted since this snapshot, or the server normalized the value. Refresh and compare before retrying."
                        : "Unexpected affected row count. Refresh and verify the database before retrying."
                    browseIsStale = true; return
                }
                written = true; mutationSucceeded = true; browseIsStale = true
                mutationNotice = "Saved · 1 affected row."
                let result = try await session.query(refreshSQL)
                if epoch == connectionAttemptID { acceptBrowseResult(result); browseIsStale = false }
            } catch {
                if epoch == connectionAttemptID {
                    mutationNotice = written
                        ? "Write succeeded, but refresh failed. Do not repeat the write. " + error.localizedDescription
                        : "Write failed or its outcome is unknown. Refresh and verify before retrying. " + error.localizedDescription
                    browseIsStale = true
                    if error is DatabaseSessionLost { show(error) }
                }
            }
        }
    }
    /// Compare every safely represented original value, including NULL. Binary
    /// columns remain read-only until their raw representation is preserved.
    private func snapshotPredicate(for table: DatabaseTable, row: Int) throws -> String {
        let columns = tableColumns[table.id] ?? []
        return try columns.filter { !isBinary($0.dataType) && !browseResult.deferredColumns.contains($0.name) && browseResult.columns.contains($0.name) }.map { column in
            guard let index = browseResult.columns.firstIndex(of: column.name) else { throw DatabaseError.invalidIdentifier(column.name) }
            let value = browseResult.isNull(row: row, column: index) ? "NULL" : try SQLStringLiteral.quote(browseResult.rows[row][index])
            return "BINARY \(try SQLIdentifier.quote(column.name)) <=> BINARY \(value)"
        }.joined(separator: " AND ")
    }
    var canMutateSelectedTable: Bool {
        guard !isReadOnly, !browseIsStale, !browseResult.isTruncated, section == .data, let table = resultTable, table == selectedTable else { return false }
        let keys = tableColumns[table.id]?.filter(\.isPrimaryKey) ?? []
        return !keys.isEmpty && keys.allSatisfy { browseResult.columns.contains($0.name) && !isBinary($0.dataType) }
    }
    func canEditColumn(_ index: Int) -> Bool {
        guard canMutateSelectedTable, let table = resultTable, browseResult.columns.indices.contains(index) else { return false }
        guard let column = tableColumns[table.id]?.first(where: { $0.name == browseResult.columns[index] }) else { return false }
        return !browseResult.deferredColumns.contains(column.name) && !isBinary(column.dataType) && !column.extra.uppercased().contains("GENERATED")
    }
    private func isLargeColumn(_ column: TableColumn) -> Bool {
        let type = column.dataType.lowercased()
        return ["text", "blob", "json", "binary"].contains { type.contains($0) }
    }
    func loadFullValue(row: Int, column: Int) async throws -> QueryResult {
        guard !isRunning, !browseIsStale, let table = resultTable, table == selectedTable,
              browseResult.rows.indices.contains(row), browseResult.columns.indices.contains(column),
              let columns = tableColumns[table.id], columns.contains(where: \.isPrimaryKey), !columns.filter(\.isPrimaryKey).contains(where: { isBinary($0.dataType) }) else {
            throw UpdateFailure("A current snapshot and a stable primary key are required to load the full value.")
        }
        let target = try SQLIdentifier.quote(browseResult.columns[column])
        let predicate = try primaryKeyPredicate(for: table, row: row)
        let epoch = connectionAttemptID
        isRunning = true; beginOperation(); busyStage = "Loading full value"
        defer { if epoch == connectionAttemptID { isRunning = false; endOperation() } }
        let result = try await requireSession().query("SELECT \(target) FROM \(try qualified(table)) WHERE \(predicate) LIMIT 2;")
        guard epoch == connectionAttemptID, !cancelRequested else { throw CancellationError() }
        guard !result.isTruncated, result.rows.count == 1 else {
            throw UpdateFailure("Full value is unavailable: the row was deleted, its identity is ambiguous, or it exceeds the 16 MB preview budget.")
        }
        fullCellValues[CellAddress(row: row, column: column)] = result
        return result
    }
    private func isBinary(_ type: String) -> Bool {
        let type = type.lowercased()
        return ["blob", "binary", "geometry", "point", "polygon", "linestring", "bit("].contains { type.contains($0) }
    }
    private func primaryKeyPredicate(for table: DatabaseTable, row: Int) throws -> String {
        try (tableColumns[table.id] ?? []).filter(\.isPrimaryKey).map { key in
            guard let index = browseResult.columns.firstIndex(of: key.name) else { throw DatabaseError.invalidIdentifier(key.name) }
            return "BINARY \(try SQLIdentifier.quote(key.name)) <=> BINARY \(try SQLStringLiteral.quote(browseResult.rows[row][index]))"
        }.joined(separator: " AND ")
    }
    private func qualified(_ table: DatabaseTable) throws -> String { "\(try SQLIdentifier.quote(table.schema)).\(try SQLIdentifier.quote(table.name))" }
    func executeSchemaChange(_ sql: String, preceding: [String] = []) async throws {
        guard !isRunning, !isReadOnly, isConnected else { throw UpdateFailure("Connect with a writable account and wait for other operations.") }
        isRunning = true; beginOperation()
        let epoch = connectionAttemptID
        defer { if epoch == connectionAttemptID { isRunning = false; endOperation() } }
        // Exactly one reviewed server command; routine bodies may contain ;.
        let writer = try requireSession()
        for command in preceding + [sql] {
            guard !cancelRequested, epoch == connectionAttemptID else { throw CancellationError() }
            _ = try await writer.query(command)
            browseIsStale = true; invalidateBrowsePages(); tableColumns = [:]; columnsTasks = [:]; structureCache = [:]
            for index in schemas.indices { schemas[index].tableLoadState = .idle }
        }
        guard epoch == connectionAttemptID else { throw CancellationError() }
        browseIsStale = true; invalidateBrowsePages(); tableColumns = [:]; columnsTasks = [:]; structureCache = [:]
        for index in schemas.indices { schemas[index].tableLoadState = .idle }
        schemaLoadState = .idle
    }
    func loadObjectDefinitions(kind: String, database: String) async throws -> [String] {
        guard !isRunning else { throw UpdateFailure("Wait for the active operation.") }
        let schema = try SQLStringLiteral.quote(database)
        let sql: String
        switch kind {
        case "View": sql = "SELECT TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA = \(schema)"
        case "Procedure", "Function": sql = "SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(schema) AND ROUTINE_TYPE = \(try SQLStringLiteral.quote(kind.uppercased()))"
        case "Trigger": sql = "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = \(schema)"
        case "Event": sql = "SELECT EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA = \(schema)"
        default: return schemas.first(where: { $0.name == database })?.tables.map(\.name) ?? []
        }
        isRunning = true; beginOperation(); let operation = operationID
        defer { if operation == operationID { isRunning = false; endOperation() } }
        let result = try await requireSession().query(sql)
        guard operation == operationID, !cancelRequested else { throw CancellationError() }
        return result.rows.compactMap(\.first)
    }
    func objectSQL(kind: String, table: DatabaseTable) async throws -> String {
        guard !isRunning, ["Table", "View", "Procedure", "Function", "Trigger", "Event"].contains(kind) else { throw UpdateFailure("Choose a supported object while idle.") }
        isRunning = true; beginOperation(); let operation = operationID
        defer { if operation == operationID { isRunning = false; endOperation() } }
        let result = try await requireSession().query("SHOW CREATE \(kind.uppercased()) \(try qualified(table))")
        guard operation == operationID, !cancelRequested else { throw CancellationError() }
        let column = result.columns.firstIndex { $0.lowercased().hasPrefix("create ") || $0 == "SQL Original Statement" } ?? 1
        guard let row = result.rows.first, row.indices.contains(column) else { throw UpdateFailure("No definition returned; check object permissions.") }
        return row[column]
    }
    private func requireGridChangeWorkspace() throws {
        guard let id = connectedProfileID else { throw DatabaseError.notConnected }
        if gridChanges.isEmpty { gridChangeProfileID = id }
        guard gridChangeProfileID == id else { throw UpdateFailure("Pending changes belong to a different connection. Reconnect that profile or discard the pending batch first.") }
    }
    func stageCell(row: Int, column: Int, value: SQLParameter) throws {
        try requireGridChangeWorkspace()
        guard !isRunning, !isReadOnly, !browseIsStale, let table = resultTable, table == selectedTable,
              browseResult.rows.indices.contains(row), browseResult.columns.indices.contains(column),
              let definition = tableColumns[table.id]?.first(where: { $0.name == browseResult.columns[column] }), !definition.extra.uppercased().contains("GENERATED") else { throw UpdateFailure("A current, writable row and column are required.") }
        if value.kind == .null && !definition.isNullable { throw UpdateFailure("This column does not allow NULL.") }
        _ = try value.literal()
        if value.kind != .null && value.kind != .binary { _ = try SQLTypedValue.literal(value.value, type: definition.dataType) }
        var original = try gridIdentity(table: table, row: row)
        let old = try gridValue(row: row, column: column)
        let rowID = "\(browseResult.id)/\(row)"
        guard !gridChanges.contains(where: { $0.rowID == rowID && $0.kind == .delete }) else { throw UpdateFailure("Discard the staged deletion before editing this row.") }
        if (old.kind == .null) == (value.kind == .null), (old.kind == .binary) == (value.kind == .binary), (old.value as NSString).isEqual(to: value.value) {
            if let index = gridChanges.firstIndex(where: { $0.rowID == rowID && $0.kind == .update }) {
                gridChanges[index].values.removeValue(forKey: definition.name)
                if gridChanges[index].values.isEmpty { gridChanges.remove(at: index) }
            }
            return
        }
        original[definition.name] = old
        if let index = gridChanges.firstIndex(where: { $0.rowID == rowID && $0.kind == .update }) {
            if gridChanges[index].before[definition.name] == nil { gridChanges[index].before[definition.name] = old }
            gridChanges[index].values[definition.name] = value
        } else {
            gridChanges.append(GridChange(table: table, kind: .update, before: original, values: [definition.name: value], label: "Row \(row + 1)", rowID: rowID))
        }
    }
    func stageInsert(table: DatabaseTable, values: [String: SQLParameter]) throws {
        try requireGridChangeWorkspace()
        guard !isReadOnly, !isRunning else { throw UpdateFailure("Connection is busy or read-only.") }
        for (name, value) in values {
            guard let column = tableColumns[table.id]?.first(where: { $0.name == name }), !column.extra.uppercased().contains("GENERATED") else { throw UpdateFailure("Invalid/generated column: \(name)") }
            if value.kind == .null && !column.isNullable { throw UpdateFailure("\(name) does not allow NULL.") }
            _ = try value.literal()
            if value.kind != .null && value.kind != .binary { _ = try SQLTypedValue.literal(value.value, type: column.dataType) }
        }
        gridChanges.append(GridChange(table: table, kind: .insert, before: [:], values: values, label: "New row · omitted columns use server defaults"))
    }
    func stageDelete(row: Int) throws {
        try requireGridChangeWorkspace()
        guard !isReadOnly, !isRunning, !browseIsStale, let table = resultTable, table == selectedTable else { throw UpdateFailure("A current writable table is required.") }
        guard tableColumns[table.id, default: []].allSatisfy({ browseResult.columns.contains($0.name) }) else { throw UpdateFailure("Load all columns before staging a row deletion.") }
        var original = try gridIdentity(table: table, row: row)
        for column in browseResult.columns.indices { original[browseResult.columns[column]] = try gridValue(row: row, column: column) }
        let rowID = "\(browseResult.id)/\(row)"
        gridChanges.removeAll { $0.rowID == rowID }
        gridChanges.append(GridChange(table: table, kind: .delete, before: original, values: [:], label: "Delete row \(row + 1)", rowID: rowID))
    }
    private func gridIdentity(table: DatabaseTable, row: Int) throws -> [String: SQLParameter] {
        guard !browseResult.isTruncated, browseResult.rows.indices.contains(row) else { throw UpdateFailure("Incomplete row cannot be edited.") }
        let keys = tableColumns[table.id, default: []].filter(\.isPrimaryKey)
        guard !keys.isEmpty else { throw UpdateFailure("A primary key is required.") }
        var values: [String: SQLParameter] = [:]
        for key in keys {
            guard let index = browseResult.columns.firstIndex(of: key.name) else { throw UpdateFailure("Primary key was not loaded.") }
            values[key.name] = try gridValue(row: row, column: index)
        }
        return values
    }
    private func gridValue(row: Int, column: Int) throws -> SQLParameter {
        let address = CellAddress(row: row, column: column)
        let source: QueryResult, r: Int, c: Int
        if browseResult.deferredColumns.contains(browseResult.columns[column]) {
            guard let full = fullCellValues[address] else { throw UpdateFailure("Load the full original value before staging this change.") }
            source = full; r = 0; c = 0
        } else { source = browseResult; r = row; c = column }
        if source.isNull(row: r, column: c) { return SQLParameter(kind: .null) }
        if let bytes = source.binaryCells[CellAddress(row: r, column: c)] { return SQLParameter(kind: .binary, value: bytes.map { String(format: "%02x", $0) }.joined()) }
        return SQLParameter(kind: .text, value: source.rows[r][c])
    }
    func commitGridChanges() {
        guard canCommitGridChanges, let credentials = previewCredentials else { return }
        let changes = gridChanges, epoch = connectionAttemptID
        isRunning = true; beginOperation(); gridChangeStatus = "Opening an independent InnoDB transaction…"
        transferTask = Task {
            var writer: (any DatabaseSession)?, commitSent = false
            do {
                let connected = try await driver.connect(profile: credentials.profile, password: credentials.password)
                writer = connected; transferSession = connected
                for table in Set(changes.map(\.table)) {
                    let engine = try await connected.query("SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(try SQLStringLiteral.quote(table.schema)) AND TABLE_NAME = \(try SQLStringLiteral.quote(table.name))")
                    guard engine.rows.first?.first?.uppercased() == "INNODB" else { throw UpdateFailure("Batch editing requires InnoDB; nontransactional tables are not supported.") }
                }
                _ = try await connected.query("START TRANSACTION")
                for (index, change) in changes.enumerated() {
                    guard !cancelRequested, epoch == connectionAttemptID else { throw CancellationError() }
                    let statement = try change.statement()
                    let result = try await connected.parameterized(statement.sql, parameters: statement.parameters, shouldCancel: { await MainActor.run { self.cancelRequested || epoch != self.connectionAttemptID } })
                    guard result.affectedRows == 1 else { throw UpdateFailure("Change \(index + 1) affected \(result.affectedRows.map(String.init) ?? "an unknown number of") rows. The original row may have changed or been deleted. Nothing in this batch will be committed.") }
                    gridChangeStatus = "Applied \(index + 1)/\(changes.count) · awaiting commit"
                }
                guard !cancelRequested, epoch == connectionAttemptID else { throw CancellationError() }
                commitSent = true; gridCommitUnknown = true
                _ = try await connected.query("COMMIT")
                gridCommitUnknown = false
                gridChanges.removeAll { old in changes.contains(where: { $0.id == old.id }) }
                gridChangeStatus = "Committed \(changes.count) changes. Refresh table data to see the result."
            } catch {
                _ = try? await writer?.query("ROLLBACK")
                if epoch == connectionAttemptID {
                    gridCommitUnknown = commitSent
                    gridChangeStatus = commitSent ? "Commit outcome unknown. Verify the database and discard/rebuild the batch before retrying. \(error.localizedDescription)" : "Batch rolled back; drafts retained. \(error.localizedDescription)"
                }
            }
            await writer?.close()
            if epoch == connectionAttemptID { transferSession = nil; transferTask = nil; browseIsStale = true; invalidateBrowsePages(); isRunning = false; endOperation() }
        }
    }
    func exportTables(_ tables: [DatabaseTable], to destination: URL, format: TransferFormat, filtered: Bool) {
        guard isConnected, !isRunning, let credentials = previewCredentials, !tables.isEmpty else { return }
        isRunning = true; beginOperation(); transferStatus = "Connecting export session…"
        let epoch = connectionAttemptID, options = appliedBrowseOptions, operation = operationID
        transferTask = Task {
            var reader: (any DatabaseSession)?
            do {
                let connected = try await driver.connect(profile: credentials.profile, password: credentials.password)
                reader = connected; transferSession = connected
                var total = 0
                for table in tables {
                    guard !cancelRequested, epoch == connectionAttemptID else { throw CancellationError() }
                    let output = tables.count == 1 ? destination : destination.appendingPathComponent(table.name.replacingOccurrences(of: "/", with: "_") + "-" + UUID().uuidString.prefix(8) + "." + format.rawValue.lowercased())
                    let partial = output.appendingPathExtension("partial-" + UUID().uuidString)
                    var query = try (filtered && tables.count == 1 ? options : TableBrowseOptions()).query(for: table, primaryKeys: [])
                    if let limit = query.range(of: " LIMIT ", options: .backwards) { query = String(query[..<limit.lowerBound]) }
                    do {
                        let count = try await connected.export(query, to: partial, format: format) { count in
                            Task { @MainActor in if epoch == self.connectionAttemptID && operation == self.operationID { self.transferStatus = "Exporting \(table.id): \(count) rows" } }
                        }
                        guard !cancelRequested, epoch == connectionAttemptID else { throw CancellationError() }
                        // The save panel authorizes replacement of its exact destination.
                        if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: partial) }
                        else { try FileManager.default.moveItem(at: partial, to: output) }
                        total += count
                    } catch { try? FileManager.default.removeItem(at: partial); throw error }
                }
                transferStatus = "Export complete: \(total) rows across \(tables.count) table(s)."
            } catch { if epoch == connectionAttemptID { transferStatus = "Export stopped: \(error.localizedDescription). Completed files remain; incomplete files were removed." } }
            await reader?.close()
            if epoch == connectionAttemptID { transferSession = nil; transferTask = nil; isRunning = false; endOperation() }
        }
    }
    func executeScript(at url: URL) {
        guard isConnected, !isRunning, !isReadOnly, let credentials = previewCredentials else { return }
        isRunning = true; beginOperation(); transferStatus = "Opening script session…"
        let epoch = connectionAttemptID
        transferTask = Task {
            var writer: (any DatabaseSession)?, count = 0, line = 1
            do {
                let connected = try await driver.connect(profile: credentials.profile, password: credentials.password)
                writer = connected; transferSession = connected
                let script = try SQLScriptReader(url: url)
                let initialMode = try await connected.query("SELECT @@SESSION.sql_mode")
                await script.setSQLMode(initialMode.rows.first?.first ?? "")
                if !selectedDatabase.isEmpty { _ = try await connected.query("USE \(try SQLIdentifier.quote(selectedDatabase))") }
                while let statement = try await script.next() {
                    guard !cancelRequested, epoch == connectionAttemptID else { throw CancellationError() }
                    line = statement.line; transferStatus = "Executing statement \(count + 1), line \(line) · \(statement.bytesRead) bytes read"
                    _ = try await connected.query(statement.sql); count += 1
                    if statement.sql.uppercased().contains("SQL_MODE") {
                        let mode = try await connected.query("SELECT @@SESSION.sql_mode")
                        await script.setSQLMode(mode.rows.first?.first ?? "")
                    }
                }
                transferStatus = "Script complete: \(count) statements. Explicit transactions follow the script; uncommitted work is rolled back when its session closes."
            } catch { if epoch == connectionAttemptID { transferStatus = "Script stopped at line \(line) after \(count) completed statements: \(error.localizedDescription). Earlier committed/DDL changes remain; do not blindly replay the script." } }
            await writer?.close()
            if epoch == connectionAttemptID {
                transferSession = nil; transferTask = nil; browseIsStale = true; invalidateBrowsePages(); tableColumns = [:]; structureCache = [:]
                for i in schemas.indices { schemas[i].tableLoadState = .idle }
                isRunning = false; endOperation()
            }
        }
    }
    func importCSV(at url: URL, table: DatabaseTable, mapping: [String], separator: UInt8, latin1: Bool, header: Bool) {
        guard isConnected, !isRunning, !isReadOnly, !importCommitUnknown, let credentials = previewCredentials else { return }
        isRunning = true; beginOperation(); transferStatus = "Opening import transaction…"
        let epoch = connectionAttemptID
        transferTask = Task {
            var writer: (any DatabaseSession)?, count = 0, committed = false, commitSent = false
            do {
                let connected = try await driver.connect(profile: credentials.profile, password: credentials.password)
                writer = connected; transferSession = connected
                let engine = try await connected.query("SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(try SQLStringLiteral.quote(table.schema)) AND TABLE_NAME = \(try SQLStringLiteral.quote(table.name))")
                guard engine.rows.first?.first?.uppercased() == "INNODB" else { throw UpdateFailure("Transactional CSV import requires an InnoDB table.") }
                let columns = try await connected.columns(in: table)
                let selected = mapping.enumerated().filter { !$0.element.isEmpty }
                guard !selected.isEmpty, Set(selected.map(\.element)).count == selected.count else { throw UpdateFailure("Map each destination column once.") }
                for name in selected.map(\.element) {
                    guard let column = columns.first(where: { $0.name == name }), !column.extra.uppercased().contains("GENERATED") else { throw UpdateFailure("Invalid/generated destination column: \(name)") }
                }
                let csv = try CSVReader(url: url, separator: separator, latin1: latin1)
                if header { _ = try await csv.next() }
                _ = try await connected.query("START TRANSACTION")
                let names = try selected.map { try SQLIdentifier.quote($0.element) }.joined(separator: ", ")
                let prefix = "INSERT INTO \(try qualified(table)) (\(names)) VALUES "
                let placeholders = "(" + Array(repeating: "?", count: selected.count).joined(separator: ", ") + ")"
                var batch: [SQLParameter] = [], batchRows = 0, batchBytes = 0
                @MainActor func flushBatch() async throws {
                    guard batchRows > 0 else { return }
                    let sql = prefix + Array(repeating: placeholders, count: batchRows).joined(separator: ", ")
                    _ = try await connected.parameterized(sql, parameters: batch, shouldCancel: { await MainActor.run { self.cancelRequested || epoch != self.connectionAttemptID } })
                    count += batchRows; batch = []; batchRows = 0; batchBytes = 0
                    transferStatus = "Imported \(count) rows · transaction not committed"
                }
                while let row = try await csv.next() {
                    guard !cancelRequested, epoch == connectionAttemptID else { throw CancellationError() }
                    guard row.count == mapping.count else { throw UpdateFailure("CSV row \(count + batchRows + 1) has \(row.count) fields; expected \(mapping.count).") }
                    let values = try selected.map { index, name -> SQLParameter in
                        let field = row[index], column = columns.first { $0.name == name }!
                        if !field.quoted && field.value == "\\N" {
                            guard column.isNullable else { throw UpdateFailure("\(name) does not allow NULL.") }; return SQLParameter(kind: .null)
                        }
                        if isBinary(column.dataType) {
                            let hex = field.value.hasPrefix("0x") ? String(field.value.dropFirst(2)) : field.value
                            let value = SQLParameter(kind: .binary, value: hex); _ = try value.literal(); return value
                        }
                        _ = try SQLTypedValue.literal(field.value, type: column.dataType)
                        return SQLParameter(kind: .text, value: field.value)
                    }
                    batch += values; batchRows += 1; batchBytes += values.reduce(0) { $0 + $1.value.utf8.count }
                    if batchRows >= 100 || batchBytes >= 1_048_576 || batch.count + selected.count > 60_000 { try await flushBatch() }
                }
                try await flushBatch()
                guard !cancelRequested, epoch == connectionAttemptID else { throw CancellationError() }
                commitSent = true; importCommitUnknown = true
                _ = try await connected.query("COMMIT"); committed = true; importCommitUnknown = false
                transferStatus = "Import committed: \(count) rows."
            } catch {
                if !committed { _ = try? await writer?.query("ROLLBACK") }
                if epoch == connectionAttemptID {
                    importCommitUnknown = commitSent
                    transferStatus = commitSent ? "Commit outcome unknown. Verify destination before retrying. \(error.localizedDescription)" : "Import stopped; transaction rolled back/connection closed. \(error.localizedDescription)"
                }
            }
            await writer?.close()
            if epoch == connectionAttemptID { transferSession = nil; transferTask = nil; browseIsStale = true; invalidateBrowsePages(); isRunning = false; endOperation() }
        }
    }
    private func requireSession() throws -> any DatabaseSession {
        guard let session else { throw DatabaseError.notConnected }; return session
    }
    private func loadPassword() {
        guard let id = selectedProfileID else { passwordLoadTask?.cancel(); password = ""; isLoadingPassword = false; return }
        passwordNotice = nil
        if let cached = sessionPasswords[id] { passwordLoadTask?.cancel(); password = cached; isLoadingPassword = false; return }
        password = ""; isLoadingPassword = true
        passwordLoadTask?.cancel()
        passwordLoadTask = Task { [weak self, keychain] in
            let saved: String?
            var unavailable = false
            do { saved = try await keychain.password(for: id) }
            catch { saved = nil; unavailable = true }
            guard let self, self.selectedProfileID == id, !Task.isCancelled else { return }
            // Never overwrite a password entered while the asynchronous read ran.
            if self.password.isEmpty { self.password = saved ?? "" }
            if let saved { self.sessionPasswords[id] = saved }
            if unavailable { self.passwordNotice = NSLocalizedString("Saved password is unavailable. Click Connect to enter it; no system authorization is required.", comment: "") }
            self.isLoadingPassword = false
        }
    }
    private func show(_ error: Error) {
        if error is DatabaseSessionLost {
            isConnected = false; browseIsStale = true
            let old = session; session = nil; Task { await old?.close() }
        }
        errorMessage = error.localizedDescription
    }
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

private extension Optional {
    func asyncValue(or create: () async throws -> Wrapped?) async rethrows -> Wrapped? {
        if let value = self { return value }; return try await create()
    }
}
