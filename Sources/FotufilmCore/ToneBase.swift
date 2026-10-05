import Foundation
import FotufilmHalide

/// Whole-frame measurement used by local highlight and shadow masks.
public struct ToneBaseMeasurement {
    /// Cells along the grid's long edge; mirrors FOTUFILM_TONE_GRID_EDGE.
    public static let gridEdge = Int(FOTUFILM_TONE_GRID_EDGE)

    /// Guided-filter window radius in cells, about one fifth of the grid's long edge.
    static let windowRadius = 12

    /// The edge threshold, in stops².
    static let epsilon: Double = 0.25

    public let gridWidth: Int
    public let gridHeight: Int
    let frameWidth: Int
    let frameHeight: Int
    /// Metering weights with everything per-pixel folded in: luminance weight x white-balance gain
    /// x exposure gain / 0.18, so a cell update is one fused multiply-add per channel.
    let weightR: Float
    let weightG: Float
    let weightB: Float

    var logSum: [Double]
    var counts: [Int]
    /// Auto Levels' per-record log sums, red, green and blue planes of one sum per cell, each
    /// record metered alone with the same white balance and exposure. Empty when not metered.
    var channelLogSum: [Double]
    /// Each record's own metering weight, white-balance gain x exposure gain / 0.18.
    let channelWeights: SIMD3<Float>

    public var metersColour: Bool { !channelLogSum.isEmpty }

    public init(frameWidth: Int, frameHeight: Int,
                balance: SIMD3<Float>, exposureGain: Float, metersColour: Bool = false) {
        self.frameWidth = max(frameWidth, 1)
        self.frameHeight = max(frameHeight, 1)
        let long = max(self.frameWidth, self.frameHeight)
        func cells(_ side: Int) -> Int {
            min(side, max(1, (side * Self.gridEdge + long / 2) / long))
        }
        self.gridWidth = cells(self.frameWidth)
        self.gridHeight = cells(self.frameHeight)
        let luma = ColorScience.luminanceWeights
        let gain = exposureGain / 0.18
        self.weightR = luma.0 * balance.x * gain
        self.weightG = luma.1 * balance.y * gain
        self.weightB = luma.2 * balance.z * gain
        self.logSum = [Double](repeating: 0, count: gridWidth * gridHeight)
        self.counts = [Int](repeating: 0, count: gridWidth * gridHeight)
        self.channelWeights = balance * gain
        self.channelLogSum = metersColour
            ? [Double](repeating: 0, count: 3 * gridWidth * gridHeight) : []
    }

    /// The white balance a kernel metering one record alone is handed, in place of the frame's:
    /// the kernel weighs each record by luminance weight x this, so the record's own luminance
    /// weight is divided out and the other two are zeroed.
    public static func channelMeteringBalance(_ balance: SIMD3<Float>,
                                              channel: Int) -> SIMD3<Float> {
        let luma = ColorScience.luminanceWeights
        let weights = SIMD3(luma.0, luma.1, luma.2)
        var isolated = SIMD3<Float>.zero
        isolated[channel] = balance[channel] / weights[channel]
        return isolated
    }

    /// Frame rows `rows` as interleaved linear RGBA, `pixels` pointing at the first of them.
    public mutating func add(linearRGBA pixels: UnsafePointer<Float>,
                             rows: Range<Int>) {
        add(rows: rows) { index in
            SIMD3(pixels[index * 4], pixels[index * 4 + 1], pixels[index * 4 + 2])
        }
    }

    /// Frame rows `rows` as planar linear RGB, each plane pointing at the first of them.
    public mutating func add(planarR red: UnsafePointer<Float>,
                             g green: UnsafePointer<Float>,
                             b blue: UnsafePointer<Float>,
                             rows: Range<Int>) {
        add(rows: rows) { index in SIMD3(red[index], green[index], blue[index]) }
    }

