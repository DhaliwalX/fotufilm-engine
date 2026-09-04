import XCTest
@testable import FotufilmCore

final class AccuracyBaselineTests: XCTestCase {

    struct Metrics: Codable, Equatable {
        var bandFloor: Double
        var zeroApproach: Double
        var revival: Double
        var exposureRatioDrift: Double?
        var neutralSpread: Double
        var midGreyError: Double
        var blueSkyRedRatio: Double?
        var hueStep: Double?
        var reversalSpreadRatio: Double?
    }

    private struct Measure {
        let name: String
        let lowerIsBetter: Bool
        let slack: Double
        let read: (Metrics) -> Double?
    }

    private static let measures: [Measure] = [
        Measure(name: "bandFloor", lowerIsBetter: false, slack: 1e-5,
                read: { $0.bandFloor }),
        Measure(name: "zeroApproach", lowerIsBetter: true, slack: 1e-5,
                read: { $0.zeroApproach }),
        Measure(name: "revival", lowerIsBetter: true, slack: 1e-4,
                read: { $0.revival }),
        Measure(name: "exposureRatioDrift", lowerIsBetter: true, slack: 1e-6,
                read: { $0.exposureRatioDrift }),
        Measure(name: "neutralSpread", lowerIsBetter: true, slack: 0.25,
                read: { $0.neutralSpread }),
        Measure(name: "midGreyError", lowerIsBetter: true, slack: 2e-5,
                read: { $0.midGreyError }),
        Measure(name: "blueSkyRedRatio", lowerIsBetter: true, slack: 2e-3,
                read: { $0.blueSkyRedRatio }),
        Measure(name: "hueStep", lowerIsBetter: true, slack: 2e-3,
                read: { $0.hueStep }),
        Measure(name: "reversalSpreadRatio", lowerIsBetter: true, slack: 1e-3,
                read: { $0.reversalSpreadRatio }),
    ]

    private static let tolerance = 0.02

