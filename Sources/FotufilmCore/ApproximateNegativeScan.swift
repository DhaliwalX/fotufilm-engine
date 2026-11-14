import Foundation

/// The native scan importer's approximate RGB-density mapping. A sampled border
/// removes base/fog and the chosen film restores its model base. Optional per-record gains
/// scale each channel's density, for scanners whose channels do not read the dyes' own
/// densities, `weights` read each record from all three channels, undoing some of the
/// dyes' crosstalk (`NegativeScanCrosstalk`), `flare` takes the scan's stray light off before a
/// density is read, and an `exposure` moves each record along the film's own curve as a
/// printer's filtration moves a print. This does not fit a scanner profile or correct
/// illumination.
public struct ApproximateNegativeScan: Encodable, Equatable, Sendable {
    /// Clear film as linear scan RGB, as it was sampled.
    public let border: [Float]
    /// Stray light the scan carries in each channel, linear scan RGB like `border`: the lens's
    /// and the room's, which lifts every sample alike. The reading takes it off a sample and
    /// off the clear film before their densities, so a dense highlight is not read thinner.
    public let flare: [Float]
    /// What the clear film reads: the film's model base.
    public let baseDensity: [Float]
    /// The scan channel each record mostly reads, which sets the usable range.
    public let recordChannels: [Int]
    /// Record density per unit of scanner-channel density above the border.
    public let gains: [Float]
    /// What each record reads from the scan channels' densities over the border
    /// (`NegativeScanCrosstalk.weights`): its own channel alone without crosstalk correction.
    public let weights: [SIMD3<Float>]
    /// The usable samples, net of `flare`.
    public let minimumSample: [Float]
    public let maximumSample: [Float]
    /// The frame's balance, as the density each record gains over what the scan reads of it:
    /// `balanceSamples` values per record, across `balanceRange` of the record's weighted
    /// density over the clear film, read linearly between them and held past the ends. An
    /// exposure moves a record along the film's curve, so the gain is none at the clear film,
    /// grows through the toe and is one density on the straight line. All zero for a reading
    /// that moves nothing.
    public let balance: [[Float]]

    public static let gainRange: ClosedRange<Float> = 0.5...2
    /// How far a balance can move a record, in log exposure.
    public static let exposureRange: ClosedRange<Float> = -1.5...1.5
    /// How much of a channel's clear film can be stray light.
    public static let flareLimit: Float = 0.5
    /// The samples of `balance` for each record, and the weighted densities over the clear film
    /// they span (FOTUFILM_SCAN_BALANCE_SAMPLES and FOTUFILM_SCAN_BALANCE_MAX).
    public static let balanceSamples = 65
    public static let balanceRange: ClosedRange<Float> = 0...4

    /// How far past where a scan's holder begins, in density, a channel still counts as film:
    /// the holder's limit is the mean of a pixel's channels, and the densest film's densest
    /// channel lies past it.
    public static let holderMargin: Float = 0.3

