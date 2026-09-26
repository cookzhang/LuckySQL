import AppKit
import SwiftUI
import XCTest
@testable import LuckySQL

@MainActor final class UpdaterRestartTests: XCTestCase {
    func testRestartWaitsForNativeSheetDismissalAndOnlyRunsOnce() async throws {
        let (workspaces, defaults, suite) = try fixture()
        defer { workspaces.flush(); defaults.removePersistentDomain(forName: suite) }
        let destination = URL(fileURLWithPath: "/tmp/LuckySQL Restart Fixture.app")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var launches = 0
        let updater = AppUpdater(applicationURL: destination) { url in
            XCTAssertNil(window.attachedSheet, "Restart must wait until the sheet no longer blocks termination")
            XCTAssertEqual(url, destination)
            launches += 1
        }
        updater.installed = true
        let host = NSHostingView(rootView: RestartSheetHarness(updater: updater, workspaces: workspaces))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        updater.isPresented = true
        try await waitUntil { window.attachedSheet != nil }
        updater.restart(workspaces: workspaces)
        updater.restart(workspaces: workspaces)
        XCTAssertEqual(launches, 0, "Requesting dismissal must not launch the helper yet")
        XCTAssertTrue(updater.busy)
        try await waitUntil { launches == 1 }
        updater.restart(workspaces: workspaces)
        XCTAssertEqual(launches, 1)
    }

    func testNormalDismissalDoesNotRestartAndFailuresCanBeRetried() async throws {
        let (workspaces, defaults, suite) = try fixture()
        defer { workspaces.flush(); defaults.removePersistentDomain(forName: suite) }
        var launches = 0
        let updater = AppUpdater { _ in
            launches += 1
            throw UpdateFailure("Fixture: quit refused")
        }
        updater.installed = true; updater.isPresented = true
        updater.isPresented = false
        XCTAssertEqual(launches, 0)
        for expected in 1...2 {
            updater.isPresented = true
            updater.restart(workspaces: workspaces)
            XCTAssertFalse(updater.isPresented)
            try await waitUntil { !updater.busy }
            XCTAssertEqual(launches, expected)
            XCTAssertTrue(updater.isPresented)
            XCTAssertFalse(updater.busy)
            XCTAssertTrue(updater.error?.contains("quit refused") == true)
        }
    }

    func testOperationStartingDuringDismissalPreventsRestart() async throws {
        let (workspaces, defaults, suite) = try fixture()
        defer { workspaces.active.isRunning = false; workspaces.flush(); defaults.removePersistentDomain(forName: suite) }
        var launches = 0
        let updater = AppUpdater { _ in launches += 1 }
        updater.installed = true; updater.isPresented = true
        updater.restart(workspaces: workspaces)
        workspaces.active.isRunning = true
        try await waitUntil { !updater.busy }
        XCTAssertEqual(launches, 0)
        XCTAssertTrue(updater.isPresented)
        XCTAssertFalse(updater.busy)
        XCTAssertNotNil(updater.error)
    }

    private func fixture() throws -> (ConnectionWorkspaces, UserDefaults, String) {
        let suite = "UpdaterRestart.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspaces = ConnectionWorkspaces(defaults: defaults) { store in
            AppModel(profileStore: ProfileStore(defaults: defaults), keychain: RestartPasswords(), workspaceStore: store)
        }
        return (workspaces, defaults, suite)
    }
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for native sheet lifecycle")
                throw UpdateFailure("Sheet lifecycle timeout")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct RestartSheetHarness: View {
    @ObservedObject var updater: AppUpdater
    let workspaces: ConnectionWorkspaces
    var body: some View {
        Text("Restart fixture").frame(width: 800, height: 550)
            .sheet(isPresented: $updater.isPresented) {
                UpdateView(updater: updater, workspaces: workspaces)
            }
    }
}
private actor RestartPasswords: PasswordStoring {
    func password(for profileID: UUID) -> String? { nil }
    func save(_ password: String, for profileID: UUID) {}
    func deletePassword(for profileID: UUID) {}
}
