/// Display-linear reflectance as the 8-bit picture a screen or file shows: the SDR delivery
/// shoulder, the sRGB transfer (which Display P3 shares), and triangular dither of one quantizer
/// step. The CLI's 8-bit files and a native host's preview both come here, so they are one picture.
public enum DisplayEncoding {
    /// Encodes display-linear RGBA rows, `rows` being where they sit in the frame, into 8-bit RGBA
    /// rows `rowBytes` apart. The dither is keyed by pixel, so a frame delivered in strips is the
    /// frame delivered whole. Alpha is not dithered.
    public static func quantize8(
        linear rgba: UnsafeBufferPointer<Float>, rows: Range<Int>, width: Int, knee: Float,
        into pixels: UnsafeMutableRawPointer, rowBytes: Int, seed: UInt32
    ) {
        quantize8(rgba, rows: rows, width: width, into: pixels, rowBytes: rowBytes,
                  seed: seed) {
            ColorScience.linearToSrgb(ColorScience.displayShoulder($0, knee: knee))
        }
    }

    public static func encode8(_ rgba: [Float], width: Int, height: Int, knee: Float,
                               seed: UInt32) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        rgba.withUnsafeBufferPointer { source in
            pixels.withUnsafeMutableBytes { target in
                quantize8(linear: source, rows: 0..<height, width: width, knee: knee,
                          into: target.baseAddress!, rowBytes: width * 4, seed: seed)
            }
        }
        return pixels
    }

    /// The same quantization for rows the engine has already shouldered and encoded
    /// (`FilmOutputTransform.displayP3`).
    public static func quantize8(
        encoded rgba: UnsafeBufferPointer<Float>, rows: Range<Int>, width: Int,
        into pixels: UnsafeMutableRawPointer, rowBytes: Int, seed: UInt32
    ) {
        quantize8(rgba, rows: rows, width: width, into: pixels, rowBytes: rowBytes,
                  seed: seed) { $0 }
    }

    /// Encodes a compact rectangle while retaining the full frame's dither coordinates.
    /// Input and destination start at the rectangle's top-left; row padding is untouched.
    public static func quantizeRegion8(
        linear rgba: UnsafeBufferPointer<Float>, width: Int, height: Int,
        originX: Int, originY: Int, frameWidth: Int, knee: Float,
        into pixels: UnsafeMutableRawPointer, rowBytes: Int, seed: UInt32
    ) {
        quantize8(rgba, rows: 0..<height, width: width, into: pixels, rowBytes: rowBytes,
                  seed: seed, originX: originX, originY: originY, frameWidth: frameWidth) {
            ColorScience.linearToSrgb(ColorScience.displayShoulder($0, knee: knee))
        }
    }

    /// Compact-region counterpart for already encoded output, without another transfer.
    public static func quantizeRegion8(
        encoded rgba: UnsafeBufferPointer<Float>, width: Int, height: Int,
        originX: Int, originY: Int, frameWidth: Int,
        into pixels: UnsafeMutableRawPointer, rowBytes: Int, seed: UInt32
    ) {
        quantize8(rgba, rows: 0..<height, width: width, into: pixels, rowBytes: rowBytes,
                  seed: seed, originX: originX, originY: originY, frameWidth: frameWidth) { $0 }
    }

    @inline(__always)
    private static func quantize8(
        _ rgba: UnsafeBufferPointer<Float>, rows: Range<Int>, width: Int,
        into pixels: UnsafeMutableRawPointer, rowBytes: Int, seed: UInt32,
        originX: Int = 0, originY: Int = 0, frameWidth: Int? = nil,
        transfer: (Float) -> Float
    ) {
        precondition(rgba.count >= rows.count * width * 4 && rowBytes >= width * 4)
        let fullWidth = frameWidth ?? width
        precondition(originX >= 0 && originY >= 0 && width >= 0 && originX <= fullWidth - width)
        ParallelWork.forEach(iterations: rows.count) { local in
            let y = rows.lowerBound + local
            let row = pixels.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let source = (local * width + x) * 4
                let index = UInt32(truncatingIfNeeded: (y + originY) * fullWidth + x + originX)
                for c in 0..<3 {
                    let dither = triangularDither(index: index, channel: UInt32(c), seed: seed)
                    row[x * 4 + c] = UInt8(clamp(transfer(rgba[source + c]) * 255 + 0.5 + dither,
                                                 0, 255))
                }
                row[x * 4 + 3] = UInt8(clamp(rgba[source + 3] * 255 + 0.5, 0, 255))
            }
        }
    }
}