    /// Reads `stock` against `border` with the frame's `gains`, its balance as an `exposure`
    /// added to each record in log exposure, crosstalk `weights` (`Balance.weights`), each
    /// record from its own channel alone when nil, and the scan's `flare`. `holder` is where
    /// the scan's holder begins, a density over the clear film (`holder(border:preview:)`): a
    /// sample `holderMargin` past it in any channel is the holder's and prints black, where
    /// otherwise the holder reads as the film's densest highlight.
    public init(stock: FilmStock, border: SIMD3<Float>, gains: SIMD3<Float> = .one,
                exposure: SIMD3<Float> = .zero, weights: [SIMD3<Float>]? = nil,
                flare: SIMD3<Float> = .zero, holder: Float? = nil) throws {
        guard !stock.isReversal else { throw ScannedNegativeError.positiveOutputRequired }
        _ = try ScannedNegativeConverter(dark: .zero, light: border, reference: .filmBase)
        guard (0..<3).allSatisfy({ gains[$0].isFinite && Self.gainRange.contains(gains[$0]) }),
              (0..<3).allSatisfy({ exposure[$0].isFinite
                  && Self.exposureRange.contains(exposure[$0]) }),
              (0..<3).allSatisfy({ flare[$0].isFinite && flare[$0] >= 0
                  && flare[$0] <= Self.flareLimit * border[$0] }),
              weights.map({ $0.count == 3 && $0.allSatisfy { row in
                  (0..<3).allSatisfy { row[$0].isFinite } } }) ?? true else {
            throw ScannedNegativeError.invalidCalibration
        }
        self.border = [border.x, border.y, border.z]
        self.flare = [flare.x, flare.y, flare.z]
        let clear = border - flare
        let filmBase = (0..<3).map { stock.curves[$0].dMin }
        baseDensity = filmBase
        recordChannels = stock.isMonochrome ? [1, 1, 1] : [0, 1, 2]
        self.gains = stock.isMonochrome ? [1, 1, 1] : [gains.x, gains.y, gains.z]
        self.weights = stock.isMonochrome || weights == nil
            ? NegativeScanCrosstalk.weights(for: stock, correction: .none, neutral: nil)
            : weights!
        var minimum = [Float](repeating: 0, count: 3)
        var maximum = [Float](repeating: .greatestFiniteMagnitude, count: 3)
        for record in 0..<3 {
            let channel = recordChannels[record]
            let gain = self.gains[record]
            // Leave the same interior margin used by native scanned-negative import, about the
            // film's own base: a frame's balance does not move what counts as film.
            let low = clear[channel] * pow(10, (filmBase[record] - NegativeInterchange.range.upperBound) / gain + 0.0001)
            let high = clear[channel] * pow(10, (filmBase[record] - NegativeInterchange.range.lowerBound) / gain - 0.0001)
            minimum[channel] = max(minimum[channel], low)
            maximum[channel] = min(maximum[channel], high)
        }
        if let holder, holder.isFinite, holder > 0 {
            for channel in 0..<3 {
                minimum[channel] = max(minimum[channel],
                                       clear[channel] * pow(10, -(holder + Self.holderMargin)))
            }
        }
        minimumSample = minimum
        maximumSample = maximum
        let recordGains = self.gains
        balance = (0..<3).map { record in
            let moved = stock.isMonochrome ? 0 : exposure[record]
            guard moved != 0 else { return [Float](repeating: 0, count: Self.balanceSamples) }
            let curve = stock.curves[record]
            return (0..<Self.balanceSamples).map { sample in
                let read = Self.balanceRange.lowerBound
                    + (Self.balanceRange.upperBound - Self.balanceRange.lowerBound)
                    * Float(sample) / Float(Self.balanceSamples - 1)
                // What the scan reads of the record, and where the film's curve puts that
                // density: the clear film, which no exposure made, stays as it is.
                let density = curve.dMin + recordGains[record] * read
                guard density > curve.dMin else { return 0 }
                let made = curve.logExposure(density: density)
                return curve.density(logExposure: made + moved) - curve.density(logExposure: made)
            }
        }
    }

    /// The density `balance` adds to `record` where the scan reads `read` of it over the clear
    /// film.
    @inlinable
    public func balance(record: Int, read: Float) -> Float {
        let table = balance[record]
        let span = Self.balanceRange.upperBound - Self.balanceRange.lowerBound
        let position = min(max((read - Self.balanceRange.lowerBound) / span
                               * Float(Self.balanceSamples - 1), 0),
                           Float(Self.balanceSamples - 1))
        // A reading that is no number moves nothing.
        guard position.isFinite else { return 0 }
        let index = min(Int(position), Self.balanceSamples - 2)
        let between = position - Float(index)
        return table[index] * (1 - between) + table[index + 1] * between
    }

    /// One linear scan sample's record densities: the stray light taken off, the border's
    /// scanner density removed, each record read from the channels by its weights, the film's
    /// model base restored and the frame's balance added, inside `NegativeInterchange.range`.
    /// `nil` where `convert` would mark the pixel invalid.
    @inlinable
    public func density(of sample: SIMD3<Float>) -> SIMD3<Float>? {
        var net = SIMD3<Float>.zero
        for channel in 0..<3 {
            let value = sample[channel] - flare[channel]
            guard value.isFinite, value > minimumSample[channel],
                  value < maximumSample[channel] else { return nil }
            net[channel] = value
        }
        let scanner = SIMD3((0..<3).map { -log10(net[$0] / (border[$0] - flare[$0])) })
        var density = SIMD3<Float>.zero
        for record in 0..<3 {
            let weight = weights[record]
            let read = weight.x * scanner.x + weight.y * scanner.y + weight.z * scanner.z
            density[record] = min(max(baseDensity[record] + gains[record] * read
                                      + balance(record: record, read: read),
                                      NegativeInterchange.range.lowerBound),
                                  NegativeInterchange.range.upperBound)
        }
        return density
    }