    /// Frame rows `rows` as interleaved sRGB-encoded RGBA bytes.
    public mutating func add(srgbRGBA bytes: UnsafePointer<UInt8>,
                             rows: Range<Int>) {
        let decode = Self.srgbDecodeTable
        add(rows: rows) { index in
            let offset = index * 4
            let alpha = bytes[offset + 3]
            let denominator = alpha > 0 && alpha < 255 ? Float(alpha) : 255
            let srgb = SIMD3<Float>(
                alpha == 0 || alpha == 255
                    ? decode[Int(bytes[offset])]
                    : ColorScience.srgbToLinear(
                        min(Float(bytes[offset]) / denominator, 1)),
                alpha == 0 || alpha == 255
                    ? decode[Int(bytes[offset + 1])]
                    : ColorScience.srgbToLinear(
                        min(Float(bytes[offset + 1]) / denominator, 1)),
                alpha == 0 || alpha == 255
                    ? decode[Int(bytes[offset + 2])]
                    : ColorScience.srgbToLinear(
                        min(Float(bytes[offset + 2]) / denominator, 1)))
            return ColorScience.linearSRGBToRec2020(srgb)
        }
    }

    /// Frame rows as transfer-encoded Display P3 RGBA bytes — what the Apple video paths hold.
    /// The samples convert into the working space before metering: the white-balance gains in
    /// `weight{R,G,B}` are diagonal in the Rec.2020 basis, and a diagonal does not commute
    /// through a change of basis, so metering P3 components against them would solve a
    /// different grid than the kernel then renders.
    public mutating func add(encodedDisplayP3RGBA bytes: UnsafePointer<UInt8>,
                             rows: Range<Int>) {
        let decode = Self.srgbDecodeTable
        add(rows: rows) { index in
            let offset = index * 4
            let alpha = bytes[offset + 3]
            let denominator = alpha > 0 && alpha < 255 ? Float(alpha) : 255
            return ColorScience.linearDisplayP3ToRec2020(SIMD3(
                alpha == 0 || alpha == 255
                    ? decode[Int(bytes[offset])]
                    : ColorScience.srgbToLinear(
                        min(Float(bytes[offset]) / denominator, 1)),
                alpha == 0 || alpha == 255
                    ? decode[Int(bytes[offset + 1])]
                    : ColorScience.srgbToLinear(
                        min(Float(bytes[offset + 1]) / denominator, 1)),
                alpha == 0 || alpha == 255
                    ? decode[Int(bytes[offset + 2])]
                    : ColorScience.srgbToLinear(
                        min(Float(bytes[offset + 2]) / denominator, 1))))
        }
    }

    private static let srgbDecodeTable: [Float] = (0..<256).map {
        ColorScience.srgbToLinear(Float($0) / 255)
    }

    /// Frame rows `rows` already reduced to one sum per grid cell column — what the measure kernel
    /// returns, `gridWidth` floats per row, the first of them for `rows.lowerBound`.
    ///
    /// The kernel does the inner sum, over the pixels of one cell in one row, and it does it in
    /// float32; this walk does the rest, and keeps the double it always kept. That split is what
    /// makes the answer independent of how the frame was banded: a row's contribution is complete
    /// before it leaves the kernel, so twenty bands and one band accumulate the same values in the
    /// same order.
    public mutating func add(cellRowSums sums: UnsafePointer<Float>,
                             rows: Range<Int>) {
        add(cellRowSums: sums, rows: rows, channel: nil)
    }

    /// One record's cell sums, from the kernel run on `channelMeteringBalance`. Cell counts are
    /// the luminance sums' to keep; the record planes share them.
    public mutating func add(channel: Int, cellRowSums sums: UnsafePointer<Float>,
                             rows: Range<Int>) {
        guard metersColour else { return }
        add(cellRowSums: sums, rows: rows, channel: channel)
    }

