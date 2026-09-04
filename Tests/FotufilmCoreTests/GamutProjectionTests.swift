import XCTest
@testable import FotufilmCore

/// The scene path's one boundary sits at the edge of the exposure table's domain — a cube whose
/// chromaticity triangle encloses the spectral locus — not at the Rec.2020 working cube. What
/// lies beyond it is colour no light can carry, and it develops as the nearest light that is.
final class GamutProjectionTests: XCTestCase {
    private func requireEngine() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
    }

    private func developedMean(_ scene: SIMD3<Float>) -> SIMD3<Float> {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        let size = 16
        var frame = ImageBuffer(width: size, height: size)
        for i in 0..<(size * size) {
            for c in 0..<3 { frame.planes[c][i] = scene[c] }
        }
        let print = FotufilmEngine(stock: TestStocks.negative, options: options)
            .process(linearRGB: frame)
        var mean = SIMD3<Float>()
        for i in 0..<(size * size) {
            mean += SIMD3(print.planes[0][i], print.planes[1][i], print.planes[2][i])
        }
        return mean / Float(size * size)
    }

    /// The kernel's walk, in the table's basis: toward the luminance axis until the binding
    /// domain channel reaches zero. Returns the result back in Rec.2020.
    private func nearestRealLight(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let (lr, lg, lb) = ColorScience.luminanceWeights
        let y = lr * c.x + lg * c.y + lb * c.z
        guard y > 0 else { return .zero }
        let d = ColorScience.linearRec2020ToExposureDomain(c)
        guard d.x < 0 || d.y < 0 || d.z < 0 else { return c }
        var s: Float = 1
        if d.x < 0 { s = min(s, y / (y - d.x)) }
        if d.y < 0 { s = min(s, y / (y - d.y)) }
        if d.z < 0 { s = min(s, y / (y - d.z)) }
        return ColorScience.linearExposureDomainToRec2020(
            SIMD3(y + s * (d.x - y), y + s * (d.y - y), y + s * (d.z - y)))
    }

    func testColourBeyondTheLocusDevelopsAsItsNearestRealLight() throws {
        try requireEngine()
        // A green no light can carry: outside the locus-enclosing triangle, positive luminance.
        let imaginary = SIMD3<Float>(-0.60, 1.00, -0.30)
        let domain = ColorScience.linearRec2020ToExposureDomain(imaginary)
        XCTAssertLessThan(domain.min(), -0.1, "the colour must lie beyond the domain cube")
        let projected = nearestRealLight(imaginary)
        XCTAssertGreaterThanOrEqual(
            ColorScience.linearRec2020ToExposureDomain(projected).min(), -1e-5,
            "the projection lands on the domain's face")

        let wide = developedMean(imaginary)
        let real = developedMean(projected)
        for c in 0..<3 {
            XCTAssertEqual(wide[c], real[c], accuracy: 2e-4,
                           "channel \(c): colour beyond the locus must develop as its nearest real light")
        }
    }

    func testColourBeyondRec2020ButInsideTheLocusIsNotProjected() throws {
        try requireEngine()
        // Outside the working cube, inside the domain: a real violet, which the old boundary
        // developed as the cube-face colour of its hue.
        let violet = SIMD3<Float>(0.30, -0.20, 2.00)
        XCTAssertGreaterThanOrEqual(
            ColorScience.linearRec2020ToExposureDomain(violet).min(), 0,
            "the violet must sit inside the domain cube")
        XCTAssertEqual(nearestRealLight(violet), violet, "nothing to project")

        let (lr, lg, lb) = ColorScience.luminanceWeights
        let y = lr * violet.x + lg * violet.y + lb * violet.z
        let cubeFace = SIMD3(y + (y / (y - violet.y)) * (violet.x - y), 0,
                             y + (y / (y - violet.y)) * (violet.z - y))
        let asItself = developedMean(violet)
        let asCubeFace = developedMean(cubeFace)
        let delta = asItself - asCubeFace
        XCTAssertGreaterThan(max(abs(delta.x), abs(delta.y), abs(delta.z)), 0.005,
                             "the violet must develop as itself: \(asItself) vs \(asCubeFace)")
    }

    func testNegativeLuminanceDevelopsAsBlack() throws {
        try requireEngine()
        let nonLight = SIMD3<Float>(0.10, -0.50, 0.60)   // y ≈ −0.28
        let dark = developedMean(nonLight)
        let black = developedMean(SIMD3<Float>(0, 0, 0))
        for c in 0..<3 {
            XCTAssertEqual(dark[c], black[c], accuracy: 2e-4,
                           "channel \(c): negative-luminance input must develop as black")
        }
    }

    func testNegativeLuminanceInsideTheDomainCubeDevelopsAsBlack() throws {
        try requireEngine()
        // AP0's blue Y coefficient is negative, so this non-light has three nonnegative domain
        // components. The luminance guard must not depend on a component crossing the cube.
        let domain = SIMD3<Float>(0.225, 0, 1)
        let nonLight = ColorScience.linearExposureDomainToRec2020(domain)
        let (lr, lg, lb) = ColorScience.luminanceWeights
        XCTAssertGreaterThanOrEqual(domain.min(), 0)
        XCTAssertLessThanOrEqual(lr * nonLight.x + lg * nonLight.y + lb * nonLight.z, 0)

        let dark = developedMean(nonLight)
        let black = developedMean(.zero)
        for c in 0..<3 {
            XCTAssertEqual(dark[c], black[c], accuracy: 2e-4,
                           "channel \(c): in-domain non-light must develop as black")
        }
    }

    func testSwiftSamplerRejectsNegativeLuminanceInsideTheDomainCube() {
        let domain = SIMD3<Float>(0.225, 0, 1)
        let nonLight = ColorScience.linearExposureDomainToRec2020(domain)
        let table = SpectralRuntime.tables(for: TestStocks.negative).exposure
        let tonePlane = [Float](repeating: 0, count: 1)
        table.values.withUnsafeBufferPointer { values in
            tonePlane.withUnsafeBufferPointer { tone in
                let sampler = ExposureSampler(
                    gain: 1, balance: SIMD3(repeating: 1),
                    highlights: 0, shadows: 0, saturation: 1, vibrance: 0,
                    neutral: true, values: values.baseAddress!,
                    dimension: table.dimension, luma: ColorScience.luminanceWeights,
                    gridWidth: 1, gridHeight: 1, frameWidth: 1, frameHeight: 1,
                    planeA: tone.baseAddress!, planeB: tone.baseAddress!)
                XCTAssertEqual(sampler.layerExposure(nonLight), .zero)
            }
        }
    }

    func testInCubeColourIsUntouchedByTheProjection() throws {
        let inCube = SIMD3<Float>(0.42, 0.18, 0.95)
        XCTAssertEqual(nearestRealLight(inCube), inCube)
    }
}