    public struct Result {
        public let density: ImageBuffer
        public let invalid: [Bool]
    }

    /// Invalid pixels (often the holder) are excluded, not clipped to an invented
    /// density. Callers paint those pixels black after the shared print stage.
    public func convert(_ image: ImageBuffer) throws -> Result {
        guard image.width > 0, image.height > 0, image.planes.count == 3,
              image.planes.allSatisfy({ $0.count == image.pixelCount }) else {
            throw ScannedNegativeError.invalidImage
        }
        var densities = image
        var invalid = [Bool](repeating: false, count: image.pixelCount)
        let base = SIMD3(baseDensity[0], baseDensity[1], baseDensity[2])
        for pixel in 0..<image.pixelCount {
            let read = density(of: SIMD3((0..<3).map { image.planes[$0][pixel] }))
            invalid[pixel] = read == nil
            let value = read ?? base
            for record in 0..<3 { densities.planes[record][pixel] = value[record] }
        }
        return Result(density: densities, invalid: invalid)
    }

    /// A stand-in for the film border until one is sampled: the thinnest film in `preview`,
    /// linear scan RGB, read as the median of the percent that passes the most light across all
    /// three channels. An open holder in the frame passes more, which is why a sampled border
    /// replaces this. Nil when no pixel passes light in every channel.
    public static func estimatedBorder(preview: ImageBuffer) -> SIMD3<Float>? {
        let film = (0..<preview.pixelCount).filter { i in
            (0..<3).allSatisfy { c in preview.planes[c][i].isFinite && preview.planes[c][i] > 0 }
        }
        guard !film.isEmpty else { return nil }
        let transmission = { (i: Int) -> Float in
            (0..<3).reduce(0) { $0 + log10(preview.planes[$1][i]) }
        }
        let brightest = film.sorted { transmission($0) > transmission($1) }
            .prefix(max(1, film.count / 100))
        var border = SIMD3<Float>()
        for c in 0..<3 {
            let values = brightest.map { preview.planes[c][$0] }.sorted()
            border[c] = values[values.count / 2]
        }
        return border
    }

    /// The clear film a reading through the scan's light and camera is measured against until
    /// one is sampled: as `estimatedBorder`, but where the scan shows its bare light past the
    /// film, through sprocket holes or around a strip, the film's base under that light and not
    /// the light itself (`NegativeFilmSuggestions.read`). That reading takes a density over the
    /// clear film as the film's own, so a light taken for film reads the film's mask into every
    /// tone; the first reading scaled each channel onto the frame's densest end, which hid it.
    /// The light is told from film as the film suggestions tell it: it is neutral where the
    /// film's base under it is orange and denser in every channel. It may fill a good part of
    /// the scan, a plateau of its own, or only its sprocket holes, too few pixels for one: then
    /// the brightest of the scan is the light, the thinnest plateau the base, and little of the
    /// scan is brighter than that base, which a picture's own tones under a neutral clear film
    /// never are.
    public static func estimatedFilmBase(preview: ImageBuffer) -> SIMD3<Float>? {
        guard let brightest = estimatedBorder(preview: preview) else { return nil }
        guard let read = NegativeFilmSuggestions.read(preview: preview) else { return brightest }
        if read.lamp != nil { return read.border }
        let base = read.border
        let density = { (v: SIMD3<Float>) in SIMD3((0..<3).map { -log10(v[$0]) }) }
        let light = NegativeFilmSuggestions.colour(brightest)
        let mask = NegativeFilmSuggestions.colour(base)
        guard max(abs(light.x), abs(light.y), abs(light.z)) < NegativeFilmSuggestions.neutral,
              mask.z - mask.x > NegativeFilmSuggestions.maskContrast,
              (0..<3).allSatisfy({ base[$0] < brightest[$0] }),
              (density(base) - density(brightest)).sum() / 3 >= NegativeFilmSuggestions.lampGap
        else { return brightest }
        // How much of the scan passes more light than the base: holes and gaps, not a picture.
        let level = density(base).sum() / 3 - NegativeFilmSuggestions.plateauWidth
        var brighter = 0, film = 0
        for i in 0..<preview.pixelCount {
            let pixel = SIMD3((0..<3).map { preview.planes[$0][i] })
            guard (0..<3).allSatisfy({ pixel[$0].isFinite && pixel[$0] > 0 }) else { continue }
            film += 1
            if density(pixel).sum() / 3 < level { brighter += 1 }
        }
        return brighter * Self.bareLightShare <= film ? base : brightest
    }

