import XCTest
@testable import FotufilmCore

/// The exposure table's domain: a basis whose cube encloses the spectral locus, so real light
/// beyond Rec.2020 — every monochromatic source but three wavelengths — reaches the emulsion as
/// itself rather than as the cube-face colour of its hue.
final class ExposureDomainTests: XCTestCase {
    private let luma2020 = SIMD3<Float>(0.2627002, 0.6779981, 0.0593017)

    private func requireEngine() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
    }

    private func luminance(_ rgb: SIMD3<Float>) -> Float {
        luma2020.x * rgb.x + luma2020.y * rgb.y + luma2020.z * rgb.z
    }

    /// Monochromatic light at one observer band, scaled to `luminance`, in linear Rec.2020.
    private func laser(nm: Float, luminance target: Float) -> SIMD3<Float> {
        let band = Int((nm - 380) / SpectralGrid.stepNM)
        let rgb = SpectralGrid.linearRec2020(fromXYZ: SIMD3(
            SpectralGrid.xBar[band], SpectralGrid.yBar[band], SpectralGrid.zBar[band]))
        return rgb * (target / luminance(rgb))
    }

    /// What the kernel does with a scene colour: into the domain, normalised to its peak,
    /// sampled, and scaled back out.
    private func tableExposure(_ table: SpectralLUT, _ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let domain = ColorScience.linearRec2020ToExposureDomain(rgb)
        let peak = max(domain.x, domain.y, domain.z)
        return table.sample(domain / peak) * peak
    }

    // MARK: - The seam

    func testSeamMatricesAreExactInversesAndHoldNeutral() {
        let colours: [SIMD3<Float>] = [
            SIMD3(0.18, 0.18, 0.18), SIMD3(0.9, 0.1, 0.05), SIMD3(-0.2, 0.8, 0.7),
            SIMD3(0.05, -0.1, 1.2), SIMD3(2.5, 0.3, -0.04), SIMD3(-0.15, 1.0, 0.04),
        ]
        for rgb in colours {
            let back = ColorScience.linearExposureDomainToRec2020(
                ColorScience.linearRec2020ToExposureDomain(rgb))
            for channel in 0..<3 {
                XCTAssertEqual(back[channel], rgb[channel], accuracy: 3e-6,
                               "the domain matrices must be exact inverses")
            }
        }
        for grey in [Float(0.05), 0.18, 1.0, 4.0] {
            let domain = ColorScience.linearRec2020ToExposureDomain(SIMD3(repeating: grey))
            for channel in 0..<3 {
                XCTAssertEqual(domain[channel], grey, accuracy: grey * 1e-6 + 1e-7,
                               "rows sum to 1: the neutral axis is the same line in both bases")
            }
        }
    }

    func testDomainLuminanceReadsTheSameCIEY() {
        let weights = ColorScience.exposureDomainLuminanceWeights
        let colours: [SIMD3<Float>] = [
            SIMD3(0.6, 0.3, 0.1), SIMD3(-0.15, 0.7, 0.9), SIMD3(0.02, -0.08, 0.5),
            SIMD3(1.8, 0.9, -0.1), SIMD3(-0.3, 1.0, 0.45),
        ]
        for rgb in colours {
            let domain = ColorScience.linearRec2020ToExposureDomain(rgb)
            let converted = weights.0 * domain.x + weights.1 * domain.y + weights.2 * domain.z
            XCTAssertEqual(converted, luminance(rgb), accuracy: 3e-6,
                           "both weight rows must read the same CIE Y")
        }
    }

    func testDomainEnclosesTheWholeSpectralLocus() {
        for band in 0..<SpectralGrid.count {
            let rgb = SpectralGrid.linearRec2020(fromXYZ: SIMD3(
                SpectralGrid.xBar[band], SpectralGrid.yBar[band], SpectralGrid.zBar[band]))
            let domain = ColorScience.linearRec2020ToExposureDomain(rgb)
            let peak = max(domain.x, domain.y, domain.z)
            for channel in 0..<3 {
                XCTAssertGreaterThanOrEqual(
                    domain[channel], -1e-5 * peak,
                    "\(SpectralGrid.wavelengths[band]) nm must lie inside the domain cube")
            }
        }
        // Rec.2020's own corners are well inside: the domain is a superset, never a rotation.
        for corner in [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)] {
            let domain = ColorScience.linearRec2020ToExposureDomain(corner)
            XCTAssertGreaterThanOrEqual(domain.min(), 0)
        }
    }

    func testSharedConstantsMatchAcrossLanguagesDigitForDigit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let seam = [
            "0.670231843", "0.152168745", "0.177599412",
            "0.044501114", "0.854482372", "0.101016514",
            "0.025777047", "0.974222953",
        ]
        for file in [
            "Sources/FotufilmHalide/FotufilmHalideShared.h",
            "Sources/FotufilmCore/ColorScience.swift",
            "Sources/FotufilmMetal/Shaders/HandwrittenPointwise.metal",
            "Sources/FotufilmMetal/Shaders/HandwrittenFrameEndpoints.metal",
            "Sources/FotufilmMetal/Shaders/HandwrittenSpectralHead.metal",
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for value in seam {
                XCTAssertTrue(source.contains(value), "\(file) lost seam digit \(value)")
            }
        }
    }

    // MARK: - What the table holds beyond Rec.2020

    func testEveryLaserIsLightAndSitsOnTheLocus() {
        for band in 0..<SpectralGrid.count {
            let rgb = laser(nm: SpectralGrid.wavelengths[band], luminance: 0.18)
            // The primaries' own wavelengths sit on the cube's edge, and the reflectance
            // model continues by projection across a margin outside it; the share is only
            // well defined once the light is clearly past that.
            let clearlyOutside = rgb.min() < -2 * SpectralRuntime.projectionMargin * rgb.max()
            guard case .locus(let light) = SpectralRuntime.sceneLight(rgb) else {
                XCTAssertFalse(clearlyOutside,
                               "\(SpectralGrid.wavelengths[band]) nm should be beyond the cube")
                continue
            }
            if clearlyOutside {
                XCTAssertEqual(light.share, 1, accuracy: 1e-3,
                               "a light on the locus is all monochromatic")
            }
            XCTAssertEqual(light.luminance, 0.18, accuracy: 1e-5)
            XCTAssertGreaterThanOrEqual(light.face.min(), 0)
            XCTAssertEqual(luminance(light.face), 0.18, accuracy: 1e-4,
                           "the cube-edge colour keeps the luminance")
            XCTAssertGreaterThanOrEqual(light.mirror.min(), 0, "the mirror point is inside")
        }
    }

    func testTableContinuesAcrossTheRec2020Face() {
        let stock = TestStocks.negative
        let illuminant = SpectralRuntime.filmReferenceIlluminant(for: stock)
        // The model is continuous at the face but steeper outside it — monochromatic light
        // moves the layers faster per unit of chromaticity than any reflectance can — so the
        // check is the limit: a hair outside must land where a hair inside does.
        let hair: Float = 1e-5
        for (inside, outside) in [
            (SIMD3<Float>(hair, 0.5, 0.5), SIMD3<Float>(-hair, 0.5, 0.5)),
            (SIMD3<Float>(0.6, hair, 0.4), SIMD3<Float>(0.6, -hair, 0.4)),
            (SIMD3<Float>(0.7, 0.5, hair), SIMD3<Float>(0.7, 0.5, -hair)),
        ] {
            let before = SpectralRuntime.domainExposure(
                ColorScience.linearRec2020ToExposureDomain(inside),
                stock: stock, illuminant: illuminant)
            let after = SpectralRuntime.domainExposure(
                ColorScience.linearRec2020ToExposureDomain(outside),
                stock: stock, illuminant: illuminant)
            for layer in 0..<3 {
                XCTAssertEqual(after[layer], before[layer],
                               accuracy: 0.01 * max(before[layer], 1e-4),
                               "layer \(layer) must not step at the cube's face")
            }
        }
    }

    func testMonochromaticGreenExposesLikeItsOwnSpectrum() {
        let stock = TestStocks.negative
        let illuminant = SpectralRuntime.filmReferenceIlluminant(for: stock)
        let band = Int((520 - 380) / SpectralGrid.stepNM)  // 520 nm
        let rgb = laser(nm: 520, luminance: 0.18)
        let direct = SpectralRuntime.domainExposure(
            ColorScience.linearRec2020ToExposureDomain(rgb), stock: stock,
            illuminant: illuminant)

        // At the locus the model is the monochromatic spectrum alone, so each layer's
        // exposure is its sensitivity at the band over its calibration against the
        // reference light: the ratios between layers follow from the sheet directly.
        let sensitivity = stock.spectralProfile.layerSensitivity
        let anchor = illuminant[Illuminant.anchorIndex]
        func calibrated(_ layer: Int) -> Float {
            var reference: Float = 0
            for i in 0..<SpectralGrid.count {
                reference += illuminant[i] / anchor * sensitivity[layer][i]
            }
            return sensitivity[layer][band] / reference
        }
        let expectedRed = calibrated(0) / calibrated(1)
        let expectedBlue = calibrated(2) / calibrated(1)
        XCTAssertEqual(direct.x / direct.y, expectedRed, accuracy: expectedRed * 1e-3 + 1e-7)
        XCTAssertEqual(direct.z / direct.y, expectedBlue, accuracy: expectedBlue * 1e-3 + 1e-7)

        // The cube-face colour of the same hue — what the old boundary handed the film —
        // reaches the off-peak layers through a broad reconstructed spectrum. The table's
        // answer for the laser must sit well below it on both, interpolation included.
        guard case .locus(let light) = SpectralRuntime.sceneLight(rgb) else {
            return XCTFail("520 nm lies outside the Rec.2020 cube")
        }
        let edge = SpectralRuntime.anchoredExposure(light.face, stock: stock,
                                                    illuminant: illuminant)
        let table = SpectralRuntime.exposureTable(for: stock, illuminant: illuminant)
        let sampled = tableExposure(table, rgb)
        XCTAssertLessThan(sampled.x / sampled.y, 0.5 * edge.x / edge.y,
                          "the red layer sees far less of a 520 nm line than of its stand-in")
        XCTAssertLessThan(sampled.z / sampled.y, 0.5 * edge.z / edge.y,
                          "the blue layer sees far less of a 520 nm line than of its stand-in")
        XCTAssertEqual(sampled.y, direct.y, accuracy: 0.05 * direct.y,
                       "the peak layer's exposure survives interpolation")
    }

    // MARK: - Through the engine

    private func developedMean(_ scene: SIMD3<Float>) -> SIMD3<Float> {
        var options = FotufilmEngine.Options()
        options.paper = .screen
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

    /// Under the old boundary a laser developed as the cube-face colour of its hue, so the two
    /// prints were one print. Now the laser reaches the film as itself: it puts less on the
    /// peak layer than a broad reflectance of the same luminance does (its power sits off the
    /// layer's peak) and next to nothing on the others, and the print shows the difference.
    func testALaserDevelopsAsItselfNotAsItsCubeFaceStandIn() throws {
        try requireEngine()
        // Greens and cyans: the locus bulges furthest from the cube there. A red line sits
        // within a cell of the face, where the table continues the reflectance model.
        for nm in [Float(490), 500, 520] {
            let rgb = laser(nm: nm, luminance: 0.18)
            guard case .locus(let light) = SpectralRuntime.sceneLight(rgb) else {
                return XCTFail("\(nm) nm lies outside the Rec.2020 cube")
            }
            let line = developedMean(rgb)
            let standIn = developedMean(light.face)
            XCTAssertGreaterThan(line.max(), 0.01, "\(nm) nm must develop at all: \(line)")
            let delta = line - standIn
            let difference = max(abs(delta.x), abs(delta.y), abs(delta.z))
            XCTAssertGreaterThan(
                difference, 0.01,
                "\(nm) nm must not print as the cube-face colour of its hue: "
                    + "\(line) vs \(standIn)")
        }
    }

    /// Zeroing the negative channel alone adds light the scene never had and shifts the ratio
    /// between the survivors; a laser must develop as itself, not as its per-channel clip.
    func testALaserDoesNotDevelopAsItsPerChannelClip() throws {
        try requireEngine()
        for nm in [Float(490), 500, 520] {
            let rgb = laser(nm: nm, luminance: 0.18)
            XCTAssertLessThan(rgb.min(), -0.05 * rgb.max(), "\(nm) nm must poke out of the cube")
            let clipped = SIMD3(max(rgb.x, 0), max(rgb.y, 0), max(rgb.z, 0))
            let line = developedMean(rgb)
            let clip = developedMean(clipped)
            let delta = line - clip
            XCTAssertGreaterThan(
                max(abs(delta.x), abs(delta.y), abs(delta.z)), 0.005,
                "\(nm) nm must not print as its per-channel clip: \(line) vs \(clip)")
        }
    }

    func testTwoRealGreensBeyondRec2020DevelopDifferently() throws {
        try requireEngine()
        let a = developedMean(laser(nm: 510, luminance: 0.18))
        let b = developedMean(laser(nm: 520, luminance: 0.18))
        let distance = (a - b).max() - min(0, (a - b).min())
        XCTAssertGreaterThan(abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z), 0.005,
                             "510 and 520 nm are different lights: \(a) vs \(b), \(distance)")
    }
}
