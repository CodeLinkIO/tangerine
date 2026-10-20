import AppKit
import TangerineKit

/// Offers to move the app into /Applications when it runs from somewhere else (a disk image,
/// Downloads, the build folder), so the login item and Finder Services point at a stable copy.
@MainActor
enum AppLocation {
    private static let skipKey = "skipMoveToApplications"

    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return ["/Applications/", NSHomeDirectory() + "/Applications/"].contains { path.hasPrefix($0) }
    }

    /// Asks once per launch (until the user ticks "Don't ask again"). Returns true when the app is
    /// relaunching from /Applications and this instance should stop setting itself up.
    static func offerMoveIfNeeded() -> Bool {
        #if DEBUG
        return false
        #else
        guard !isInApplications, !UserDefaults.standard.bool(forKey: skipKey) else { return false }
        let alert = NSAlert()
        alert.icon = TangerineArt.appIcon(size: 128)
        alert.messageText = "Move Tangerine to Applications?"
        alert.informativeText = "Tangerine works best from the Applications folder: it can open at login and appears in Finder’s Services menu."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: skipKey) }
        guard response == .alertFirstButtonReturn else { return false }
        do {
            relaunch(at: try moveToApplications())
            return true
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn’t move Tangerine"
            failure.informativeText = error.localizedDescription
            failure.runModal()
            return false
        }
        #endif
    }

    private static func moveToApplications() throws -> URL {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(source.lastPathComponent)
        let exists = fm.fileExists(atPath: destination.path)
        // Only ever replace an older copy of this app, never a different app with the same name.
        if exists, Bundle(url: destination)?.bundleIdentifier != Bundle.main.bundleIdentifier {
            throw ConversionError.failed("Another app named “\(source.lastPathComponent)” is already in Applications.")
        }
        // Copy next to the destination first so a failed copy never leaves Applications without the app.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(source.lastPathComponent)")
        try fm.copyItem(at: source, to: staging)
        do {
            if exists { try fm.trashItem(at: destination, resultingItemURL: nil) }
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        // Leave the original when it's on a disk image or Gatekeeper's read-only translocation mount.
        let readOnly = (try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? true
        if !readOnly, !source.path.contains("/AppTranslocation/") {
            try? fm.trashItem(at: source, resultingItemURL: nil)
        }
        return destination
    }

    /// Opens the new copy once this process has exited.
    private static func relaunch(at app: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                          app.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