    /// The most of a scan that may pass more light than its base where the light is no plateau
    /// of its own, as one over this: a third. Holes, gaps and their blurred edges fill up to a
    /// fifth of real scans; a picture under a neutral clear film fills more than half.
    static let bareLightShare = 3

    /// What a frame's own tones say about reading it on a film: per-record gains and offsets, and
    /// where its highlights sit.
    public struct Balance: Equatable, Sendable {
        /// What each record's density over the clear film is multiplied by, green held as it
        /// is. A reading without the scan model makes the frame's densest end, its highlights,
        /// read as one exposure on every record this way: broadband scanners and cameras see a
        /// cyan dye through a red channel that also passes light the dye does not absorb, which
        /// otherwise leaves the highlights off colour at every tone. A reading on the model
        /// keeps gains for how steep a roll's records read against each other (`contrast`).
        public var gains: SIMD3<Float>
        /// Where the print is timed, in stops over the film's mid-grey, for
        /// `FotufilmEngine.Options.sceneHighlightStops`: the highlights' exposure, or less where
        /// they sit far over the frame's mid-tones (`timedHighlight`). Nil for a frame too flat
        /// to tell.
        public var highlightStops: Float?
        /// What each record reads from the scan channels, undoing the dyes' crosstalk on the
        /// frame's own grey (`NegativeScanCrosstalk.weights`); nil reads each from its own channel.
        public var weights: [SIMD3<Float>]? = nil
        /// Log exposure added to each record, green held as it is, which puts a neutral of the
        /// frame on the film's own grey scale as a printer's filtration would
        /// (`balance(stock:setup:separation:mode:tones:roll:)`). An exposure, not a density: the
        /// scene's light moved each record along its curve, so the clear film and the toe move
        /// less than the straight line does, and the straight line by no more than the neutral
        /// is off.
        public var exposure: SIMD3<Float> = .zero

        public static let neutral = Balance(gains: .one, highlightStops: nil)
    }

    /// Reads `preview`, linear scan RGB of the framed picture, against `stock`. The central 80%
    /// keeps the holder out, as automatic conversion does; a monochrome film reads one channel.
    public static func balance(stock: FilmStock, border: SIMD3<Float>,
                               preview: ImageBuffer) -> Balance {
        channelEnds(border: border, preview: preview).map { balance(stock: stock, denseEnd: $0) }
            ?? .neutral
    }

    /// The densest end of the framed picture, its highlights, in the scan channels' densities
    /// over `border`: the densest hundredth of the central 80%, judged by each pixel's thinnest
    /// channel, and each channel's median over those pixels. One set of pixels gives all three
    /// channels, so the end is something the frame holds: a channel's own densest pixels may be
    /// a saturated colour, a yellow flower in the sun being as dense to red and green as a white
    /// wall and far thinner to blue, and three channels read from three objects are no neutral.
    /// The thinnest channel passes such a colour over for whatever is dense in all three. A
    /// frame whose densest pixels are a grey reads as each channel's 99.5th percentile. Nil for
    /// a frame too small to read.
    public static func denseEnd(border: SIMD3<Float>, preview: ImageBuffer) -> SIMD3<Float>? {
        guard let densities = framedDensities(border: border, preview: preview) else { return nil }
        let thinnest = densities.map { $0.min() }
        let level = thinnest.sorted()[Int(Float(thinnest.count - 1) * 0.99)]
        let densest = densities.indices.filter { thinnest[$0] >= level }
        var dense = SIMD3<Float>.zero
        for c in 0..<3 {
            let values = densest.map { densities[$0][c] }.sorted()
            dense[c] = values[values.count / 2]
        }
        return dense
    }

