import Foundation

/// Whole-frame measurement used by local highlight and shadow masks.
public struct ToneBaseMeasurement {
    /// Cells along the grid's long edge; mirrors FOTUFILM_TONE_GRID_EDGE.
    public static let gridEdge = 64

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

    public init(frameWidth: Int, frameHeight: Int,
                balance: SIMD3<Float>, exposureGain: Float) {
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
        guard !rows.isEmpty else { return }
        let (gw, gh) = (gridWidth, gridHeight)
        let (fw, fh) = (frameWidth, frameHeight)
        for y in rows {
            let cy = y * gh / fh
            let row = (y - rows.lowerBound) * gw
            for cx in 0..<gw {
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
        let firstCell = rows.lowerBound * gh / fh
        let lastCell = (rows.upperBound - 1) * gh / fh
        logSum.withUnsafeMutableBufferPointer { sums in
            counts.withUnsafeMutableBufferPointer { counts in
                DispatchQueue.concurrentPerform(
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
                            for x in xLow..<xHigh {
                                let rgb = sample(row + x)
                                let metered = wr * max(rgb.x, 0)
                                    + wg * max(rgb.y, 0) + wb * max(rgb.z, 0)
                                sum += Double(log2(max(metered, 1e-6)))
                            }
                            sums[cy * gw + cx] += sum
                            counts[cy * gw + cx] += xHigh - xLow
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

extension FilmEngineInvocation {
    /// Whether the tone controls are doing anything *and* asked to be keyed locally.
    public var localToneActive: Bool {
        localToneEnabled
            && (configuration[Self.sceneAdjustOffset] != 0
                || configuration[Self.sceneAdjustOffset + 1] != 0)
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
            exposureGain: configuration[Self.exposureGainOffset])
    }

    /// Solves the accumulated measurement and pins the grid into the packed
    /// configuration, replacing the identity default.
    public mutating func setToneBase(_ measurement: ToneBaseMeasurement) {
        let (a, b) = measurement.solvedCoefficients()
        configuration[Self.toneGridSizeOffset] = Float(measurement.gridWidth)
        configuration[Self.toneGridSizeOffset + 1] = Float(measurement.gridHeight)
        for i in 0..<a.count {
            configuration[Self.toneGridAOffset + i] = a[i]
            configuration[Self.toneGridBOffset + i] = b[i]
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
