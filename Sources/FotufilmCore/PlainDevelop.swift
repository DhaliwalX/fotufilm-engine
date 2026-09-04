import Foundation

/// Film-free processing with exposure, white balance, local tone, chroma, and print-grade controls.
/// It omits spectral film exposure, characteristic curves, couplers, grain, halation, and paper.
public struct PlainDevelop {
    /// 2^EV, matching FOTUFILM_CONFIG_EXPOSURE_GAIN.
    let exposureGain: Float
    let balance: SIMD3<Float>
    let highlights: Float
    let shadows: Float
    let saturation: Float
    let vibrance: Float
    let grade: ColorGrade
    let gradeSpace: ColorGrade.Space
    let localTone: Bool

    /// Whether the tone and chroma controls would leave the scene exactly as they found it, which is
    /// the common case and skips both the metering and the masks.
    let isNeutral: Bool

    /// The solved tone grid, empty until `setToneBase` — and empty is the identity the kernel
    /// defaults to, where a pixel keys to its own stops rather than its region's.
    private var gridWidth = 0
    private var gridHeight = 0
    private var gridA: [Float] = []
    private var gridB: [Float] = []
    /// The frame the grid's cells divide, which is what places a pixel in them.
    private var frameWidth: Float = 1
    private var frameHeight: Float = 1

    public init(options: FotufilmEngine.Options) {
        exposureGain = exp2(options.exposureEV)
        let gains = options.whiteBalance.gains
        balance = SIMD3(gains.r, gains.g, gains.b)
        // A source that declares recorded light above diffuse white gets the same highlight
        // shaping the film path stacks in (`FilmEngine`'s configuration) — here fitted to the
        // only window this path has, the SDR ceiling at diffuse white, since with nothing
        // loaded there is no emulsion latitude to absorb the range first.
        var shapedHighlights = options.highlights
        if options.sceneHeadroom > 1 {
            shapedHighlights = max(-1, min(1, shapedHighlights
                + AutoAdjustment.headroomHighlights(
                    contentHeadroom: options.sceneHeadroom,
                    window: (shadows: 0,
                             highlights: AutoAdjustment.kDiffuseWhiteStops))))
        }
        highlights = shapedHighlights
        shadows = options.shadows
        saturation = options.saturation
        vibrance = options.vibrance
        grade = options.grade
        gradeSpace = options.gradeSpace
        localTone = options.localTone
        isNeutral = highlights == 0 && shadows == 0
            && saturation == 1 && vibrance == 0
    }

    /// Whether the local masks are doing anything, and so whether the frame needs the whole-frame
    /// prepass before any row of it can be developed.
    public var needsToneBase: Bool {
        localTone && (highlights != 0 || shadows != 0)
    }

    /// An accumulator sized and weighted for this frame, white balance and exposure — the same one
    /// the film path measures into.
    public func toneBaseMeasurement(frameWidth: Int,
                                    frameHeight: Int) -> ToneBaseMeasurement {
        ToneBaseMeasurement(frameWidth: frameWidth, frameHeight: frameHeight,
                            balance: balance, exposureGain: exposureGain)
    }

    /// Solves the accumulated measurement and keys the masks to it.
    public mutating func setToneBase(_ measurement: ToneBaseMeasurement) {
        let (a, b) = measurement.solvedCoefficients()
        gridWidth = measurement.gridWidth
        gridHeight = measurement.gridHeight
        gridA = a
        gridB = b
        frameWidth = Float(max(measurement.frameWidth, 1))
        frameHeight = Float(max(measurement.frameHeight, 1))
    }