    /// The densest end as the first reading takes it, which an edit made with it keeps: each
    /// channel's own density over `border` at the 99.5th percentile of the central 80%.
    public static func channelEnds(border: SIMD3<Float>, preview: ImageBuffer) -> SIMD3<Float>? {
        guard let densities = framedDensities(border: border, preview: preview) else { return nil }
        var dense = SIMD3<Float>.zero
        for c in 0..<3 {
            let values = densities.map { $0[c] }.sorted()
            dense[c] = values[Int(Float(values.count - 1) * 0.995)]
        }
        return dense
    }

    /// The framed picture's mid-tones in the scan channels' densities over `border`: each
    /// channel's mean over the central 80%, what a printer's integrating meter reads of a
    /// negative. It tells a frame whose highlights are most of the picture from one where they
    /// are a lamp or a window in a dark room (`timedHighlight`). Nil for a frame too small to
    /// read.
    public static func midtone(border: SIMD3<Float>, preview: ImageBuffer) -> SIMD3<Float>? {
        guard let densities = framedDensities(border: border, preview: preview) else { return nil }
        return densities.reduce(SIMD3<Float>.zero, +) / Float(densities.count)
    }

    /// The green density over the clear film a pixel has to count toward a frame's average:
    /// past the toe, where the clear film's own error is most of what a pixel reads, and short
    /// of the densest highlights, a lamp or the sun, whose colour is their own.
    public static let averageRange: ClosedRange<Float> = 0.1...1.5

    /// The framed picture's average in the scan channels' densities over `border`: over the
    /// central 80%'s pixels whose green lies in `averageRange`, the median green, and red and
    /// blue that far from it as the medians of their differences from green. A picture's tones
    /// taken together lean to no colour far more often than its brightest thing is white, a
    /// sunlit wall at dusk or a yellow flower, so the average stands for the frame's neutral
    /// and, over a roll's frames, for the roll's (`RollBalance.average`). Nil where fewer than
    /// one pixel in 128 counts, a night with a few lamps.
    public static func average(border: SIMD3<Float>, preview: ImageBuffer) -> SIMD3<Float>? {
        guard let densities = framedDensities(border: border, preview: preview) else { return nil }
        let counted = densities.filter { averageRange.contains($0.y) }
        guard counted.count >= max(16, densities.count / 128) else { return nil }
        let median = { (values: [Float]) -> Float in values.sorted()[values.count / 2] }
        let green = median(counted.map(\.y))
        return SIMD3(green + median(counted.map { $0.x - $0.y }), green,
                     green + median(counted.map { $0.z - $0.y }))
    }

    /// A picture area picked on the scan, for what a frame measures: `preview`, the area drawn
    /// as a picture of its own, set in the middle of a frame a quarter larger with nothing
    /// around it. The measures read a frame's central 80%, a margin that keeps a holder and a
    /// rebate out of a scan nobody framed; of a picked area that is then all of it, and no
    /// more. What surrounds it is no number, which every measure passes over.
    public static func pictureArea(_ preview: ImageBuffer) -> ImageBuffer {
        guard preview.width > 0, preview.height > 0 else { return preview }
        // The smallest frame whose central 80%, as the measures cut it, holds the area.
        func padded(_ size: Int) -> Int {
            var whole = size
            while whole - 2 * (whole / 10) < size { whole += 1 }
            return whole
        }
        let width = padded(preview.width), height = padded(preview.height)
        var frame = ImageBuffer(width: width, height: height, fill: .nan)
        let (left, top) = (width / 10, height / 10)
        for c in 0..<3 { for y in 0..<preview.height {
            let from = y * preview.width, to = (y + top) * width + left
            frame.planes[c].replaceSubrange(
                to..<(to + preview.width), with: preview.planes[c][from..<(from + preview.width)])
        } }
        return frame
    }

    /// The scan channels' densities over `border` of the central 80% of `preview`, which keeps
    /// the holder out, at the pixels that pass light in every channel. Nil with fewer than
    /// sixteen of them.
    private static func framedDensities(border: SIMD3<Float>,
                                        preview: ImageBuffer) -> [SIMD3<Float>]? {
        guard preview.width >= 2, preview.height >= 2 else { return nil }
        var densities: [SIMD3<Float>] = []
        let mx = preview.width / 10, my = preview.height / 10
        for y in my..<(preview.height - my) { for x in mx..<(preview.width - mx) {
            let i = y * preview.width + x
            let pixel = SIMD3((0..<3).map { preview.planes[$0][i] })
            guard (0..<3).allSatisfy({ pixel[$0].isFinite && pixel[$0] > 0 }) else { continue }
            densities.append(SIMD3((0..<3).map { -log10(pixel[$0] / border[$0]) }))
        } }
        return densities.count >= 16 ? densities : nil
    }

