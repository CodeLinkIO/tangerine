import AppKit
import Carbon.HIToolbox
import Combine
import TangerineKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let dragMonitor = DragMonitor()
    private let services = ServiceProvider()
    private var finderHotKey: HotKey?
    private var subscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if AppLocation.offerMoveIfNeeded() { return }
        statusItem = StatusItemController()
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        WheelController.shared.onChoose = { item, files in JobRunner.shared.perform(item, on: files) }

        dragMonitor.onModifierTap = { key, files in
            let prefs = Preferences.shared
            guard prefs.dragWheelEnabled, let mode = prefs.mode(for: key) else { return }
            let wheel = WheelController.shared
            if wheel.isVisible, wheel.interaction == .drag {
                wheel.setMode(mode)
            } else {
                wheel.show(files: files, mode: mode, interaction: .drag)
            }
        }
        dragMonitor.onDragEnded = { WheelController.shared.dragEnded() }
        dragMonitor.start()

        Preferences.shared.$finderShortcutEnabled
            .sink { [weak self] enabled in self?.updateFinderShortcut(enabled) }
            .store(in: &subscriptions)

        // Warm up engine capability checks (spawns ffmpeg once) so the first wheel opens instantly.
        Task.detached(priority: .utility) {
            _ = FFmpeg.shared.encoders
            _ = ImageCodec.writableFormats
        }

        if !Preferences.shared.hasSeenWelcome {
            WelcomeWindowController.shared.show()
        }
        #if DEBUG
        runDemoHooks()
        #endif
    }

    #if DEBUG
    /// Debug builds only: TANGERINE_DEMO=wheel|tools|converter|settings|welcome|editor|hud [TANGERINE_DEMO_FILE=a:b] [TANGERINE_DEMO_DARK=1]
    /// [TANGERINE_DEMO_PETAL=n] opens UI without input events, for screenshots and manual checks.
    private func runDemoHooks() {
        let env = ProcessInfo.processInfo.environment
        guard let demo = env["TANGERINE_DEMO"] else { return }
        let files = (env["TANGERINE_DEMO_FILE"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        if env["TANGERINE_DEMO_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            switch demo {
            case "wheel", "tools":
                let frame = NSScreen.main?.visibleFrame ?? .zero
                WheelController.shared.show(files: files, mode: demo == "tools" ? .tools : .convert, interaction: .click,
                                            at: CGPoint(x: frame.midX, y: frame.midY))
                if let petal = env["TANGERINE_DEMO_PETAL"].flatMap(Int.init) { WheelController.shared.highlight(petal) }
            case "converter": ConverterWindowController.shared.show(adding: files)
            case "settings": SettingsWindowController.shared.show()
            case "welcome": WelcomeWindowController.shared.show()
            case "editor": if let file = files.first { JobRunner.shared.openEditor(file) }
            case "hud":
                HUDController.shared.present(title: "Converting…", detail: "").progress = 0.6
                HUDController.shared.present(title: "", detail: "")
                    .finish(.success, title: "Saved \(files.first?.lastPathComponent ?? "file") · −63%", outputs: files)
            default: break
            }
        }
    }
    #endif

    /// Files opened via "Open With", the Dock or `open -a`: images go to the editor, the rest to the Converter.
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.count == 1, FileFormat.detect(urls[0])?.category == .image {
            JobRunner.shared.openEditor(urls[0])
        } else {
            ConverterWindowController.shared.show(adding: urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { ConverterWindowController.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func updateFinderShortcut(_ enabled: Bool) {
        finderHotKey?.unregister()
        finderHotKey = nil
        guard enabled else { return }
        finderHotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) {
            let files = FinderSelection.current()
            guard !files.isEmpty else {
                NSSound.beep()
                return
            }
            WheelController.shared.show(files: files, mode: .convert, interaction: .click)
        }
    }
}
