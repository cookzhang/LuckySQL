import AppKit

@MainActor enum AppRelauncher {
    static func restart(at applicationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Keep paths in positional arguments; wait for this process to exit so
        // Launch Services cannot merely reactivate the old instance.
        process.arguments = ["-c", "i=0; while [ \"$i\" -lt 120 ]; do if ! kill -0 \"$1\" 2>/dev/null; then exec /usr/bin/open \"$2\"; fi; /bin/sleep 1; i=$((i + 1)); done", "LuckySQL-relaunch", String(ProcessInfo.processInfo.processIdentifier), applicationURL.path]
        try process.run()
        NSApp.terminate(nil)
        // Our application delegate returns terminateNow or terminateCancel.
        // A return here means quit was refused; don't leave an orphaned helper
        // that unexpectedly reopens the application on a later manual quit.
        if process.isRunning { process.terminate() }
        throw UpdateFailure("The application did not accept the quit request.")
    }
}