    /// A diffuse white's exposure in stops over the film's mid-grey: a print is timed so the
    /// film's density there prints white.
    public static let diffuseWhiteStops: Float = log2(0.9 / 0.18)

    /// How far over a frame's mid-tones its highlights sit and still time the print, in stops:
    /// a diffuse white is two and a third stops over a mid-grey, and a backlit scene's sky
    /// another stop and more over its average. Real frames lit as a whole sit within it.
    public static let highlightSpan: Float = 4

    /// Where a frame's print is timed: its highlights, `highlight` stops over the film's
    /// mid-grey, which print as white, unless they sit far over its mid-tones, `midtone` stops
    /// over the mid-grey. A lamp, a window or the sun on water in a dark picture is a small
    /// part of it, and a print timed to hold it leaves everything else black; the print is then
    /// timed `highlightSpan` over the mid-tones, and no lighter than the film was exposed, a
    /// diffuse white printing as white, which keeps a night or a stage as dark as it was shot.
    /// Highlights under a diffuse white time the print as they are.
    public static func timedHighlight(_ highlight: Float, midtone: Float) -> Float {
        guard highlight > diffuseWhiteStops, midtone.isFinite else { return highlight }
        return min(highlight, max(diffuseWhiteStops, midtone + highlightSpan))
    }

    /// What a roll's frames share: the colour of its clear film, the average its pictures
    /// come to, which stands for its neutral, and how steep its records read against each
    /// other. None of these changes along a roll, and one frame cannot tell any of them from
    /// its own picture: the film's, its development's and the scan's are one for the roll,
    /// where a frame's own densest end or tonal steps follow whatever it shows. The editor
    /// measures it over the roll's frames and keeps it with each frame's edit
    /// (web/src/negative-document.js `rollBalance` mirrors `init(measures:)`).
    public struct RollBalance: Codable, Equatable, Sendable {
        /// The densest end's red and blue over its green: the median over the frames whose
        /// densest ends can be read.
        public var colour: [Float]
        /// How many frames it was measured on.
        public var frames: Int
        /// The green of the frames' densest ends, their median, in the scan channel's density
        /// over the clear film. With `colour` it is the roll's neutral. Nil in a roll measured
        /// before it was kept.
        public var level: Float?
        /// How red and blue rise per unit of green across the frames' tonal steps
        /// (`tonalSlopes(border:preview:)`), the median over the frames that have enough. Nil
        /// with fewer than `contrastFrames` of them.
        public var slopes: [Float]?
        /// The roll's neutral in the scan channels' densities over the clear film: the median
        /// over the frames' averages (`average(border:preview:)`) of their green, with red and
        /// blue as far from it as the medians of theirs. A frame balanced on its roll is
        /// balanced on this. Nil in a roll measured before it was kept, which is balanced on
        /// the colour of its densest ends.
        public var average: [Float]?
        /// The clear film's red and blue over its green, linear scan RGB: the median over the
        /// frames' own clear film. A scan's exposure moves its clear film up and down and not
        /// its colour, and a frame that shows no unexposed film reads its own off its picture
        /// (`clearFilm(_:)`). Nil in a roll measured before it was kept.
        public var clear: [Float]?

        /// How many frames' tonal steps a roll's contrast takes: fewer leave it to one
        /// picture's colours.
        public static let contrastFrames = 6
        /// How far a frame's own clear film may be off its roll's colour, in density, and
        /// still take it: further is another film, or a scan under another light.
        public static let clearReach: Float = 0.15

