import AppKit

/// Detects file drags anywhere on screen (Finder, Desktop, other apps, our own windows) and
/// reports modifier-key taps while the drag is in progress.
///
/// How it works without Accessibility permission: a mouse-down (global or local monitor) starts a
/// short-lived 60 Hz timer that runs only while the button is held. The timer watches the drag
/// pasteboard's change count — a new drag session writes to it — and then polls the global
/// modifier state, which needs no special permission either.
@MainActor
final class DragMonitor {
    /// A modifier was pressed during a file drag.
    var onModifierTap: ((ModifierKey, [URL]) -> Void)?
    /// The mouse button was released after a file drag.
    var onDragEnded: (() -> Void)?

    private(set) var isDragging = false
    private(set) var draggedFiles: [URL] = []

    private var monitors: [Any] = []
    private var timer: Timer?
    private var startChangeCount = 0
    private var previousFlags: NSEvent.ModifierFlags = []
    private var ignoreCurrentDrag = false
    private let dragPasteboard = NSPasteboard(name: .drag)
    private static let watchedFlags: NSEvent.ModifierFlags = [.shift, .command, .control, .option]

    func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown() }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        stopTimer()
    }

    private func mouseDown() {
        startChangeCount = dragPasteboard.changeCount
        isDragging = false
        ignoreCurrentDrag = false
        draggedFiles = []
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes keep it firing while our own windows run a drag tracking loop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            stopTimer()
            if isDragging {
                isDragging = false
                onDragEnded?()
            }
            return
        }

        guard isDragging else {
            guard !ignoreCurrentDrag, dragPasteboard.changeCount != startChangeCount else { return }
            let urls = (dragPasteboard.readObjects(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !urls.isEmpty else {
                ignoreCurrentDrag = true   // text, images from browsers, file promises…
                return
            }
            isDragging = true
            draggedFiles = urls
            // Keys already held when the drag began (e.g. ⌘-drag to move) don't count as taps.
            previousFlags = NSEvent.modifierFlags.intersection(Self.watchedFlags)
            return
        }

        let flags = NSEvent.modifierFlags.intersection(Self.watchedFlags)
        let pressed = flags.subtracting(previousFlags)
        previousFlags = flags
        for key in ModifierKey.allCases where pressed.contains(key.flag) {
            onModifierTap?(key, draggedFiles)
        }
    }
}
