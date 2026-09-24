import Foundation
import XCTest
@testable import LuckySQL

@MainActor final class LiveWorkflowTests: XCTestCase {
    private func connection() throws -> (ConnectionProfile, String) {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["LUCKYSQL_TEST_PORT"].flatMap(Int.init), let password = env["LUCKYSQL_TEST_PASSWORD"] else { throw XCTSkip("Configure the isolated MySQL fixture") }
        return (ConnectionProfile(name: "Live fixture", host: "127.0.0.1", port: port, username: env["LUCKYSQL_TEST_USER"] ?? "luckysql", database: "luckysql"), password)
    }
    private func settle(_ model: AppModel) async throws {
        for _ in 0..<3000 { if !model.isRunning { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw UpdateFailure("Model operation did not finish within 30 seconds")
    }
    func testLiveModelConflictBatchRollbackWidePreviewAndStreamingExport() async throws {
        let (profile, password) = try connection(), driver = MySQLDriver()
        let other = try await driver.connect(profile: profile, password: password)
        let table = DatabaseTable(schema: "luckysql", name: "workflow_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let target = "`luckysql`.`\(table.name)`"
        let name = "LiveWorkflow.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let profiles = ProfileStore(defaults: defaults); profiles.save([profile])
        let model = AppModel(profileStore: profiles, keychain: LivePasswords(password), driver: driver, workspaceStore: WorkspaceStore(defaults: defaults))
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID()).csv")
        defer { model.disconnect(); model.flushWorkspace(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: exportURL) }
        do {
            _ = try await other.query("CREATE TABLE \(target) (id BIGINT UNSIGNED PRIMARY KEY, value VARCHAR(100) NULL, body LONGTEXT, bytes LONGBLOB) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4")
            _ = try await other.query("INSERT INTO \(target) VALUES (1, 'old', REPEAT('x', 3145728), X'00FF'), (2, NULL, '中文😀', X'0102')")
            for first in stride(from: 3, through: 1103, by: 100) {
                let values = (first...min(first + 99, 1103)).map { "(\($0), 'row', 'small', X'00')" }.joined(separator: ",")
                _ = try await other.query("INSERT INTO \(target) VALUES \(values)")
            }
            model.connect(); try await settle(model); XCTAssertTrue(model.isConnected)
            model.newQuery(sql: "SET SESSION sql_mode = 'STRICT_ALL_TABLES'")
            model.runCurrentQuery(); if model.pendingSQL != nil { model.confirmExecution() }; try await settle(model)
            model.browse(table); try await settle(model)
            XCTAssertEqual(model.browseResult.rows.count, 100)
            XCTAssertEqual(model.browseResult.rows[0][2].count, 256)
            XCTAssertLessThan(model.browseResult.retainedBytes, 100_000)
            XCTAssertFalse(model.canEditColumn(2))
            let full = try await model.loadFullValue(row: 0, column: 3)
            XCTAssertEqual(full.binaryCells[CellAddress(row: 0, column: 0)], Data([0, 255]))
            model.updateCell(row: 0, column: 1, value: String(repeating: "x", count: 101)); try await settle(model)
            XCTAssertFalse(model.mutationSucceeded)
            XCTAssertFalse(model.browseIsStale)
            XCTAssertTrue(model.canEditColumn(1))
            XCTAssertTrue(model.mutationNotice?.contains("Server rejected this value") == true)
            let rejected = try await other.query("SELECT value FROM \(target) WHERE id = 1")
            XCTAssertEqual(rejected.rows, [["old"]])
            model.updateCell(row: 0, column: 1, value: "corrected"); try await settle(model)
            XCTAssertTrue(model.mutationSucceeded)
            XCTAssertEqual(model.browseResult.rows[0][1], "corrected")
            _ = try await other.query("UPDATE \(target) SET value = 'other writer' WHERE id = 1")
            model.updateCell(row: 0, column: 1, value: "my stale value"); try await settle(model)
            XCTAssertFalse(model.mutationSucceeded)
            let protected = try await other.query("SELECT value FROM \(target) WHERE id = 1")
            XCTAssertEqual(protected.rows, [["other writer"]])
            model.refreshData(); try await settle(model)
            try model.stageCell(row: 0, column: 1, value: SQLParameter(kind: .text, value: "batch first"))
            try model.stageCell(row: 1, column: 1, value: SQLParameter(kind: .text, value: "batch second"))
            _ = try await other.query("DELETE FROM \(target) WHERE id = 2")
            model.commitGridChanges(); try await settle(model)
            XCTAssertTrue(model.gridChangeStatus.contains("rolled back")); XCTAssertEqual(model.gridChanges.count, 2)
            let rolledBack = try await other.query("SELECT value FROM \(target) WHERE id = 1")
            XCTAssertEqual(rolledBack.rows, [["other writer"]])
            model.gridChanges = []; model.refreshData(); try await settle(model)
            try model.stageCell(row: 0, column: 1, value: SQLParameter(kind: .text, value: "中文😀\nnew"))
            try model.stageInsert(table: table, values: ["id": SQLParameter(kind: .integer, value: "2000"), "value": SQLParameter(kind: .null), "bytes": SQLParameter(kind: .binary, value: "00ff")])
            model.commitGridChanges(); try await settle(model)
            XCTAssertTrue(model.gridChanges.isEmpty, model.gridChangeStatus)
            model.exportTables([table], to: exportURL, format: .csv, filtered: false); try await settle(model)
            XCTAssertTrue(model.transferStatus.contains("Export complete"), model.transferStatus)
            let reader = try CSVReader(url: exportURL)
            _ = try await reader.next()
            var exported = 0
            while let row = try await reader.next() {
                exported += 1
                if row[0].value == "1" { XCTAssertEqual(row[1].value, "中文😀\nnew"); XCTAssertEqual(row[2].value.count, 3145728); XCTAssertEqual(row[3].value, "0x00FF") }
            }
            XCTAssertEqual(exported, 1103)
            let jsonURL = exportURL.appendingPathExtension("json"), sqlURL = exportURL.appendingPathExtension("sql")
            defer { try? FileManager.default.removeItem(at: jsonURL); try? FileManager.default.removeItem(at: sqlURL) }
            model.exportTables([table], to: jsonURL, format: .json, filtered: false); try await settle(model)
            XCTAssertTrue(model.transferStatus.contains("Export complete"), model.transferStatus)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)))
            model.exportTables([table], to: sqlURL, format: .sql, filtered: false); try await settle(model)
            XCTAssertTrue(model.transferStatus.contains("Export complete"), model.transferStatus)
            let copy = "`luckysql`.`copy_\(table.name)`"
            _ = try await other.query("CREATE TABLE \(copy) LIKE \(target)")
            do {
                let script = try String(contentsOf: sqlURL, encoding: .utf8).replacingOccurrences(of: target, with: copy)
                XCTAssertGreaterThan(script.utf8.count, 2_000_000)
                let routine = "`luckysql`.`script_\(table.name)`"
                let extended = script + "\nDELIMITER $$\nCREATE PROCEDURE \(routine)() BEGIN SELECT 'inside;routine'; END$$\nDROP PROCEDURE \(routine)$$\nDELIMITER ;\n"
                try extended.write(to: sqlURL, atomically: true, encoding: .utf8)
                model.executeScript(at: sqlURL); try await settle(model)
                XCTAssertTrue(model.transferStatus.contains("Script complete"), model.transferStatus)
                let count = try await other.query("SELECT COUNT(*) FROM \(copy)")
                XCTAssertEqual(count.rows, [["1103"]])
                let binary = try await other.query("SELECT HEX(bytes), CHAR_LENGTH(body), value FROM \(copy) WHERE id=1")
                XCTAssertEqual(binary.rows, [["00FF", "3145728", "中文😀\nnew"]])
                _ = try await other.query("DROP TABLE \(copy)")
            } catch { _ = try? await other.query("DROP TABLE IF EXISTS \(copy)"); throw error }
            _ = try await other.query("DROP TABLE \(target)"); await other.close()
        } catch { _ = try? await other.query("DROP TABLE IF EXISTS \(target)"); await other.close(); throw error }
        withExtendedLifetime(driver) {}
    }
    func testLiveCSVImportAndDDLWorkflow() async throws {
        let (profile, password) = try connection(), driver = MySQLDriver()
        let setup = try await driver.connect(profile: profile, password: password)
        let table = DatabaseTable(schema: "luckysql", name: "import_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        let target = "`luckysql`.`\(table.name)`", name = "ImportWorkflow.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)), profiles = ProfileStore(defaults: defaults)
        profiles.save([profile])
        let model = AppModel(profileStore: profiles, keychain: LivePasswords(password), driver: driver, workspaceStore: WorkspaceStore(defaults: defaults))
        let csv = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { model.disconnect(); model.flushWorkspace(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: csv) }
        do {
            model.connect(); try await settle(model)
            var id = ColumnDraft(); id.name = "id"; id.type = "INT"; id.nullable = false; id.primaryKey = true
            var value = ColumnDraft(); value.name = "value"; value.type = "VARCHAR(100)"
            try await model.executeSchemaChange(SchemaChange.columns(table: table, original: [], desired: [id, value], creating: true))
            model.browse(table); try await settle(model)
            try Data("id,value\n1,\"中文😀\nline\"\n2,\\N\n3,\"\\N\"\n".utf8).write(to: csv)
            model.importCSV(at: csv, table: table, mapping: ["id", "value"], separator: 44, latin1: false, header: true)
            try await settle(model)
            XCTAssertTrue(model.transferStatus.contains("Import committed: 3"), model.transferStatus)
            let rows = try await setup.query("SELECT * FROM \(target) ORDER BY id")
            XCTAssertEqual(rows.rows[0][1], "中文😀\nline"); XCTAssertTrue(rows.isNull(row: 1, column: 1)); XCTAssertEqual(rows.rows[2][1], "\\N")
            try Data("id,value\n4,first\n1,duplicate\n".utf8).write(to: csv)
            model.importCSV(at: csv, table: table, mapping: ["id", "value"], separator: 44, latin1: false, header: true)
            try await settle(model)
            let rollback = try await setup.query("SELECT COUNT(*) FROM \(target) WHERE id = 4")
            XCTAssertEqual(rollback.rows, [["0"]]); XCTAssertTrue(model.transferStatus.contains("rolled back"))
            try await model.executeSchemaChange(SchemaChange.index(table: table, name: "value_index", columns: ["value"], unique: false, drop: false))
            let structure = try await setup.structure(in: table)
            XCTAssertTrue(structure.indexes.rows.contains { $0.contains("value_index") })
            let routine = "`luckysql`.`proc_\(table.name)`"
            try await model.executeSchemaChange("CREATE PROCEDURE \(routine)() BEGIN SELECT 1; END")
            try await model.executeSchemaChange("DROP PROCEDURE \(routine)")
            let child = DatabaseTable(schema: "luckysql", name: "child_" + table.name)
            let childTarget = "`luckysql`.`\(child.name)`"
            try await model.executeSchemaChange("CREATE TABLE \(childTarget) (id INT PRIMARY KEY, parent_id INT) ENGINE=InnoDB")
            do {
                try await model.executeSchemaChange(SchemaChange.foreignKey(table: child, name: "fk_parent", columns: ["parent_id"], referenced: table, referenceColumns: ["id"], onDelete: "RESTRICT", drop: false))
                _ = try await setup.query("INSERT INTO \(childTarget) VALUES (1, 1)")
                do { _ = try await setup.query("DELETE FROM \(target) WHERE id=1"); XCTFail("Foreign key must protect referenced parent") } catch {}
                try await model.executeSchemaChange(SchemaChange.foreignKey(table: child, name: "fk_parent", columns: [], referenced: table, referenceColumns: [], onDelete: "RESTRICT", drop: true))
                _ = try await setup.query("DROP TABLE \(childTarget)")
            } catch { _ = try? await setup.query("DROP TABLE IF EXISTS \(childTarget)"); throw error }
            // Full object support on every configured engine/version. DDL is not transactional.
            let view = "`luckysql`.`view_\(table.name)`", function = "`luckysql`.`fn_\(table.name)`"
            let trigger = "`luckysql`.`trg_\(table.name)`", event = "`luckysql`.`evt_\(table.name)`"
            for sql in ["CREATE VIEW \(view) AS SELECT id FROM \(target)", "CREATE FUNCTION \(function)() RETURNS INT DETERMINISTIC RETURN 1", "CREATE TRIGGER \(trigger) BEFORE INSERT ON \(target) FOR EACH ROW SET NEW.value = COALESCE(NEW.value, 'trigger')", "CREATE EVENT \(event) ON SCHEDULE EVERY 1 DAY DISABLE DO SELECT 1"] {
                try await model.executeSchemaChange(sql)
            }
            for sql in ["DROP EVENT \(event)", "DROP TRIGGER \(trigger)", "DROP FUNCTION \(function)", "DROP VIEW \(view)"] { try await model.executeSchemaChange(sql) }
            try await model.executeSchemaChange("ALTER TABLE \(target) DROP INDEX value_index, MODIFY value LONGTEXT")
            let largeCSV = "id,value\n" + (10..<1210).map { "\($0),\"中文😀\n" + String(repeating: "x", count: 2000) + "\"\n" }.joined()
            XCTAssertGreaterThan(largeCSV.utf8.count, 2_000_000)
            try Data(largeCSV.utf8).write(to: csv)
            model.importCSV(at: csv, table: table, mapping: ["id", "value"], separator: 44, latin1: false, header: true)
            try await settle(model); XCTAssertTrue(model.transferStatus.contains("Import committed: 1200"), model.transferStatus)
            // Failure after multiple successful batches must roll back the whole import.
            let failedCSV = "id,value\n" + (2000..<2300).map { "\($0),new\n" }.joined() + "1,duplicate\n"
            try Data(failedCSV.utf8).write(to: csv)
            model.importCSV(at: csv, table: table, mapping: ["id", "value"], separator: 44, latin1: false, header: true)
            try await settle(model)
            let afterFailure = try await setup.query("SELECT COUNT(*) FROM \(target) WHERE id >= 2000")
            XCTAssertEqual(afterFailure.rows, [["0"]]); XCTAssertTrue(model.transferStatus.contains("rolled back"), model.transferStatus)
            _ = try await setup.query("DROP TABLE \(target)"); await setup.close()
        } catch { _ = try? await setup.query("DROP TABLE IF EXISTS \(target)"); await setup.close(); throw error }
        withExtendedLifetime(driver) {}
    }
}
private actor LivePasswords: PasswordStoring {
    let value: String
    init(_ value: String) { self.value = value }
    func password(for profileID: UUID) -> String? { value }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
