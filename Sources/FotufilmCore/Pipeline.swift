import Foundation

/// The film simulation pipeline.
public struct FotufilmEngine {
    /// Whether the Halide engine was linked into this build.
    public static var isHalideBackendAvailable: Bool { HalideBackend.isAvailable }

    public struct Options: Sendable {
        /// Exposure compensation in stops (applied to the camera exposure).
        public var exposureEV: Float = 0
        /// Source range above diffuse white as a linear multiple. One is SDR identity. HDR values
        /// drive `AutoAdjustment.headroomHighlights` to fit declared range into measured latitude.
        public var sceneHeadroom: Float = 1
        /// The illuminant the scene was lit by.
        public var whiteBalance: WhiteBalance = .neutral
        /// Scene-referred highlight shaping, -1...1: an exposure shift of up to 3 EV that fades in
        /// over the six stops above mid-grey, applied before the film model so the emulsion sees
        /// the adjusted light.
        public var highlights: Float = 0
        /// Scene-referred shadow shaping, -1...1: the same shift fading in
        /// below mid-grey, keyed the same regional way.
        public var shadows: Float = 0
        /// Whether the highlight/shadow shifts key to the regional base above.
        public var localTone: Bool = true
        /// Chroma multiplier about each pixel's own luminance; 1 is untouched
        /// and 0 renders the scene achromatic before the film responds.
        public var saturation: Float = 1
        /// Signed chroma boost weighted toward the least colourful pixels,
        /// -1...1; already-vivid colours are left alone.
        public var vibrance: Float = 0
        /// Multiplier on the stock's grain strength (0 disables grain).
        public var grainScale: Float = 1
        /// Override of the stock's grain-size mixture: the fraction of the published
        /// granularity's variance carried by the coarse mottle field
        /// (`FilmStock.grainMottleShare`), 0...0.9. The published RMS stays the anchor
        /// whatever the split — the two components divide its variance, each corrected
        /// through the 48 µm aperture at its own size. nil — the default — renders the
        /// stock's own value, and a stock that says nothing is the single-radius field
        /// bit-identically.
        public var grainMottleShare: Float? = nil
        /// Coarse-population clump radius as a multiple of `grainSizeMM`, clamped to 1...8.
        /// Each component remains corrected against the 48 µm aperture. Nil uses the stock value.
        public var grainMottleSizeRatio: Float? = nil
        /// How coarse an explicitly requested mottle population lands on a
        /// delivery lattice, as a multiple of the emulsion's clump radius. A
        /// sheet-ratio clump sits under a pixel at video sizes, where neither
        /// the frame nor its encoder can hold it.
        public static let deliveryMottleSizeRatio: Float = 8
        /// Applies `deliveryMottleSizeRatio` when a mixture share is explicit but its size is not.
        /// Nil share leaves both settings unchanged.
        public mutating func completeDeliveryMottle() {
            guard grainMottleShare != nil else { return }
            grainMottleSizeRatio =
                grainMottleSizeRatio ?? Self.deliveryMottleSizeRatio
        }
        /// Which model develops the grain.
        public var grainModel: GrainModel = .clumpField
        /// Multiplier on the fraction of light the base returns (0 disables halation).
        public var halationScale: Float = 1
        /// How much the halo keeps the source's own colour instead of the stock's layered
        /// red, 0…1. The returning light re-enters the emulsion from below, so the bottom
        /// (red) record takes nearly all of it and a colour film's ring is red whatever the
        /// light was. At 1 the dimmer records are raised to the strongest record's return —
        /// the scattered light then carries the source's own balance, a pronounced ring the
        /// colour of the light. A look choice, not a stock property: 0 is the film.
        public var halationSourceColour: Float = 0
        /// Per-wavelength gain on the 41-band halation return spectrum. Empty preserves the stock
        /// spectrum. The engine reduces the curve through each record's sensitivity;
        /// `halationSourceColour` and `halationScale` apply separately.
        public var halationReturnGain: [Float] = []
        /// Override of the stock's `halationHazeMM` — the support's impurity scatter, as a
        /// Gaussian sigma in millimeters softening the halo's edges. `nil` — the default —
        /// renders the sheet's own figure.
        public var halationHazeMM: Float? = nil
        /// Uses a provisional spatial profile when no independently calibrated profile exists.
        public var useEstimatedHalationProfile: Bool = false
        /// Multiplier on taking-lens veiling glare. The default is 0 because photographic inputs
        /// already include lens glare. Enable it for synthetic light or to model additional glare
        /// relative to the capture lens.
        public var flareScale: Float = 0
        /// Strength of DIR coupler inhibition (0 disables inter-image effects, 1 is the calibrated
        /// stock). Creative overdrive above 1 is compressed so the 2 endpoint applies 1.5 physical
        /// doses rather than letting spatial inhibition grow without bound.
        public var couplerScale: Float = 1
        /// Multiplier on how far the released inhibitor reaches through the layer stack, applied to
        /// every interlayer alike (`CouplerGeometry.interlayerTransmission`). 0 seals the layers off
        /// from each other; above 1 crosses more.
        public var couplerRangeScale: Float = 1
        /// The same reach, set per interlayer instead of together: index 0 is the red–green
        /// scavenger interlayer and index 1 the green–blue yellow filter layer. `nil` — the default
        /// — applies `couplerRangeScale` to both, which is exactly what a single reach has always
        /// done, at every setting and not merely at 1.
        public var couplerGapReachScales: [Float]?
        /// Multiplier on the retained self-inhibition
        /// (`CouplerGeometry.selfRetention`), the matrix diagonal.
        public var couplerSelfScale: Float = 1
        /// Years the roll sat past its process-by date at room temperature, 0 up. Drives
        /// the age transform (`FilmStock.expired(years:)`): the lab's one-stop-per-decade
        /// speed loss with the blue-sensitive layer going first, base fog rising in
        /// proportion, and grain up with the fog that causes it. The print re-times
        /// through the risen base, so the mid corrects and the crossed, muddy toe is what
        /// shows — shoot it with the same extra stop the lab rule asks for and the look
        /// is the shadows', not the whole frame's. 0 — the default — is the fresh roll,
        /// bit-identically.
        public var expiredYears: Float = 0
        /// Shutter duration in seconds from capture metadata or manual input. Beyond the stock's
        /// reciprocity threshold, per-layer exposure and print-timing corrections are bounded by
        /// the last measured table entry. Nil, in-range values, and stocks without reciprocity data
        /// leave rendering bit-identical.
        public var shutterSeconds: Float? = nil
        /// Stops of push (positive) or pull (negative) development, the instruction on the
        /// film can's sticker. Non-zero values must name an exact measured condition in the
        /// stock's `developmentProfile`; arbitrary values and stocks without a measured family
        /// are rejected rather than receiving a generic contrast/fog/grain transform. Pair a push
        /// with the underexposure it was bought for (`exposureEV`). 0 — the default — is the
        /// stock pack's reference development, bit-identically.
        public var developmentEV: Float = 0
        /// How much of the developed silver the bleach leaves in the negative, 0...1. The bleach's
        /// whole job is to take the metallic silver back out once the dyes are formed; skipping it
        /// — the lab service behind the bleach-bypass look — leaves a black-and-white image
        /// superimposed on the colour one. The retained silver is spectrally flat, so the print
        /// gains contrast and loses chroma together, and the print exposure re-anchors on the
        /// denser mid-grey exactly as a lab re-times a skip-bleach negative. 0 — the default and
        /// the fully bleached C-41 every existing render is — changes nothing. Monochrome stocks
        /// ignore it (their image *is* the silver), as does a reversal stock's direct positive.
        public var bleachBypass: Float = 0
        /// Optional *additional* correction of film channel-contrast mismatch.
        public var printCorrection: Float = 0.05
        /// Where the developed image is finished. `nil` — the default — takes the medium the
        /// loaded stock was designed for, so a motion-picture camera negative reaches its release
        /// print stock and a still negative reaches the measured sheet, without the caller naming
        /// either. A stated medium, including the developed negative itself, is honoured for any
        /// stock that can reach it.
        ///
        /// Read it through `paper(for:)`; the stored value is the request, not the answer.
        public var paper: PrintPaper? = nil
        /// The lamp a physical print is viewed under, as a correlated colour temperature in
        /// kelvin: the CIE daylight series from 4000 K up (5003 is D50), and the Planckian
        /// radiator below it (2856 is CIE A). Bradford adaptation carries the lamp white to the
        /// D65 display while retaining dye metamerism. nil uses the medium's calibrated reference:
        /// D50 for reflection paper and 5400 K filtered xenon for a cinema print. Scans, screen
        /// output, viewed negatives, and reversal stocks ignore this value.
        public var printViewingKelvin: Float? = nil
        /// The grade laid over the finished image — lift, gamma and gain by band.
        public var grade: ColorGrade = .neutral
        /// Which signal that grade works on. `.linear` is what this engine has always done and stays
        /// the default, because switching re-grades every picture carrying a non-neutral grade — the
        /// highlight band most of all, whose gain opens the whole midrange once it is spent on the
        /// encoded signal. `.encoded` is where a grading suite's three-way corrector works. A
        /// neutral grade is the identity either way.
        public var gradeSpace: ColorGrade.Space = .linear
        /// Film gauge the frame is exposed on.
        public var format: FilmFormat = .still35
        /// Fraction of the film frame's short edge the rendered image spans, 0...1. Cropping
        /// throws film away and enlarges the rest, so a cropped picture holds more pixels per
        /// millimetre of emulsion than the full frame at the same output size — grain, MTF,
        /// halation, adjacency and coupler diffusion all scale with it. 1 — the default, and
        /// every uncropped render — is the whole frame, bit-identically.
        public var frameCoverage: Float = 1
        /// Seed for the grain generator; same seed + input = same grain.
        public var seed: UInt64 = 0x46494C4D
        /// Show the developed negative rather than the positive medium it would otherwise make.
        /// This also selects the appearance of the `.negative` output medium; when that medium is
        /// chosen and this value is nil, the engine uses `.lightBox`.
        public var negativeViewing: NegativeViewing? = nil
        /// Which span of the pipeline this render performs. `.full` — the default — is scene
        /// light in and a finished image out, and is what every render did before the seam had a
        /// name. The other three cut the pipeline at the density boundary the engine has always
        /// had; see `PipelineStage` and `NegativeInterchange` for what crosses it.
        ///
        /// A stage is not a look: nothing here selects different physics, only which of the
        /// stock's own stages this particular render runs.
        public var stage: PipelineStage = .full
        /// Which spatial stages `stage == .texture` lays over the frame. Ignored by every other
        /// stage, where the selection is the ordinary strength levers.
        public var textureStages: TextureStages = .all
        /// The scene's correlated colour temperature in kelvin, when the source states one —
        /// the film-side half of the physical-light system. A warm temperature swaps the
        /// spectral exposure table for one integrated against the exact CIE-locus SPD
        /// (`SpectralRuntime.sceneExposure`), retaining both film colour balance and metamerism.
        /// nil — the default for a source without capture metadata — uses the loaded stock's fixed
        /// `referenceIlluminantKelvin` as both the assumed scene light and exposure reference.
        /// An explicit scene light changes only the numerator; film balance remains fixed stock data.
        public var sceneIlluminantKelvin: Float? = nil
        /// An explicit spectral power distribution on `SpectralGrid` (380...780 nm, 10 nm steps).
        /// This takes precedence over CCT and allows fluorescent, LED, and measured sources whose
        /// spectra cannot be recovered from chromaticity. Empty uses `sceneIlluminantKelvin`.
        public var sceneIlluminantSpectrum: [Float] = []
        /// What is screwed onto the front of the lens, and how the exposure was set with it
        /// there. A filter is the one accessory that sits ahead of the whole engine, so it
        /// reaches only two things: the light the emulsion integrates — spectrally, against the
        /// stock's own three sensitivities, which is why the same filter behaves differently on
        /// a tungsten stock and a daylight one — and the lens's veiling glare, which every extra
        /// air-glass surface adds to. Empty, the default, changes nothing at all: no filter is
        /// not a clear filter, and a clear filter still costs light and still makes a ghost.
        public var lensFilters: LensFilterStack = .none
        /// A diffusion filter on the front of the lens — mist, fog, black mist, glimmer.
        ///
        /// Physically the glass is ahead of the emulsion: a
        /// share of the scene's light meets a particle and leaves in a new direction, and the
        /// lens images it somewhere else on the frame. The share that missed every particle is
        /// untouched, which is why a diffused picture keeps its edges instead of going soft.
        /// The engine convolves after spectral integration because both operations are linear and
        /// commute; that lets each film record use the kernel fitted to its sensitivity instead of
        /// assigning film wavelengths to RGB working-space primaries. nil is no filter.
        public var diffusionFilter: DiffusionFilter? = nil
        /// The lens's focal length in millimetres, when the source states one.
        ///
        /// Read only by the diffusion filter, which needs it because a ray deviated by an angle
        /// ahead of the lens lands `focal length × angle` off its unscattered position — so the
        /// same filter glows bigger on a long lens, exactly as it does in the world. nil falls
        /// back to the gauge's own normal lens (`FilmFormat.normalFocalLengthMM`), which is what
        /// the grade numbering on a filter's ring is calibrated around.
        public var focalLengthMM: Float? = nil