    private mutating func add(cellRowSums sums: UnsafePointer<Float>,
                              rows: Range<Int>, channel: Int?) {
        guard !rows.isEmpty else { return }
        let (gw, gh) = (gridWidth, gridHeight)
        let (fw, fh) = (frameWidth, frameHeight)
        for y in rows {
            let cy = y * gh / fh
            let row = (y - rows.lowerBound) * gw
            for cx in 0..<gw {
                if let channel {
                    channelLogSum[channel * gw * gh + cy * gw + cx] += Double(sums[row + cx])
                    continue
                }
                let xLow = (cx * fw + gw - 1) / gw
                let xHigh = ((cx + 1) * fw + gw - 1) / gw
                logSum[cy * gw + cx] += Double(sums[row + cx])
                counts[cy * gw + cx] += xHigh - xLow
            }
        }
    }

    /// The shared accumulation walk. `rows` are absolute frame rows; `sample`
    /// is indexed relative to the first of them.
    private mutating func add(rows: Range<Int>,
                              _ sample: @escaping (Int) -> SIMD3<Float>) {
        guard !rows.isEmpty else { return }
        let (gw, gh) = (gridWidth, gridHeight)
        let (fw, fh) = (frameWidth, frameHeight)
        let (wr, wg, wb) = (weightR, weightG, weightB)
        let colour = metersColour, channelWeights = self.channelWeights
        let plane = gw * gh
        let firstCell = rows.lowerBound * gh / fh
        let lastCell = (rows.upperBound - 1) * gh / fh
        channelLogSum.withUnsafeMutableBufferPointer { channelSums in
        logSum.withUnsafeMutableBufferPointer { sums in
            counts.withUnsafeMutableBufferPointer { counts in
                ParallelWork.forEach(
                    iterations: lastCell - firstCell + 1
                ) { task in
                    let cy = firstCell + task
                    let yLow = max(rows.lowerBound, (cy * fh + gh - 1) / gh)
                    let yHigh = min(rows.upperBound, ((cy + 1) * fh + gh - 1) / gh)
                    for y in yLow..<yHigh {
                        let row = (y - rows.lowerBound) * fw
                        for cx in 0..<gw {
                            let xLow = (cx * fw + gw - 1) / gw
                            let xHigh = ((cx + 1) * fw + gw - 1) / gw
                            var sum = 0.0
                            var channelSum = SIMD3<Double>.zero
                            for x in xLow..<xHigh {
                                let rgb = sample(row + x)
                                let metered = wr * max(rgb.x, 0)
                                    + wg * max(rgb.y, 0) + wb * max(rgb.z, 0)
                                sum += Double(log2(max(metered, 1e-6)))
                                if colour {
                                    let each = channelWeights * SIMD3(max(rgb.x, 0),
                                                                      max(rgb.y, 0),
                                                                      max(rgb.z, 0))
                                    channelSum += SIMD3(Double(log2(max(each.x, 1e-6))),
                                                        Double(log2(max(each.y, 1e-6))),
                                                        Double(log2(max(each.z, 1e-6))))
                                }
                            }
                            sums[cy * gw + cx] += sum
                            counts[cy * gw + cx] += xHigh - xLow
                            if colour {
                                for c in 0..<3 {
                                    channelSums[c * plane + cy * gw + cx] += channelSum[c]
                                }
                            }
                        }
                    }
                }
            }
        }
        }
    }

    /// The accumulated regional log-luminances, one value per covered cell,
    /// in stops from metered mid-grey.
    public func regionStops() -> [Float] {
        var stops: [Float] = []
        stops.reserveCapacity(logSum.count)
        for i in 0..<logSum.count where counts[i] > 0 {
            stops.append(Float(logSum[i] / Double(counts[i])))
        }
        return stops
    }

