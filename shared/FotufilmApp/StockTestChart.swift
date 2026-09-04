import CoreGraphics
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Generated workshop chart with known exposure levels.
/// It shares `SpectrumScene`'s 0.18 mid-grey, +1.5-stop sweep, and black surround, and adds memory
/// colours, a specular disc for flare/halation, and detail bars for spatial stages.
enum StockTestChart {

    /// Mid grey, and the level every other element is placed against. `SpectrumScene`'s, so the two
    /// pictures can be read side by side.
    static let mid = SpectrumScene.mid

    /// Diffuse white — a surface reflecting everything, under the light the chart is lit by. The
    /// memory colours below are reflectances against it.
    static let white: Float = 1

    /// 3:2, so the chart fills a preview panel shaped like the picture the app usually holds.
    static let aspect: CGFloat = 3.0 / 2.0

    // MARK: - The scene

    /// The chart at a given long edge, as the emulsion receives it.
    ///
    /// Built straight into the scene's own float samples rather than encoded into an image and
    /// decoded back. The chart already *is* scene-linear, and a round trip through a file's decode
    /// would put an interpretation — a tone map, a headroom recovery — between the level authored
    /// here and the level developed.
    static func scene(longEdge: Int) -> FilmRender.Scene? {
        let width = max(64, longEdge)
        let height = max(48, Int((CGFloat(width) / aspect).rounded()))
        let rowBytes = width * MemoryLayout<Float>.size * 4
        guard let pixels = MappedBuffer(byteCount: rowBytes * height) else {
            return nil
        }

        let samples = pixels.bound(to: Float.self)
        for index in 0..<(width * height) {
            samples[index * 4] = 0
            samples[index * 4 + 1] = 0
            samples[index * 4 + 2] = 0
            samples[index * 4 + 3] = 1
        }
        draw(into: samples, width: width, height: height)
        pixels.flush(byteOffset: 0, byteCount: rowBytes * height)

        var state = EditState()
        state.stockID = StockPreset.noFilmID
        return FilmRender.Scene(pixels: pixels, width: width, height: height,
                                key: FilmRender.SceneKey(state: state,
                                                         longEdge: longEdge))
    }

    /// The interactive size. Small enough that a slider drag develops between one value and the
    /// next, large enough that the finest bar pitch is still two pixels wide.
    static let previewLongEdge = 640

    // MARK: - Drawing

    private static func draw(into samples: UnsafeMutableBufferPointer<Float>,
                             width: Int, height: Int) {
        let w = Float(width), h = Float(height)

        func put(_ x: Int, _ y: Int, _ colour: SIMD3<Float>) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let index = (y * width + x) * 4
            samples[index] = colour.x
            samples[index + 1] = colour.y
            samples[index + 2] = colour.z
        }

        func fill(x: ClosedRange<Float>, y: ClosedRange<Float>,
                  _ colour: SIMD3<Float>) {
            for py in Int(y.lowerBound * h)..<Int(y.upperBound * h) {
                for px in Int(x.lowerBound * w)..<Int(x.upperBound * w) {
                    put(px, py, colour)
                }
            }
        }

        // A hue sweep, corner-free, at a stop and a half over mid. Where the dye set, the layer
        // sensitivities and the interlayer barriers show themselves.
        let sweepPeak = mid * exp2(1.5)
        let sweepLeft = Int(0.06 * w), sweepRight = Int(0.94 * w)
        for px in sweepLeft..<sweepRight {
            let degrees = Float(px - sweepLeft) / Float(sweepRight - sweepLeft) * 360
            let (r, g, b) = SpectrumScene.hue(degrees)
            let colour = SIMD3(r, g, b) * sweepPeak
            for py in Int(0.06 * h)..<Int(0.15 * h) { put(px, py, colour) }
        }

        // Memory-colour patches at representative surface reflectances.
        patches(memoryColours.map { $0 * white }, y: 0.19...0.33,
                fill: fill)

        // One-stop grey wedge from five stops below mid-grey to three stops above it.
        let steps = (-5...3).map { mid * exp2(Float($0)) }
        patches(steps.map { SIMD3(repeating: $0) }, y: 0.37...0.51, fill: fill)

