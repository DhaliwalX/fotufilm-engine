import XCTest
@testable import FotufilmCore

/// The print stage's self-consistency check. A sheet plots Status A integral
/// density; the renderer composes a spectrum from dye amounts. These assert the
/// two are inverses of each other, which is what lets the shipped
/// characteristic curves mean on the output what they meant on the page.
final class DensitometryTests: XCTestCase {

    private static let physicalPrints: [PrintPaper] = [
        .ektacolorEdge, .enduraPremier, .crystalArchive,
        .vision2383, .vision2393, .eternaCP,
    ]

    private var stock: FilmStock { FilmStock.presets["example-negative-400"]! }

    func testStatusABandsMatchThePublishedTable() {
        let peaks = Densitometry.statusA.map { band -> Float in
            SpectralGrid.wavelengths[band.firstIndex(of: band.max()!)!]
        }
        // Hunt Table 14.1: P_AR, P_AG and P_AB carry 5.000 at 620, 530 and
        // 440 nm. A band that has drifted means the table was mis-entered.
        XCTAssertEqual(peaks, [620, 530, 440])
        for band in Densitometry.statusA {
            XCTAssertEqual(band.max()!, 1, accuracy: 1e-6,
                           "each band's peak product is 10^(5.000 - 5)")
            XCTAssertTrue(band.allSatisfy { $0 >= 0 })
        }
        // A clear sample reads zero density in every band.
        let clear = [Float](repeating: 1, count: SpectralGrid.count)
        let read = Densitometry.statusADensity(transmittance: clear)
        XCTAssertEqual(read.x, 0, accuracy: 1e-6)
        XCTAssertEqual(read.y, 0, accuracy: 1e-6)
        XCTAssertEqual(read.z, 0, accuracy: 1e-6)
    }

    /// The closure the partitioned basis could not state: unmix a density
    /// triple to amounts, compose the spectrum those amounts make, read it back
    /// through the densitometer, and land on the density asked for.
    func testUnmixRoundTripsThroughTheDensitometer() {
        for paper in Self.physicalPrints {
            let unmix = PrintDyeUnmix(dyes: paper.analyticalDyes)
            var worst: Float = 0
            for red in stride(from: Float(0), through: 2.0, by: 0.25) {
                for green in stride(from: Float(0), through: 2.0, by: 0.25) {
                    for blue in stride(from: Float(0), through: 2.0, by: 0.25) {
                        let target = SIMD3(red, green, blue)
                        let amounts = unmix.amounts(forStatusA: target)
                        // Closure is asserted clear of the boundary blend;
                        // the boundary itself is checked by the test below.
                        guard min(amounts.x, min(amounts.y, amounts.z)) > 0.15
                        else { continue }
                        let read = Densitometry.statusADensity(
                            amounts: amounts, dyes: paper.analyticalDyes)
                        let error = read - target
                        worst = max(worst, max(abs(error.x),
                                               max(abs(error.y), abs(error.z))))
                    }
                }
            }
            XCTAssertLessThan(worst, 1e-4,
                              "\(paper.rawValue) does not close on its own "
                              + "densitometer: worst \(worst) D")
        }
    }

    /// A density triple outside the dye set is answered by removing dye, not by
    /// cutting off the output: every amount stays non-negative, so the spectrum
    /// is one Beer's law can make.
    func testUnreachableDensitiesLandOnTheGamutBoundary() {
        for paper in Self.physicalPrints {
            let unmix = PrintDyeUnmix(dyes: paper.analyticalDyes)
            // High red and blue with no green asks for less magenta than the
            // cyan and yellow already contribute to the green band.
            for target in [SIMD3<Float>(2.0, 0, 2.0), SIMD3(2.2, 0.1, 2.2),
                           SIMD3(0, 2.0, 2.0), SIMD3(2.0, 2.0, 0)] {
                let amounts = unmix.amounts(forStatusA: target)
                XCTAssertGreaterThanOrEqual(
                    min(amounts.x, min(amounts.y, amounts.z)), 0,
                    "\(paper.rawValue) returned an emitting dye for \(target)")
                XCTAssertTrue(amounts.x.isFinite && amounts.y.isFinite
                              && amounts.z.isFinite)
            }
        }
    }

    /// The partitioned basis asserts a flat neutral. The measured basis does
    /// not, and the size of that difference is the reason the unmix exists.
    func testTheMeasuredNeutralIsNotFlat() {
        let dyes = SpectralGrid.paperDyeAmounts
        var low = Float.greatestFiniteMagnitude
        var high: Float = 0
        for i in 0..<SpectralGrid.count {
            let wavelength = SpectralGrid.wavelengths[i]
            guard wavelength >= 400, wavelength <= 700 else { continue }
            let sum = dyes[0][i] + dyes[1][i] + dyes[2][i]
            low = min(low, sum); high = max(high, sum)
        }
        // The RA-4 neutral runs from under half a density at the red end to
        // over one in the green. `partition` divides exactly this out.
        XCTAssertEqual(low, 0.45, accuracy: 0.02)
        XCTAssertEqual(high, 1.15, accuracy: 0.02)
    }

    /// Reflection-paper setup is a fixed exposure translation, not a density offset.
    /// Its density effect must vanish in both the toe and shoulder.
    func testReflectionSetupActsOnExposureNotDevelopedDensity() {
        for paper: PrintPaper in [.ektacolorEdge, .enduraPremier, .crystalArchive] {
            let curves = paper.printCurves(for: stock)
            let midpoints = paper.printExposureMidpoints(for: stock)
            let light = SpectralRuntime.referenceViewingLight(for: paper)
            let receiver = SpectralRuntime.printReceiver(stock: stock, paper: paper, viewingLight: light)
            let density = SIMD3((0..<3).map {
                curves[$0].density(logExposure: midpoints[$0]) - curves[$0].dMin
            })
            let rgb = receiver.rgb(density: density)
            for channel in 0..<3 {
                XCTAssertEqual(rgb[channel], pow(10, -paper.midDensity), accuracy: 1e-4)
                let curve = curves[channel]
                let untrimmed = curve.logExposure(density: curve.dMin + paper.anchorDensity)
                let shift = midpoints[channel] - untrimmed
                XCTAssertLessThan(abs(shift), 0.05, "log exposure, not density units")
                for exposure in [curve.toe - 10, curve.shoulder + 10] {
                    XCTAssertEqual(curve.density(logExposure: exposure + shift),
                                   curve.density(logExposure: exposure), accuracy: 3e-5)
                }
            }
        }
    }
}
