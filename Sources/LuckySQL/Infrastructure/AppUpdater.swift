import AppKit
import CryptoKit
import Foundation

struct ReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        self.parts = parts.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AppRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int
        let digest: String?
    }
    let tag_name: String
    let html_url: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    func update(after current: String) throws -> Asset? {
        guard !draft, !prerelease, tag_name.hasPrefix("v"), let version = ReleaseVersion(tag_name), let installed = ReleaseVersion(current) else {
            throw UpdateFailure("Invalid release version. Install a stable packaged release to enable updates.")
        }
        guard version > installed else { return nil }
        let name = "LuckySQL-\(tag_name)-macos-arm64.zip"
        guard let asset = assets.first(where: { $0.name == name }), asset.size > 0, asset.size <= 100_000_000,
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path == "/cookzhang/LuckySQL/releases/download/\(tag_name)/\(name)",
              let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw UpdateFailure("This release has no compatible, SHA-256-verified Apple Silicon package.")
        }
        return asset
    }
}

struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Network and filesystem work stays off the UI actor. Trust is rooted in the
/// repository's HTTPS release metadata; ad-hoc signing is not publisher identity.
actor UpdateService {
    static let latestURL = URL(string: "https://api.github.com/repos/cookzhang/LuckySQL/releases/latest")!
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func latest() async throws -> AppRelease {
        var request = URLRequest(url: Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LuckySQL-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.checkHTTP(response)
        guard data.count < 2_000_000 else { throw UpdateFailure("Release metadata is too large.") }
        return try JSONDecoder().decode(AppRelease.self, from: data)
    }

    func download(_ asset: AppRelease.Asset, version: String) async throws -> URL {
        let request = URLRequest(url: asset.browser_download_url, timeoutInterval: 120)
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.checkHTTP(response)
        try Task.checkCancellation()
        try Self.verifyArchive(temporary, asset: asset)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LuckySQL-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            // Reject path traversal and symlinks before extraction, not afterward.
            let entries = try Self.run("/usr/bin/zipinfo", ["-1", temporary.path])
            try Self.validateArchiveEntries(entries)
            let listing = try Self.run("/usr/bin/zipinfo", ["-l", temporary.path])
            guard !listing.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else { throw UpdateFailure("Update archive contains symbolic links.") }
            let expandedSizes = listing.split(separator: "\n").filter { $0.hasPrefix("-") || $0.hasPrefix("d") }.compactMap { line -> UInt64? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                return fields.count > 3 ? UInt64(fields[3]) : nil
            }
            guard !expandedSizes.isEmpty, expandedSizes.allSatisfy({ $0 <= 500_000_000 }), expandedSizes.reduce(0, +) <= 500_000_000 else { throw UpdateFailure("Expanded update exceeds the 500 MB safety limit.") }
            try Self.run("/usr/bin/ditto", ["-x", "-k", temporary.path, root.path])
            let app = root.appendingPathComponent("LuckySQL.app", isDirectory: true)
            try Self.validateApp(app, version: version)
            return app
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func install(_ source: URL, at destination: URL, version: String) throws -> URL {
        let fm = FileManager.default
        guard destination.pathExtension == "app", destination.resolvingSymlinksInPath() == destination.standardizedFileURL,
              let bundle = Bundle(url: destination), bundle.bundleIdentifier == "com.cookzhang.LuckySQL",
              fm.isWritableFile(atPath: destination.path), fm.isWritableFile(atPath: destination.deletingLastPathComponent().path),
              !destination.path.contains("/AppTranslocation/"), !destination.path.hasPrefix("/Volumes/") else {
            throw UpdateFailure("Move LuckySQL to a writable Applications folder and launch it there before installing updates. The downloaded update is still available.")
        }
        try Self.validateApp(source, version: version)
        // Same-volume staging permits an atomic replacement. Keep a uniquely
        // named backup, so rollback never deletes or overwrites another version.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: staging) }
        let stagedApp = staging.appendingPathComponent("LuckySQL.app")
        try fm.copyItem(at: source, to: stagedApp)
        try Self.validateApp(stagedApp, version: version)
        let backupName = "LuckySQL-backup-\(UUID().uuidString).app"
        _ = try fm.replaceItemAt(destination, withItemAt: stagedApp, backupItemName: backupName, options: [.usingNewMetadataOnly, .withoutDeletingBackupItem])
        return destination.deletingLastPathComponent().appendingPathComponent(backupName)
    }

    static func verifyArchive(_ url: URL, asset: AppRelease.Asset) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(); var size = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            size += data.count
            guard size <= asset.size else { throw UpdateFailure("Update download size does not match release metadata.") }
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == asset.size, asset.digest?.lowercased() == "sha256:" + digest else { throw UpdateFailure("Update SHA-256 verification failed. Nothing was installed.") }
    }

    static func validateArchiveEntries(_ listing: String) throws {
        let paths = listing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !paths.isEmpty, paths.count <= 10_000, paths.allSatisfy({ path in
            !path.hasPrefix("/") && !path.contains("\\") && !path.split(separator: "/").contains("..") &&
                (path.hasPrefix("LuckySQL.app/") || path.hasPrefix("__MACOSX/"))
        }) else { throw UpdateFailure("Unsafe update archive paths.") }
    }

    static func validateApp(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.cookzhang.LuckySQL",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "LuckySQL",
              let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String else { throw UpdateFailure("The downloaded app identity or version is invalid.") }
        let runningOS = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(runningOS.majorVersion).\(runningOS.minorVersion).\(runningOS.patchVersion)"
        guard minimum.compare(os, options: .numeric) != .orderedDescending else { throw UpdateFailure("This update requires macOS \(minimum) or later.") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let handle = try FileHandle(forReadingFrom: app.appendingPathComponent("Contents/MacOS/LuckySQL"))
        defer { try? handle.close() }
        guard containsARM64(try handle.read(upToCount: 4096) ?? Data()) else { throw UpdateFailure("The update does not contain an Apple Silicon executable.") }
    }

    // Read Mach-O headers directly; users must not need Xcode's lipo tool.
    static func containsARM64(_ data: Data) -> Bool {
        let bytes = Array(data)
        func word(_ offset: Int, little: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let slice = Array(bytes[offset..<offset + 4])
            return (little ? slice.reversed().map { $0 } : slice).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard let magic = word(0) else { return false }
        if magic == 0xcffaedfe { return word(4, little: true) == 0x0100000c }
        if magic == 0xfeedfacf { return word(4) == 0x0100000c }
        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        guard [0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca].contains(magic),
              let count = word(4, little: little), count > 0, count <= 16 else { return false }
        let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
        return (0..<Int(count)).contains { word(8 + $0 * stride, little: little) == 0x0100000c }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure("Update validation failed (\(URL(fileURLWithPath: executable).lastPathComponent)). \(String(decoding: data.prefix(2_000), as: UTF8.self))") }
        return String(decoding: data, as: UTF8.self)
    }
    private static func checkHTTP(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https" else { throw UpdateFailure("Unable to download update. Check the network or try again later (GitHub may be rate limiting requests).") }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published var isPresented = false
    @Published var busy = false
    @Published var status = "Check for a new LuckySQL release."
    @Published var release: AppRelease?
    @Published var downloadedApp: URL?
    @Published var installed = false
    @Published var error: String?
    private var asset: AppRelease.Asset?
    private var task: Task<Void, Never>?
    private let service: UpdateService
    let currentVersion: String
    init(service: UpdateService = UpdateService(), currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.1") {
        self.service = service; self.currentVersion = currentVersion
    }
    func check() {
        isPresented = true
        guard !busy, !installed else { return }
        #if !arch(arm64)
        error = "Automatic installation currently supports Apple Silicon only. Use GitHub Releases for other builds."
        return
        #endif
        busy = true; error = nil; status = "Checking GitHub Releases…"
        task = Task {
            defer { busy = false }
            do {
                let latest = try await service.latest()
                try Task.checkCancellation()
                let selected = try latest.update(after: currentVersion)
                release = selected == nil ? nil : latest; asset = selected
                downloadedApp = nil
                status = selected == nil ? "LuckySQL \(currentVersion) is up to date." : "LuckySQL \(latest.tag_name) is available."
            } catch is CancellationError { status = "Update check cancelled." }
            catch { self.error = error.localizedDescription; status = "Update check failed. You can retry." }
        }
    }
    func download() {
        guard !busy, let asset, let release else { return }
        busy = true; error = nil; status = "Downloading and verifying \(release.tag_name)…"
        task = Task {
            defer { busy = false }
            do {
                downloadedApp = try await service.download(asset, version: String(release.tag_name.dropFirst()))
                status = "Verified update ready to install. Your connections and SQL drafts will be preserved."
            } catch is CancellationError { status = "Download cancelled. Nothing was installed." }
            catch { self.error = error.localizedDescription; status = "Download failed. Nothing was installed; you can retry." }
        }
    }
    func cancel() { task?.cancel() }
    func install(model: AppModel) {
        guard !busy, !model.isRunning, let downloadedApp, let release else { return }
        model.saveWorkspace()
        busy = true; error = nil; status = "Installing verified update…"
        task = Task {
            defer { busy = false }
            do {
                let backup = try await service.install(downloadedApp, at: Bundle.main.bundleURL, version: String(release.tag_name.dropFirst()))
                installed = true
                status = "Update installed. Restart to use it. Previous app retained at \(backup.path)."
            } catch { self.error = error.localizedDescription; status = "Installation failed. You can retry or reveal the verified download." }
        }
    }
    func restart(model: AppModel) {
        guard installed, !model.isRunning else { return }
        model.saveWorkspace(); model.disconnect()
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Positional arguments, never interpolation of a filesystem path into
            // shell source. Only launch after this process has actually exited.
            process.arguments = ["-c", "for i in $(seq 1 120); do if ! kill -0 \"$1\" 2>/dev/null; then exec /usr/bin/open \"$2\"; fi; sleep 1; done", "LuckySQL-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
            try process.run()
            NSApp.terminate(nil)
        } catch { self.error = "Could not restart automatically. Quit and reopen LuckySQL. \(error.localizedDescription)" }
    }
}