    /// The frame's colour as Auto Levels reads it, in stops from metered mid-grey: green's median
    /// over the lit cells, and red and blue that far off it by the median of each lit cell's own
    /// ratio to green. A cell is lit above the frame's lower quartile and clear of the meter's
    /// floor, so a frame that is mostly black is read by what the light falls on. Nil when colour
    /// was not metered or nothing is lit.
    public func channelMedians() -> SIMD3<Float>? {
        guard metersColour else { return nil }
        let plane = logSum.count
        var luma: [Float] = [], cells: [SIMD3<Float>] = []
        for i in 0..<plane where counts[i] > 0 {
            luma.append(Float(logSum[i] / Double(counts[i])))
            cells.append(SIMD3((0..<3).map {
                Float(channelLogSum[$0 * plane + i] / Double(counts[i]))
            }))
        }
        guard let floor = Self.percentile(luma, 0.25).map({ max($0, Self.litFloorStops) })
        else { return nil }
        let lit = zip(luma, cells).filter { $0.0 >= floor }.map(\.1)
        guard let green = Self.percentile(lit.map(\.y), 0.5),
              let red = Self.percentile(lit.map { $0.x - $0.y }, 0.5),
              let blue = Self.percentile(lit.map { $0.z - $0.y }, 0.5) else { return nil }
        return SIMD3(green + red, green, green + blue)
    }

    /// Cells darker than this, in stops from mid-grey, are too near the meter's floor to carry
    /// colour.
    static let litFloorStops: Float = -12

    private static func percentile(_ values: [Float], _ q: Float) -> Float? {
        AutoAdjustment.SceneStops(regionStops: values).map { _ in
            let sorted = values.sorted()
            let position = q * Float(sorted.count - 1)
            let low = Int(position), high = min(low + 1, sorted.count - 1)
            return sorted[low] + (position - Float(low)) * (sorted[high] - sorted[low])
        }
    }

    /// The self-guided filter over the accumulated cells, returning the two
    /// coefficient planes the kernel samples.
    func solvedCoefficients() -> (a: [Float], b: [Float]) {
        let (gw, gh) = (gridWidth, gridHeight)
        let cells = gw * gh
        var g = [Double](repeating: 0, count: cells)
        for i in 0..<cells where counts[i] > 0 {
            g[i] = logSum[i] / Double(counts[i])
        }
        let radius = min(Self.windowRadius, max(gw, gh) - 1)
        let meanG = Self.boxMean(g, width: gw, height: gh, radius: radius)
        let meanGG = Self.boxMean(g.map { $0 * $0 }, width: gw, height: gh,
                                  radius: radius)
        var a = [Double](repeating: 0, count: cells)
        var b = [Double](repeating: 0, count: cells)
        for i in 0..<cells {
            let variance = max(0, meanGG[i] - meanG[i] * meanG[i])
            a[i] = variance / (variance + Self.epsilon)
            b[i] = (1 - a[i]) * meanG[i]
        }
        let smoothA = Self.boxMean(a, width: gw, height: gh, radius: radius)
        let smoothB = Self.boxMean(b, width: gw, height: gh, radius: radius)
        return (smoothA.map(Float.init), smoothB.map(Float.init))
    }

    /// Edge-clipped box mean via a summed-area table.
    static func boxMean(_ values: [Double], width: Int, height: Int,
                        radius: Int) -> [Double] {
        var sat = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            for x in 0..<width {
                rowSum += values[y * width + x]
                sat[(y + 1) * (width + 1) + x + 1] =
                    sat[y * (width + 1) + x + 1] + rowSum
            }
        }
        var result = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width - 1, x + radius)
                let sum = sat[(y1 + 1) * (width + 1) + x1 + 1]
                    - sat[y0 * (width + 1) + x1 + 1]
                    - sat[(y1 + 1) * (width + 1) + x0]
                    + sat[y0 * (width + 1) + x0]
                result[y * width + x] = sum / Double((y1 - y0 + 1) * (x1 - x0 + 1))
            }
        }
        return result
    }
}

/// Where metered levels place a frame, in the kernel's contrast and paper mid-point slots: a
/// scale and a shift for each record, red, green and blue. Auto Levels also gives the extra film
/// exposure, in the exposure slot; the stop it prints mid-grey, which keys the tone controls; and
/// the highlight hold and shadow lift that bring a frame wider than the print onto it.
struct MeteredLevels {
    var scale: SIMD3<Float> = .one
    var shift: SIMD3<Float> = .zero
    /// Lab Scan's keys and lightening on the film's exposure; its levels ride `scale` and `shift`.
    var film: LabScanTiming.Setup = .identity
    var filmBoost: Float = 0
    var toneKey: Float? = nil
    var shadowLift: Float = 0
    var highlightHold: Float = 0
}

