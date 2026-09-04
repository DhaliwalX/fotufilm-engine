import XCTest
@testable import FotufilmCore

final class BleachBypassTests: XCTestCase {

    private static var negative: FilmStock {
        FilmStock.presets["example-negative-400"]!
    }

    private func printed(_ logExposureStops: Float, stock: FilmStock,
                         bleach: Float) -> SIMD3<Float> {
        let tables = SpectralRuntime.tables(for: stock, paper: .default,
                                            bleachBypass: bleach)
        let perStop = Float(log10(2.0))
        let ranges = stock.curves.map { $0.dMax - $0.dMin }
        let p = SIMD3<Float>(
            (stock.curves[0].density(logExposure: logExposureStops * perStop)
                - stock.curves[0].dMin) / ranges[0],
            (stock.curves[1].density(logExposure: logExposureStops * perStop)
                - stock.curves[1].dMin) / ranges[1],
            (stock.curves[2].density(logExposure: logExposureStops * perStop)
                - stock.curves[2].dMin) / ranges[2])
        let relativeLogE = tables.filmOutput.sample(p)
        let paperCurve = FotufilmEngine.Options().paper(for: stock).printCurve(for: stock)
        let xMid = paperCurve.logExposure(
            density: paperCurve.dMin
                + FotufilmEngine.Options().paper(for: stock).anchorDensity(stock.paperMidDensity))
        let range = paperCurve.dMax - paperCurve.dMin
        let activation = SIMD3<Float>(
            (paperCurve.density(logExposure: xMid + relativeLogE.x) - paperCurve.dMin) / range,
            (paperCurve.density(logExposure: xMid + relativeLogE.y) - paperCurve.dMin) / range,
            (paperCurve.density(logExposure: xMid + relativeLogE.z) - paperCurve.dMin) / range)
        return tables.paperOutput!.sample(activation)
    }

    private func luminance(_ rgb: SIMD3<Float>) -> Float {
        let w = ColorScience.luminanceWeights
        return w.0 * rgb.x + w.1 * rgb.y + w.2 * rgb.z
    }

    // MARK: Off position

    func testOffPositionKeepsEveryCacheIdentity() {
        for stock in FilmStock.presets.values {
            XCTAssertEqual(
                SpectralRuntime.cacheIdentifier(for: stock),
                SpectralRuntime.cacheIdentifier(for: stock, bleachBypass: 0),
                stock.name)
        }
    }

    func testMonochromeAndReversalRefuseTheLever() {
        for stock in FilmStock.presets.values where stock.isMonochrome || stock.isReversal {
            XCTAssertEqual(
                SpectralRuntime.cacheIdentifier(for: stock),
                SpectralRuntime.cacheIdentifier(for: stock, bleachBypass: 1),
                stock.name)
            XCTAssertEqual(SpectralRuntime.retainedSilverFraction(1, stock: stock), 0,
                           stock.name)
        }
    }

    // MARK: The look, measured

    func testMidGreyStaysAnchored() {
        let stock = Self.negative
        let normal = luminance(printed(0, stock: stock, bleach: 0))
        let bypassed = luminance(printed(0, stock: stock, bleach: 1))
        // Measured 2026-08-12: 0.1807007 both ways — the anchor holds to the seventh
        // digit. 2% is the widest drift a re-timed print could hide behind; dropping
        // the silver from either side of the anchor moves mid-grey by whole stops.
        XCTAssertEqual(bypassed / normal, 1, accuracy: 0.02)
    }

    func testContrastRises() {
        let stock = Self.negative
        func span(_ bleach: Float) -> Float {
            luminance(printed(1, stock: stock, bleach: bleach))
                / max(luminance(printed(-1, stock: stock, bleach: bleach)), 1e-6)
        }
        let normal = span(0)
        let bypassed = span(1)
        // Measured 2026-08-12: the ±1-stop span goes 9.06 → 86.9 — in log terms the
        // print contrast exactly doubles (×2.03), which is what one density of silver
        // per density of dye must do to a record read through a log-domain paper.
        // Assert half the measured log motion, so losing the silver from the sample
        // side of the integral fails while requantisation noise cannot.
        XCTAssertGreaterThan(bypassed, normal * 4)
    }

