import XCTest
@testable import FotufilmCore

/// The lab scan is profiled once, on a reference negative, and every other stock keeps the cast
/// its own mask puts between it and that reference. The profile committed here is solved from
/// Portra 400, the stock the same-lab corpus puts closest to neutral. These cases hold both the
/// mechanism and the committed numbers, so neither a simplification nor an unreviewed re-solve
/// can move them without a test noticing.
final class LabScanReferenceTests: XCTestCase {
    private static var negative: FilmStock { TestStocks.negative }

    func testOnlyTheLabScanIsReferenceAnchored() {
        for paper in PrintPaper.allCases {
            XCTAssertEqual(paper.isReferenceAnchored, paper == .labScan, paper.rawValue)
        }
    }

    /// The committed profile. Regenerating it is a deliberate act with a stated command, so the
    /// numbers are pinned rather than merely asserted finite.
    func testTheCommittedProfileIsThePortraSolve() {
        XCTAssertEqual(PrintPaper.labScanReferenceMidRatio.x, 0.5609019, accuracy: 1e-6)
        XCTAssertEqual(PrintPaper.labScanReferenceMidRatio.y, -0.444564, accuracy: 1e-6)
        XCTAssertEqual(PrintPaper.labScanReferenceBalance.count, 3)
        XCTAssertEqual(PrintPaper.labScanReferenceBalance[0], 1.0579212, accuracy: 1e-6)
        XCTAssertEqual(PrintPaper.labScanReferenceBalance[1], 1, accuracy: 1e-6)
        XCTAssertEqual(PrintPaper.labScanReferenceBalance[2], 0.880968, accuracy: 1e-6)
        XCTAssertEqual(PrintPaper.labScanCastCeiling, 0.029, accuracy: 1e-6)
    }

    /// A stock away from the reference keeps a cast, and it is the one the profile describes:
    /// green is never moved, and the magnitude never exceeds the committed ceiling.
    func testAStockAwayFromTheReferenceKeepsABoundedCast() {
        let offset = SpectralRuntime.referenceCastOffset(
            midEnergy: SIMD3(2, 1, 0.5), stock: Self.negative, paper: .labScan)
        XCTAssertEqual(offset.y, 0, "the timing record is never offset")
        let magnitude = (offset.x * offset.x + offset.z * offset.z).squareRoot()
        XCTAssertGreaterThan(magnitude, 0, "a calibrated reference must hand a cast through")
        XCTAssertLessThanOrEqual(magnitude, PrintPaper.labScanCastCeiling + 1e-6)
    }

    /// The profile's correction authority: a cast inside the ceiling passes as film character,
    /// a larger one is pulled back to the ceiling with its direction kept, and the reference
    /// itself, a monochrome stock, and every per-stock-timed medium get no offset at all.
    func testCastOffsetFollowsTheReferenceAndHoldsAtTheCeiling() {
        let reference = SIMD2<Float>(0.3, -0.4)
        let ceiling: Float = 0.05
        func offset(_ red: Float, _ blue: Float, stock: FilmStock = Self.negative,
                    paper: PrintPaper = .labScan) -> SIMD3<Float> {
            // A mid-grey read whose red/green and blue/green ratios are the given logs.
            let energy = SIMD3<Float>(pow(10, red), 1, pow(10, blue))
            return SpectralRuntime.referenceCastOffset(
                midEnergy: energy, stock: stock, paper: paper,
                reference: reference, ceiling: ceiling)
        }
        let atReference = offset(reference.x, reference.y)
        XCTAssertEqual(atReference.x, 0, accuracy: 1e-6)
        XCTAssertEqual(atReference.z, 0, accuracy: 1e-6)

        let small = offset(reference.x + 0.02, reference.y - 0.01)
        XCTAssertEqual(small.x, 0.02, accuracy: 1e-5)
        XCTAssertEqual(small.y, 0)
        XCTAssertEqual(small.z, -0.01, accuracy: 1e-5)

        let large = offset(reference.x + 0.3, reference.y - 0.4)
        let magnitude = (large.x * large.x + large.z * large.z).squareRoot()
        XCTAssertEqual(magnitude, ceiling, accuracy: 1e-5)
        XCTAssertEqual(large.x / large.z, 0.3 / -0.4, accuracy: 1e-4,
                       "the ceiling changed the cast's direction")
        XCTAssertEqual(large.y, 0)

        XCTAssertEqual(offset(reference.x + 0.3, reference.y, stock: TestStocks.monochrome),
                       .zero)
        for paper in PrintPaper.allCases where paper != .labScan {
            XCTAssertEqual(offset(reference.x + 0.3, reference.y, paper: paper), .zero,
                           paper.rawValue)
        }
    }

    /// What a calibrated build commits is exactly the stock's own mid-grey read through the
    /// scan's bands and its solved balance, so re-solving the reference stock returns the
    /// numbers the profile was anchored on.
    func testReferenceSolveMirrorsTheMidGreyRead() {
        let stock = Self.negative
        let solved = SpectralRuntime.labScanReferenceSolve(for: stock)
        let midDensity = (0..<3).map { stock.curves[$0].density(logExposure: 0) }
        let energy = SpectralRuntime.paperExposure(
            density: midDensity, dyes: stock.spectralProfile.imageDyeDensity,
            lamp: SpectralGrid.equalEnergy, paperSensitivity: PrintPaper.labScan.sensitivity)
        XCTAssertEqual(solved.midRatioRed, log10(energy.x / energy.y), accuracy: 1e-5)
        XCTAssertEqual(solved.midRatioBlue, log10(energy.z / energy.y), accuracy: 1e-5)
        XCTAssertEqual(solved.balance,
                       SpectralRuntime.neutralPrintingBalance(for: stock, paper: .labScan))
        XCTAssertTrue(solved.midRatioRed.isFinite && solved.midRatioBlue.isFinite)
    }

    /// The printing table is where the profile reaches a pixel. The machine auto-exposes every
    /// frame, so the timing record still lands on the anchor; red and blue carry the stock's
    /// distance from the reference, and no further than the ceiling allows.
    func testMidGreyIsTimedOnGreenAndCarriesOnlyTheBoundedCast() {
        let stock = Self.negative
        let tables = SpectralRuntime.tables(for: stock, paper: .labScan)
        let ranges = stock.curves.map { $0.dMax - $0.dMin }
        let mid = SIMD3<Float>((0..<3).map {
            (stock.curves[$0].density(logExposure: 0) - stock.curves[$0].dMin) / ranges[$0]
        })
        let relative = tables.filmOutput.sample(mid)
        XCTAssertEqual(relative[1], 0, accuracy: 1e-3,
                       "the timing record left the anchor: \(relative)")
        for channel in [0, 2] {
            XCTAssertLessThanOrEqual(
                abs(relative[channel]), PrintPaper.labScanCastCeiling + 1e-3,
                "channel \(channel) exceeded the profile's authority: \(relative)")
        }
        // A per-stock-timed medium re-solves its own neutral, so it keeps no cast at all.
        let paper = SpectralRuntime.tables(for: stock, paper: .ektacolorEdge)
        let printed = paper.filmOutput.sample(mid)
        for channel in 0..<3 {
            XCTAssertEqual(printed[channel], 0, accuracy: 1e-3,
                           "mid-grey left the anchor on channel \(channel): \(printed)")
        }
    }
}
