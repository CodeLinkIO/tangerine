import AppKit
import Combine
import SwiftUI
import TangerineKit

/// Hosts the image editor. One window per file; reopening a file focuses its window.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [URL: EditorWindowController] = [:]

    let model: EditorModel
    private let key: URL
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var allowClose = false

    /// Opens (or focuses) an editor for `url`. `onSaved` receives the written file.
    static func open(_ url: URL, options: ConversionOptions, onSaved: @escaping (URL) -> Void) {
        let key = url.standardizedFileURL
        if let existing = controllers[key] {
            existing.present()
            return
        }
        let controller = EditorWindowController(url: key, options: options, onSaved: onSaved)
        controllers[key] = controller
        controller.present()
    }

    private init(url: URL, options: ConversionOptions, onSaved: @escaping (URL) -> Void) {
        key = url
        model = EditorModel(url: url, options: options, onSaved: onSaved)

        let window = NSWindow.themed(size: CGSize(width: 980, height: 720), title: url.lastPathComponent)
        let hosting = NSHostingController(rootView: EditorView(model: model))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 980, height: 720))
        window.minSize = NSSize(width: 760, height: 560)
        window.tabbingMode = .disallowed
        super.init(window: window)

        window.delegate = self
        if Self.controllers.isEmpty, window.setFrameUsingName("TangerineEditor") {
            // Restored the last frame.
        } else if let previous = Self.controllers.values.compactMap(\.window).last {
            window.setFrame(previous.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        } else {
            window.center()
        }
        window.setFrameAutosaveName("TangerineEditor")

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.window?.isDocumentEdited = self.model.isDirty
            }
            .store(in: &cancellables)

        installKeyMonitor()
        model.load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Editor shortcuts. The app runs as an accessory without an Edit menu, so they are handled here.
    private func handle(_ event: NSEvent) -> Bool {
        let editingText = window?.firstResponder is NSTextView
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

        if event.keyCode == 49, modifiers.isEmpty, !editingText {   // Space: hold to compare
            if event.type == .keyDown {
                if !event.isARepeat { model.isComparing = true }
            } else {
                model.isComparing = false
            }
            return true
        }
        if event.type == .keyDown, modifiers.isEmpty, !editingText, model.tool == .crop {
            switch event.keyCode {
            case 36, 76: model.commitCrop(); return true    // Return, Enter
            case 53: model.cancelCrop(); return true        // Escape
            default: break
            }
        }
        guard event.type == .keyDown, modifiers.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            guard !editingText else { return false }
            modifiers.contains(.shift) ? model.redo() : model.undo()
        case "=", "+":
            model.zoomIn()
        case "-":
            model.zoomOut()
        case "0":
            model.zoomToFit()
        case "s":
            Task { await model.saveCopy() }
        case "w":
            window?.performClose(nil)
        default:
            return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowClose, model.isDirty, !model.isSaving else { return !model.isSaving }
        let alert = NSAlert()
        alert.messageText = "Save your edits to “\(model.url.lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save as Copy")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save").hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                Task {
                    if await self.model.saveCopy() {
                        self.allowClose = true
                        sender.performClose(nil)
                    }
                }
            case .alertThirdButtonReturn:
                self.allowClose = true
                sender.performClose(nil)
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        cancellables.removeAll()
        Self.controllers[key] = nil
    }
}
