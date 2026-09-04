#if canImport(Metal)
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Builds the immutable developed-density to display-linear response used by the handwritten
/// Metal frame graphs.
///
/// This is preparation work, not a frame renderer. It evaluates the same data-driven spectral
/// LUTs, paper curves, monochrome conversion, and colour grade as the exact endpoint, directly
/// from `FilmEngineInvocation`. Keeping the bake here removes the former call into a Halide Metal
/// schedule while leaving Halide available as an offline differential-test oracle.
enum HandwrittenPrintResponseBaker {
    private static let curveSamples = 2_048
    // Green retains the original packed-configuration slots. Red and blue are append-only fields
    // exposed by FilmEngineInvocation.
    private static let paperGreenOffset = 33
    private static let maskingOffset = 39
    private static let paperMidpointGreenOffset = 62

    /// Returns an RGBA Float32 cube in Metal's native X-fastest order. RGB is the complete
    /// developed-density to display-linear response; alpha is one. `warpKnots`, when supplied,
    /// contains the three axis warps as `(segments + 1)` knots per channel.
    static func linearCubeValues(
        invocation: FilmEngineInvocation, edge: Int,
        warpKnots: [Float]? = nil
    ) -> [Float]? {
        guard edge >= 2,
              invocation.configuration.count == FilmEngineInvocation.configurationCount,
              invocation.spectral.filmOutput.dimension >= 2,
              invocation.spectral.filmOutput.values.allSatisfy(\.isFinite)
        else { return nil }

        let segments: Int
        if let warpKnots {
            guard warpKnots.count >= 6, warpKnots.count.isMultiple(of: 3) else {
                return nil
            }
            segments = warpKnots.count / 3 - 1
            guard segments >= 1,
                  warpKnots.allSatisfy(\.isFinite),
                  (0..<3).allSatisfy({ channel in
                      let base = channel * (segments + 1)
                      return warpKnots[base] == 0
                          && warpKnots[base + segments] == 1
                          && (0..<segments).allSatisfy {
                              warpKnots[base + $0] <= warpKnots[base + $0 + 1]
                          }
                  })
            else { return nil }
        } else {
            segments = 0
        }

        let configuration = invocation.configuration
        let reversal = invocation.featureMask & FilmEngineFeature.reversal != 0
        let monochrome = invocation.featureMask & FilmEngineFeature.monochrome != 0
        let paper = reversal ? nil : invocation.spectral.paperOutput
        if !reversal {
            guard let paper, paper.dimension >= 2,
                  paper.values.allSatisfy(\.isFinite) else { return nil }
        }

        let paperBases = [
            FilmEngineInvocation.paperRedOffset,
            Self.paperGreenOffset,
            FilmEngineInvocation.paperBlueOffset,
        ]
        let paperMidpoints = [
            FilmEngineInvocation.paperMidpointRedOffset,
            Self.paperMidpointGreenOffset,
            FilmEngineInvocation.paperMidpointBlueOffset,
        ]
        var paperCurves = [[Float]]()
        if !reversal {
            paperCurves.reserveCapacity(3)
            for base in paperBases {
                var curve = [Float](repeating: 0, count: Self.curveSamples)
                for sample in curve.indices {
                    let exposure = -8
                        + 16 * Float(sample) / Float(Self.curveSamples - 1)
                    let value = curveDensity(
                        configuration, base: base, exposure: exposure)
                    guard value.isFinite else { return nil }
                    curve[sample] = value
                }
                paperCurves.append(curve)
            }
        }

        let gradeBase = FilmEngineInvocation.gradeOffset
        let gradeLift = SIMD3<Float>(
            configuration[gradeBase], configuration[gradeBase + 1],
            configuration[gradeBase + 2])
        let gradeGain = SIMD3<Float>(
            configuration[gradeBase + 3], configuration[gradeBase + 4],
            configuration[gradeBase + 5])
        let gradeExponent = SIMD3<Float>(
            configuration[gradeBase + 6], configuration[gradeBase + 7],
            configuration[gradeBase + 8])
        let gradeActive = gradeLift != .zero
            || gradeGain != SIMD3<Float>(repeating: 1)
            || gradeExponent != SIMD3<Float>(repeating: 1)
        let encodedGrade = configuration[FilmEngineInvocation.gradeSpaceOffset] != 0

        let pixelCount = edge * edge * edge
        var result = [Float](repeating: 0, count: pixelCount * 4)
        let inverseEdge = 1 / Float(edge - 1)
        let filmTable = invocation.spectral.filmOutput

        @inline(__always)
        func axisCoordinate(_ grid: Float, channel: Int) -> Float {
            guard let warpKnots else { return grid }
            let q = min(max(grid, 0), 1) * Float(segments)
            let segment = min(Int(q), segments - 1)
            let fraction = q - Float(segment)
            let base = channel * (segments + 1)
            return warpKnots[base + segment]
                + fraction * (warpKnots[base + segment + 1]
                              - warpKnots[base + segment])
        }

        func fill(
            filmValues: UnsafePointer<Float>,
            paperValues: UnsafePointer<Float>?, paperDimension: Int
        ) -> Bool {
            for blue in 0..<edge {
                for green in 0..<edge {
                    for red in 0..<edge {
                        let unit = SIMD3<Float>(
                            axisCoordinate(Float(red) * inverseEdge, channel: 0),
                            axisCoordinate(Float(green) * inverseEdge, channel: 1),
                            axisCoordinate(Float(blue) * inverseEdge, channel: 2))
                        let relative = SpectralLUT.sample(
                            unit, values: filmValues,
                            dimension: filmTable.dimension)
                        var printed = relative
                        if !reversal {
                            guard let paperValues else { return false }
                            var paperActivation = SIMD3<Float>.zero
                            for channel in 0..<3 {
                                let base = paperBases[channel]
                                let exposure = configuration[paperMidpoints[channel]]
                                    + configuration[Self.maskingOffset + channel]
                                        * relative[channel]
                                let density = sampleCurve(
                                    paperCurves[channel], exposure: exposure)
                                let range = configuration[base + 1]
                                    * (configuration[base + 4]
                                       - configuration[base + 2])
                                guard range.isFinite, range > 0 else { return false }
                                paperActivation[channel] =
                                    (density - configuration[base]) / range
                            }
                            printed = SpectralLUT.sample(
                                paperActivation, values: paperValues,
                                dimension: paperDimension)
                        }
                        if monochrome {
                            printed = SIMD3(repeating:
                                (printed.x + printed.y + printed.z) / 3)
                        }
                        if gradeActive {
                            for channel in 0..<3 {
                                let working = encodedGrade
                                    ? ColorScience.gradingEncode(printed[channel])
                                    : printed[channel]
                                let lifted = working
                                    * (gradeGain[channel] - gradeLift[channel])
                                    + gradeLift[channel]
                                let graded = gradeExponent[channel] == 1
                                    ? lifted
                                    : pow(max(lifted, 0), gradeExponent[channel])
                                printed[channel] = encodedGrade
                                    ? ColorScience.gradingDecode(graded) : graded
                            }
                        }
                        guard printed.x.isFinite, printed.y.isFinite,
                              printed.z.isFinite else { return false }
                        let index = ((blue * edge + green) * edge + red) * 4
                        result[index] = max(printed.x, 0)
                        result[index + 1] = max(printed.y, 0)
                        result[index + 2] = max(printed.z, 0)
                        result[index + 3] = 1
                    }
                }
            }
            return true
        }

        let completed = filmTable.values.withUnsafeBufferPointer { filmValues in
            guard let filmBase = filmValues.baseAddress else { return false }
            guard let paper else {
                return fill(
                    filmValues: filmBase, paperValues: nil,
                    paperDimension: 0)
            }
            return paper.values.withUnsafeBufferPointer { paperValues in
                guard let paperBase = paperValues.baseAddress else { return false }
                return fill(
                    filmValues: filmBase, paperValues: paperBase,
                    paperDimension: paper.dimension)
            }
        }
        return completed ? result : nil
    }

