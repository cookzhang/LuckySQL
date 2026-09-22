import AppKit
import Combine
import Security
import struct SwiftUI.Binding
import XCTest
@testable import LuckySQL

final class SmoothnessTests: XCTestCase {
    @MainActor func testMarkedTextDoesNotReplaceDraftUntilCommitted() {
        var draft = ""
        let coordinator = SQLTextEditor.Coordinator(SQLTextEditor(text: Binding(get: { draft }, set: { draft = $0 })))
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        editor.isRichText = false; editor.delegate = coordinator
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(draft, "")
        editor.insertText("中😀", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "中😀")
        XCTAssertEqual(draft, editor.string)
        XCTAssertEqual(editor.selectedRange().location, 3)
    }
    func testCellPreviewBoundsCombiningMarksAndPreservesSurrogates() {
        let giantGrapheme = "a" + String(repeating: "\u{0301}", count: 200_000)
        let preview = CellDisplayPreview.make(giantGrapheme, isNull: false)
        XCTAssertLessThanOrEqual(preview.text.utf16.count, 513)
        XCTAssertLessThanOrEqual(preview.tooltip.utf16.count, 1001)
        let emoji = CellDisplayPreview.make(String(repeating: "x", count: 511) + "😀tail", isNull: false)
        XCTAssertFalse(emoji.text.contains("�"))
        XCTAssertTrue(emoji.text.hasSuffix("…"))
        XCTAssertEqual(CellDisplayPreview.make("", isNull: true).text, "NULL")
    }
    func testTenThousandTableSearchKeepsRecentOrderAndUnicodeMatching() {
        let tables = (0..<10_000).map { DatabaseTable(schema: "shop", name: "table_\($0)") } + [DatabaseTable(schema: "shop", name: "中文Évents")]
        let index = TableSearchIndex(TableSearchSnapshot(schemas: [DatabaseSchema(name: "shop", tables: tables)], database: "shop", recent: [tables[9999], DatabaseTable(schema: "gone", name: "missing")]))
        XCTAssertEqual(index.search("").first, tables[9999])
        XCTAssertEqual(index.search("中文events"), [tables.last!])
        XCTAssertEqual(index.search("SHOP.TABLE_9999"), [tables[9999]])
        let clock = ContinuousClock(), start = clock.now
        for _ in 0..<50 { XCTAssertEqual(index.search("table_9999").count, 1) }
        print("10,001-table indexed search, 50 passes: \(start.duration(to: clock.now))")
    }
    func testIncrementalLexerConvergesForHeadMiddleAndTailEdits() async {
        let source = String(repeating: "SELECT id, name FROM customers WHERE id = 1;\n", count: 45_000)
        for position in [0, (source as NSString).length / 2, (source as NSString).length] {
            let service = SQLAnalysisService()
            _ = await service.analyze(source, document: "large")
            let range = NSRange(location: position, length: 0)
            let edited = (source as NSString).replacingCharacters(in: range, with: " ")
            let start = ContinuousClock.now
            let analysis = await service.analyze(edited, document: "large", edit: SQLTextEdit(original: source, range: range, replacementLength: 1))
            let elapsed = start.duration(to: .now)
            XCTAssertLessThan(analysis.scannedUTF16, 100)
            assertAnalysis(analysis, equals: edited)
            print("Local edit \(position)/\((source as NSString).length): \(elapsed), scanned \(analysis.scannedUTF16) UTF-16 units (analysis only)")
        }
    }