    private static var baselineURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("accuracy-baseline.json")
    }

    private struct Baseline: Codable {
        var note: String
        var stocks: [String: Metrics]
    }

    func testAccuracyHasNotGotWorse() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "the Halide engine is the only processing backend")
        let stocks = FilmStock.presets
            .sorted { $0.key < $1.key }
            .map { (id: $0.key, stock: $0.value) }
        try XCTSkipUnless(!stocks.isEmpty, "no stock pack is installed")

        var measured: [String: Metrics] = [:]
        for entry in stocks { measured[entry.id] = metrics(of: entry.stock) }

        if ProcessInfo.processInfo.environment["FOTUFILM_ACCURACY_BASELINE"]
            == "update" {
            try write(measured)
            XCTFail("""
                baseline rewritten from this run — \
                review the diff and run again without \
                FOTUFILM_ACCURACY_BASELINE to check it
                """)
            return
        }

        guard let baseline = try read() else {
            throw XCTSkip("""
                no accuracy baseline in this checkout (\
                \(Self.baselineURL.lastPathComponent)); generate one with \
                FOTUFILM_ACCURACY_BASELINE=update
                """)
        }

        var improvements: [String] = []
        for entry in stocks {
            guard let was = baseline.stocks[entry.id] else {
                XCTFail("""
                    \(entry.stock.name) (\(entry.id)) has no baseline — a new \
                    stock has to be recorded before it can be tracked
                    """)
                continue
            }
            let now = measured[entry.id]!
            for measure in Self.measures {
                guard let before = measure.read(was),
                      let after = measure.read(now) else {
                    XCTAssertEqual(
                        measure.read(was) == nil, measure.read(now) == nil,
                        "\(entry.stock.name) \(measure.name) appeared or "
                        + "disappeared; regenerate the baseline")
                    continue
                }
                let allowance = abs(before) * Self.tolerance + measure.slack
                let worse = measure.lowerIsBetter
                    ? after - before : before - after
                XCTAssertLessThanOrEqual(
                    worse, allowance,
                    """
                    \(entry.stock.name) \(measure.name) got worse: \
                    \(before) → \(after)
                    """)
                let better = -worse
                if better > allowance * 4 {
                    improvements.append(
                        "\(entry.stock.name) \(measure.name) "
                        + "\(before) → \(after)")
                }
            }
        }

        if !improvements.isEmpty {
            print("""
                accuracy improved beyond the baseline in \
                \(improvements.count) place(s); regenerate to pin it:
                \(improvements.joined(separator: "\n"))
                """)
        }
    }

    private func metrics(of stock: FilmStock) -> Metrics {
        let records = recordMetrics(of: stock)
        let neutral = neutralMetrics(of: stock)
        return Metrics(
            bandFloor: records.floor,
            zeroApproach: records.zeroApproach,
            revival: records.revival,
            exposureRatioDrift: stock.isMonochrome ? nil : exposureDrift(of: stock),
            neutralSpread: neutral.spread,
            midGreyError: neutral.midGrey,
            blueSkyRedRatio: stock.isMonochrome ? nil : skyMetrics(of: stock).red,
            hueStep: stock.isMonochrome ? nil : skyMetrics(of: stock).step,
            reversalSpreadRatio: stock.isReversal ? wedgeRatio(of: stock) : nil)
    }

    private func recordMetrics(
        of stock: FilmStock
    ) -> (floor: Double, zeroApproach: Double, revival: Double) {
        let sensitivity = stock.spectralProfile.layerSensitivity
        let peaks = (0..<3).map { sensitivity[$0].max() ?? 0 }

        var floor = Double.infinity
        for index in 0..<SpectralGrid.count {
            let wavelength = SpectralGrid.wavelengths[index]
            guard wavelength >= 400, wavelength <= 660 else { continue }
            let best = (0..<3).map { layer -> Double in
                peaks[layer] > 0
                    ? Double(sensitivity[layer][index] / peaks[layer]) : 0
            }.max()!
            floor = min(floor, best)
        }

        var zeroApproach = 0.0
        var revival = 0.0
        for layer in 0..<3 {
            let curve = sensitivity[layer]
            guard let peak = curve.max(), peak > 0 else { continue }
            for index in 1..<curve.count where curve[index] == 0 {
                zeroApproach = max(zeroApproach, Double(curve[index - 1] / peak))
            }
            let summit = curve.firstIndex(of: peak)!
            for direction in [-1, 1] {
                var fallen = false
                var index = summit
                while curve.indices.contains(index + direction) {
                    index += direction
                    if curve[index] < peak * 0.25 { fallen = true }
                    if fallen {
                        revival = max(revival, Double(curve[index] / peak))
                    }
                }
            }
        }
        return (floor.isFinite ? floor : 0, zeroApproach, revival)
    }

    private static let chromaticities: [SIMD3<Float>] = [
        SIMD3(0.18, 0.40, 1.00), SIMD3(0.05, 0.10, 1.00),
        SIMD3(1.00, 0.12, 0.06), SIMD3(0.10, 1.00, 0.15),
        SIMD3(0.15, 0.80, 1.00), SIMD3(1.00, 0.60, 0.45),
    ]

    private func layerExposure(_ rgb: SIMD3<Float>,
                               stock: FilmStock) -> SIMD3<Float> {
        let reflectance = SpectralRuntime.reconstructedReflectance(linearRGB: rgb)
        var exposure = SIMD3<Float>(repeating: 0)
        var neutral = SIMD3<Float>(repeating: 0)
        for index in 0..<SpectralGrid.count {
            for layer in 0..<3 {
                let sensitivity = stock.spectralProfile.layerSensitivity[layer][index]
                exposure[layer] += reflectance[index] * SpectralGrid.d65[index] * sensitivity
                neutral[layer] += SpectralGrid.d65[index] * sensitivity
            }
        }
        return exposure / neutral
    }

    private func exposureDrift(of stock: FilmStock) -> Double {
        var worst = 0.0
        for chromaticity in Self.chromaticities {
            let unit = layerExposure(chromaticity, stock: stock)
            guard unit.max() > 0 else { continue }
            let reference = unit / unit.max()
            for scale: Float in [0.1, 0.5, 0.9, 0.99, 1.0, 1.01, 1.5, 8] {
                let exposure = layerExposure(chromaticity * scale, stock: stock)
                guard exposure.max() > 0 else { continue }
                let ratio = exposure / exposure.max()
                for layer in 0..<3 {
                    worst = max(worst, Double(abs(ratio[layer] - reference[layer])))
                }
            }
        }
        return worst
    }

    private func render(_ patch: SIMD3<Float>, stock: FilmStock) -> SIMD3<Float> {
        let size = 8
        var image = ImageBuffer(width: size, height: size)
        for i in 0..<(size * size) {
            image.planes[0][i] = patch.x
            image.planes[1][i] = patch.y
            image.planes[2][i] = patch.z
        }
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        let out = FotufilmEngine(stock: stock, options: options).process(linearRGB: image)
        let centre = (size / 2) * size + size / 2
        return SIMD3(out.planes[0][centre], out.planes[1][centre],
                     out.planes[2][centre])
    }

    private func code(_ v: Float) -> Double {
        Double(ColorScience.linearToSrgb(ColorScience.displayShoulder(v)) * 255)
    }

    private func neutralMetrics(
        of stock: FilmStock
    ) -> (spread: Double, midGrey: Double) {
        var spread = 0.0
        for step in stride(from: Float(-3), through: 3, by: 0.5) {
            let value = 0.18 * pow(2, step)
            let out = render(SIMD3(value, value, value), stock: stock)
            let channels = [code(out.x), code(out.y), code(out.z)]
            spread = max(spread, channels.max()! - channels.min()!)
        }
        let grey = render(SIMD3(0.18, 0.18, 0.18), stock: stock)
        let midGrey = [grey.x, grey.y, grey.z]
            .map { Double(abs($0 - 0.18)) }.max()!
        return (spread, midGrey)
    }

    private func skyMetrics(of stock: FilmStock) -> (red: Double, step: Double) {
        // The physical sky blue the baseline has always measured, written down in the P3 era
        // and converted into the working basis — the colour, not the tuple.
        let chromaticity = ColorScience.linearDisplayP3ToRec2020(
            SIMD3<Float>(0.18, 0.40, 1.00))
        var red = 0.0
        var step = 0.0
        var previous: Double?
        for peak: Float in [0.90, 0.95, 1.00, 1.05, 1.10] {
            let rendered = render(chromaticity * peak, stock: stock)
            let redToBlue = Double(rendered.x / max(rendered.z, 1e-6))
            red = max(red, redToBlue)
            if let previous, previous > 0 {
                step = max(step, redToBlue / previous)
            }
            previous = redToBlue
        }
        return (red, step)
    }

    private func wedgeRatio(of stock: FilmStock) -> Double {
        let basis = SpectralRuntime.neutralDensityBasis(for: stock)
        var spread: Float = 0
        for logExposure in stride(from: Float(-1), through: 0.75, by: 0.025) {
            let density = (0..<3).map {
                stock.developedDensity(layer: $0, logExposure: logExposure)
            }
            let aligned = basis(density)
            spread = max(spread, aligned.max()! - aligned.min()!)
        }
        return Double(spread)
    }

    private func read() throws -> Baseline? {
        guard let data = try? Data(contentsOf: Self.baselineURL) else { return nil }
        return try JSONDecoder().decode(Baseline.self, from: data)
    }

    private func write(_ stocks: [String: Metrics]) throws {
        let baseline = Baseline(
            note: """
                Colour accuracy as measured when this file was last accepted. \
                Regenerate with FOTUFILM_ACCURACY_BASELINE=update and read the \
                diff: bandFloor rising is better, every other measure falling \
                is better. See AccuracyBaselineTests. The five motion-picture \
                negatives develop on VISION 2383 rather than RA-4 paper, \
                because their packs name it as their native print medium, and \
                their print-side measures sit higher for it. That is the \
                medium and not a regression: a release print is far steeper \
                than a sheet of paper and carries a fifth of its viewing \
                flare, so a neutral wedge spreads more at both ends. Printing \
                a still stock on 2383 raises its spread the same way, which is \
                what says this is the sheet rather than the pairing.
                """,
            stocks: stocks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(baseline).write(to: Self.baselineURL)
    }
}
