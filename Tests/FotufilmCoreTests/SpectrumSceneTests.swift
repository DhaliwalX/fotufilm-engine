import XCTest
@testable import FotufilmCore

final class SpectrumSceneTests: XCTestCase {

    private func geometryStocks() throws -> [GoldenStocks.Entry] {
        let candidates = GoldenStocks.all.filter { $0.stock.couplerGeometry != nil }
        guard !candidates.isEmpty else {
            throw XCTSkip("no stock on disk carries a coupler geometry")
        }
        return candidates
    }

    // MARK: - the scene itself

    func testEachThirdOfTheSweepPinsOneLayerUnderTheOtherTwo() {
        let scene = SpectrumScene.make(width: 256, height: 171)
        for zone in SpectrumScene.Zone.allCases {
            let indices = scene.indices(of: zone)
            XCTAssertFalse(indices.isEmpty, "\(zone.label) is empty")
            for i in indices {
                let r = scene.image.planes[0][i]
                let g = scene.image.planes[1][i]
                let b = scene.image.planes[2][i]
                switch zone {
                case .neutral:
                    XCTAssertEqual(r, g, accuracy: 1e-6, "grey is not grey")
                    XCTAssertEqual(g, b, accuracy: 1e-6, "grey is not grey")
                case .background:
                    // A true zero, so nothing an exposure control does can lift the surround.
                    XCTAssertEqual(r, 0)
                    XCTAssertEqual(g, 0)
                    XCTAssertEqual(b, 0)
                case .redGreen:
                    // The lobes peak 120° apart, so across each third the remaining layer sits at
                    // or below *both* of the two trading places. That is what makes the sweep a
                    // walk through the cross-layer condition rather than a general brightening.
                    XCTAssertLessThanOrEqual(b, min(r, g) + 1e-6)
                case .greenBlue:
                    XCTAssertLessThanOrEqual(r, min(g, b) + 1e-6)
                case .redBlue:
                    XCTAssertLessThanOrEqual(g, min(r, b) + 1e-6)
                case .wheel:
                    // Every hue and saturation at once, so it belongs to no pairing — it is here
                    // to be looked at, and only has to be a picture.
                    XCTAssertGreaterThanOrEqual(min(r, g, b), 0)
                }
            }
        }
    }

    // MARK: - what the controls do to it

    func testEveryFilmMovesTheSweepPastTheGateWhileTheGreysHold() throws {
        try requireEngine()
        let scene = SpectrumScene.make(width: SpectrumScene.previewSize.width,
                                       height: SpectrumScene.previewSize.height)
        let stocks = try geometryStocks()
        print("stock                control | R-G    G-B    R-B    wheel  ramp   ratio")

        for entry in stocks {
            let base = render(scene.image, stock: entry.stock, gaps: [1, 1])
            for (label, gaps) in [("R-G 1.8", [Float(1.8), 1]),
                                  ("G-B 1.8", [Float(1), 1.8])] {
                let delta = zoneDeltas(base,
                                       render(scene.image, stock: entry.stock, gaps: gaps),
                                       scene: scene)
                let weakest = SpectrumScene.colourZones.map { delta[$0]! }.min()!
                let ramp = delta[.neutral]!
                print(String(format: "%-20@ %@ | %6.3f %6.3f %6.3f %6.3f %6.3f %6.1f",
                             entry.id as NSString, label as NSString,
                             delta[.redGreen]!, delta[.greenBlue]!, delta[.redBlue]!,
                             delta[.wheel]!, ramp, weakest / ramp))

                // Every third of the sweep, not the strongest: whichever one the user's eye lands
                // on has to show the change.
                XCTAssertGreaterThan(
                    weakest, Self.clearsTheGate,
                    "\(entry.id) barely moves under \(label)")

                // The coupler warp is solved on the grey axis, so raising a barrier must not drag
                // the ramp with it. This is what would catch an anchor that stopped holding.
                XCTAssertLessThan(ramp, Self.rampHolds,
                                  "\(entry.id): the neutral anchor is not holding under \(label)")
                XCTAssertGreaterThan(
                    weakest, ramp * Self.rampMargin,
                    "\(entry.id): the greys move nearly as much as the colours under \(label)")
            }
        }
    }

    func testEdgeContrastShowsOnTheLitPartOfTheScene() throws {
        try requireEngine()
        let stock = try geometryStocks()[0].stock

        var atAppSize = 0.0
        for size in Self.sizes {
            let scene = SpectrumScene.make(width: size.width, height: size.height)
            let delta = mean(render(scene.image, stock: stock, gaps: [1, 1], selfScale: 1),
                             render(scene.image, stock: stock, gaps: [1, 1], selfScale: 2),
                             over: lit(scene))
            print(String(format: "edge contrast 1 -> 2 at %dx%d: mean dE %.3f",
                         size.width, size.height, delta))
            if size == SpectrumScene.previewSize { atAppSize = delta }
        }

        XCTAssertGreaterThan(atAppSize, Self.edgeContrastShows,
                             "the Edge Contrast control does not show on the scene")
    }

