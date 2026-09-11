import XCTest
@testable import FotufilmCore

final class PrintPaperRecordTests: XCTestCase {

    private static var stock: FilmStock {
        FilmStock.presets["example-negative-400"]!
    }

    private func invocation(paper: PrintPaper) -> FilmEngineInvocation {
        var options = FotufilmEngine.Options()
        options.paper = paper
        return FilmEngineInvocation(stock: Self.stock, options: options,
                                    width: 640, height: 480)
    }

    private func slots(_ configuration: [Float], at offset: Int) -> [Float] {
        Array(configuration[offset..<(offset + 6)])
    }

    func testEachRecordRidesItsOwnCurveAndMidpoint() {
        let inv = invocation(paper: .ektacolorEdge)
        let configuration = inv.configuration
        let expected = [PrintPaper.ra4PrintCurveRed, PrintPaper.ra4PrintCurve,
                        PrintPaper.ra4PrintCurveBlue]
        let offsets = [FilmEngineInvocation.paperRedOffset, 33,
                       FilmEngineInvocation.paperBlueOffset]
        let midpointSlots = [FilmEngineInvocation.paperMidpointRedOffset, 62,
                             FilmEngineInvocation.paperMidpointBlueOffset]
        let midpoints = PrintPaper.ektacolorEdge.printExposureMidpoints(for: Self.stock)
        for (channel, curve) in expected.enumerated() {
            XCTAssertEqual(slots(configuration, at: offsets[channel]),
                           [curve.dMin, curve.gamma, curve.toe, curve.toeWidth,
                            curve.shoulder, curve.shoulderWidth],
                           "record \(channel)")
            let midpoint = configuration[midpointSlots[channel]]
            XCTAssertEqual(midpoint, midpoints[channel], accuracy: 1e-6,
                           "record \(channel) must anchor its own curve")
        }
        // Three genuinely different records, or the per-channel plumbing is
        // carrying one curve three times.
        XCTAssertNotEqual(slots(configuration, at: offsets[0]),
                          slots(configuration, at: offsets[1]))
        XCTAssertNotEqual(slots(configuration, at: offsets[2]),
                          slots(configuration, at: offsets[1]))
    }

    func testSingleCurveSheetsPackOneRecordThreeTimes() {
        for paper in [PrintPaper.crystalArchive, .labScan, .telecine] {
            let configuration = invocation(paper: paper).configuration
            let green = slots(configuration, at: 33)
            XCTAssertEqual(slots(
                configuration, at: FilmEngineInvocation.paperRedOffset),
                green, paper.rawValue)
            XCTAssertEqual(slots(
                configuration, at: FilmEngineInvocation.paperBlueOffset),
                green, paper.rawValue)
            // A shared characteristic curve does not imply shared exposure timing:
            // the physical paper's dye spectra still need separate setup exposures.
            let midpoints = paper.printExposureMidpoints(for: Self.stock)
            XCTAssertEqual(configuration[FilmEngineInvocation.paperMidpointRedOffset], midpoints[0])
            XCTAssertEqual(configuration[62], midpoints[1])
            XCTAssertEqual(configuration[FilmEngineInvocation.paperMidpointBlueOffset], midpoints[2])
        }
    }

    func testShippedRecordsReproduceTheSheet() {
        let sheet: [(CharacteristicCurve, [(Float, Float)])] = [
            (PrintPaper.ra4PrintCurveRed,
             [(-1.8, 0.183), (-1.2, 1.649), (-0.6, 2.213), (-0.04, 2.277)]),
            (PrintPaper.ra4PrintCurve,
             [(-1.8, 0.168), (-1.2, 1.562), (-0.6, 2.135), (-0.04, 2.154)]),
            (PrintPaper.ra4PrintCurveBlue,
             [(-1.8, 0.193), (-1.2, 1.539), (-0.6, 2.241)]),
        ]
        for (record, (curve, points)) in sheet.enumerated() {
            for (logExposure, density) in points {
                XCTAssertEqual(curve.density(logExposure: logExposure), density,
                               accuracy: 0.04,
                               "record \(record) at logH \(logExposure)")
            }
        }
    }

    func testEnduraPremierEachRecordRidesItsOwnCurveAndMidpoint() {
        let inv = invocation(paper: .enduraPremier)
        let configuration = inv.configuration
        let expected = [EnduraPremierPaperSpectra.redCurve,
                        EnduraPremierPaperSpectra.greenCurve,
                        EnduraPremierPaperSpectra.blueCurve]
        let offsets = [FilmEngineInvocation.paperRedOffset, 33,
                       FilmEngineInvocation.paperBlueOffset]
        let midpointSlots = [FilmEngineInvocation.paperMidpointRedOffset, 62,
                             FilmEngineInvocation.paperMidpointBlueOffset]
        let midpoints = PrintPaper.enduraPremier.printExposureMidpoints(for: Self.stock)
        for (channel, curve) in expected.enumerated() {
            XCTAssertEqual(slots(configuration, at: offsets[channel]),
                           [curve.dMin, curve.gamma, curve.toe, curve.toeWidth,
                            curve.shoulder, curve.shoulderWidth],
                           "record \(channel)")
            let midpoint = configuration[midpointSlots[channel]]
            XCTAssertEqual(midpoint, midpoints[channel], accuracy: 1e-6,
                           "record \(channel) must anchor its own curve")
        }
        XCTAssertNotEqual(slots(configuration, at: offsets[0]),
                          slots(configuration, at: offsets[1]))
        XCTAssertNotEqual(slots(configuration, at: offsets[2]),
                          slots(configuration, at: offsets[1]))
    }

    func testEnduraPremierShippedRecordsReproduceTheSheet() {
        let sheet: [(CharacteristicCurve, [(Float, Float)])] = [
            (EnduraPremierPaperSpectra.redCurve,
             [(-2.0, 0.109), (-1.5, 0.447), (-1.2, 1.479), (-0.8, 2.647), (-0.4, 2.756)]),
            (EnduraPremierPaperSpectra.greenCurve,
             [(-2.0, 0.109), (-1.5, 0.486), (-1.2, 1.561), (-0.8, 2.440), (-0.4, 2.523)]),
            (EnduraPremierPaperSpectra.blueCurve,
             [(-2.0, 0.084), (-1.5, 0.448), (-1.2, 1.557), (-0.8, 2.395), (-0.4, 2.441)]),
        ]
        for (record, (curve, points)) in sheet.enumerated() {
            for (logExposure, density) in points {
                XCTAssertEqual(curve.density(logExposure: logExposure), density,
                                accuracy: 0.04,
                                "record \(record) at logH \(logExposure)")
            }
        }
    }

}
