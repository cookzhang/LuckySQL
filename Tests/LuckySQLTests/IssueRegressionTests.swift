import AppKit
import CryptoKit
import XCTest
@testable import LuckySQL

final class IssueRegressionTests: XCTestCase {
    func testOuterPreviewLimitAndComments() throws {
        XCTAssertEqual(try SQLPreview.query("SELECT * FROM t; -- tail"), "SELECT * FROM t\nLIMIT 1000\n; -- tail")
        XCTAssertEqual(try SQLPreview.query("SELECT * FROM (SELECT * FROM t LIMIT 3) s"), "SELECT * FROM (SELECT * FROM t LIMIT 3) s\nLIMIT 1000\n")
        XCTAssertEqual(try SQLPreview.query("SELECT 'LIMIT 5000', 1 AS same, 2 AS same /* tail */"), "SELECT 'LIMIT 5000', 1 AS same, 2 AS same\nLIMIT 1000\n /* tail */")
        XCTAssertTrue(try SQLPreview.query("SELECT 1 UNION ALL SELECT 2").hasSuffix("LIMIT 1000\n"))
        XCTAssertTrue(try SQLPreview.query("WITH c AS (SELECT 1 LIMIT 1) SELECT * FROM c").hasSuffix("LIMIT 1000\n"))
        XCTAssertTrue(try SQLPreview.query("SELECT * FROM t FOR UPDATE;").contains("LIMIT 1000\nFOR UPDATE"))
        XCTAssertTrue(try SQLPreview.query("SELECT * FROM t LOCK IN SHARE MODE;").contains("LIMIT 1000\nLOCK IN SHARE MODE"))
        XCTAssertEqual(try SQLPreview.query("SELECT t.limit, t.lock FROM t"), "SELECT t.limit, t.lock FROM t\nLIMIT 1000\n")
    }
    func testPreservesSmallLimitsAndOffsetsAndWrites() throws {
        for query in ["SELECT * FROM t LIMIT 0", "SELECT * FROM t LIMIT 20", "SELECT * FROM t LIMIT 20 OFFSET 3000", "SELECT * FROM t LIMIT 3000,20", "UPDATE t SET x=1 LIMIT 5000", "DELETE FROM t LIMIT 5000", "INSERT INTO t SELECT * FROM s", "WITH c AS (SELECT 1) DELETE FROM t", "SHOW TABLES", "EXPLAIN SELECT * FROM t", "SELECT * FROM t INTO OUTFILE '/tmp/example'"] {
            XCTAssertEqual(try SQLPreview.query(query), query)
        }
        XCTAssertEqual(try SQLPreview.query("SELECT * FROM t LIMIT 20,5000"), "SELECT * FROM t LIMIT 20,1000")
        XCTAssertEqual(try SQLPreview.query("SELECT * FROM t LIMIT 5000 OFFSET 20"), "SELECT * FROM t LIMIT 1000 OFFSET 20")
        XCTAssertEqual(try SQLPreview.query("SELECT * FROM t LIMIT 18446744073709551615"), "SELECT * FROM t LIMIT 1000")
        XCTAssertThrowsError(try SQLPreview.query("SELECT * FROM t LIMIT ?"))
        XCTAssertThrowsError(try SQLPreview.query("SELECT * FROM t /*! LIMIT 10000 */"))
    }
    private var catalog: SQLCompletionCatalog {
        let users = DatabaseTable(schema: "shop", name: "users")
        let orders = DatabaseTable(schema: "shop", name: "orders")
        return SQLCompletionCatalog(schemas: [DatabaseSchema(name: "shop", tables: [users, orders, DatabaseTable(schema: "shop", name: "user notes")])], columns: [
            users.id: [column("id"), column("name"), column("中文名"), column("full name")],
            orders.id: [column("order_id"), column("user_id")]
        ], database: "shop")
    }
    private func column(_ name: String) -> TableColumn { TableColumn(name: name, dataType: "TEXT", isNullable: true, isPrimaryKey: false, defaultValue: nil, extra: "") }
    private func complete(_ sql: String, automatic: Bool = false) -> SQLCompletionRequest? {
        let caret = (sql as NSString).range(of: "|").location
        return SQLCompletion.request(sql: sql.replacingOccurrences(of: "|", with: ""), caret: caret, catalog: catalog, automatic: automatic)
    }
    func testCompletionKeywordsSchemasTablesAndAliases() {
        XCTAssertTrue(complete("sel|", automatic: true)?.candidates.contains("SELECT") == true)
        XCTAssertNil(complete("s|", automatic: true))
        XCTAssertEqual(complete("SELECT * FROM us|")?.candidates, ["users", "`user notes`"].sorted())
        XCTAssertTrue(complete("SELECT * FROM shop.|")?.candidates.contains("orders") == true)
        XCTAssertEqual(complete("SELECT u.na| FROM shop.users AS u")?.candidates, ["name"])
        XCTAssertEqual(complete("SELECT o.| FROM users u JOIN orders o ON u.id=o.user_id")?.candidates, ["order_id", "user_id"])
        XCTAssertEqual(complete("SELECT u.`full n| FROM users u")?.candidates, ["`full name`"])
        XCTAssertEqual(complete("SELECT u.`full n|` FROM users u")?.candidates, ["`full name`"])
        XCTAssertEqual(complete("SELECT u.中文| FROM users u")?.candidates, ["中文名"])
        XCTAssertEqual(complete("SELECT 1; SELECT o.| FROM orders o")?.candidates, ["order_id", "user_id"])
    }
    func testCompletionDoesNotTouchStringsCommentsOrSuffix() {
        for text in ["SELECT 'sel|", "SELECT 1 -- sel|", "SELECT 1 # sel|", "SELECT /* sel|", "SELECT \"sel|"] { XCTAssertNil(complete(text)) }
        let sql = "SELECT '😀', u.na| FROM users u"
        let request = complete(sql)!
        let text = sql.replacingOccurrences(of: "|", with: "") as NSString
        XCTAssertEqual(text.replacingCharacters(in: request.range, with: request.candidates[0]), "SELECT '😀', u.name FROM users u")
        let middle = complete("SELECT u.na|me FROM users u")!
        XCTAssertEqual(("SELECT u.name FROM users u" as NSString).replacingCharacters(in: middle.range, with: middle.candidates[0]), "SELECT u.name FROM users u")
    }
    func testVersionComparisonAndReleaseSelection() throws {
        XCTAssertTrue(ReleaseVersion("v0.10.0")! > ReleaseVersion("0.9.9")!)
        XCTAssertTrue(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.0")!)
        for invalid in ["1.2", "1.2.3-rc1", "1..3", "-1.2.3", "1.2.3.4", "hello"] { XCTAssertNil(ReleaseVersion(invalid)) }
        let release = fixtureRelease()
        XCTAssertNotNil(try release.update(after: "0.2.0"))
        XCTAssertNil(try release.update(after: "0.2.1"))
        XCTAssertNil(try release.update(after: "0.3.0"))
        XCTAssertThrowsError(try fixtureRelease(host: "example.com").update(after: "0.2.0"))
        XCTAssertThrowsError(try fixtureRelease(digest: nil).update(after: "0.2.0"))
        XCTAssertThrowsError(try release.update(after: "dev"))
    }
    private func fixtureRelease(host: String = "github.com", digest: String? = "sha256:" + String(repeating: "a", count: 64)) -> AppRelease {
        AppRelease(tag_name: "v0.2.1", html_url: URL(string: "https://github.com/cookzhang/LuckySQL/releases/tag/v0.2.1")!, body: "Notes", draft: false, prerelease: false, assets: [AppRelease.Asset(name: "LuckySQL-v0.2.1-macos-arm64.zip", browser_download_url: URL(string: "https://\(host)/cookzhang/LuckySQL/releases/download/v0.2.1/LuckySQL-v0.2.1-macos-arm64.zip")!, size: 3, digest: digest)])
    }
    func testUpdateRejectsCorruptionAndArchiveTraversal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let digest = "sha256:" + SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        try UpdateService.verifyArchive(url, asset: fixtureRelease(digest: digest).assets[0])
        XCTAssertThrowsError(try UpdateService.verifyArchive(url, asset: fixtureRelease().assets[0]))
        try Data("abcd".utf8).write(to: url)
        XCTAssertThrowsError(try UpdateService.verifyArchive(url, asset: fixtureRelease(digest: digest).assets[0]))
        try UpdateService.validateArchiveEntries("LuckySQL.app/\nLuckySQL.app/Contents/MacOS/LuckySQL\n__MACOSX/._LuckySQL.app")
        for listing in ["/tmp/x", "LuckySQL.app/../../escape", "Other.app/x", "", "LuckySQL.app/..\\escape"] {
            XCTAssertThrowsError(try UpdateService.validateArchiveEntries(listing))
        }
    }
    func testVerifiedUpdateInstallRetainsBackupAndRejectsWrongVersion() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LuckySQL-update-test-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let original = try makeApp(at: root.appendingPathComponent("Installed.app"), version: "0.2.0")
        let source = try makeApp(at: root.appendingPathComponent("New.app"), version: "0.2.1")
        let updater = UpdateService()
        do { _ = try await updater.install(source, at: original, version: "9.9.9"); XCTFail("Wrong version must not install") } catch { }
        XCTAssertEqual(try plistVersion(original), "0.2.0")
        let backup = try await updater.install(source, at: original, version: "0.2.1")
        XCTAssertEqual(try plistVersion(original), "0.2.1")
        XCTAssertEqual(try plistVersion(backup), "0.2.0")
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }
    private func plistVersion(_ app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }
    func testLiveReleaseDownloadWhenConfigured() async throws {
        guard ProcessInfo.processInfo.environment["LUCKYSQL_TEST_UPDATE_DOWNLOAD"] == "1" else { throw XCTSkip("Set LUCKYSQL_TEST_UPDATE_DOWNLOAD=1 to verify the actual GitHub release download.") }
        let service = UpdateService()
        let release = try await service.latest()
        let asset = try XCTUnwrap(try release.update(after: "0.0.0"))
        let app = try await service.download(asset, version: String(release.tag_name.dropFirst()))
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        XCTAssertEqual(try plistVersion(app), String(release.tag_name.dropFirst()))
    }
    private func makeApp(at app: URL, version: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        // A small system Mach-O provides a real ad-hoc signature/architecture
        // fixture without launching or replacing the user's installed app.
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/LuckySQL"))
        let plist = ["CFBundleIdentifier": "com.cookzhang.LuckySQL", "CFBundleExecutable": "LuckySQL", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": version, "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try UpdateService.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }
}
