import Compression
import Foundation
import TangerineCore

/// Minimal ZIP archive writer (stored or deflated entries, no ZIP64), enough for EPUB packages.
struct ZipWriter {
    private var archive = Data()
    private var centralDirectory = Data()
    private var entryCount: UInt16 = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        // DOS dates span 1980...2107.
        dosDate = UInt16(min(127, max(0, (c.year ?? 1980) - 1980)) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    /// Thrown instead of trapping when the archive outgrows the classic (non-ZIP64) format.
    static let tooLarge = ConversionError.failed("The book is too large to package as an EPUB.")

    /// Adds a file. `compress: false` stores it verbatim (required for the EPUB `mimetype` entry).
    mutating func add(_ path: String, _ contents: Data, compress: Bool = true) throws {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(contents)
        let deflated = compress ? Self.deflate(contents) : nil
        let payload = deflated ?? contents
        let method: UInt16 = deflated == nil ? 0 : 8
        let isASCII = path.utf8.allSatisfy { $0 < 0x80 }
        let flags: UInt16 = isASCII ? 0 : 0x0800 // bit 11: UTF-8 file name
        guard entryCount < UInt16.max,
              let offset = UInt32(exactly: archive.count),
              let compressedSize = UInt32(exactly: payload.count),
              let size = UInt32(exactly: contents.count),
              let nameLength = UInt16(exactly: name.count),
              UInt32(exactly: archive.count + 30 + name.count + payload.count) != nil
        else { throw Self.tooLarge }

        // Local file header.
        archive.appendLE(UInt32(0x0403_4B50))
        archive.appendLE(UInt16(20))
        archive.appendLE(flags)
        archive.appendLE(method)
        archive.appendLE(dosTime)
        archive.appendLE(dosDate)
        archive.appendLE(crc)
        archive.appendLE(compressedSize)
        archive.appendLE(size)
        archive.appendLE(nameLength)
        archive.appendLE(UInt16(0))
        archive.append(name)
        archive.append(payload)

        // Central directory record.
        centralDirectory.appendLE(UInt32(0x0201_4B50))
        centralDirectory.appendLE(UInt16(20))
        centralDirectory.appendLE(UInt16(20))
        centralDirectory.appendLE(flags)
        centralDirectory.appendLE(method)
        centralDirectory.appendLE(dosTime)
        centralDirectory.appendLE(dosDate)
        centralDirectory.appendLE(crc)
        centralDirectory.appendLE(compressedSize)
        centralDirectory.appendLE(size)
        centralDirectory.appendLE(nameLength)
        centralDirectory.appendLE(UInt16(0)) // extra
        centralDirectory.appendLE(UInt16(0)) // comment
        centralDirectory.appendLE(UInt16(0)) // disk
        centralDirectory.appendLE(UInt16(0)) // internal attributes
        centralDirectory.appendLE(UInt32(0)) // external attributes
        centralDirectory.appendLE(offset)
        centralDirectory.append(name)
        entryCount += 1
    }

    func finalize() throws -> Data {
        guard let directoryOffset = UInt32(exactly: archive.count),
              let directorySize = UInt32(exactly: centralDirectory.count),
              UInt32(exactly: archive.count + centralDirectory.count) != nil
        else { throw Self.tooLarge }
        var out = archive
        out.append(centralDirectory)
        out.appendLE(UInt32(0x0605_4B50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(entryCount)
        out.appendLE(entryCount)
        out.appendLE(directorySize)
        out.appendLE(directoryOffset)
        out.appendLE(UInt16(0))
        return out
    }

    /// Raw DEFLATE (Apple's COMPRESSION_ZLIB has no zlib header, as ZIP requires). Nil when it doesn't help.
    private static func deflate(_ input: Data) -> Data? {
        guard input.count > 64 else { return nil }
        let capacity = input.count + 1024
        var output = Data(count: capacity)
        let size = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard size > 0, size < input.count else { return nil }
        output.count = size
        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
