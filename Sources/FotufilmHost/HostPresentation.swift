import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// How a presented picture's pixels are laid out (`FOTUFILM_SURFACE_*` in `fotufilm.h`).
public enum HostSurfaceFormat: Int32 {
    /// Display P3 with the sRGB transfer, 8 bits a channel, RGBA: an SDR picture.
    case rgba8DisplayP3 = 0
    /// Extended-linear Display P3 in half floats, RGBA: 1 is SDR white, above it EDR headroom.
    case rgba16FloatExtendedLinearP3 = 1

    var bytesPerPixel: Int { self == .rgba8DisplayP3 ? 4 : 8 }
}

/// Memory a presenter lends for one picture. The engine writes rows into `pixels` between
/// `acquire` and `present` (or `discard`); what the memory is — an IOSurface on macOS, an upload
/// buffer for a D3D11 or Vulkan texture elsewhere — is the presenter's business.
public final class HostSurface {
    public let width: Int
    public let height: Int
    public let format: HostSurfaceFormat
    public let pixels: UnsafeMutableRawPointer
    public let rowBytes: Int
    /// The presenter's own reference to the memory.
    let handle: Any?

    public init(width: Int, height: Int, format: HostSurfaceFormat,
                pixels: UnsafeMutableRawPointer, rowBytes: Int, handle: Any? = nil) {
        self.width = width
        self.height = height
        self.format = format
        self.pixels = pixels
        self.rowBytes = rowBytes
        self.handle = handle
    }
}

/// Where the editor's photograph goes when the host draws it itself (Fotufilm Desktop's
/// compositor, beneath a web page that leaves the photograph's area transparent): the engine
/// develops into surfaces the host lends and hands them back to be shown, so a render reaches the
/// screen without an encoded image crossing to the page. `fotufilm_presenter` is one, reached
/// through its C callbacks; tests keep pictures in memory.
public protocol HostPresenter: AnyObject {
    /// How far above SDR white the display showing the layer can go now; 1 without EDR.
    var headroom: Float { get }
    func acquire(width: Int, height: Int, format: HostSurfaceFormat) -> HostSurface?
    /// Shows a written surface in `layer` and returns the frame's id (never 0).
    func present(_ surface: HostSurface, layer: String, info: [String: Any]) -> UInt64
    func discard(_ surface: HostSurface)
}

enum HostPresentation {
    /// The frames a `render` presented, as its answer names them to the page.
    struct Presented {
        var frame: UInt64
        var original: UInt64
        var extended: Bool
        var headroom: Float

        var json: [String: Any] {
            ["frame": frame, "original": original, "dynamicRange": extended ? "hdr" : "sdr",
             "headroom": Double(headroom)]
        }
    }

    /// Where a request asked its picture to go: `{"slot": "preview" | "detail", "scope"}`. The
    /// scope names what the page shows (the photograph, the crop tool), so a presenter may show a
    /// newer frame of the same size and scope before the page has placed it.
    struct Request {
        var slot: String
        var scope: String

        init?(_ body: [String: Any]) {
            guard let present = body["present"] as? [String: Any],
                  let slot = present["slot"] as? String, !slot.isEmpty else { return nil }
            self.slot = slot
            scope = present["scope"] as? String ?? ""
        }
    }

    /// Copies `region` of a developed frame (`bytesPerPixel` a pixel, `frameWidth` wide) into a
    /// fresh surface and presents it; nil when the presenter has no surface to lend.
    static func present(_ pixels: [UInt8], frameWidth: Int, format: HostSurfaceFormat,
                        region: (x: Int, y: Int, width: Int, height: Int),
                        to presenter: HostPresenter, layer: String,
                        info: [String: Any]) -> UInt64? {
        guard let surface = presenter.acquire(width: region.width, height: region.height,
                                              format: format) else { return nil }
        guard surface.width == region.width, surface.height == region.height,
              surface.format == format,
              surface.rowBytes >= region.width * format.bytesPerPixel else {
            presenter.discard(surface)
            return nil
        }
        let stride = format.bytesPerPixel
        let rowLength = region.width * stride
        pixels.withUnsafeBytes { source in
            let base = source.baseAddress!
            SceneGeometry.concurrent(region.height) { row in
                let from = base + ((region.y + row) * frameWidth + region.x) * stride
                (surface.pixels + row * surface.rowBytes).copyMemory(from: from,
                                                                     byteCount: rowLength)
            }
        }
        let id = presenter.present(surface, layer: layer, info: info)
        return id == 0 ? nil : id
    }

