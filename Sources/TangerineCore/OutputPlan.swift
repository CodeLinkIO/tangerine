import Foundation

/// Decides where results are written and never overwrites existing files.
public struct OutputPlan: Sendable {
    public let directory: URL
    public let baseName: String
    /// Holds the names this plan hands out until the job ends, so files converted in parallel never pick the same name.
    public let reservations: OutputReservations?

    public init(directory: URL, baseName: String, reservations: OutputReservations? = nil) {
        self.directory = directory
        self.baseName = baseName
        self.reservations = reservations
    }

    /// Plan for writing next to `input`, or into `directory` when given.
    public init(for input: URL, directory: URL? = nil, reservations: OutputReservations? = nil) {
        self.directory = directory ?? input.deletingLastPathComponent()
        self.baseName = FileFormat.baseName(of: input)
        self.reservations = reservations
    }

    /// A free file URL: `<base>[ <suffix>].<ext>`, adding " 2", " 3"… when taken.
    public func file(extension ext: String, suffix: String? = nil) -> URL {
        Self.unique(in: directory, name: fittedName(suffix: suffix, extension: ext), extension: ext,
                    isDirectory: false, reservations: reservations)
    }

    /// Creates and returns a free folder: `<base>[ <suffix>]`.
    public func makeFolder(suffix: String? = nil) throws -> URL {
        let url = Self.unique(in: directory, name: fittedName(suffix: suffix, extension: ""), extension: "",
                              isDirectory: true, reservations: reservations)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Returns `url` if nothing exists there, otherwise the first free "name N.ext" variant.
    public static func unique(_ url: URL) -> URL {
        let name = url.lastPathComponent as NSString
        return unique(in: url.deletingLastPathComponent(), name: name.deletingPathExtension, extension: name.pathExtension,
                      isDirectory: url.hasDirectoryPath, reservations: nil)
    }

    /// Longest output name in UTF-8 bytes: file names are limited to 255, and ImageIO writes through a temporary
    /// name about 8 bytes longer.
    static let maxNameLength = 247

    /// `<base>[ <suffix>]`, shortening the base so the name still fits once " N" and the extension are added.
    private func fittedName(suffix: String?, extension ext: String) -> String {
        let tail = suffix.map { " \($0)" } ?? ""
        let room = Self.maxNameLength - tail.utf8.count - (ext.isEmpty ? 0 : ext.utf8.count + 1) - 4   // " 999"
        var base = baseName
        while base.utf8.count > max(room, 1), !base.isEmpty { base.removeLast() }
        return base + tail
    }

    /// The first free `name[ N][.ext]` that is neither on disk nor reserved by a running job.
    private static func unique(in directory: URL, name: String, extension ext: String, isDirectory: Bool,
                               reservations: OutputReservations?) -> URL {
        let fm = FileManager.default
        OutputReservations.lock.lock()
        defer { OutputReservations.lock.unlock() }
        var n = 1
        while true {
            let numbered = n == 1 ? name : "\(name) \(n)"
            let url = directory.appendingPathComponent(ext.isEmpty ? numbered : "\(numbered).\(ext)", isDirectory: isDirectory)
            if !fm.fileExists(atPath: url.path), !OutputReservations.isReserved(url) {
                reservations?.reserve(url)
                return url
            }
            n += 1
        }
    }
}

/// Output names handed out but possibly not written yet. Each job holds one so files running in parallel,
/// or in other jobs, never write to the same name; `release()` frees the names once the job has finished.
public final class OutputReservations: @unchecked Sendable {
    /// Guards `reserved` and every instance's `mine`.
    fileprivate static let lock = NSLock()
    private static var reserved = Set<String>()
    private var mine: [String] = []

    public init() {}

    /// APFS and HFS+ ignore case and Unicode normalization, so "Photo.JPG" and "photo.jpg" are one name.
    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Callers hold `lock`.
    fileprivate static func isReserved(_ url: URL) -> Bool { reserved.contains(key(url)) }

    /// Callers hold `lock`.
    fileprivate func reserve(_ url: URL) {
        let key = Self.key(url)
        Self.reserved.insert(key)
        mine.append(key)
    }

    /// Frees every name reserved through this object.
    public func release() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        for key in mine { Self.reserved.remove(key) }
        mine.removeAll()
    }

    deinit { release() }
}

/// Scratch directory that is removed when the value is released.
public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL

    public init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tangerine", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

public extension URL {
    /// File size in bytes, or 0 when unknown. Folders report the sum of their contents.
    var fileSize: Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        let enumerator = fm.enumerator(at: self, includingPropertiesForKeys: [.fileSizeKey])
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