        public init(colour: [Float], frames: Int, level: Float? = nil, slopes: [Float]? = nil,
                    average: [Float]? = nil, clear: [Float]? = nil) {
            self.colour = colour
            self.frames = frames
            self.level = level
            self.slopes = slopes
            self.average = average
            self.clear = clear
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            colour = try container.decode([Float].self, forKey: .colour)
            frames = try container.decode(Int.self, forKey: .frames)
            level = try container.decodeIfPresent(Float.self, forKey: .level)
            slopes = try container.decodeIfPresent([Float].self, forKey: .slopes)
            average = try container.decodeIfPresent([Float].self, forKey: .average)
            clear = try container.decodeIfPresent([Float].self, forKey: .clear)
            let pair = { (values: [Float]) in
                values.count == 2 && values.allSatisfy { $0.isFinite && $0 > 0 }
            }
            guard pair(colour), frames >= 2, level.map({ $0.isFinite && $0 > 0 }) ?? true,
                  slopes.map(pair) ?? true, clear.map(pair) ?? true,
                  average.map({ $0.count == 3 && $0.allSatisfy(\.isFinite) && $0[1] > 0 })
                      ?? true else {
                throw DecodingError.dataCorruptedError(
                    forKey: .colour, in: container, debugDescription: "Invalid roll balance.")
            }
        }

        /// What one frame gives its roll.
        public struct Measure: Equatable, Sendable {
            /// The frame's densest end (`denseEnd(border:preview:)`).
            public var denseEnd: SIMD3<Float>?
            /// The rises across its tonal steps (`tonalSlopes(border:preview:)`).
            public var slopes: SIMD2<Float>?
            /// Its mid-tones (`midtone(border:preview:)`), which its own print's timing takes;
            /// a roll takes nothing from them.
            public var midtone: SIMD3<Float>?
            /// Its average (`average(border:preview:)`).
            public var average: SIMD3<Float>?
            /// Its own clear film, linear scan RGB: as sampled on it, else as estimated from
            /// its scan, before any roll's colour.
            public var clear: SIMD3<Float>?
            /// The clear film its densities are over, where that is not its own: a frame
            /// measured again on a roll is read against the roll's colour of it.
            public var border: SIMD3<Float>?

            public init(denseEnd: SIMD3<Float>? = nil, slopes: SIMD2<Float>? = nil,
                        midtone: SIMD3<Float>? = nil, average: SIMD3<Float>? = nil,
                        clear: SIMD3<Float>? = nil, border: SIMD3<Float>? = nil) {
                self.denseEnd = denseEnd
                self.slopes = slopes
                self.midtone = midtone
                self.average = average
                self.clear = clear
                self.border = border
            }
        }

        /// The roll of the frames measured as `measures`. A frame filled by one colour moves a
        /// median little. Nil when fewer than two frames' densest ends can be read.
        public init?(measures: [Measure]) {
            let ends = measures.compactMap(\.denseEnd).filter { end in
                (0..<3).allSatisfy { end[$0].isFinite && end[$0] > 0.05 }
            }
            guard ends.count >= 2 else { return nil }
            let median = { (values: [Float]) -> Float in
                let sorted = values.sorted(), middle = sorted.count / 2
                return sorted.count % 2 == 1 ? sorted[middle]
                    : (sorted[middle - 1] + sorted[middle]) / 2
            }
            colour = [median(ends.map { $0.x / $0.y }), median(ends.map { $0.z / $0.y })]
            frames = ends.count
            level = median(ends.map(\.y))
            let stepped = measures.compactMap(\.slopes).filter { slope in
                (0..<2).allSatisfy { slope[$0].isFinite && slope[$0] > 0 }
            }
            slopes = stepped.count >= Self.contrastFrames
                ? [median(stepped.map(\.x)), median(stepped.map(\.y))] : nil
            let positive = { (light: SIMD3<Float>) in
                (0..<3).allSatisfy { light[$0].isFinite && light[$0] > 0 }
            }
            let films = measures.compactMap(\.clear).filter(positive)
            if films.count >= 2 {
                // Medians of the logarithms, so a frame twice too red counts as one half as red.
                clear = [pow(10, median(films.map { log10($0.x / $0.y) })),
                         pow(10, median(films.map { log10($0.z / $0.y) }))]
            }
            // Each frame's average over the clear film the roll gives it, whatever it was
            // measured over.
            let averages = measures.compactMap { measure -> SIMD3<Float>? in
                guard var average = measure.average,
                      (0..<3).allSatisfy({ average[$0].isFinite }), average.y > 0.05
                else { return nil }
                if let own = measure.clear, positive(own),
                   case let over = measure.border ?? own, positive(over) {
                    let film = clearFilm(own)
                    for c in 0..<3 { average[c] += log10(film[c] / over[c]) }
                }
                return average
            }
            if averages.count >= 2 {
                let green = median(averages.map(\.y))
                average = [green + median(averages.map { $0.x - $0.y }), green,
                           green + median(averages.map { $0.z - $0.y })]
            }
        }

