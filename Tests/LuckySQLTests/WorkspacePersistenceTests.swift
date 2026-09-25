import XCTest
@testable import LuckySQL

final class WorkspacePersistenceTests: XCTestCase {
    @MainActor func testFlushWritesPreferencesOnMainAndQueuedCallbacksCannotRestoreOldDrafts() async throws {
        let suite = "QuitPersistence.\(UUID())"
        let defaults = try XCTUnwrap(ObservedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        for index in 0..<30 {
            store.saveTabs([QueryTab(title: "\(index)", sql: "SELECT \(index); -- 中文 😀", database: "test")])
        }
        store.flush()
        XCTAssertEqual(WorkspaceStore(defaults: defaults).loadTabs().first?.title, "29")
        XCTAssertEqual(defaults.backgroundWrites, 0)
        // Deliver encoding completions queued before flush, including stale revisions.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(WorkspaceStore(defaults: defaults).loadTabs().first?.sql, "SELECT 29; -- 中文 😀")
        XCTAssertEqual(defaults.backgroundWrites, 0)
    }

    @MainActor func testAutosaveCommitsWithoutExplicitFlush() async throws {
        let suite = "AutosavePersistence.\(UUID())"
        let defaults = try XCTUnwrap(ObservedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = expectation(description: "Draft saved on main")
        defaults.didWriteData = { saved.fulfill() }
        let store = WorkspaceStore(defaults: defaults)
        store.saveTabs([QueryTab(title: "Draft", sql: "SELECT NULL", database: "")])
        await fulfillment(of: [saved], timeout: 3)
        XCTAssertEqual(defaults.backgroundWrites, 0)
        XCTAssertEqual(WorkspaceStore(defaults: defaults).loadTabs().first?.sql, "SELECT NULL")
    }
}

private final class ObservedDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var offMain = 0
    var didWriteData: (() -> Void)?
    var backgroundWrites: Int { lock.lock(); defer { lock.unlock() }; return offMain }
    override func set(_ value: Any?, forKey key: String) {
        if value is Data {
            lock.lock(); if !Thread.isMainThread { offMain += 1 }; lock.unlock()
        }
        super.set(value, forKey: key)
        if value is Data { didWriteData?() }
    }
}
