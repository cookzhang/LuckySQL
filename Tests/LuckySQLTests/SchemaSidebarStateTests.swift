import Combine
import XCTest
@testable import LuckySQL

final class SchemaSidebarStateTests: XCTestCase {
    @MainActor func testBrowseUpdatesDoNotInvalidateTenThousandTableHierarchy() throws {
        let (model, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        let tables = (0..<10_000).map { DatabaseTable(schema: "shop", name: "table_\($0)") }
        model.schemas = [DatabaseSchema(name: "shop", tables: tables, tableLoadState: .loaded)]
        let sidebar = SchemaSidebarState(model: model)
        var hierarchyUpdates = 0
        let subscription = sidebar.objectWillChange.sink { hierarchyUpdates += 1 }
        defer { subscription.cancel() }

        for index in 0..<50 {
            model.selectedTable = tables[index]
            model.browseOptions.filterValue = String(index)
            model.busyStage = "Loading page \(index)"
            model.browseResult = QueryResult(columns: ["id"], rows: [[String(index)]], elapsed: .zero, message: "")
            model.hasNextPage = index.isMultiple(of: 2)
            model.browseError = "Result \(index)"
            model.isRunning = index.isMultiple(of: 2)
        }
        model.tableColumns[tables[100].id] = [TableColumn(name: "id", dataType: "bigint", isNullable: false,
                                                         isPrimaryKey: true, defaultValue: nil, extra: "")]

        XCTAssertEqual(hierarchyUpdates, 0)
        XCTAssertEqual(sidebar.schemas.first?.tables.count, 10_000)
        XCTAssertEqual(sidebar.activity.isRunning, model.isRunning)
    }

    @MainActor func testSelectionAndColumnsInvalidateOnlyAffectedTableRows() throws {
        let (model, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        let tables = ["orders", "customers", "products"].map { DatabaseTable(schema: "shop", name: $0) }
        let states = tables.map { SchemaTableState(model: model, table: $0) }
        var updates = [0, 0, 0]
        let subscriptions = states.enumerated().map { index, state in
            state.objectWillChange.sink { updates[index] += 1 }
        }
        defer { subscriptions.forEach { $0.cancel() } }

        model.selectedTable = tables[0]
        model.selectedTable = tables[1]
        model.selectedTable = tables[1]
        XCTAssertEqual(updates, [2, 1, 0])
        XCTAssertFalse(states[0].snapshot.isSelected)
        XCTAssertTrue(states[1].snapshot.isSelected)

        let column = TableColumn(name: "id", dataType: "bigint", isNullable: false,
                                 isPrimaryKey: true, defaultValue: nil, extra: "")
        model.tableColumns["shop.other"] = [column]
        XCTAssertEqual(updates, [2, 1, 0])
        model.tableColumns[tables[0].id] = [column]
        model.tableColumns[tables[0].id] = [column]
        XCTAssertEqual(updates, [3, 1, 0])
        XCTAssertEqual(states[0].snapshot.columns, [column])

        model.favorites.insert("/\(tables[2].id)")
        XCTAssertEqual(updates, [3, 1, 1])
        XCTAssertTrue(states[2].snapshot.isFavorite)
        model.isRunning = false
        XCTAssertEqual(updates, [3, 1, 1])
        model.isRunning = true
        XCTAssertEqual(updates, [3, 1, 1], "Busy changes must not rebuild every table disclosure row")
        model.isRunning = false
        XCTAssertEqual(updates, [3, 1, 1])
    }

    @MainActor func testOperationAvailabilityUpdatesOnceWithoutPublishingTableSnapshots() throws {
        let (model, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        let sidebar = SchemaSidebarState(model: model)
        let rows = (0..<500).map {
            SchemaTableState(model: model, table: DatabaseTable(schema: "shop", name: "table_\($0)"))
        }
        var rowUpdates = 0, hierarchyUpdates = 0, activityUpdates = 0
        let subscriptions = rows.map { $0.objectWillChange.sink { rowUpdates += 1 } } + [
            sidebar.objectWillChange.sink { hierarchyUpdates += 1 },
            sidebar.activity.objectWillChange.sink { activityUpdates += 1 }
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        for _ in 0..<25 {
            model.isRunning = true
            XCTAssertTrue(sidebar.activity.isRunning)
            model.isRunning = true
            model.busyStage = "Loading table data"
            model.isRunning = false
            XCTAssertFalse(sidebar.activity.isRunning)
        }

        XCTAssertEqual(activityUpdates, 50, "Only actual availability changes should update the interaction boundary")
        XCTAssertEqual(hierarchyUpdates, 0)
        XCTAssertEqual(rowUpdates, 0, "A table query must not publish an update for every sidebar row")
    }

    @MainActor func testOutlineMetadataRemainsLiveAndDuplicateValuesAreIgnored() throws {
        let (model, defaults, name) = try makeModel()
        defer { defaults.removePersistentDomain(forName: name) }
        let sidebar = SchemaSidebarState(model: model)
        var updates = 0
        let subscription = sidebar.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }

        model.schemas = []
        model.schemaLoadState = .idle
        XCTAssertEqual(updates, 0)
        let schema = DatabaseSchema(name: "shop")
        model.schemas = [schema]
        model.schemas = [schema]
        XCTAssertEqual(updates, 1)
        model.schemas[0].tableLoadState = .loaded
        XCTAssertEqual(updates, 2)
        XCTAssertEqual(sidebar.schemas[0].tableLoadState, .loaded)
        model.schemaLoadState = .loaded
        XCTAssertEqual(sidebar.schemaLoadState, .loaded)
        model.connectedProfileID = model.profiles[0].id
        XCTAssertEqual(sidebar.connectedProfileID, model.profiles[0].id)
        model.profiles[0].name = "Updated Connection"
        XCTAssertEqual(sidebar.profiles[0].name, "Updated Connection")
    }

    @MainActor private func makeModel() throws -> (AppModel, UserDefaults, String) {
        let name = "LuckySQLSidebarState.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), keychain: SidebarPasswords(),
                             workspaceStore: WorkspaceStore(defaults: defaults))
        return (model, defaults, name)
    }
}

private actor SidebarPasswords: PasswordStoring {
    func password(for profileID: UUID) -> String? { nil }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
