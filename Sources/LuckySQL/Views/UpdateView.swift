import SwiftUI

struct UpdateView: View {
    @ObservedObject var updater: AppUpdater
    @ObservedObject var workspaces: ConnectionWorkspaces
    @State private var confirmInstall = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("LuckySQL Updates", systemImage: "arrow.down.circle").font(.title2.bold())
            Text("Installed version: \(updater.currentVersion)").foregroundStyle(.secondary)
            HStack { if updater.busy { ProgressView().controlSize(.small) }; Text(updater.status).textSelection(.enabled) }
            if let error = updater.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let release = updater.release {
                ScrollView { Text(release.body ?? "No release notes.").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 220)
            }
            Text("Updates come only from cookzhang/LuckySQL on GitHub and are verified against its SHA-256 digest. Current releases are ad-hoc signed, not Apple-notarized. Installation requires a writable app folder; no administrator password is requested.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("GitHub Releases", destination: URL(string: "https://github.com/cookzhang/LuckySQL/releases")!)
                Spacer()
                if updater.busy { Button("Cancel") { updater.cancel() }.disabled(updater.status.hasPrefix("Installing")) }
                else if updater.installed {
                    Button("Restart LuckySQL") { updater.restart(workspaces: workspaces) }.disabled(workspaces.isBusy || workspaces.hasPendingGridChanges).buttonStyle(.borderedProminent)
                } else if let app = updater.downloadedApp {
                    Button("Reveal Download") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                    Button("Install Update…") { confirmInstall = true }.disabled(workspaces.isBusy || workspaces.hasPendingGridChanges).buttonStyle(.borderedProminent)
                } else if updater.release != nil {
                    Button("Download Update") { updater.download() }.buttonStyle(.borderedProminent)
                } else { Button("Check Again") { updater.check() } }
                Button("Close") { updater.isPresented = false }.disabled(updater.busy)
            }
            if workspaces.hasPendingGridChanges { Text("Commit or discard pending table changes in every workspace before installing or restarting.").font(.caption) }
            if workspaces.isBusy { Text("Wait for the active database operation to finish before installing or restarting.").font(.caption) }
        }.padding(24).frame(width: 640)
            .background(UpdateSheetWindow { updater.trackPresentationWindow($0) })
            .interactiveDismissDisabled(updater.busy)
            .confirmationDialog("Install this update?", isPresented: $confirmInstall) {
                Button("Install Verified Update") { updater.install(workspaces: workspaces) }
            } message: { Text("Your current app will be replaced, with a backup retained beside it. SQL drafts are saved first. Restart when installation finishes.") }
    }
}

/// Report the specific update sheet instead of guessing from the key window.
private struct UpdateSheetWindow: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> Marker { Marker(onWindow: onWindow) }
    func updateNSView(_ view: Marker, context: Context) { view.onWindow = onWindow }
    final class Marker: NSView {
        var onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}