        // A specular highlight on black. Halation is a red glow around exactly this, and lens flare
        // is the lift in the black around it; neither is visible on any patch.
        let discCentre = (x: 0.155 * w, y: 0.70 * h)
        let discRadius = 0.055 * w
        let specular = mid * exp2(5)
        for py in Int(discCentre.y - discRadius - 1)...Int(discCentre.y + discRadius + 1) {
            for px in Int(discCentre.x - discRadius - 1)...Int(discCentre.x + discRadius + 1) {
                let dx = Float(px) - discCentre.x, dy = Float(py) - discCentre.y
                let distance = (dx * dx + dy * dy).squareRoot()
                // One pixel of coverage at the rim provides antialiasing.
                let coverage = min(max(discRadius - distance + 0.5, 0), 1)
                if coverage > 0 { put(px, py, SIMD3(repeating: specular * coverage)) }
            }
        }

        // Bar pairs at three pitches and at ±1 stop around mid-grey exercise MTF, softness, and
        // grain at different spatial frequencies.
        let dark = mid * exp2(-1), light = mid * exp2(1)
        var x = 0.28 * w
        for pitch in [8, 4, 2] {
            let blockWidth = 0.06 * w
            for px in Int(x)..<Int(x + blockWidth) {
                let bar = ((px - Int(x)) / pitch) % 2 == 0
                for py in Int(0.58 * h)..<Int(0.82 * h) {
                    put(px, py, SIMD3(repeating: bar ? light : dark))
                }
            }
            x += blockWidth + 0.012 * w
        }

        // A hard edge between known levels isolates the adjacency effect.
        fill(x: 0.50...0.58, y: 0.58...0.82, SIMD3(repeating: mid * exp2(-2)))
        fill(x: 0.58...0.66, y: 0.58...0.82, SIMD3(repeating: mid * exp2(2)))

        // A uniform mid-grey field exposes grain, mottle, and film fog.
        fill(x: 0.70...0.94, y: 0.58...0.82, SIMD3(repeating: mid))
    }

    private static func patches(
        _ colours: [SIMD3<Float>], y: ClosedRange<Float>,
        fill: (ClosedRange<Float>, ClosedRange<Float>, SIMD3<Float>) -> Void
    ) {
        guard !colours.isEmpty else { return }
        let left: Float = 0.06, right: Float = 0.94
        let pitch = (right - left) / Float(colours.count)
        let gap = pitch * 0.08
        for (index, colour) in colours.enumerated() {
            let x0 = left + Float(index) * pitch
            fill(x0...(x0 + pitch - gap), y, colour)
        }
    }

    // MARK: - Memory colours

    private static let memoryColours: [SIMD3<Float>] = [
        rec709(0.85, 0.68, 0.60),   // light skin
        rec709(0.72, 0.52, 0.44),   // mid skin
        rec709(0.38, 0.24, 0.18),   // deep skin
        rec709(0.30, 0.46, 0.19),   // foliage
        rec709(0.40, 0.57, 0.86),   // sky
        rec709(0.78, 0.20, 0.16),   // a red that costs a negative its shoulder
        rec709(0.92, 0.78, 0.16),   // saturated yellow
        rec709(0.16, 0.36, 0.62),   // a deep blue, where the yellow filter layer tells
    ]

    private static func rec709(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        let linear = SIMD3(sRGBToLinear(r), sRGBToLinear(g), sRGBToLinear(b))
        let m = rec709ToWorking
        return SIMD3(m.0.x * linear.x + m.0.y * linear.y + m.0.z * linear.z,
                     m.1.x * linear.x + m.1.y * linear.y + m.1.z * linear.z,
                     m.2.x * linear.x + m.2.y * linear.y + m.2.z * linear.z)
    }

    private static func sRGBToLinear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }

    private static let rec709ToWorking: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = {
        let gamut = CameraGamut(primaries: CameraGamut.Primaries(
            r: (0.640, 0.330), g: (0.300, 0.600), b: (0.150, 0.060)))
        let m = gamut.toRec2020.map(Float.init)
        return (SIMD3(m[0], m[1], m[2]),
                SIMD3(m[3], m[4], m[5]),
                SIMD3(m[6], m[7], m[8]))
    }()
}
