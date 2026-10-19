import AppKit
import ServiceManagement
import TangerineKit

/// Modifier keys that can open a wheel while dragging.
enum ModifierKey: String, CaseIterable, Codable, Identifiable {
    case shift, command, control, option

    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .command: .command
        case .control: .control
        case .option: .option
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        }
    }

    var name: String { rawValue.capitalized }
}

/// The two wheels: format conversion and one-shot edits/tools.
enum WheelMode: String, CaseIterable {
    case convert, tools

    var title: String { self == .convert ? "Convert" : "Edit" }
}

/// App settings persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var convertKey: ModifierKey { didSet { defaults.set(convertKey.rawValue, forKey: "convertKey") } }
    @Published var toolsKey: ModifierKey { didSet { defaults.set(toolsKey.rawValue, forKey: "toolsKey") } }
    @Published var dragWheelEnabled: Bool { didSet { defaults.set(dragWheelEnabled, forKey: "dragWheelEnabled") } }
    @Published var options: ConversionOptions { didSet { save(options, forKey: "conversionOptions") } }
    /// Fixed output folder, or nil to save next to the original.
    @Published var outputFolder: URL? { didSet { defaults.set(outputFolder?.path, forKey: "outputFolder") } }
    @Published var revealInFinder: Bool { didSet { defaults.set(revealInFinder, forKey: "revealInFinder") } }
    /// Move originals to the Trash after a successful conversion.
    @Published var replaceOriginals: Bool { didSet { defaults.set(replaceOriginals, forKey: "replaceOriginals") } }
    @Published var finderShortcutEnabled: Bool { didSet { defaults.set(finderShortcutEnabled, forKey: "finderShortcutEnabled") } }
    @Published var hasSeenWelcome: Bool { didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }
    /// Formats pinned to the convert wheel, per category, in order. Missing categories use the catalog order.
    @Published var pinnedTargets: [FormatCategory: [FileFormat]] {
        didSet { save(Dictionary(uniqueKeysWithValues: pinnedTargets.map { ($0.key.rawValue, $0.value) }), forKey: "pinnedTargets") }
    }

    private init() {
        convertKey = ModifierKey(rawValue: defaults.string(forKey: "convertKey") ?? "") ?? .shift
        toolsKey = ModifierKey(rawValue: defaults.string(forKey: "toolsKey") ?? "") ?? .command
        dragWheelEnabled = defaults.object(forKey: "dragWheelEnabled") as? Bool ?? true
        options = Self.load(ConversionOptions.self, from: defaults, key: "conversionOptions") ?? ConversionOptions()
        outputFolder = defaults.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        revealInFinder = defaults.bool(forKey: "revealInFinder")
        replaceOriginals = defaults.bool(forKey: "replaceOriginals")
        finderShortcutEnabled = defaults.object(forKey: "finderShortcutEnabled") as? Bool ?? true
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
        let pinned = Self.load([String: [FileFormat]].self, from: defaults, key: "pinnedTargets") ?? [:]
        pinnedTargets = Dictionary(uniqueKeysWithValues: pinned.compactMap { key, value in
            FormatCategory(rawValue: key).map { ($0, value) }
        })
    }

    func key(for mode: WheelMode) -> ModifierKey { mode == .convert ? convertKey : toolsKey }

    func mode(for key: ModifierKey) -> WheelMode? {
        if key == convertKey { return .convert }
        if key == toolsKey { return .tools }
        return nil
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Tangerine: launch at login change failed: \(error.localizedDescription)")
            }
        }
    }

    /// Wheel targets: pinned formats that are available, else the first available in catalog order.
    func wheelTargets(category: FormatCategory, available: [FileFormat]) -> [FileFormat] {
        let capacity = TargetCatalog.wheelCapacity
        if let pinned = pinnedTargets[category], !pinned.isEmpty {
            let shown = pinned.filter(available.contains)
            if !shown.isEmpty { return Array(shown.prefix(capacity)) }
        }
        return Array(available.prefix(capacity))
    }

    // MARK: Persistence helpers

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Recently written files, newest first, shown in the menu-bar menu.
@MainActor
final class Recents: ObservableObject {
    static let shared = Recents()

    @Published private(set) var files: [URL]

    private init() {
        files = (UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }
    }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        files = Array((urls.reversed() + files.filter { !urls.contains($0) }).prefix(15))
        UserDefaults.standard.set(files.map(\.path), forKey: "recentFiles")
    }

    func clear() {
        files = []
        UserDefaults.standard.removeObject(forKey: "recentFiles")
    }

    /// Recent files that still exist.
    var existing: [URL] { files.filter { FileManager.default.fileExists(atPath: $0.path) } }
}
