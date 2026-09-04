import Foundation
@testable import FotufilmCore

enum GranularityMeter {
    static let measuredFrameMM: Float = 1.6

    static func aperture(radiusPx: Float)
        -> (taps: [(dx: Int, dy: Int, weight: Float)], half: Int, total: Float) {
        let half = Int(radiusPx.rounded(.up)) + 1
        var taps: [(dx: Int, dy: Int, weight: Float)] = []
        var total: Float = 0
        for dy in -half...half {
            for dx in -half...half {
                var inside = 0
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let px = Float(dx) - 0.375 + Float(sx) * 0.25
                        let py = Float(dy) - 0.375 + Float(sy) * 0.25
                        if px * px + py * py <= radiusPx * radiusPx { inside += 1 }
                    }
                }
                guard inside > 0 else { continue }
                let weight = Float(inside) / 16
                taps.append((dx, dy, weight))
                total += weight
            }
        }
        return (taps, half, total)
    }

    static func ratios(_ stock: FilmStock, pxPerMM: Float, seed: UInt64,
                       model: GrainModel = .clumpField,
                       exposure: Float = 0.18) -> [Float] {
        let size = Int(measuredFrameMM * pxPerMM)
        var options = FotufilmEngine.Options()
        options.format = FilmFormat(name: "microdensitometer",
                                    frameHeightMM: measuredFrameMM)
        options.halationScale = 0
        options.couplerScale = 0
        options.seed = seed
        options.grainModel = model
        var image = ImageBuffer(width: size, height: size)
        for c in 0..<3 {
            for i in 0..<image.pixelCount { image.planes[c][i] = exposure }
        }
        let negative = FotufilmEngine(stock: stock, options: options)
            .developNegative(linearRGB: image)

        let (taps, half, total) = aperture(
            radiusPx: FilmStock.granularityApertureRadiusMM * pxPerMM)
        // Apertures a quarter of a radius apart. Closer spacing re-reads the same film rather
        // than adding independent apertures, and the answer is already set by how many of those
        // the measured frame holds.
        let stride = max(half / 2, 1)
        return (0..<3).map { plane in
            let values = negative.planes[plane]
            var readings: [Float] = []
            var cy = half
            while cy < size - half {
                var cx = half
                while cx < size - half {
                    var sum: Float = 0
                    for tap in taps {
                        sum += tap.weight * values[(cy + tap.dy) * size + cx + tap.dx]
                    }
                    readings.append(sum / total)
                    cx += stride
                }
                cy += stride
            }
            let mean = readings.reduce(0, +) / Float(readings.count)
            let variance = readings.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Float(readings.count)
            let curve = stock.curves[plane]
            // The developed density the modulation runs on: a reversal flips the formed
            // density before the grain stage, exactly as the engine does.
            let formed = curve.density(logExposure: log10(exposure / 0.18))
            let developed = stock.isReversal
                ? curve.dMin + curve.dMax - formed : formed
            // The sheet's read point, written out independently of the engine's helper:
            // net diffuse density 1.0 above base for a negative material, gross 1.0 for
            // a reversal, clamped the way a too-short curve must be.
            let range = curve.dMax - curve.dMin
            let net: Float = stock.isReversal ? 1 - curve.dMin : 1
            let anchorD = min(max(net, 0.05 * range), 0.9 * range)
                + stock.grainFogDensity
            let here = max(developed - curve.dMin, 0) + stock.grainFogDensity
            // Each model carries the published figure from the read density to this one its own
            // way, and both are written out here from the physics rather than called on the
            // engine, so the test can disagree with it.
            //
            // The clump field takes the emulsion's own granularity-against-density law. A
            // chromogenic negative's is measured — Kodak plots it for Vision3 250D and 500T —
            // and peaks just above D-min before falling; opaque silver's is the Boolean
            // aperture variance; a reversal, whose curve nobody publishes, keeps Selwyn's
            // `sigma ∝ sqrt(D)`. The disc path fluctuates covered *area* instead, and converts
            // with Nutting's derivative, so its shape is the model's own sigma times that gain,
            // both taken at the coverage the density implies.
            let aperture = FilmStock.granularityApertureRadiusMM
            let shape: Float
            switch model {
            case .clumpField:
                let profile = stock.grainDensityProfile
                func dyeCloudVariance(_ d: Float) -> Float {
                    (1 - exp(-d / profile[1])) * (1 + profile[0] * exp(-d / profile[2]))
                }
                func silverVariance(_ d: Float) -> Float {
                    d * pow(10, 0.21004 * d + 0.06114 * d * d)
                }
                switch stock.grainDensityLaw {
                case .dyeCloud:
                    shape = sqrt(dyeCloudVariance(here) / dyeCloudVariance(anchorD))
                case .silver:
                    shape = sqrt(silverVariance(here) / silverVariance(anchorD))
                case .dyeCloudSelwyn:
                    shape = sqrt(here / anchorD)
                }
            case .discs:
                let radius = stock.grainSizeMM * stock.grainLayerSizeRatio[plane]
                func coverage(_ d: Float) -> Float {
                    min(max(1 - pow(10, -max(d, 0)), 1e-4), 0.99)
                }
                func gain(_ a: Float) -> Float {
                    1 / (max(1 - a, 1e-2) * Float(log(10.0)))
                }
                let a = coverage(here), a0 = coverage(anchorD)
                shape = (BooleanGrain.granularity(radiusMM: radius, coverage: a,
                                                  apertureRadiusMM: aperture) * gain(a))
                    / (BooleanGrain.granularity(radiusMM: radius, coverage: a0,
                                                apertureRadiusMM: aperture) * gain(a0))
            }
            let stated = stock.grainStrength * stock.grainLayerWeights[plane] * shape
            return sqrt(variance) / stated
        }
    }

    static func ratio(_ stock: FilmStock, pxPerMM: Float = 500,
                      model: GrainModel = .clumpField,
                      exposure: Float = 0.18) -> Float {
        let seeds: [UInt64] = [0x46494C4D, 0xC0FFEE_1234_5678]
        let measured = seeds.flatMap {
            ratios(stock, pxPerMM: pxPerMM, seed: $0, model: model,
                   exposure: exposure)
        }
        return measured.reduce(0, +) / Float(measured.count)
    }

    static func latticeReadBias(_ stock: FilmStock, pxPerMM: Float) -> Float {
        let size = Int(measuredFrameMM * pxPerMM)
        var options = FotufilmEngine.Options()
        options.format = FilmFormat(name: "microdensitometer",
                                    frameHeightMM: measuredFrameMM)
        options.halationScale = 0
        options.couplerScale = 0
        let invocation = FilmEngineInvocation(stock: stock, options: options,
                                              width: size, height: size)
        let (taps, _, total) = aperture(
            radiusPx: FilmStock.granularityApertureRadiusMM * pxPerMM)
        var weights: [Int: Float] = [:]
        for tap in taps { weights[tap.dy * 4096 + tap.dx] = tap.weight }

        let biases = (0..<3).map { layer -> Float in
            let sigma = invocation.configuration[
                FilmEngineInvocation.grainSigmaLayerOffset + layer]
            let reach = max(FilmEngineInvocation.gaussianRadius(sigma), 1)
            var blur = (-reach...reach).map {
                exp(-Float($0 * $0) / (2 * sigma * sigma))
            }
            let blurSum = blur.reduce(0, +)
            blur = blur.map { $0 / blurSum }
            // The rendered field's covariance at integer lags, one axis.
            var covariance = [Float](repeating: 0, count: 2 * reach + 1)
            for lag in 0...(2 * reach) {
                for k in 0..<(blur.count - lag) {
                    covariance[lag] += blur[k] * blur[k + lag]
                }
            }
            // The aperture-weighted variance of that field: every pair of taps, joined by the
            // separable covariance at their offset.
            var read: Float = 0
            for dy in -(2 * reach)...(2 * reach) {
                for dx in -(2 * reach)...(2 * reach) {
                    var overlap: Float = 0
                    for tap in taps {
                        if let other = weights[(tap.dy + dy) * 4096 + tap.dx + dx] {
                            overlap += tap.weight * other
                        }
                    }
                    read += covariance[abs(dy)] * covariance[abs(dx)] * overlap
                }
            }
            // The amplitude the engine calibrated, taken off the configuration rather than
            // rebuilt: a silver stock's aperture correction is read at the Gaussian its render
            // stands in with, not at the emulsion's own clump, and only the configuration knows
            // which. Divided back out of the published figure, this is the white-noise limit
            // the layer was scaled against.
            let amplitude = invocation.configuration[
                FilmEngineInvocation.grainOffset + layer]
                / (stock.grainStrength * stock.grainLayerWeights[layer])
            return amplitude * read.squareRoot() / total
        }
        return biases.reduce(0, +) / 3
    }
}