        /// The roll's neutral in the scan channels' densities over the clear film: the average
        /// of its frames, or for a roll kept without one its densest ends' colour at their
        /// level, or at `green` where it kept no level either.
        func neutral(green: Float?) -> SIMD3<Float>? {
            if let average, average.count == 3, average[1] > 0.05 {
                return SIMD3(average[0], average[1], average[2])
            }
            guard let green = level ?? green, green.isFinite, green > 0.05 else { return nil }
            return SIMD3(colour[0] * green, green, colour[1] * green)
        }

        /// A frame's clear film on its roll: `own`, linear scan RGB as estimated from its scan,
        /// at its own green with red and blue in the roll's proportion to it. A frame that
        /// shows no unexposed film reads its clear film off the thinnest of its picture, close
        /// in level and off in colour, which then tints every tone of it; the roll's colour is
        /// the film's. `own` as it is for a roll kept without the colour, or one further from
        /// it than `clearReach`.
        public func clearFilm(_ own: SIMD3<Float>) -> SIMD3<Float> {
            guard let clear, clear.count == 2, own.y.isFinite, own.y > 0,
                  own.x.isFinite, own.x > 0, own.z.isFinite, own.z > 0,
                  abs(log10(own.x / own.y / clear[0])) <= Self.clearReach,
                  abs(log10(own.z / own.y / clear[1])) <= Self.clearReach
            else { return own }
            return SIMD3(clear[0] * own.y, own.y, clear[1] * own.y)
        }
    }

    /// A frame's densest end read on its roll's colour: its own green, which times its print,
    /// with red and blue in the roll's proportion to it. `dense` as it is without a roll, or one
    /// too thin to read. Mirrors web/src/negative-reading.js `rolledDenseEnd`.
    public static func denseEnd(_ dense: SIMD3<Float>?, roll: RollBalance?) -> SIMD3<Float>? {
        guard let dense, let roll, (0..<3).allSatisfy({ dense[$0].isFinite }), dense.y > 0.05
        else { return dense }
        return SIMD3(roll.colour[0] * dense.y, dense.y, roll.colour[1] * dense.y)
    }

    /// The balance of a frame whose densest end reads `dense` over the border, against `stock`,
    /// and its `correction` of the dyes' crosstalk, which keeps the densest end as it reads
    /// (`NegativeScanCrosstalk`). A frame too small or flat to read is unbalanced, its correction
    /// keeping equal densities.
    public static func balance(stock: FilmStock, denseEnd dense: SIMD3<Float>?,
                               correction: NegativeScanCrosstalk.Correction) -> Balance {
        let readable = dense.flatMap { d in (0..<3).allSatisfy({ d[$0].isFinite }) ? d : nil }
        let weights = correction.strength > 0
            ? NegativeScanCrosstalk.weights(for: stock, correction: correction, neutral: readable)
            : nil
        var measured = readable.map { Self.balance(stock: stock, denseEnd: $0, weights: weights) }
            ?? Balance.neutral
        measured.weights = weights
        return measured
    }

    /// The balance of a frame whose densest end reads `dense` over the border, against `stock`.
    public static func balance(stock: FilmStock, denseEnd dense: SIMD3<Float>) -> Balance {
        balance(stock: stock, denseEnd: dense, weights: nil)
    }

    private static func balance(stock: FilmStock, denseEnd raw: SIMD3<Float>,
                                weights: [SIMD3<Float>]?) -> Balance {
        guard (0..<3).allSatisfy({ raw[$0].isFinite }) else { return .neutral }
        let dense = weights.map { NegativeScanCrosstalk.apply($0, raw) } ?? raw
        guard dense[1] > 0.05 else { return .neutral }
        let exposure = stock.curves[1].logExposure(density: stock.curves[1].dMin + dense[1])
        var gains = SIMD3<Float>.one
        if !stock.isMonochrome {
            for record in [0, 2] where dense[record] > 0.05 {
                let expected = stock.curves[record].density(logExposure: exposure)
                    - stock.curves[record].dMin
                gains[record] = min(max(expected / dense[record], gainRange.lowerBound),
                                    gainRange.upperBound)
            }
        }
        return Balance(gains: gains, highlightStops: exposure / log10(2))
    }
}