extension FilmEngineInvocation {
    /// Whether the highlight and shadow controls are moving anything. The tone grid keys
    /// those two masks and nothing else, so this is also whether the light a scene forms reads
    /// the metered base: at rest, the masks lift nothing whatever the grid holds.
    public var toneControlsActive: Bool {
        configuration[Self.sceneAdjustOffset] + meterLevels.highlightHold != 0
            || configuration[Self.sceneAdjustOffset + 1] - meterLevels.shadowLift != 0
    }

    /// Whether the tone controls are doing anything *and* asked to be keyed locally.
    public var localToneActive: Bool { localToneEnabled && toneControlsActive }

    /// Whether Lab Scan's dodging is holding or lifting this frame.
    var labScanDodges: Bool {
        meterMedium == .labScan && (meterLevels.highlightHold != 0 || meterLevels.shadowLift != 0)
    }

    /// Whether the tone grid carries a regional base: the tone controls keyed locally, or Lab
    /// Scan's dodging, which is regional by nature. A host copying a measured frame's levels onto
    /// another develop copies the grid with them when this is true.
    public var toneKeyedLocally: Bool { localToneEnabled && (toneControlsActive || labScanDodges) }

    /// Whether Auto Levels' reading reaches the light a scene forms, and not the print alone: a
    /// negative's sets its film exposure and keys and moves its tone.
    public var screenLevelsReachLight: Bool {
        meterMedium == .screen && (meterStock.map(DigitalReferenceReceiver.keysTone) ?? false)
    }

    /// Whether Lab Scan meters this frame, whose dodge reaches the light a scene forms.
    public var labScanMeters: Bool { meterMedium == .labScan && meterStock != nil }

    /// Metered levels and local tone share one whole-frame measurement on CPU and Metal.
    public var sceneMeteringActive: Bool { localToneActive || meterStock != nil }

    public mutating func copyMeteredLevels(from measured: FilmEngineInvocation) {
        guard meterStock != nil else { return }
        applyMeteredLevels(measured.meterLevels)
    }

    private mutating func applyMeteredLevels(_ levels: MeteredLevels) {
        let ratio = levels.scale / meterLevels.scale
        for c in 0..<3 { configuration[Int(FOTUFILM_CONFIG_MASKING) + c] *= ratio[c] }
        // Green keeps the legacy mid-point slot; red and blue ride the appended ones.
        let offsets = [Self.paperMidpointRedOffset, Int(FOTUFILM_CONFIG_PAPER_MIDPOINT),
                       Self.paperMidpointBlueOffset]
        for c in 0..<3 {
            configuration[offsets[c]] += levels.shift[c] - meterLevels.shift[c]
        }
        configuration[Self.exposureGainOffset] *= exp2(levels.filmBoost - meterLevels.filmBoost)
        if levels.film.shift != meterLevels.film.shift || levels.film.keys != meterLevels.film.keys,
           let stock = meterStock {
            packFilmCurves(of: stock, setup: levels.film)
        }
        // The tone controls are keyed on the stop the print takes for mid-grey, unless they are
        // keyed regionally.
        if configuration[Self.toneGridSizeOffset] == 1, configuration[Self.toneGridSizeOffset + 1] == 1 {
            configuration[Self.toneGridBOffset] = -(levels.toneKey ?? 0)
        }
        let shadows = Self.sceneAdjustOffset + 1
        let userShadows = configuration[shadows] - meterLevels.shadowLift
        var levels = levels
        levels.shadowLift = min(levels.shadowLift, max(1 - userShadows, 0))
        configuration[shadows] = userShadows + levels.shadowLift
        // The highlight hold, likewise, stops where the highlight control does.
        let highlights = Self.sceneAdjustOffset
        let userHighlights = configuration[highlights] + meterLevels.highlightHold
        levels.highlightHold = min(levels.highlightHold, max(userHighlights + 1, 0))
        configuration[highlights] = userHighlights - levels.highlightHold
        meterLevels = levels
    }

