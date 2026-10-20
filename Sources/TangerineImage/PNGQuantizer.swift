import CoreGraphics
import Foundation
import TangerineCore

/// Lossy PNG compression in the spirit of pngquant: reduces the image to a 256-color palette
/// (with per-entry alpha) using median cut, maps pixels with light Floyd–Steinberg dithering,
/// and writes an indexed PNG. Typically 60–80% smaller than a truecolor PNG.
enum PNGQuantizer {
    static func encode(_ image: CGImage, colors: Int = 256, dithering: Float = 0.75) throws -> Data {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { throw ConversionError.failed("Empty image.") }
        // Quantizing holds several full-size buffers at once.
        try ImageCodec.checkPixelBudget(width: width, height: height)
        var pixels = try rgba(image)
        let palette = medianCut(pixels, maxColors: colors)
        let indices = map(&pixels, width: width, height: height, palette: palette, dithering: dithering)
        return PNGWriter.indexed(width: width, height: height, palette: palette, indices: indices)
    }

    /// Straight (non-premultiplied) RGBA8 pixels in sRGB.
    static func rgba(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw ConversionError.failed("Couldn't read pixels.") }
        // Un-premultiply.
        var i = 0
        while i < data.count {
            let a = Int(data[i + 3])
            if a > 0, a < 255 {
                data[i] = UInt8(min(255, Int(data[i]) * 255 / a))
                data[i + 1] = UInt8(min(255, Int(data[i + 1]) * 255 / a))
                data[i + 2] = UInt8(min(255, Int(data[i + 2]) * 255 / a))
            } else if a == 0 {
                data[i] = 0; data[i + 1] = 0; data[i + 2] = 0
            }
            i += 4
        }
        return data
    }

    // MARK: Palette

    private struct Box {
        var colors: [SIMD4<UInt8>]
        var lower: SIMD4<UInt8>
        var upper: SIMD4<UInt8>

        init(_ colors: [SIMD4<UInt8>]) {
            self.colors = colors
            var lo = SIMD4<UInt8>(repeating: 255), hi = SIMD4<UInt8>(repeating: 0)
            for c in colors {
                lo = pointwiseMin(lo, c)
                hi = pointwiseMax(hi, c)
            }
            lower = lo
            upper = hi
        }

        var widestChannel: Int {
            let range = SIMD4<Int>(truncatingIfNeeded: upper) &- SIMD4<Int>(truncatingIfNeeded: lower)
            var best = 0
            for c in 1..<4 where range[c] > range[best] { best = c }
            return best
        }

        var score: Int {
            let range = SIMD4<Int>(truncatingIfNeeded: upper) &- SIMD4<Int>(truncatingIfNeeded: lower)
            return max(range[0], range[1], range[2], range[3]) * colors.count
        }

        var average: SIMD4<UInt8> {
            var sum = SIMD4<Int>(repeating: 0)
            for c in colors { sum &+= SIMD4<Int>(truncatingIfNeeded: c) }
            let n = max(colors.count, 1)
            return SIMD4<UInt8>(truncatingIfNeeded: sum / SIMD4<Int>(repeating: n))
        }
    }

    static func medianCut(_ pixels: [UInt8], maxColors: Int) -> [SIMD4<UInt8>] {
        // Sample up to ~200k pixels for speed; fully transparent pixels collapse to one entry.
        let count = pixels.count / 4
        let step = max(1, count / 200_000)
        var samples: [SIMD4<UInt8>] = []
        samples.reserveCapacity(count / step + 1)
        var hasTransparent = false
        var i = 0
        while i < count {
            let o = i * 4
            if pixels[o + 3] == 0 {
                hasTransparent = true
            } else {
                samples.append(SIMD4(pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3]))
            }
            i += step
        }
        let budget = maxColors - (hasTransparent ? 1 : 0)
        var palette: [SIMD4<UInt8>] = hasTransparent ? [SIMD4(0, 0, 0, 0)] : []
        guard !samples.isEmpty else { return palette.isEmpty ? [SIMD4(0, 0, 0, 255)] : palette }

        // Opaque and translucent pixels start in separate boxes, so opaque areas always get opaque entries.
        var boxes = [samples.filter { $0[3] == 255 }, samples.filter { $0[3] < 255 }].filter { !$0.isEmpty }.map(Box.init)
        if boxes.count > budget { boxes = [Box(samples)] }
        while boxes.count < budget {
            // Split the most spread-out box that can still be split.
            guard let index = boxes.indices
                .filter({ boxes[$0].colors.count > 1 && boxes[$0].score > 0 })
                .max(by: { boxes[$0].score < boxes[$1].score })
            else { break }
            let box = boxes.remove(at: index)
            let channel = box.widestChannel
            let sorted = box.colors.sorted { $0[channel] < $1[channel] }
            let mid = sorted.count / 2
            boxes.append(Box(Array(sorted[..<mid])))
            boxes.append(Box(Array(sorted[mid...])))
        }
        // Snap near-opaque/near-clear alpha so solid areas don't pick up faint transparency.
        palette += boxes.map { box in
            var color = box.average
            if color[3] >= 250 { color[3] = 255 } else if color[3] <= 4 { color[3] = 0 }
            return color
        }
        return palette
    }

    // MARK: Mapping

    static func map(_ pixels: inout [UInt8], width: Int, height: Int, palette: [SIMD4<UInt8>],
                    dithering: Float) -> [UInt8] {
        var indices = [UInt8](repeating: 0, count: width * height)
        // Cache nearest-palette lookups keyed by 5 bits per channel.
        var cache = [Int16](repeating: -1, count: 1 << 20)
        let transparentIndex = palette.firstIndex(where: { $0[3] == 0 })
        let paletteInt = palette.map { SIMD4<Int32>(truncatingIfNeeded: $0) }
        let allEntries = Array(paletteInt.indices), opaqueEntries = allEntries.filter { paletteInt[$0][3] == 255 }

        func nearest(_ c: SIMD4<Int32>) -> Int {
            // Fully opaque pixels get their own alpha bucket and only match opaque entries, so they never turn translucent.
            let opaque = c[3] >= 255 && !opaqueEntries.isEmpty
            let alphaKey = c[3] >= 255 ? 31 : min(30, Int(c[3] >> 3))
            let key = Int(c[0] >> 3) << 15 | Int(c[1] >> 3) << 10 | Int(c[2] >> 3) << 5 | alphaKey
            if cache[key] >= 0 { return Int(cache[key]) }
            var best = 0, bestDistance = Int32.max
            for i in opaque ? opaqueEntries : allEntries {
                let p = paletteInt[i]
                let d = c &- p
                // Weight alpha heavily so translucent edges stay smooth.
                let distance = d[0] &* d[0] &* 2 &+ d[1] &* d[1] &* 3 &+ d[2] &* d[2] &+ d[3] &* d[3] &* 4
                if distance < bestDistance { bestDistance = distance; best = i }
            }
            cache[key] = Int16(best)
            return best
        }

        // Error buffers for the current and next row (RGBA as Float).
        var current = [SIMD4<Float>](repeating: .zero, count: width + 2)
        var next = [SIMD4<Float>](repeating: .zero, count: width + 2)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                if pixels[o + 3] == 0, let transparentIndex {
                    indices[y * width + x] = UInt8(transparentIndex)
                    continue
                }
                let original = SIMD4<Float>(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2]), Float(pixels[o + 3]))
                var wanted = (original + current[x + 1] * dithering)
                    .clamped(lowerBound: .zero, upperBound: SIMD4<Float>(repeating: 255))
                if pixels[o + 3] == 255 { wanted[3] = 255 }   // dither color only; neighbors' alpha error stays out
                let index = nearest(SIMD4<Int32>(wanted.rounded(.toNearestOrEven)))
                indices[y * width + x] = UInt8(index)
                let error = wanted - SIMD4<Float>(paletteInt[index])
                current[x + 2] += error * (7 / 16)
                next[x] += error * (3 / 16)
                next[x + 1] += error * (5 / 16)
                next[x + 2] += error * (1 / 16)
            }
            swap(&current, &next)
            for i in next.indices { next[i] = .zero }
        }
        return indices
    }
}