        public init() {}

        /// The medium this stock actually develops onto under these options: the stated request
        /// where the stock can reach it, the stock's own native medium where nothing was stated,
        /// and the only medium it can reach where neither applies.
        public func paper(for stock: FilmStock) -> PrintPaper {
            paper?.resolved(for: stock) ?? PrintPaper.default(for: stock)
        }
    }

    public var stock: FilmStock
    public var options: Options

    public init(stock: FilmStock, options: Options = Options()) {
        self.stock = stock
        self.options = options
    }

    /// Scene-linear RGB in, display-linear RGB out — at `options.stage == .full`, which is the
    /// default and what this has always done. Another span reads and writes what
    /// `PipelineStage` says it does: `.negative` returns the developed negative's densities,
    /// `.print` is handed them, and `.texture` returns the frame it was given.
    public func process(linearRGB image: ImageBuffer) -> ImageBuffer {
        guard let positive = HalideBackend.process(image: image, stock: stock,
                                                   options: options) else {
            fatalError(Self.missingEngineMessage)
        }
        return positive
    }

    /// Convenience: 8-bit sRGB interleaved RGB(A) in, same format out.
    public func processSRGB8(_ pixels: [UInt8], width: Int, height: Int, bytesPerPixel: Int = 4) -> [UInt8] {
        precondition(pixels.count >= width * height * bytesPerPixel)
        var linear = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) {
            let alpha = bytesPerPixel >= 4 ? pixels[i * bytesPerPixel + 3] : 255
            let unpremultiply = alpha > 0 && alpha < 255 ? 255 / Float(alpha) : 1
            let srgb = SIMD3<Float>(
                ColorScience.srgbToLinear(
                    min(Float(pixels[i * bytesPerPixel]) / 255 * unpremultiply, 1)),
                ColorScience.srgbToLinear(
                    min(Float(pixels[i * bytesPerPixel + 1]) / 255 * unpremultiply, 1)),
                ColorScience.srgbToLinear(
                    min(Float(pixels[i * bytesPerPixel + 2]) / 255 * unpremultiply, 1)))
            let working = ColorScience.linearSRGBToRec2020(srgb)
            for c in 0..<3 { linear.planes[c][i] = working[c] }
        }
        let out = process(linearRGB: linear)
        var result = pixels
        let ditherSeed = UInt32(truncatingIfNeeded: options.seed)
        let shoulderKnee = FilmSDRDelivery.shoulderKnee(
            isReversal: stock.isReversal)
        for i in 0..<(width * height) {
            let displayP3 = SIMD3<Float>(
                ColorScience.displayShoulder(out.planes[0][i], knee: shoulderKnee),
                ColorScience.displayShoulder(out.planes[1][i], knee: shoulderKnee),
                ColorScience.displayShoulder(out.planes[2][i], knee: shoulderKnee))
            let srgb = ColorScience.linearDisplayP3ToSRGB(displayP3)
            for c in 0..<3 {
                let v = ColorScience.linearToSrgb(clamp(srgb[c], 0, 1))
                let dither = triangularDither(index: UInt32(i), channel: UInt32(c), seed: ditherSeed)
                result[i * bytesPerPixel + c] = UInt8(clamp(v * 255 + 0.5 + dither, 0, 255))
            }
        }
        return result
    }

    /// Convenience: 8-bit Display P3 interleaved RGB(A) in — P3 primaries under the sRGB
    /// transfer, an Android or Apple "Display P3" bitmap — and the same format out. Ingest
    /// steps the decoded P3 into the Rec.2020 working space; the developed print is already
    /// Display P3, so the way out is transfer-encoding alone, with no change of primaries.
    public func processDisplayP38(_ pixels: [UInt8], width: Int, height: Int,
                                  bytesPerPixel: Int = 4) -> [UInt8] {
        precondition(pixels.count >= width * height * bytesPerPixel)
        var timing = StageTiming()
        let count = width * height
        var red = [Float](repeating: 0, count: count)
        var green = red
        var blue = red
        // Both walks either side of the engine are per-pixel and independent, and on a phone they
        // were a third of a twelve-megapixel still between them — two transfer functions over
        // seventy-two million channels, on one core. They are the same arithmetic here, taken a
        // row at a time across the cores the frame is already going to use.
        pixels.withUnsafeBufferPointer { source in
            red.withUnsafeMutableBufferPointer { red in
                green.withUnsafeMutableBufferPointer { green in
                    blue.withUnsafeMutableBufferPointer { blue in
                        let bytes = source.baseAddress!
                        let r = red.baseAddress!, g = green.baseAddress!
                        let b = blue.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: height) { y in
                            let row = y * width
                            for x in 0..<width {
                                let i = row + x
                                let base = i * bytesPerPixel
                                let alpha = bytesPerPixel >= 4 ? bytes[base + 3] : 255
                                var p3: SIMD3<Float>
                                if alpha == 0 || alpha == 255 {
                                    // Nothing to undo, so the byte is the whole argument and the
                                    // transfer has only 256 answers. The table is those answers,
                                    // not an approximation of them.
                                    p3 = SIMD3(srgbDecodedByte[Int(bytes[base])],
                                               srgbDecodedByte[Int(bytes[base + 1])],
                                               srgbDecodedByte[Int(bytes[base + 2])])
                                } else {
                                    let unpremultiply = 255 / Float(alpha)
                                    p3 = SIMD3(
                                        ColorScience.srgbToLinear(
                                            min(Float(bytes[base]) / 255 * unpremultiply, 1)),
                                        ColorScience.srgbToLinear(
                                            min(Float(bytes[base + 1]) / 255 * unpremultiply, 1)),
                                        ColorScience.srgbToLinear(
                                            min(Float(bytes[base + 2]) / 255 * unpremultiply, 1)))
                                }
                                let working = ColorScience.linearDisplayP3ToRec2020(p3)
                                r[i] = working[0]
                                g[i] = working[1]
                                b[i] = working[2]
                            }
                        }
                    }
                }
            }
        }
        let linear = ImageBuffer(width: width, height: height,
                                 planes: [red, green, blue])
        timing.mark("ingest")
        let out = process(linearRGB: linear)
        timing.mark("engine")
        var result = pixels
        let ditherSeed = UInt32(truncatingIfNeeded: options.seed)
        let shoulderKnee = FilmSDRDelivery.shoulderKnee(
            isReversal: stock.isReversal)
        result.withUnsafeMutableBufferPointer { destination in
            out.planes[0].withUnsafeBufferPointer { plane0 in
                out.planes[1].withUnsafeBufferPointer { plane1 in
                    out.planes[2].withUnsafeBufferPointer { plane2 in
                        let bytes = destination.baseAddress!
                        let planes = [plane0.baseAddress!, plane1.baseAddress!,
                                      plane2.baseAddress!]
                        DispatchQueue.concurrentPerform(iterations: height) { y in
                            let row = y * width
                            for x in 0..<width {
                                let i = row + x
                                for c in 0..<3 {
                                    let rolled = ColorScience.displayShoulder(
                                        planes[c][i], knee: shoulderKnee)
                                    let v = ColorScience.linearToSrgb(clamp(rolled, 0, 1))
                                    let dither = triangularDither(
                                        index: UInt32(i), channel: UInt32(c), seed: ditherSeed)
                                    bytes[i * bytesPerPixel + c] =
                                        UInt8(clamp(v * 255 + 0.5 + dither, 0, 255))
                                }
                            }
                        }
                    }
                }
            }
        }
        timing.mark("egress")
        timing.report("displayP3-8 \(width)x\(height)")
        return result
    }

    /// Returns per-layer dye densities of the developed film — `NegativeInterchange`, and the
    /// same quantity `process` produces at `PipelineStage.negative`. This is the CPU seam the
    /// spans were named after; it ignores `options.stage` and always develops the negative.
    public func developNegative(linearRGB image: ImageBuffer) -> ImageBuffer {
        guard let developed = HalideBackend.develop(image: image, stock: stock,
                                                    options: options) else {
            fatalError(Self.missingEngineMessage)
        }
        return developed
    }

    /// Converts developed densities to display-linear RGB.
    public func printPositive(negativeDensity density: ImageBuffer) -> ImageBuffer {
        guard let positive = HalideBackend.print(density: density, stock: stock,
                                                 options: options) else {
            fatalError(Self.missingEngineMessage)
        }
        return positive
    }

    private static let missingEngineMessage = """
    Fotufilm's Halide engine is not available in this build. Install Halide \
    (`brew install halide`, or set HALIDE_ROOT) and rebuild; on iOS use \
    HalideMetalFilmRenderer, which links the AOT-compiled engine.
    """
}

/// The sRGB transfer of every byte an 8-bit frame can present.
///
/// The decode's argument is `byte / 255`, so it has 256 possible arguments and 256 possible
/// answers. This is those answers — not a sampling of the curve, the curve itself at the only
/// points an 8-bit ingest ever asks about. Where alpha has to be undone the argument is no longer
/// a byte, and that pixel takes the transfer directly.
let srgbDecodedByte: [Float] = (0...255).map {
    ColorScience.srgbToLinear(Float($0) / 255)
}