    /// A fresh accumulator sized and weighted for this invocation's frame,
    /// white balance, and exposure.
    public func toneBaseMeasurement() -> ToneBaseMeasurement {
        let offset = Self.whiteBalanceOffset
        return ToneBaseMeasurement(
            frameWidth: Int(configuration[Self.frameSizeOffset]),
            frameHeight: Int(configuration[Self.frameSizeOffset + 1]),
            balance: SIMD3(configuration[offset], configuration[offset + 1],
                           configuration[offset + 2]),
            exposureGain: configuration[Self.exposureGainOffset],
            metersColour: screenMeterStock.map(DigitalReferenceReceiver.metersColour) ?? false)
    }

    /// The highlight reading this develop's levels take from a whole-frame measurement, or nil
    /// where it does not meter for levels. A host hands it to the develops that must print on the
    /// same levels as this frame, such as its unexposed edge.
    public func sceneHighlightStops(_ measurement: ToneBaseMeasurement) -> Float? {
        if meterStock != nil, meterMedium == .labScan {
            return AutoAdjustment.SceneStops(regionStops: measurement.regionStops())
                .map(LabScanTiming.highlight)
        }
        let exposureEV = log2(configuration[Self.exposureGainOffset]) - meterLevels.filmBoost
        return screenScene(measurement).map {
            DigitalReferenceReceiver.retimeHighlight($0, exposureEV: exposureEV)
        }
    }

    /// The tone reading Auto Levels takes from a whole-frame measurement, or nil where it does
    /// not meter: the frame's median and its two ends, the 0.5th and 99.5th percentiles. A host
    /// hands it on with `sceneHighlightStops`.
    public func sceneToneStops(_ measurement: ToneBaseMeasurement) -> SIMD3<Float>? {
        let scene = meterMedium == .labScan && meterStock != nil
            ? AutoAdjustment.SceneStops(regionStops: measurement.regionStops())
            : screenScene(measurement)
        return scene.map { SIMD3($0.median, $0.dark, $0.bright) }
    }

    /// The stock Auto Levels meters for, when this develop meters on the screen.
    private var screenMeterStock: FilmStock? { meterMedium == .screen ? meterStock : nil }

    private func screenScene(_ measurement: ToneBaseMeasurement) -> AutoAdjustment.SceneStops? {
        guard screenMeterStock != nil else { return nil }
        return AutoAdjustment.SceneStops(regionStops: measurement.regionStops())
    }

    /// The colour reading Auto Levels takes from a whole-frame measurement, or nil where it does
    /// not meter colour. A host hands it on with `sceneHighlightStops`.
    public func sceneChannelMedians(_ measurement: ToneBaseMeasurement) -> SIMD3<Float>? {
        guard screenMeterStock != nil else { return nil }
        return measurement.channelMedians()
    }

