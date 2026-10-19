import AppKit
import TangerineKit

/// Menu-bar icon: a menu on click, and a drop target that opens the wheel for dropped files.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let recentMenu = NSMenu()

    override init() {
        super.init()
        item.button?.image = TangerineArt.menuBarIcon()
        item.button?.toolTip = "Tangerine — drop files here to convert"
        menu.delegate = self
        item.menu = menu
        // Status bar buttons can't be subclassed, but their window forwards drag messages to its delegate.
        item.button?.window?.registerForDraggedTypes([.fileURL])
        item.button?.window?.delegate = self
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: "Open Converter…", action: #selector(openConverter), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Convert Files…", action: #selector(convertFiles), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit Image…", action: #selector(editImage), keyEquivalent: "e").target = self

        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentMenu.removeAllItems()
        let recents = Recents.shared.existing
        if recents.isEmpty {
            recentMenu.addItem(withTitle: "No Recent Files", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            for url in recents.prefix(10) {
                let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = url
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = CGSize(width: 16, height: 16)
                entry.image = icon
                recentMenu.addItem(entry)
            }
            recentMenu.addItem(.separator())
            recentMenu.addItem(withTitle: "Clear Recents", action: #selector(clearRecents), keyEquivalent: "").target = self
        }
        recentItem.submenu = recentMenu
        menu.addItem(.separator())
        menu.addItem(recentItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "How It Works", action: #selector(showWelcome), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tangerine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openConverter() { ConverterWindowController.shared.show() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func showWelcome() { WelcomeWindowController.shared.show() }
    @objc private func clearRecents() { Recents.shared.clear() }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func convertFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Convert"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        WheelController.shared.show(files: panel.urls, mode: .convert, interaction: .click, at: screenCenter())
    }

    @objc private func editImage() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Edit"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        JobRunner.shared.openEditor(url)
    }

    private func screenCenter() -> CGPoint {
        let frame = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: Drop target

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        item.button?.highlight(true)
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    func draggingExited(_ sender: NSDraggingInfo?) { item.button?.highlight(false) }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        // Open just below the icon once the drop finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var point = NSEvent.mouseLocation
            if let frame = self.item.button?.window?.frame { point = CGPoint(x: frame.midX, y: frame.minY - 170) }
            WheelController.shared.show(files: urls, mode: .convert, interaction: .click, at: point)
        }
        return true
    }
}
