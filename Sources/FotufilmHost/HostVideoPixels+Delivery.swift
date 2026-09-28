import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

// What a movie writer hands its encoder from developed linear Display P3 light, as the Mac app
// records it: 16-bit R'G'B' for ProRes (`ProResRecording`) and 10-bit 4:2:0 Y′CbCr for HEVC
// (`SDR10Recording`, `HLGRecording`). Every platform's writer fills its encoder's buffers here.
extension HostVideoPixels {
    /// Where a writer's 16-bit R'G'B' codes go.
    enum RGB16Layout {
        /// CoreVideo's 64ARGB: opaque alpha first, big-endian.
        case argbBigEndian
        /// Alpha last, little-endian.
        case rgbaLittleEndian
    }

    /// Linear light through the film's SDR shoulder and the sRGB transfer, or as HLG BT.2020 RGB
    /// with the relight alpha folded in, 16 bits a channel.
    static func fillRGB16(_ pixels: UnsafeRawBufferPointer, width: Int, height: Int, knee: Float,
                          hdr: Bool, into base: UnsafeMutableRawPointer, rowBytes: Int,
                          layout: RGB16Layout) {
        let developed = UnsafeBufferPointer(start: pixels.baseAddress!.assumingMemoryBound(to: Float.self),
                                            count: width * height * 4)
        let (alpha, red) = layout == .argbBigEndian ? (0, 1) : (3, 0)
        func store(_ value: UInt16) -> UInt16 {
            layout == .argbBigEndian ? value.bigEndian : value.littleEndian
        }
        if hdr {
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let row = (base + y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let gain = max(developed[i + 3], 1)
                    let signal = HLGTransfer.encodeRGB(r: developed[i] * gain, g: developed[i + 1] * gain,
                                                       b: developed[i + 2] * gain)
                    row[x * 4 + alpha] = store(UInt16.max)
                    row[x * 4 + red] = store(code16(signal.r))
                    row[x * 4 + red + 1] = store(code16(signal.g))
                    row[x * 4 + red + 2] = store(code16(signal.b))
                }
            }
            return
        }
        let signal = SDRSignal.table(knee: knee)
        DispatchQueue.concurrentPerform(iterations: height) { y in
            let row = (base + y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                let i = (y * width + x) * 4
                row[x * 4 + alpha] = store(UInt16.max)
                for c in 0..<3 { row[x * 4 + red + c] = store(code16(signal[developed[i + c]])) }
            }
        }
    }

    /// The same light as 10-bit 4:2:0 video-range Y′CbCr in P010 planes, each code in the high
    /// ten bits of its sample: BT.709 through the film's SDR shoulder, or BT.2020 HLG. Strides
    /// count samples.
    static func fillP010(_ pixels: UnsafeRawBufferPointer, width: Int, height: Int, knee: Float,
                         hdr: Bool, luma: UnsafeMutablePointer<UInt16>, lumaStride: Int,
                         chroma: UnsafeMutablePointer<UInt16>, chromaStride: Int) {
        func code(_ value: Float) -> UInt16 { UInt16(min(max(value.rounded(), 0), 1023)) << 6 }
        func write(_ encoded: (luma: SIMD4<Float>, u: Float, v: Float), x: Int,
                   top: UnsafeMutablePointer<UInt16>, bottom: UnsafeMutablePointer<UInt16>,
                   chromaRow: UnsafeMutablePointer<UInt16>) {
            top[x] = code(encoded.luma.x * 876 + 64)
            top[x + 1] = code(encoded.luma.y * 876 + 64)
            bottom[x] = code(encoded.luma.z * 876 + 64)
            bottom[x + 1] = code(encoded.luma.w * 876 + 64)
            chromaRow[x] = code(encoded.u * 896 + 512)
            chromaRow[x + 1] = code(encoded.v * 896 + 512)
        }
        if hdr {
            let developed = pixels.baseAddress!.assumingMemoryBound(to: Float.self)
            func light(_ p: UnsafePointer<Float>) -> SIMD3<Float> { SIMD3(p[0], p[1], p[2]) * max(p[3], 1) }
            DispatchQueue.concurrentPerform(iterations: height / 2) { cy in
                let top = developed + cy * 2 * width * 4, bottom = top + width * 4
                let topLuma = luma + cy * 2 * lumaStride
                for x in stride(from: 0, to: width, by: 2) {
                    let encoded = HLGTransfer.encode420(
                        topLeft: light(top + x * 4), topRight: light(top + x * 4 + 4),
                        bottomLeft: light(bottom + x * 4), bottomRight: light(bottom + x * 4 + 4))
                    write(encoded, x: x, top: topLuma,
                          bottom: topLuma + lumaStride, chromaRow: chroma + cy * chromaStride)
                }
            }
            return
        }
        let developed = pixels.baseAddress!.assumingMemoryBound(to: Float.self)
        let signal = SDRSignal.table(knee: knee)
        DispatchQueue.concurrentPerform(iterations: height / 2) { cy in
            let top = developed + cy * 2 * width * 4, bottom = top + width * 4
            func rgb(_ p: UnsafePointer<Float>) -> SIMD3<Float> {
                SIMD3(signal[p[0]], signal[p[1]], signal[p[2]])
            }
            let topLuma = luma + cy * 2 * lumaStride
            for x in stride(from: 0, to: width, by: 2) {
                let encoded = SDRVideoTransfer.encode420(
                    topLeft: rgb(top + x * 4), topRight: rgb(top + x * 4 + 4),
                    bottomLeft: rgb(bottom + x * 4), bottomRight: rgb(bottom + x * 4 + 4))
                write(encoded, x: x, top: topLuma,
                      bottom: topLuma + lumaStride, chromaRow: chroma + cy * chromaStride)
            }
        }
    }

    private static func code16(_ value: Float) -> UInt16 {
        UInt16((min(max(value, 0), 1) * Float(UInt16.max)).rounded())
    }
}

/// `FilmDisplayP3SDRConversion`'s signal for one channel of light, the film's SDR shoulder then
/// the sRGB transfer, as a table read between entries: the fills take two transcendentals a
/// channel otherwise. Within 2e-6 of the curve, well inside half a 16-bit code.
final class SDRSignal: @unchecked Sendable {
    /// Light past this is rare enough to take the curve itself.
    private static let range: Float = 2
    private static let steps = 1 << 16
    private static let lock = NSLock()
    private static var last: SDRSignal?

    let knee: Float
    private let values: UnsafeMutableBufferPointer<Float>

    private init(knee: Float) {
        self.knee = knee
        values = .allocate(capacity: Self.steps + 1)
        for index in 0...Self.steps {
            values[index] = Self.exact(Float(index) * Self.range / Float(Self.steps), knee: knee)
        }
    }

    deinit { values.deallocate() }

    /// The table for an export's knee; an export keeps one knee, so one is kept.
    static func table(knee: Float) -> SDRSignal {
        lock.lock()
        defer { lock.unlock() }
        if let last, last.knee == knee { return last }
        let made = SDRSignal(knee: knee)
        last = made
        return made
    }

    private static func exact(_ light: Float, knee: Float) -> Float {
        ColorScience.linearToSrgb(ColorScience.displayShoulder(light, knee: knee))
    }

    subscript(light: Float) -> Float {
        guard light > 0 else { return 0 }   // NaN too
        guard light < Self.range else { return Self.exact(light, knee: knee) }
        let position = light * (Float(Self.steps) / Self.range)
        let index = Int(position)
        let low = values[index]
        return low + (values[index + 1] - low) * (position - Float(index))
    }
}
