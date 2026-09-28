/// PNG with stored (uncompressed) deflate blocks, tagged Display P3 through cICP — the same
/// encoding as `web/src/png-stored.js`. A preview is shown once and dropped, so compressing it
/// would cost more than the page saves decoding it.
enum StoredPNG {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256 * 8)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[n] = c
        }
        for n in 0..<256 {
            for t in 1..<8 {
                let previous = table[(t - 1) * 256 + n]
                table[t * 256 + n] = (previous >> 8) ^ table[Int(previous & 255)]
            }
        }
        return table
    }()

    private static func crc32(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        var i = start
        table.withUnsafeBufferPointer { t in
            while i + 8 <= end {
                let low: UInt32 = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                let high: UInt32 = UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                let a: UInt32 = crc ^ (low | high)
                let first: UInt32 = t[1792 + Int(a & 255)] ^ t[1536 + Int((a >> 8) & 255)]
                    ^ t[1280 + Int((a >> 16) & 255)] ^ t[1024 + Int(a >> 24)]
                let second: UInt32 = t[768 + Int(bytes[i + 4])] ^ t[512 + Int(bytes[i + 5])]
                    ^ t[256 + Int(bytes[i + 6])] ^ t[Int(bytes[i + 7])]
                crc = first ^ second
                i += 8
            }
            while i < end {
                crc = t[Int((crc ^ UInt32(bytes[i])) & 255)] ^ (crc >> 8)
                i += 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// `pixels` is RGBA8, `rowBytes` apart; alpha is dropped.
    static func encode(_ pixels: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int) -> [UInt8] {
        let row = width * 3 + 1, raw = row * height
        let blockSize = 65535
        let blocks = max(1, (raw + blockSize - 1) / blockSize)
        let idat = 2 + raw + blocks * 5 + 4
        let size = 8 + 25 + 16 + 12 + idat + 12
        var out = [UInt8](repeating: 0, count: size)
        out.withUnsafeMutableBufferPointer { out in
            var at = 0
            func put32(_ value: UInt32, _ p: Int) {
                out[p] = UInt8(value >> 24); out[p + 1] = UInt8((value >> 16) & 255)
                out[p + 2] = UInt8((value >> 8) & 255); out[p + 3] = UInt8(value & 255)
            }
            for (i, byte) in [137, 80, 78, 71, 13, 10, 26, 10].enumerated() { out[i] = UInt8(byte) }
            at = 8
            func chunk(_ type: String, _ length: Int, _ write: (Int) -> Void) {
                put32(UInt32(length), at)
                for (i, c) in type.utf8.enumerated() { out[at + 4 + i] = c }
                write(at + 8)
                put32(crc32(UnsafeBufferPointer(out), at + 4, at + 8 + length), at + 8 + length)
                at += 12 + length
            }
            chunk("IHDR", 13) { p in
                put32(UInt32(width), p); put32(UInt32(height), p + 4)
                out[p + 8] = 8; out[p + 9] = 2
            }
            // P3-D65 primaries, sRGB transfer, RGB, full range.
            chunk("cICP", 4) { p in out[p] = 12; out[p + 1] = 13; out[p + 2] = 0; out[p + 3] = 1 }
            chunk("IDAT", idat) { p in
                out[p] = 0x78; out[p + 1] = 0x01
                // The filtered stream: a zero filter byte, then the row's RGB.
                var stream = [UInt8](repeating: 0, count: raw)
                stream.withUnsafeMutableBufferPointer { stream in
                    let stream = stream
                    SceneGeometry.concurrent(height) { y in
                        let source = pixels.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                        var o = y * row + 1
                        for x in 0..<width {
                            stream[o] = source[x * 4]
                            stream[o + 1] = source[x * 4 + 1]
                            stream[o + 2] = source[x * 4 + 2]
                            o += 3
                        }
                    }
                }
                var a: UInt32 = 1, b: UInt32 = 0
                var cursor = p + 2
                stream.withUnsafeBufferPointer { stream in
                    var index = 0
                    while index < raw {
                        let end = min(raw, index + 5552)
                        for i in index..<end { a &+= UInt32(stream[i]); b &+= a }
                        a %= 65521; b %= 65521
                        index = end
                    }
                    var written = 0
                    while written < raw {
                        let length = min(blockSize, raw - written)
                        out[cursor] = written + length == raw ? 1 : 0
                        out[cursor + 1] = UInt8(length & 255); out[cursor + 2] = UInt8(length >> 8)
                        out[cursor + 3] = ~UInt8(length & 255); out[cursor + 4] = ~UInt8(length >> 8)
                        cursor += 5
                        (out.baseAddress! + cursor).update(from: stream.baseAddress! + written,
                                                           count: length)
                        cursor += length
                        written += length
                    }
                }
                put32(b << 16 | a, cursor)
            }
            chunk("IEND", 0) { _ in }
        }
        return out
    }
}