/// Minimal PNG encoder for indexed images.
enum PNGWriter {
    static func indexed(width: Int, height: Int, palette: [SIMD4<UInt8>], indices: [UInt8]) -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header.append(contentsOf: [8, 3, 0, 0, 0])   // 8-bit, palette, deflate, adaptive filter, no interlace
        png.appendChunk("IHDR", header)

        png.appendChunk("PLTE", Data(palette.flatMap { [$0[0], $0[1], $0[2]] }))
        if let lastTranslucent = palette.lastIndex(where: { $0[3] < 255 }) {
            png.appendChunk("tRNS", Data(palette[...lastTranslucent].map { $0[3] }))
        }

        var raw = Data(capacity: (width + 1) * height)
        for y in 0..<height {
            raw.append(0)   // filter: none (best for palette images)
            raw.append(contentsOf: indices[(y * width)..<((y + 1) * width)])
        }
        png.appendChunk("IDAT", zlib(raw))
        png.appendChunk("IEND", Data())
        return png
    }

    /// zlib stream: header + raw deflate (from the Compression framework) + Adler-32.
    static func zlib(_ data: Data) -> Data {
        var out = Data([0x78, 0xDA])
        let deflated = (try? (data as NSData).compressed(using: .zlib)) as Data? ?? Data()
        out.append(deflated)
        var a: UInt32 = 1, b: UInt32 = 0
        for chunk in stride(from: 0, to: data.count, by: 5552) {
            let end = min(chunk + 5552, data.count)
            data[data.startIndex.advanced(by: chunk)..<data.startIndex.advanced(by: end)].forEach {
                a &+= UInt32($0)
                b &+= a
            }
            a %= 65521
            b %= 65521
        }
        out.appendBigEndian(b << 16 | a)
        return out
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<S: Sequence>(_ bytes: S, initial: UInt32 = 0) -> UInt32 where S.Element == UInt8 {
        var crc = ~initial
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        appendBigEndian(UInt32(body.count))
        let typeBytes = Array(type.utf8)
        append(contentsOf: typeBytes)
        append(body)
        appendBigEndian(CRC32.checksum(typeBytes + Array(body)))
    }
}
