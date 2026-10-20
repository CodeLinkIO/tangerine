import AppKit
import Carbon.HIToolbox
import TangerineKit

/// Global ⌃⌥T shortcut via Carbon hot keys (no Accessibility permission needed).
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        let id = Self.nextID
        Self.nextID += 1
        Self.instances[id] = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.instances[id]?.action() } }
            return noErr
        }, 1, &spec, nil, &handler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x544E_4752), id: id)   // 'TNGR'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}

/// Reads the current Finder selection via Apple Events (asks for Automation permission once).
enum FinderSelection {
    static func current() -> [URL] {
        // A list, not newline-joined text: file names may contain newlines.
        let source = """
        tell application "Finder"
            set output to {}
            repeat with anItem in (get selection)
                set end of output to POSIX path of (anItem as alias)
            end repeat
            return output
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            if let error { NSLog("Tangerine: Finder selection failed: \(error)") }
            return []
        }
        guard result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }.map { URL(fileURLWithPath: $0) }
    }
}

/// Finder → Services → "Convert with Tangerine" / "Edit Image with Tangerine".
@MainActor
final class ServiceProvider: NSObject {
    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.urls(on: pasteboard)
        guard !urls.isEmpty else { return }
        WheelController.shared.show(files: urls, mode: .convert, interaction: .click)
    }

    @objc func editImage(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let url = Self.urls(on: pasteboard).first else { return }
        JobRunner.shared.openEditor(url)
    }

    private static func urls(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
