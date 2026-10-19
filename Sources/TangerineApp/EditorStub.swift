import AppKit
import TangerineKit

// Temporary stand-in until the editor branch is merged.
@MainActor
final class EditorWindowController: NSWindowController {
    static func open(_ url: URL, options: ConversionOptions, onSaved: @escaping (URL) -> Void) {
        NSWorkspace.shared.open(url)
    }
}