    func testShadowsBlockWhileMidtonesKeepChroma() {
        let stock = Self.negative
        func chroma(_ rgb: SIMD3<Float>) -> Float {
            let peak = max(rgb.x, rgb.y, rgb.z)
            guard peak > 1e-6 else { return 0 }
            return (peak - min(rgb.x, rgb.y, rgb.z)) / peak
        }
        let tables0 = SpectralRuntime.tables(for: stock, bleachBypass: 0)
        let tables1 = SpectralRuntime.tables(for: stock, bleachBypass: 1)
        let paper = FotufilmEngine.Options().paper(for: stock)
        let paperCurves = paper.printCurves(for: stock)
        let perStop = Float(log10(2.0))
        let ranges = stock.curves.map { $0.dMax - $0.dMin }
        func out(_ tables: SpectralPipelineTables, scene: SIMD3<Float>) -> SIMD3<Float> {
            // The exposure cube is indexed in its locus-enclosing basis, as the kernel reads it.
            let exposure = tables0.exposure.sample(
                ColorScience.linearRec2020ToExposureDomain(scene))
            var p = SIMD3<Float>()
            for layer in 0..<3 {
                let logE = log10(max(exposure[layer], 1e-6) / 0.18) / perStop
                p[layer] = (stock.curves[layer].density(logExposure: logE * perStop)
                            - stock.curves[layer].dMin) / ranges[layer]
            }
            let logE = tables.filmOutput.sample(p)
            let activation = SIMD3<Float>((0..<3).map { channel in
                let curve = paperCurves[channel]
                let xMid = curve.logExposure(
                    density: curve.dMin + paper.anchorDensity(stock.paperMidDensity))
                return (curve.density(logExposure: xMid + logE[channel])
                        - curve.dMin) / (curve.dMax - curve.dMin)
            })
            return tables.paperOutput!.sample(activation)
        }
        let midRed = SIMD3<Float>(0.3, 0.05, 0.05)
        let shadowRed = midRed / 8 // three stops down, where the normal print still has tone
        // Midtone chroma survives the bypass.
        // Measured 2026-08-12: mid chroma 0.949 → 0.956 — the re-timing cancels the
        // silver's common-mode shift and the steeper response even lifts it a touch.
        let midNormal = chroma(out(tables0, scene: midRed))
        let midBypassed = chroma(out(tables1, scene: midRed))
        XCTAssertEqual(midBypassed, midNormal, accuracy: 0.05)
        // The shadow crushes toward the paper's black and loses its colour with it.
        // The paper's three records leave their own cast on the deepest tones, so the
        // collapse is measured against the print of a *neutral* patch of the same
        // scene luminance: the bypassed red shadow and the bypassed neutral shadow
        // print the same colour, which is the scene's red gone entirely. Measured
        // 2026-08-13: luminance 0.01277 → 0.00994, chroma 0.330 → 0.0937 with the
        // neutral's own bypassed cast at 0.0937 — equal to 3e-6, against a 0.26
        // separation from the uncrushed print.
        let shadowNormal = out(tables0, scene: shadowRed)
        let shadowBypassed = out(tables1, scene: shadowRed)
        let neutralBypassed = out(
            tables1, scene: SIMD3(repeating: luminance(shadowRed)))
        XCTAssertLessThan(luminance(shadowBypassed), luminance(shadowNormal) * 0.9)
        XCTAssertGreaterThan(chroma(shadowNormal), 0.25)
        XCTAssertEqual(chroma(shadowBypassed), chroma(neutralBypassed),
                       accuracy: 0.01)
    }

    func testNegativeViewingShowsTheSilver() {
        let stock = Self.negative
        let normal = SpectralRuntime.negativeViewing(for: stock, look: .lightBox)
        let bypassed = SpectralRuntime.negativeViewing(for: stock, look: .lightBox,
                                                       bleachBypass: 1)
        // p = 0 is D-min: no development, no silver.
        let baseNormal = normal.sample(SIMD3(repeating: 0))
        let baseBypassed = bypassed.sample(SIMD3(repeating: 0))
        XCTAssertEqual(baseNormal.x, baseBypassed.x, accuracy: 1e-4)
        XCTAssertEqual(baseNormal.y, baseBypassed.y, accuracy: 1e-4)
        XCTAssertEqual(baseNormal.z, baseBypassed.z, accuracy: 1e-4)
        // Mid development darkens under exactly its own silver: the retained silver is
        // spectrally flat, so per channel the view must attenuate by 10^-silver — for
        // this stock at the table's midpoint, half its 9.78 summed density range, or
        // 4.89 D. Measured 2026-08-12: 0.0069976 → 9.03e-8, which is that power of ten;
        // a silver double-counted (or halved) anywhere in the read fails this by
        // orders of magnitude.
        let silver = 0.5 * stock.curves.map { $0.dMax - $0.dMin }.reduce(0, +)
        let expected = pow(10, -silver)
        let midNormal = normal.sample(SIMD3(repeating: 0.5))
        let midBypassed = bypassed.sample(SIMD3(repeating: 0.5))
        for channel in 0..<3 where midNormal[channel] > 1e-6 {
            XCTAssertEqual(midBypassed[channel] / midNormal[channel] / expected, 1,
                           accuracy: 0.02, "channel \(channel)")
        }
    }
}