    func testTheSceneMovesAtLeastAsMuchAsAColorCheckerDoes() throws {
        try requireEngine()
        let stock = try geometryStocks()[0].stock

        let scene = SpectrumScene.make(width: SpectrumScene.previewSize.width,
                                       height: SpectrumScene.previewSize.height)
        let sceneDelta = mean(render(scene.image, stock: stock, gaps: [1, 1]),
                              render(scene.image, stock: stock, gaps: [1.8, 1.8]),
                              over: lit(scene))

        let checker = ReferenceChart.colorChecker
        let checkerDelta = meanDeltaITP(
            render(checker.image, stock: stock, gaps: [1, 1]),
            render(checker.image, stock: stock, gaps: [1.8, 1.8]))

        print(String(format: "both controls raised: scene (lit) %.3f  colorchecker %.3f  (%.2fx)",
                     sceneDelta, checkerDelta, sceneDelta / checkerDelta))
        XCTAssertGreaterThan(sceneDelta, checkerDelta * Self.matchesAChecker,
                             "the scene shows less than an ordinary colour target does")
    }

    func testWriteTheRendersForReview() throws {
        try requireEngine()
        guard let directory = ProcessInfo.processInfo
            .environment["FOTUFILM_WRITE_DEMO"] else {
            throw XCTSkip("set FOTUFILM_WRITE_DEMO=<directory> to write the renders")
        }
        let stock = try geometryStocks()[0].stock
        let scene = SpectrumScene.make(width: SpectrumScene.previewSize.width,
                                       height: SpectrumScene.previewSize.height)
        let cases: [(String, [Float], Float)] = [
            ("calibrated", [1, 1], 1),
            ("red-green-0", [0, 1], 1),
            ("red-green-3", [3, 1], 1),
            ("green-blue-0", [1, 0], 1),
            ("green-blue-3", [1, 3], 1),
            ("edge-contrast-3", [1, 1], 3),
        ]
        let base = render(scene.image, stock: stock, gaps: [1, 1], selfScale: 1)
        for (name, gaps, selfScale) in cases {
            let image = render(scene.image, stock: stock, gaps: gaps, selfScale: selfScale)
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("demo-\(name).png")
            try image.pngData().write(to: url)
            let delta = zoneDeltas(base, image, scene: scene)
            print(String(format: "%-16@ R-G %6.2f  G-B %6.2f  R-B %6.2f  ramp %5.2f  -> %@",
                         name as NSString,
                         delta[.redGreen]!, delta[.greenBlue]!,
                         delta[.redBlue]!, delta[.neutral]!,
                         url.lastPathComponent as NSString))
        }
    }

    // MARK: - thresholds

    private static let sizes = [(width: 256, height: 171),
                                SpectrumScene.previewSize,
                                (width: 768, height: 513)]

    /// Set from the numbers these tests print, not guessed at. Measured over all 20 packs that
    /// carry a geometry, one control at 1.8:
    ///
    ///   weakest third of the sweep   1.564 … 12.688  (worst: example-negative-400 under G-B)
    ///   grey ramp                    0.004 … 0.438
    ///   weakest third ÷ ramp         10.3 … 687.2    (worst: PRO 160NS under R-G)
    ///   edge contrast, lit pixels     0.228 … 0.234  across 256×171 … 768×513
    ///   scene ÷ ColorChecker          0.99×
    ///
    /// `clearsTheGate` is stated against the golden harness's own ΔE ITP tolerance of 1.0: below
    /// that the picture would be showing the user something the suite calls indistinguishable.
    // The nonlinear example pack's weakest zone measures 1.564. Keep a little measurement margin
    // while requiring a result 49% above the golden harness's one-JND gate.
    private static let clearsTheGate = 1.49
    private static let rampHolds = 1.0
    private static let rampMargin = 5.0
    private static let edgeContrastShows = 0.2
    private static let matchesAChecker = 0.9

    // MARK: - plumbing

    private func requireEngine() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
    }

    private func render(_ image: ImageBuffer, stock: FilmStock,
                        gaps: [Float], selfScale: Float = 1) -> RGBAImage {
        var options = FotufilmEngine.Options()
        options.paper = .screen
        options.grainScale = 0
        // This instrument measures coupler geometry, not deliberate off-balance lighting.
        // Give every emulsion the illuminant it was designed for so its neutral ramp stays neutral.
        options.sceneIlluminantKelvin = stock.referenceIlluminantKelvin
        options.couplerGapReachScales = gaps
        options.couplerSelfScale = selfScale
        return RGBAImage(print: FotufilmEngine(stock: stock, options: options)
            .process(linearRGB: image))
    }

    private func lit(_ scene: SpectrumScene) -> [Int] {
        SpectrumScene.litZones.flatMap { scene.indices(of: $0) }
    }

    private func meanDeltaITP(_ a: RGBAImage, _ b: RGBAImage) -> Double {
        mean(a, b, over: Array(0..<(a.width * a.height)))
    }

    private func zoneDeltas(_ a: RGBAImage, _ b: RGBAImage,
                            scene: SpectrumScene)
        -> [SpectrumScene.Zone: Double] {
        var out: [SpectrumScene.Zone: Double] = [:]
        for zone in SpectrumScene.Zone.allCases {
            out[zone] = mean(a, b, over: scene.indices(of: zone))
        }
        return out
    }

    private func mean(_ a: RGBAImage, _ b: RGBAImage, over indices: [Int]) -> Double {
        guard !indices.isEmpty else { return 0 }
        var total = 0.0
        for i in indices {
            let p = i * 4
            let al = (PrintDifference.displayLinear(a.pixels[p]),
                      PrintDifference.displayLinear(a.pixels[p + 1]),
                      PrintDifference.displayLinear(a.pixels[p + 2]))
            let bl = (PrintDifference.displayLinear(b.pixels[p]),
                      PrintDifference.displayLinear(b.pixels[p + 1]),
                      PrintDifference.displayLinear(b.pixels[p + 2]))
            total += PrintDifference.ITP.between(al, bl)
        }
        return total / Double(indices.count)
    }
}