    static func filmCurveRange(
        configuration: [Float], channel: Int
    ) -> Float {
        let primary = channel * 6
        let secondary = FilmEngineInvocation.curveSecondaryOffset + channel * 5
        return configuration[primary + 1]
            * (configuration[primary + 4] - configuration[primary + 2])
            + configuration[secondary]
            * (configuration[secondary + 3] - configuration[secondary + 1])
    }

    private static func curveDensity(
        _ configuration: [Float], base: Int, exposure: Float
    ) -> Float {
        let dMin = configuration[base]
        let gamma = configuration[base + 1]
        let toe = configuration[base + 2]
        let toeWidth = max(configuration[base + 3], 1e-6)
        let shoulder = configuration[base + 4]
        let shoulderWidth = max(configuration[base + 5], 1e-6)
        let toeTerm = toeWidth * softplus((exposure - toe) / toeWidth)
        let shoulderTerm = shoulderWidth
            * softplus((exposure - shoulder) / shoulderWidth)
        return dMin + gamma * min(max(toeTerm - shoulderTerm, 0), shoulder - toe)
    }

    private static func softplus(_ value: Float) -> Float {
        if value > 20 { return value }
        if value < -20 { return exp(value) }
        return log1p(exp(value))
    }

    private static func sampleCurve(_ values: [Float], exposure: Float) -> Float {
        let q = min(max(
            (exposure + 8) * (Float(curveSamples - 1) / 16), 0),
            Float(curveSamples - 1))
        let index = min(Int(q), curveSamples - 2)
        return values[index]
            + (q - Float(index)) * (values[index + 1] - values[index])
    }
}
#endif