    /// Display-linear Display P3, as the engine develops it before any shoulder, for an
    /// extended-range layer: the HDR shoulder rolls highlights into the display's `ceiling` (its
    /// headroom, no further than the file side's `hdrDisplayCeiling`), and the result is packed as
    /// half floats, RGBA. `HLGTransfer.previewDisplayLight` states the mapping.
    static func extendedLinear(_ linear: [Float], width: Int, height: Int,
                               ceiling: Float) -> [UInt8] {
        var packed = [UInt8](repeating: 0, count: width * height * 8)
        linear.withUnsafeBufferPointer { source in
            packed.withUnsafeMutableBytes { target in
                let halves = target.baseAddress!.assumingMemoryBound(to: UInt16.self)
                SceneGeometry.concurrent(height) { y in
                    for i in (y * width)..<((y + 1) * width) {
                        let light = HLGTransfer.previewDisplayLight(
                            r: finite(source[i * 4]), g: finite(source[i * 4 + 1]),
                            b: finite(source[i * 4 + 2]), ceiling: ceiling)
                        halves[i * 4] = half(light.r)
                        halves[i * 4 + 1] = half(light.g)
                        halves[i * 4 + 2] = half(light.b)
                        halves[i * 4 + 3] = 0x3C00
                    }
                }
            }
        }
        return packed
    }

    /// The SDR picture a half-float frame shows on an SDR screen: clipped at white, 8-bit.
    static func standardRange(_ packed: [UInt8], width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        packed.withUnsafeBytes { source in
            let halves = source.baseAddress!.assumingMemoryBound(to: UInt16.self)
            for i in 0..<(width * height) {
                for c in 0..<3 {
                    let value = ColorScience.linearToSrgb(min(max(float(halves[i * 4 + c]), 0), 1))
                    pixels[i * 4 + c] = UInt8(clamp(value * 255 + 0.5, 0, 255))
                }
            }
        }
        return pixels
    }

    @inline(__always)
    private static func finite(_ value: Float) -> Float { value.isFinite ? value : 0 }

    /// IEEE half from float, rounding to nearest.
    @inline(__always)
    static func half(_ value: Float) -> UInt16 {
        #if arch(arm64)
        return Float16(value).bitPattern
        #else
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
        var mantissa = bits & 0x7F_FFFF
        if exponent >= 31 { return sign | 0x7C00 }
        if exponent <= 0 {
            guard exponent >= -10 else { return sign }
            mantissa |= 0x80_0000
            let shift = UInt32(14 - exponent)
            let rounded = (mantissa + (1 << (shift - 1))) >> shift
            return sign | UInt16(rounded)
        }
        let rounded = UInt32(exponent) << 10 | ((mantissa + 0x1000) >> 13)
        return sign | UInt16(min(rounded, 0x7C00))
        #endif
    }

    @inline(__always)
    static func float(_ bits: UInt16) -> Float {
        #if arch(arm64)
        return Float(Float16(bitPattern: bits))
        #else
        let sign: Float = bits & 0x8000 != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F), mantissa = Float(bits & 0x3FF)
        if exponent == 0 { return sign * mantissa * pow(2, -24) }
        if exponent == 31 { return sign * .infinity }
        return sign * (1 + mantissa / 1024) * pow(2, Float(exponent - 15))
        #endif
    }
}
