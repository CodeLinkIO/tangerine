import AppKit

MainActor.assumeIsolated {
    // Developer flags used by scripts/build-app.sh and for visual checks; they exit without launching the UI.
    if DeveloperCommands.run(CommandLine.arguments) { exit(0) }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