    /// Solves the accumulated measurement and pins the grid into the packed
    /// configuration, replacing the identity default.
    public mutating func setToneBase(_ measurement: ToneBaseMeasurement) {
        // Auto Levels' own hold and lift are keyed on its print grey, as a host that hands the
        // reading on gets them; the user's tone controls and Lab Scan's dodging take the
        // regional key.
        if let stock = meterStock, meterMedium == .labScan,
           let scene = AutoAdjustment.SceneStops(regionStops: measurement.regionStops()) {
            let dodge = LabScanTiming.dodge(scene, strength: meterDodging)
            let setup = LabScanTiming.setup(
                for: stock, sceneHighlightStops: LabScanTiming.highlight(scene),
                sceneMedianStops: scene.median, exposureEV: meterExposureEV,
                scanExposure: meterScanExposure, keys: meterKeys)
            applyMeteredLevels(MeteredLevels(scale: setup.scale, shift: setup.print, film: setup,
                                             toneKey: dodge.key,
                                             shadowLift: dodge.lift, highlightHold: dodge.hold))
        }
        let keyedLocally = toneKeyedLocally
        if let stock = screenMeterStock, let scene = screenScene(measurement) {
            // The meter reads the frame after the edit's exposure and before any film boost.
            let exposureEV = log2(configuration[Self.exposureGainOffset])
                - meterLevels.filmBoost
            let white = DigitalReferenceReceiver.retimeHighlight(scene, exposureEV: exposureEV)
            let boost = DigitalReferenceReceiver.filmBoost(for: stock, white: white,
                                                           exposureEV: exposureEV)
            let levels = DigitalReferenceReceiver.levels(
                for: stock, style: .autoLevels, sceneHighlightStops: white + boost,
                exposureEV: exposureEV)
            let colour = DigitalReferenceReceiver.autoColourShift(
                for: stock, channelMedians: sceneChannelMedians(measurement).map { $0 + boost },
                exposureEV: exposureEV)
            let compression = DigitalReferenceReceiver.toneCompression(for: stock, scene,
                                                                           white: white)
            applyMeteredLevels(MeteredLevels(
                scale: SIMD3(repeating: levels.scale), shift: SIMD3(repeating: levels.shift) + colour,
                filmBoost: boost,
                toneKey: DigitalReferenceReceiver.keysTone(stock)
                    ? DigitalReferenceReceiver.toneKey(white: white) + boost : nil,
                shadowLift: compression.lift, highlightHold: compression.hold))
        }
        // Levels meter the same regions even when local tone is disabled. Keep the
        // whole-frame key in that case: automatic headroom adjustment can still supply a
        // nonzero highlight control, which must remain keyed by each pixel's own brightness.
        guard keyedLocally else { return }
        let (a, b) = measurement.solvedCoefficients()
        // Lab Scan keys its regions on the frame's median, as its whole-frame key does.
        let key = meterMedium == .labScan ? meterLevels.toneKey ?? 0 : 0
        configuration[Self.toneGridSizeOffset] = Float(measurement.gridWidth)
        configuration[Self.toneGridSizeOffset + 1] = Float(measurement.gridHeight)
        for i in 0..<a.count {
            configuration[Self.toneGridAOffset + i] = a[i]
            configuration[Self.toneGridBOffset + i] = b[i] - key
        }
    }

    /// Whole-frame convenience for callers holding planar linear RGB.
    public mutating func measureToneBase(
        planarR red: UnsafePointer<Float>, g green: UnsafePointer<Float>,
        b blue: UnsafePointer<Float>, width: Int, height: Int
    ) {
        var measurement = toneBaseMeasurement()
        measurement.add(planarR: red, g: green, b: blue, rows: 0..<height)
        setToneBase(measurement)
    }

    /// Whole-frame convenience for callers holding interleaved linear RGBA.
    public mutating func measureToneBase(
        linearRGBA pixels: UnsafePointer<Float>, width: Int, height: Int
    ) {
        var measurement = toneBaseMeasurement()
        measurement.add(linearRGBA: pixels, rows: 0..<height)
        setToneBase(measurement)
    }

    /// Whole-frame convenience for callers holding interleaved sRGB bytes.
    public mutating func measureToneBase(
        srgbRGBA bytes: UnsafePointer<UInt8>, width: Int, height: Int
    ) {
        var measurement = toneBaseMeasurement()
        measurement.add(srgbRGBA: bytes, rows: 0..<height)
        setToneBase(measurement)
    }

    /// Whole-frame convenience for Apple video buffers carrying encoded Display P3.
    public mutating func measureToneBase(
        encodedDisplayP3RGBA bytes: UnsafePointer<UInt8>, width: Int, height: Int
    ) {
        var measurement = toneBaseMeasurement()
        measurement.add(encodedDisplayP3RGBA: bytes, rows: 0..<height)
        setToneBase(measurement)
    }
}