    func testCoalescedUnicodeEditsAndLexicalBoundariesMatchFullAnalysis() async {
        let service = SQLAnalysisService()
        var source = "SELECT '中文😀', `列`;\n-- comment\nSELECT 2 /* hi */;\n"
        let insertions = ["'", "\"", "`", "-- ", "/*", "*/", "\n", " ", "😀", "中文", "\\", ";", "", "a"]
        var seed: UInt64 = 27
        func random(_ count: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(count)) }
        for _ in 0..<200 {
            _ = await service.analyze(source, document: "fuzz")
            let original = source
            var edit: SQLTextEdit?
            for _ in 0..<3 {
                let boundaries = Array(source.indices) + [source.endIndex]
                let lo = random(boundaries.count), hi = min(boundaries.count - 1, lo + random(4))
                let range = NSRange(boundaries[lo]..<boundaries[hi], in: source)
                let inserted = insertions[random(insertions.count)]
                if edit == nil { edit = SQLTextEdit(original: original, range: range, replacementLength: (inserted as NSString).length) }
                else { edit?.append(range: range, replacementLength: (inserted as NSString).length) }
                source = (source as NSString).replacingCharacters(in: range, with: inserted)
            }
            let result = await service.analyze(source, document: "fuzz", edit: edit)
            assertAnalysis(result, equals: source)
        }
    }

    func testLargeMultilineTokenAndScannerWindowBoundaries() async {
        let original = "SELECT '" + String(repeating: "中😀", count: 5000) + "';\nSELECT 2;"
        let service = SQLAnalysisService()
        _ = await service.analyze(original, document: "quotes")
        let range = (original as NSString).range(of: "';")
        let edited = (original as NSString).replacingCharacters(in: range, with: "\n")
        let analysis = await service.analyze(edited, document: "quotes", edit: SQLTextEdit(original: original, range: range, replacementLength: 1))
        assertAnalysis(analysis, equals: edited)
    }

    private func assertAnalysis(_ analysis: SQLAnalysis, equals sql: String, file: StaticString = #filePath, line: UInt = #line) {
        let full = SQLTools.tokens(sql)
        XCTAssertEqual(analysis.tokens.map(\.text), full.map(\.text), file: file, line: line)
        XCTAssertEqual(analysis.tokens.map(\.range), full.map(\.range), file: file, line: line)
        XCTAssertEqual(analysis.tokens.map(\.kind), full.map(\.kind), file: file, line: line)
        let lines = [0] + sql.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil }
        XCTAssertEqual(analysis.lineStarts, lines, file: file, line: line)
    }

    @MainActor func testTypingAndCaretDoNotPublishWorkspaceChanges() async throws {
        let (model, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        try await waitUntil { !model.isLoadingPassword }
        var workspaceChanges = 0, documentChanges = 0
        let a = model.objectWillChange.sink { workspaceChanges += 1 }
        let b = model.queryTabs[0].document.objectWillChange.sink { documentChanges += 1 }
        for index in 0..<100 { model.sql = "SELECT \(index)"; model.sqlSelection = NSRange(location: 3, length: 0) }
        model.saveWorkspace()
        XCTAssertEqual(workspaceChanges, 0)
        XCTAssertEqual(documentChanges, 100)
        withExtendedLifetime([a, b]) {}
    }

    @MainActor func testVisibleHighlightDoesNotRepaintSameRange() async {
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        editor.string = String(repeating: "SELECT 1;\n", count: 100)
        editor.analysis = await SQLAnalysisService().analyze(editor.string, document: "visible")
        editor.colorVisibleText()
        let count = editor.colorPassCount
        XCTAssertGreaterThan(count, 0)
        for _ in 0..<100 { editor.colorVisibleText() }
        XCTAssertEqual(editor.colorPassCount, count)
    }

    func testPageCacheBoundsExpiryAndRefresh() {
        var cache = BrowsePageCache(byteLimit: 1000, pageLimit: 2, lifetime: 5)
        let table = DatabaseTable(schema: "shop", name: "customers")
        let now = Date()
        let row = QueryResult(columns: ["id"], rows: [["1"]], elapsed: .zero, message: "", retainedBytes: 100)
        var keys: [BrowsePageKey] = []
        for page in 0..<3 {
            var options = TableBrowseOptions(); options.page = page
            let key = BrowsePageKey(table: table, options: options); keys.append(key)
            cache.insert(row, sql: "SELECT", for: key, now: now)
        }
        XCTAssertNil(cache.value(for: keys[0], now: now))
        XCTAssertNotNil(cache.value(for: keys[1], now: now))
        XCTAssertLessThanOrEqual(cache.bytes, 1000)
        XCTAssertNil(cache.value(for: keys[2], now: now.addingTimeInterval(6)))
        cache.removeAll(); XCTAssertEqual(cache.bytes, 0)
        var partial = row; partial.isTruncated = true
        cache.insert(partial, sql: "SELECT", for: keys[0]); XCTAssertNil(cache.value(for: keys[0]))
    }

    func testKeysetPagingPreservesFiltersDirectionAndFallback() throws {
        let table = DatabaseTable(schema: "shop", name: "orders")
        var options = TableBrowseOptions(); options.page = 300
        options.filterColumn = "name"; options.filterValue = "O'Reilly"
        let query = try options.query(for: table, primaryKeys: ["id"], afterPrimaryKey: "30000")
        XCTAssertTrue(query.contains("LOCATE('O''Reilly', `name`) > 0 AND `id` > 30000"))
        XCTAssertFalse(query.contains("OFFSET"))
        options.descending = true
        XCTAssertTrue(try options.query(for: table, primaryKeys: ["id"], afterPrimaryKey: "4").contains("`id` < 4 ORDER BY `id` DESC"))
        XCTAssertTrue(try options.query(for: table, primaryKeys: ["id"], afterPrimaryKey: "18446744073709551614").contains("`id` < 18446744073709551614"))
        XCTAssertThrowsError(try options.query(for: table, primaryKeys: ["id"], afterPrimaryKey: "1 OR 1=1"))
        options.sortColumn = "name"
        XCTAssertTrue(try options.query(for: table, primaryKeys: ["id"], afterPrimaryKey: "4").contains("OFFSET 30000"))
        XCTAssertTrue(try options.query(for: table, primaryKeys: ["id", "name"], afterPrimaryKey: "4").contains("OFFSET 30000"))
    }

    func testKeychainInteractionPolicyIsDisabledAndRestoredEvenOnFailure() {
        var original: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&original), errSecSuccess)
        let status = KeychainStore.withoutInteraction {
            var current: DarwinBoolean = true
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&current), errSecSuccess)
            XCTAssertFalse(current.boolValue)
            return errSecAuthFailed
        }
        XCTAssertEqual(status, errSecAuthFailed)
        var restored: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
        XCTAssertEqual(restored.boolValue, original.boolValue)
    }

    @MainActor func testUnavailableKeychainDoesNotBreakSuccessfulConnection() async throws {
        let store = UnavailablePasswords()
        let (model, defaults, name) = try makeModel(passwords: store)
        defer { defaults.removePersistentDomain(forName: name) }
        try await waitUntil { !model.isLoadingPassword }
        XCTAssertNotNil(model.passwordNotice)
        model.password = "session-only"
        let id = model.selectedProfileID
        model.connect(to: id)
        try await waitUntil { !model.isRunning }
        XCTAssertTrue(model.isConnected)
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.passwordNotice)
        let other = ConnectionProfile(name: "Other")
        model.profiles.append(other); model.selectProfile(other.id); model.selectProfile(id)
        XCTAssertEqual(model.password, "session-only")
        let reads = await store.reads
        XCTAssertEqual(reads, 1)
        model.disconnect()
    }

    @MainActor func testBrowseBackUsesCacheAndExplicitRefreshInvalidates() async throws {
        let session = PagingSession()
        let (model, defaults, name) = try makeModel(session: session)
        defer { defaults.removePersistentDomain(forName: name) }
        model.connect(); try await waitUntil { !model.isRunning }
        model.browse(DatabaseTable(schema: "shop", name: "orders"))
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.browseResult.rows.first?.first, "1")
        model.nextPage(1); try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.browseResult.rows.first?.first, "101")
        let before = await session.queries.count
        model.nextPage(-1)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.browseResult.rows.first?.first, "1")
        let after = await session.queries.count; XCTAssertEqual(before, after)
        model.refreshData(forceMetadata: true); try await waitUntil { !model.isRunning }
        let refreshed = await session.queries.count; XCTAssertEqual(refreshed, after + 1)
        model.disconnect()
    }

    @MainActor func testPrefetchDoesNotBlockForegroundAndUserSQLInvalidatesIt() async throws {
        let foreground = PagingSession(), reader = PagingSession()
        let (model, defaults, name) = try makeModel(session: foreground, driver: PreviewDriver(foreground: foreground, reader: reader))
        defer { defaults.removePersistentDomain(forName: name) }
        model.connect(); try await waitUntil { !model.isRunning }
        model.profiles[0].host = "edited-but-not-connected.invalid"
        model.browse(DatabaseTable(schema: "shop", name: "orders"))
        try await waitUntil { await reader.closed > 0 }
        let previewHost = await reader.previewHost
        XCTAssertEqual(previewHost, "127.0.0.1")
        XCTAssertFalse(model.isRunning)
        let before = await foreground.queries.count
        model.nextPage(1)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.browseResult.rows.first?.first, "101")
        let cached = await foreground.queries.count; XCTAssertEqual(cached, before)
        model.sql = "SELECT 1"; model.runCurrentQuery()
        try await waitUntil { !model.isRunning }
        let prefetches = await reader.queries.count
        model.section = .data; model.nextPage(-1)
        try await waitUntil { !model.isRunning }
        let reloaded = await foreground.queries.count; XCTAssertGreaterThan(reloaded, cached)
        try await Task.sleep(for: .milliseconds(250))
        let finalPrefetches = await reader.queries.count; XCTAssertEqual(finalPrefetches, prefetches)
        model.disconnect()
    }

    @MainActor func testCancelledPrefetchCannotPopulateNewConnectionCache() async throws {
        let foreground = PagingSession(), reader = PagingSession(delay: .milliseconds(250))
        let (model, defaults, name) = try makeModel(session: foreground, driver: PreviewDriver(foreground: foreground, reader: reader))
        defer { defaults.removePersistentDomain(forName: name) }
        model.connect(); try await waitUntil { !model.isRunning }
        let table = DatabaseTable(schema: "shop", name: "orders")
        model.browse(table)
        try await waitUntil { await !reader.queries.isEmpty }
        XCTAssertFalse(model.isRunning)
        model.disconnect(); model.connect(); try await waitUntil { !model.isRunning }
        model.browse(table); try await waitUntil { !model.isRunning }
        let before = await foreground.queries.count
        model.nextPage(1); try await waitUntil { !model.isRunning }
        let after = await foreground.queries.count
        XCTAssertEqual(after, before + 1)
        model.disconnect()
    }

    @MainActor private func makeModel(passwords: any PasswordStoring = AvailablePasswords(), session: PagingSession = PagingSession(), driver: (any DatabaseDriver)? = nil) throws -> (AppModel, UserDefaults, String) {
        let name = "LuckySQLSmoothness.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (AppModel(profileStore: ProfileStore(defaults: defaults), keychain: passwords, driver: driver ?? PagingDriver(session: session), workspaceStore: WorkspaceStore(defaults: defaults)), defaults, name)
    }
    @MainActor private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for model")
    }
}

