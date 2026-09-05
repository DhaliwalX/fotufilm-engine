import XCTest
@testable import FotufilmCore

/// The lab scan is profiled once, on a reference negative, and every other stock keeps the cast
/// its own mask puts between it and that reference. This repository ships the mechanism with a
/// neutral reference and a zero ceiling; a calibrated build commits real numbers. These cases
/// hold the mechanism itself, so a simplification cannot drop it without a test noticing.
final class LabScanReferenceTests: XCTestCase {
    private static var negative: FilmStock { TestStocks.negative }

    func testOnlyTheLabScanIsReferenceAnchored() {
        for paper in PrintPaper.allCases {
            XCTAssertEqual(paper.isReferenceAnchored, paper == .labScan, paper.rawValue)
        }
    }

    func testThisRepositorysReferenceIsNeutralAndInert() {
        XCTAssertEqual(PrintPaper.labScanReferenceMidRatio, .zero)
        XCTAssertEqual(PrintPaper.labScanReferenceBalance, [1, 1, 1])
        XCTAssertEqual(PrintPaper.labScanCastCeiling, 0)
        // Whatever the stock's own mid-grey read is, a zero ceiling hands none of it through.
        let offset = SpectralRuntime.referenceCastOffset(
            midEnergy: SIMD3(2, 1, 0.5), stock: Self.negative, paper: .labScan)
        XCTAssertEqual(offset, .zero)
        XCTAssertEqual(Self.negative.printingContrastScale(correction: 1, paper: .labScan),
                       [1, 1, 1])
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

    /// The printing table is where the profile reaches a pixel. With a neutral reference the
    /// stock's own mid-grey must still print at the anchor, the same neutral every per-stock
    /// medium hits, or the offset has picked up a sign or a scale it should not have.
    func testNeutralReferenceLeavesMidGreyOnTheAnchor() {
        let stock = Self.negative
        let tables = SpectralRuntime.tables(for: stock, paper: .labScan)
        let ranges = stock.curves.map { $0.dMax - $0.dMin }
        let mid = SIMD3<Float>((0..<3).map {
            (stock.curves[$0].density(logExposure: 0) - stock.curves[$0].dMin) / ranges[$0]
        })
        let relative = tables.filmOutput.sample(mid)
        for channel in 0..<3 {
            XCTAssertEqual(relative[channel], 0, accuracy: 1e-3,
                           "mid-grey left the anchor on channel \(channel): \(relative)")
        }
    }
}