    /// Develops interleaved scene-linear RGBA rows in place, `pixels` pointing at the first of
    /// `rows` and `rows` counted in the whole frame so the masks land where they were measured.
    /// Alpha is left alone for the output encoder.
    public func apply(linearRGBA pixels: UnsafeMutableBufferPointer<Float>,
                      rows: Range<Int>, width: Int) {
        guard width > 0, !rows.isEmpty, let base = pixels.baseAddress,
              pixels.count >= rows.count * width * 4 else { return }
        let gain = exposureGain
        let balance = self.balance
        let grade = self.grade
        let space = gradeSpace
        let flat = grade.isNeutral

        /// Exposure, the step into the delivery basis, and the grade — everything that happens
        /// to every balanced pixel whether or not the tone and chroma controls are doing
        /// anything. The white balance has already gone on: the caller hands over the adapted
        /// scene, so the tone and chroma controls read the same light this does, as the film
        /// path's kernel has it. The scene half works in linear Rec.2020; the film path's paper
        /// integrates its dyes straight to Display P3, so with no paper in the way the same
        /// re-expression happens here as a matrix, and the grade then means what it means on
        /// the film path: an operation on delivery-basis values.
        func printed(_ balanced: SIMD3<Float>) -> SIMD3<Float> {
            let lit = ColorScience.linearRec2020ToDisplayP3(balanced * gain)
            return flat ? lit : grade.apply(lit, in: space)
        }

        func write(_ value: SIMD3<Float>, at index: Int) {
            base[index] = value.x
            base[index + 1] = value.y
            base[index + 2] = value.z
        }

        if isNeutral {
            DispatchQueue.concurrentPerform(iterations: rows.count) { row in
                let start = row * width * 4
                for index in stride(from: start, to: start + width * 4, by: 4) {
                    // Out-of-gamut components stay: the grade is a bijection over the
                    // whole line, and the delivery encoder owns the clip, exactly as the
                    // film path clamps only at the exposure domain's physical-light boundary.
                    write(printed(SIMD3(base[index],
                                        base[index + 1],
                                        base[index + 2]) * balance),
                          at: index)
                }
            }
            return
        }

        let luma = ColorScience.luminanceWeights
        /// The metering gain the tone grid was measured through: mid-grey lands on 0 stops.
        let meterGain = gain / 0.18
        let highlights = self.highlights, shadows = self.shadows
        let saturation = self.saturation, vibrance = self.vibrance
        let key = toneKey()

        DispatchQueue.concurrentPerform(iterations: rows.count) { row in
            let y = rows.lowerBound + row
            let start = row * width * 4
            for x in 0..<width {
                let index = start + x * 4
                let r0 = base[index] * balance.x
                let g0 = base[index + 1] * balance.y
                let b0 = base[index + 2] * balance.z
                let metered = (luma.0 * r0 + luma.1 * g0 + luma.2 * b0) * meterGain
                let keyed = key(log2(max(metered, 1e-6)), x, y)
                let high = min(max(keyed * (1.0 / 6.0), 0), 1)
                let low = min(max(-keyed * (1.0 / 6.0), 0), 1)
                let highMask = high * high * (3 - 2 * high)
                let lowMask = low * low * (3 - 2 * low)
                let toneGain = exp2(3 * (highlights * highMask
                                         + shadows * lowMask))
                let r1 = r0 * toneGain, g1 = g0 * toneGain, b1 = b0 * toneGain
                let luma1 = luma.0 * r1 + luma.1 * g1 + luma.2 * b1
                let peak = max(r1, max(g1, b1))
                let colourfulness = (peak - min(r1, min(g1, b1)))
                    / max(peak, 1e-6)
                let chroma = saturation * (1 + vibrance * (1 - colourfulness))
                write(printed(SIMD3(luma1 + chroma * (r1 - luma1),
                                    luma1 + chroma * (g1 - luma1),
                                    luma1 + chroma * (b1 - luma1))),
                      at: index)
            }
        }
    }

    /// What a pixel's tone masks key to: its region's stops where a grid has been solved, its own
    /// otherwise. Bilinear over the grid, matching the kernel's sampling cell for cell.
    private func toneKey() -> (Float, Int, Int) -> Float {
        guard gridWidth > 0, gridHeight > 0,
              gridA.count >= gridWidth * gridHeight,
              gridB.count >= gridWidth * gridHeight else {
            return { stops, _, _ in stops }
        }
        let (gw, gh) = (gridWidth, gridHeight)
        let (a, b) = (gridA, gridB)
        let (fw, fh) = (frameWidth, frameHeight)
        return { stops, x, y in
            let gx = min(max((Float(x) + 0.5) * Float(gw) / fw - 0.5, 0),
                         Float(gw - 1))
            let gy = min(max((Float(y) + 0.5) * Float(gh) / fh - 0.5, 0),
                         Float(gh - 1))
            let x0 = min(max(Int(gx), 0), max(gw - 2, 0))
            let y0 = min(max(Int(gy), 0), max(gh - 2, 0))
            let x1 = min(x0 + 1, gw - 1)
            let y1 = min(y0 + 1, gh - 1)
            let fx = min(max(gx - Float(x0), 0), 1)
            let fy = min(max(gy - Float(y0), 0), 1)
            func bilinear(_ plane: [Float]) -> Float {
                let top = (1 - fx) * plane[y0 * gw + x0] + fx * plane[y0 * gw + x1]
                let bottom = (1 - fx) * plane[y1 * gw + x0] + fx * plane[y1 * gw + x1]
                return (1 - fy) * top + fy * bottom
            }
            return bilinear(a) * stops + bilinear(b)
        }
    }

    /// Stops from metered mid-grey to display white and the darkest distinct 8-bit sRGB value.
    /// Without a film toe or shoulder, automatic adjustment protects highlights but does not lift
    /// shadows.
    public static let latitude: (shadows: Float, highlights: Float) = (
        shadows: log2(max(ColorScience.srgbToLinear(0.5 / 255), 1e-9) / 0.18),
        highlights: log2(1 / 0.18)
    )
}