private actor UnavailablePasswords: PasswordStoring {
    var reads = 0
    func password(for profileID: UUID) throws -> String? { reads += 1; throw KeychainError(errSecInteractionNotAllowed) }
    func save(_ password: String, for profileID: UUID) throws { throw KeychainError(errSecInteractionNotAllowed) }
    func deletePassword(for profileID: UUID) throws { throw KeychainError(errSecInteractionNotAllowed) }
}
private actor AvailablePasswords: PasswordStoring {
    func password(for profileID: UUID) -> String? { "test" }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
private struct PagingDriver: DatabaseDriver {
    let session: PagingSession
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { session }
}
private struct PreviewDriver: DatabaseDriver {
    let foreground: PagingSession
    let reader: PagingSession
    func connect(profile: ConnectionProfile, password: String) async throws -> any DatabaseSession { foreground }
    func connectPreview(profile: ConnectionProfile, password: String) async throws -> (any DatabaseSession)? { await reader.recordPreviewHost(profile.host); return reader }
}
private actor PagingSession: DatabaseSession {
    var queries: [String] = []
    var closed = 0
    var previewHost: String?
    func recordPreviewHost(_ host: String) { previewHost = host }
    let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    func query(_ sql: String) async -> QueryResult {
        queries.append(sql)
        if delay > .zero { try? await Task.sleep(for: delay) }
        let start = sql.contains("`id` > 100") || sql.contains("OFFSET 100") ? 101 : 1
        return QueryResult(columns: ["id"], rows: (start..<(start + 101)).map { [String($0)] }, elapsed: .zero, message: "", retainedBytes: 1000)
    }
    func schemas() -> [String] { ["shop"] }
    func tables(in schema: String) -> [String] { ["orders"] }
    func columns(in table: DatabaseTable) -> [TableColumn] { [TableColumn(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true, defaultValue: nil, extra: "")] }
    func close() { closed += 1 }
}
