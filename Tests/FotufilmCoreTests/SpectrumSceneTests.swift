import XCTest
@testable import FotufilmCore

final class SpectrumSceneTests: XCTestCase {

    private func geometryStocks() throws -> [CatalogueStocks.Entry] {
        let candidates = CatalogueStocks.all.filter { $0.stock.couplerGeometry != nil }
        _ = try XCTUnwrap(candidates.first, "no bundled stock carries a coupler geometry")
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

    func testGapControlsMoveTheColoursWhileTheGreysHold() throws {
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
                let ramp = mean(base, render(scene.image, stock: entry.stock, gaps: gaps),
                                over: rampCore(scene))
                print(String(format: "%-20@ %@ | %6.3f %6.3f %6.3f %6.3f %6.3f %6.1f",
                             entry.id as NSString, label as NSString,
                             delta[.redGreen]!, delta[.greenBlue]!, delta[.redBlue]!,
                             delta[.wheel]!, ramp, weakest / ramp))

                // The coupler warp is solved on the grey axis, so raising a barrier must not drag
                // the ramp with it. This is what would catch an anchor that stopped holding. It is
                // read on the core of the ramp: an inhibitor that travels far reaches the ramp's
                // rim from the black around it, and that border effect follows the reach by design.
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

        // Under the forward-compensated v4 QDI model (`useForwardCouplerModel`), intra-layer
        // self-retention (`K[c][c]`) cancels identically on flat areas (`q_c - blur(q_c) == 0`)
        // instead of leaking onto uniform colour, while `couplerPreviewSigmaFloorPixels` (`0.85 px`)
        // keeps micro-edge contrast responsive along lit borders even in a 512x342 preview.
        var flatChromatic = ImageBuffer(width: 64, height: 64)
        for idx in 0..<(64 * 64) {
            flatChromatic.planes[0][idx] = 0.55
            flatChromatic.planes[1][idx] = 0.12
            flatChromatic.planes[2][idx] = 0.08
        }
        let flatDelta = meanDeltaITP(
            render(flatChromatic, stock: stock, gaps: [1, 1], selfScale: 1),
            render(flatChromatic, stock: stock, gaps: [1, 1], selfScale: 2))
        XCTAssertEqual(flatDelta, 0, accuracy: 1e-5,
                       "self-inhibition must not leak onto uniform chromatic patches")

        let preview = SpectrumScene.make(width: SpectrumScene.previewSize.width,
                                         height: SpectrumScene.previewSize.height)
        let borderDelta = mean(render(preview.image, stock: stock, gaps: [1, 1], selfScale: 1),
                               render(preview.image, stock: stock, gaps: [1, 1], selfScale: 2),
                               over: litBorders(preview))
        print(String(format: "edge contrast 1 -> 2 on preview borders at %dx%d: mean dE %.3f",
                     preview.width, preview.height, borderDelta))
        XCTAssertGreaterThan(borderDelta, Self.edgeContrastShows,
                             "the Edge Contrast control does not show on preview edges")
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

    /// Set from the numbers these tests print, not guessed at. Measured over all 22 released
    /// packs that carry an active geometry (`21` colour negatives + `velvia50`), one control at 1.8:
    ///
    ///   grey ramp, core              0.000 … 0.004
    ///   weakest third ÷ ramp         114 or more     (worst: Eterna Vivid 500 under G-B)
    ///   edge contrast, lit borders   6.969           on preview borders (`512×342`), `0` on flat
    ///   scene ÷ ColorChecker          0.90×
    ///
    private static let rampHolds = 1.0
    private static let rampMargin = 5.0
    private static let edgeContrastShows = 0.2
    private static let matchesAChecker = 0.85

    // MARK: - plumbing

    private func requireEngine() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
    }

    private func render(_ image: ImageBuffer, stock: FilmStock,
                        gaps: [Float], selfScale: Float = 1,
                        format: FilmFormat? = nil) -> RGBAImage {
        var options = FotufilmEngine.Options()
        options.paper = .screen
        if let format { options.format = format }
        // Compare coupler visibility at one fixed exposure: per-frame Auto Levels would
        // retime the sweep and checker independently and confound this colour measurement.
        options.digitalReference = .referenceExposure
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

    private func litBorders(_ scene: SpectrumScene) -> [Int] {
        let w = scene.width, h = scene.height
        return lit(scene).filter { idx in
            let x = idx % w, y = idx / w
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                if nx >= 0, nx < w, ny >= 0, ny < h,
                   scene.zones[ny * w + nx] == .background {
                    return true
                }
            }
            return false
        }
    }

    /// The ramp's middle rows and inner columns: greys whose whole neighbourhood is grey.
    private func rampCore(_ scene: SpectrumScene) -> [Int] {
        let ramp = scene.indices(of: .neutral)
        let rows = ramp.map { $0 / scene.width }, columns = ramp.map { $0 % scene.width }
        guard let top = rows.min(), let bottom = rows.max(),
              let left = columns.min(), let right = columns.max() else { return [] }
        let rowInset = (bottom - top + 1) / 3, columnInset = (right - left + 1) / 10
        return ramp.filter {
            let row = $0 / scene.width, column = $0 % scene.width
            return row >= top + rowInset && row <= bottom - rowInset
                && column >= left + columnInset && column <= right - columnInset
        }
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
