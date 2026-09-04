#if canImport(Metal)
import Metal
import XCTest
@testable import FotufilmCore
@testable import FotufilmImaging
@testable import FotufilmMetal

/// End-to-end proof against the still export's real oracle. Component tests are useful for
/// locating a defect, but they can agree while their composition disagrees with the complete
/// reference schedule. These tests therefore enter through scene-linear Float32 on both roads,
/// invoke `developStreaming` exactly as the offline exporter does, and compare both its linear
/// print and its 16-bit delivery codes with the handwritten full-frame graph.
final class HandwrittenMetalFullFrameOfflineParityTests: XCTestCase {
    private static let width = 80
    private static let height = 48
    private static let frameIndex: UInt64 = 0x4F46_464C_494E_4501
    /// The production handwritten graph is the standard full-quality approximation mode, not the
    /// separate opt-in exact-transcendental export variant. Match that bit explicitly on the oracle.
    private static let exactMath = false

    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let renderer: HandwrittenMetalFullFrameRenderer
        let delivery: HandwrittenMetalStillDelivery
        let digitalDelivery: HandwrittenMetalDigitalDelivery
        let oracle: HalideMetalFilmRenderer

        init() throws {
            device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            queue = try XCTUnwrap(device.makeCommandQueue())
            renderer = try XCTUnwrap(HandwrittenMetalFullFrameRenderer(
                device: device, maximumInFlightFrames: 1,
                spatialOptimizationVariant: .perceptualMultires))
            delivery = try HandwrittenMetalStillDelivery(device: device)
            digitalDelivery = try HandwrittenMetalDigitalDelivery(device: device)
            oracle = try XCTUnwrap(HalideMetalFilmRenderer.shared)
        }
    }

    private struct ParityCase {
        let name: String
        let stock: FilmStock
        let options: FotufilmEngine.Options
        let requiredMask: Int32
        let expectsLocalTone: Bool
    }

    private struct Result {
        let master: [Float]
        let hdrCodes: [UInt16]
        let sdrCodes: [UInt16]
    }

    private struct Metrics {
        var maximumLinear: Float = 0
        var totalLinear: Double = 0
        var maximumDeltaE: Double = 0
        var totalDeltaE: Double = 0
        var maximumHDRCode = 0
        var totalHDRCode: UInt64 = 0
        var maximumSDRCode = 0
        var totalSDRCode: UInt64 = 0
        var colourValues = 0
        var pixels = 0

        var meanLinear: Double { totalLinear / Double(max(colourValues, 1)) }
        var meanDeltaE: Double { totalDeltaE / Double(max(pixels, 1)) }
        var meanHDRCode: Double { Double(totalHDRCode) / Double(max(colourValues, 1)) }
        var meanSDRCode: Double { Double(totalSDRCode) / Double(max(colourValues, 1)) }
    }

    private struct X420Codes {
        let luma: [Int]
        let chroma: [Int]
    }

    private struct CodeMetrics {
        let maximum: Int
        let mean: Double
    }

    func testSceneLinearMasterAndSixteenBitDeliveriesTrackOfflineHalideFeatureMatrix()
        throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide offline export oracle required")
        let harness = try Harness()
        let scene = representativeHDRScene(width: Self.width, height: Self.height)

        for parity in parityCases(width: Self.width, height: Self.height) {
            let invocation = FilmEngineInvocation(
                stock: parity.stock, options: parity.options,
                width: Self.width, height: Self.height,
                frameIndex: Self.frameIndex)
            XCTAssertEqual(
                invocation.featureMask & parity.requiredMask,
                parity.requiredMask, "\(parity.name): fixture did not enable its stages")
            XCTAssertEqual(
                invocation.localToneActive, parity.expectsLocalTone,
                "\(parity.name): fixture local-tone state")

            let actual = try handwritten(
                scene: scene, parity: parity, harness: harness,
                frameIndex: Self.frameIndex)
            let expectedMaster = try offlineHalide(
                scene: scene, parity: parity, oracle: harness.oracle,
                frameIndex: Self.frameIndex)
            let expectedHDR = encode16(
                expectedMaster, converter: .rec2020HLG,
                width: Self.width, height: Self.height)
            let expectedSDR = encode16(
                expectedMaster, converter: .rec709SDR,
                width: Self.width, height: Self.height)
            let metrics = compare(
                actual: actual, expectedMaster: expectedMaster,
                expectedHDR: expectedHDR, expectedSDR: expectedSDR)

            // The master crosses two intentionally binary16 seams (record density and output).
            // The maxima include the two-population grain blur's half stores; mean and displayed
            // error remain much tighter. The limits leave measured platform margin without hiding
            // a decorrelated grain realization, which exceeds them by more than an order of
            // magnitude.
            XCTAssertLessThanOrEqual(
                metrics.maximumLinear, 0.01,
                "\(parity.name): max linear \(metrics.maximumLinear), mean \(metrics.meanLinear)")
            XCTAssertLessThanOrEqual(
                metrics.meanLinear, 0.001,
                "\(parity.name): max linear \(metrics.maximumLinear), mean \(metrics.meanLinear)")
            XCTAssertLessThanOrEqual(
                metrics.maximumDeltaE, 1.25,
                "\(parity.name): max dE76 \(metrics.maximumDeltaE), mean \(metrics.meanDeltaE)")
            XCTAssertLessThanOrEqual(
                metrics.meanDeltaE, 0.2,
                "\(parity.name): max dE76 \(metrics.maximumDeltaE), mean \(metrics.meanDeltaE)")
            XCTAssertLessThanOrEqual(
                metrics.maximumHDRCode, 512,
                "\(parity.name): max HDR16 \(metrics.maximumHDRCode), mean \(metrics.meanHDRCode)")
            XCTAssertLessThanOrEqual(
                metrics.meanHDRCode, 64,
                "\(parity.name): max HDR16 \(metrics.maximumHDRCode), mean \(metrics.meanHDRCode)")
            XCTAssertLessThanOrEqual(
                metrics.maximumSDRCode, 768,
                "\(parity.name): max SDR16 \(metrics.maximumSDRCode), mean \(metrics.meanSDRCode)")
            XCTAssertLessThanOrEqual(
                metrics.meanSDRCode, 80,
                "\(parity.name): max SDR16 \(metrics.maximumSDRCode), mean \(metrics.meanSDRCode)")
        }
    }

    func testAllOnSeededGrainIsDeterministicAgainstOfflineHalide() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide offline export oracle required")
        let harness = try Harness()
        let scene = representativeHDRScene(width: Self.width, height: Self.height)
        let parity = try XCTUnwrap(
            parityCases(width: Self.width, height: Self.height)
                .first(where: { $0.name == "all-on" }))

        let first = try handwritten(
            scene: scene, parity: parity, harness: harness,
            frameIndex: Self.frameIndex)
        let repeated = try handwritten(
            scene: scene, parity: parity, harness: harness,
            frameIndex: Self.frameIndex)
        let next = try handwritten(
            scene: scene, parity: parity, harness: harness,
            frameIndex: Self.frameIndex &+ 1)
        XCTAssertEqual(first.master, repeated.master)
        XCTAssertEqual(first.hdrCodes, repeated.hdrCodes)
        XCTAssertEqual(first.sdrCodes, repeated.sdrCodes)
        XCTAssertNotEqual(first.master, next.master)

        let oracle = try offlineHalide(
            scene: scene, parity: parity, oracle: harness.oracle,
            frameIndex: Self.frameIndex)
        let oracleRepeated = try offlineHalide(
            scene: scene, parity: parity, oracle: harness.oracle,
            frameIndex: Self.frameIndex)
        let oracleNext = try offlineHalide(
            scene: scene, parity: parity, oracle: harness.oracle,
            frameIndex: Self.frameIndex &+ 1)
        XCTAssertEqual(oracle, oracleRepeated)
        XCTAssertNotEqual(oracle, oracleNext)
    }

    func testUniformHDRFieldRemainsUniformThroughAllSpatialStages() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide offline export oracle required")
        let harness = try Harness()
        var parity = try XCTUnwrap(
            parityCases(width: Self.width, height: Self.height)
                .first(where: { $0.name == "all-on" }))
        parity = ParityCase(
            name: "all-spatial-uniform", stock: parity.stock,
            options: withoutGrain(parity.options),
            requiredMask: parity.requiredMask & ~FilmEngineFeature.grain,
            expectsLocalTone: true)
        let pixel = SIMD4<Float>(1.75, 1.75, 1.75, 1)
        let scene = [Float](
            repeating: 0, count: Self.width * Self.height * 4)
        var uniform = scene
        for offset in stride(from: 0, to: uniform.count, by: 4) {
            uniform[offset] = pixel.x
            uniform[offset + 1] = pixel.y
            uniform[offset + 2] = pixel.z
            uniform[offset + 3] = pixel.w
        }

        let actual = try handwritten(
            scene: uniform, parity: parity, harness: harness,
            frameIndex: Self.frameIndex)
        let expected = try offlineHalide(
            scene: uniform, parity: parity, oracle: harness.oracle,
            frameIndex: Self.frameIndex)
        assertUniform(actual.master, tolerance: 0.001, label: "handwritten")
        assertUniform(expected, tolerance: 0.000_02, label: "Halide")

        let expectedHDR = encode16(
            expected, converter: .rec2020HLG,
            width: Self.width, height: Self.height)
        let expectedSDR = encode16(
            expected, converter: .rec709SDR,
            width: Self.width, height: Self.height)
        let metrics = compare(
            actual: actual, expectedMaster: expected,
            expectedHDR: expectedHDR, expectedSDR: expectedSDR)
        XCTAssertLessThanOrEqual(metrics.maximumLinear, 0.01)
        XCTAssertLessThanOrEqual(metrics.maximumDeltaE, 1.0)
    }

    func testX420HLGTracksOfflineMasterThroughCanonicalBT2020Quantization() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide offline export oracle required")
        let harness = try Harness()
        let parity = try XCTUnwrap(
            parityCases(width: Self.width, height: Self.height)
                .first(where: { $0.name == "all-on" }))
        var master = try offlineHalide(
            scene: representativeHDRScene(width: Self.width, height: Self.height),
            parity: parity, oracle: harness.oracle, frameIndex: Self.frameIndex)

        // Constant 2x2 blocks exercise the chroma siting independently of spatial averaging. They
        // include saturated Display-P3 primaries, an HDR mixture, and alpha relighting on top of
        // the real offline print so the reference covers both ordinary imagery and gamut edges.
        let probes: [SIMD4<Float>] = [
            SIMD4(4, 0, 0, 1), SIMD4(0, 4, 0, 1), SIMD4(0, 0, 4, 1),
            SIMD4(3.2, 0.15, 1.8, 1), SIMD4(0.15, 0.04, 0.8, 2.25),
        ]
        for (block, probe) in probes.enumerated() {
            let blockX = block * 2
            for y in 0..<2 {
                for x in 0..<2 {
                    let offset = (y * Self.width + blockX + x) * 4
                    master[offset] = probe.x
                    master[offset + 1] = probe.y
                    master[offset + 2] = probe.z
                    master[offset + 3] = probe.w
                }
            }
        }
        let storedMaster = master.map { Float(Float16($0)) }
        let actual = try deliverX420(master: storedMaster, harness: harness)
        let expected = canonicalX420(master: storedMaster)
        let luma = codeMetrics(actual.luma, expected.luma)
        let chroma = codeMetrics(actual.chroma, expected.chroma)

        // Safe Metal math and the portable converter may straddle a quantizer boundary, but a
        // matrix, transfer, range, or plane-order error moves saturated chroma by hundreds.
        XCTAssertLessThanOrEqual(
            luma.maximum, 2,
            "offline master x420 luma max \(luma.maximum), mean \(luma.mean)")
        XCTAssertLessThanOrEqual(
            luma.mean, 0.1,
            "offline master x420 luma max \(luma.maximum), mean \(luma.mean)")
        XCTAssertLessThanOrEqual(
            chroma.maximum, 2,
            "offline master x420 chroma max \(chroma.maximum), mean \(chroma.mean)")
        XCTAssertLessThanOrEqual(
            chroma.mean, 0.1,
            "offline master x420 chroma max \(chroma.maximum), mean \(chroma.mean)")
    }

    private func handwritten(
        scene: [Float], parity: ParityCase, harness: Harness,
        frameIndex: UInt64
    ) throws -> Result {
        let key = "offline-parity-\(parity.name)-\(frameIndex)"
        try harness.renderer.prepareChecked(
            key: key, stock: parity.stock, options: parity.options,
            frameWidth: Self.width, frameHeight: Self.height)
        let input = try scene.withUnsafeBytes { bytes in
            try XCTUnwrap(harness.device.makeBuffer(
                bytes: bytes.baseAddress!, length: bytes.count,
                options: .storageModeShared))
        }
        let master = try rgba16Texture(
            device: harness.device, width: Self.width, height: Self.height)
        let hdr = try rgba16Texture(
            device: harness.device, width: Self.width, height: Self.height)
        let sdr = try rgba16Texture(
            device: harness.device, width: Self.width, height: Self.height)
        let commands = try XCTUnwrap(harness.queue.makeCommandBuffer())
        XCTAssertTrue(harness.renderer.encodeSceneLinearRec2020RGBAFloat(
            sceneLinearRec2020RGBAFloat: input, output: master,
            width: Self.width, height: Self.height, key: key,
            frameIndex: frameIndex, commandBuffer: commands))
        try harness.delivery.encode(
            master: master, output: hdr, as: .hdrHLGRec2020,
            commandBuffer: commands)
        try harness.delivery.encode(
            master: master, output: sdr, as: .sdrRec709,
            commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed,
                       commands.error?.localizedDescription ?? "")
        return Result(
            master: readRGBA16(master).map(Float.init),
            hdrCodes: codes(readRGBA16(hdr)),
            sdrCodes: codes(readRGBA16(sdr)))
    }

    private func offlineHalide(
        scene: [Float], parity: ParityCase,
        oracle: HalideMetalFilmRenderer, frameIndex: UInt64
    ) throws -> [Float] {
        var output = [Float](repeating: 0, count: scene.count)
        let ok = scene.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                oracle.developStreaming(
                    width: Self.width, height: Self.height,
                    stock: parity.stock, options: parity.options,
                    frameIndex: frameIndex, realtime: false,
                    exactMath: Self.exactMath, overlapsWriteback: false,
                    readRows: { rows, into in
                        into.baseAddress!.update(
                            from: source.baseAddress!
                                .advanced(by: rows.lowerBound * Self.width * 4),
                            count: rows.count * Self.width * 4)
                    },
                    writeRows: { rows, from in
                        destination.baseAddress!
                            .advanced(by: rows.lowerBound * Self.width * 4)
                            .update(from: from.baseAddress!,
                                    count: rows.count * Self.width * 4)
                    })
            }
        }
        XCTAssertTrue(ok, "\(parity.name): offline Halide render failed")
        return output
    }

    private func encode16(
        _ master: [Float], converter: FilmOutputConversion,
        width: Int, height: Int
    ) -> [UInt16] {
        var output = [UInt16](repeating: 0, count: master.count)
        master.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                PrintEncoding.encodeRows(
                    source, rows: 0..<height, width: width,
                    into: destination, converter: converter)
            }
        }
        return output
    }

    private func compare(
        actual: Result, expectedMaster: [Float],
        expectedHDR: [UInt16], expectedSDR: [UInt16]
    ) -> Metrics {
        precondition(actual.master.count == expectedMaster.count)
        precondition(actual.hdrCodes.count == expectedHDR.count)
        precondition(actual.sdrCodes.count == expectedSDR.count)
        var result = Metrics()
        for pixel in 0..<(expectedMaster.count / 4) {
            let base = pixel * 4
            let expectedRGB = SIMD3(
                max(expectedMaster[base], 0),
                max(expectedMaster[base + 1], 0),
                max(expectedMaster[base + 2], 0))
            let actualRGB = SIMD3(
                actual.master[base], actual.master[base + 1],
                actual.master[base + 2])
            for channel in 0..<3 {
                let linearError = abs(actualRGB[channel] - expectedRGB[channel])
                result.maximumLinear = max(result.maximumLinear, linearError)
                result.totalLinear += Double(linearError)
                let hdrError = abs(Int(actual.hdrCodes[base + channel])
                                   - Int(expectedHDR[base + channel]))
                let sdrError = abs(Int(actual.sdrCodes[base + channel])
                                   - Int(expectedSDR[base + channel]))
                result.maximumHDRCode = max(result.maximumHDRCode, hdrError)
                result.maximumSDRCode = max(result.maximumSDRCode, sdrError)
                result.totalHDRCode += UInt64(hdrError)
                result.totalSDRCode += UInt64(sdrError)
                result.colourValues += 1
            }
            let delta = displayDeltaE(actualRGB, expectedRGB)
            result.maximumDeltaE = max(result.maximumDeltaE, delta)
            result.totalDeltaE += delta
            result.pixels += 1
        }
        return result
    }

    private func parityCases(width: Int, height: Int) -> [ParityCase] {
        let format = FilmFormat(
            name: "Offline/Halide parity fixture",
            frameHeightMM: Float(height) / 60)
        func options(
            tone: Bool = false, flare: Bool = false,
            halation: Bool = false, couplers: Bool = false,
            grain: Bool = false, mottle: Bool = false,
            pixelsPerMM: Float = 60
        ) -> FotufilmEngine.Options {
            var result = FotufilmEngine.Options()
            result.paper = .screen
            result.format = pixelsPerMM == 60 ? format : FilmFormat(
                name: "Offline/Halide parity fixture @ \(pixelsPerMM) px/mm",
                frameHeightMM: Float(height) / pixelsPerMM)
            result.sceneHeadroom = 4
            result.localTone = tone
            result.highlights = tone ? 0.32 : 0
            result.shadows = tone ? -0.24 : 0
            result.flareScale = flare ? 1 : 0
            result.halationScale = halation ? 1 : 0
            result.couplerScale = couplers ? 1 : 0
            result.grainScale = grain ? 1 : 0
            if mottle {
                result.grainMottleShare = 0.35
                result.grainMottleSizeRatio = 4
            }
            result.seed = 0x5354_494C_4C5F_4844
            return result
        }
        func stock(
            mtf: Bool = false, flare: Bool = false,
            halation: Bool = false, interimage: Bool = false,
            grain: Bool = false, monochrome: Bool = false
        ) -> FilmStock {
            var result = monochrome ? TestStocks.monochrome : TestStocks.negative
            result.flare = flare ? 0.18 : 0
            if !mtf {
                result.emulsionDiffusionMM = [0, 0, 0]
                result.emulsionDiffusionSecondaryMM = [0, 0, 0]
                result.emulsionDiffusionPrimaryShare = [1, 1, 1]
                result.mtfLumaShare = 0
                result.lumaDiffusionMM = 0
            }
            if !halation {
                result.halationStrength = [0, 0, 0]
                result.halationProfile = nil
                result.estimatedHalationProfile = nil
            }
            if !interimage {
                result.couplerGeometry = nil
                result.couplerInhibition = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
                result.couplerDiffusionMM = 0
                result.adjacencyStrength = 0
                result.adjacencyRadiusMM = 0
            }
            if !grain { result.grainStrength = 0 }
            return result
        }

        let mtfMask = FilmEngineFeature.mtf
        let halationMask = FilmEngineFeature.halation
        let interimageMask = FilmEngineFeature.couplers
            | FilmEngineFeature.couplerDiffusion | FilmEngineFeature.adjacency
        let allMask = mtfMask | halationMask | interimageMask
            | FilmEngineFeature.flare | FilmEngineFeature.grain
            | FilmEngineFeature.grainMottle
        return [
            ParityCase(
                name: "spectral-tail", stock: stock(), options: options(),
                requiredMask: 0, expectsLocalTone: false),
            ParityCase(
                name: "mtf", stock: stock(mtf: true), options: options(),
                requiredMask: mtfMask, expectsLocalTone: false),
            ParityCase(
                name: "local-tone-flare", stock: stock(flare: true),
                options: options(tone: true, flare: true),
                requiredMask: FilmEngineFeature.flare, expectsLocalTone: true),
            ParityCase(
                name: "halation", stock: stock(halation: true),
                options: options(halation: true),
                requiredMask: halationMask, expectsLocalTone: false),
            ParityCase(
                name: "couplers-adjacency", stock: stock(interimage: true),
                options: options(couplers: true),
                requiredMask: interimageMask, expectsLocalTone: false),
            ParityCase(
                name: "grain", stock: stock(grain: true),
                options: options(grain: true),
                requiredMask: FilmEngineFeature.grain, expectsLocalTone: false),
            ParityCase(
                name: "grain-gaussian-limit", stock: stock(grain: true),
                options: options(grain: true, pixelsPerMM: 30),
                requiredMask: FilmEngineFeature.grain, expectsLocalTone: false),
            ParityCase(
                name: "grain-mottle", stock: stock(grain: true),
                options: options(grain: true, mottle: true),
                requiredMask: FilmEngineFeature.grain | FilmEngineFeature.grainMottle,
                expectsLocalTone: false),
            ParityCase(
                name: "monochrome-grain-mottle",
                stock: stock(grain: true, monochrome: true),
                options: options(grain: true, mottle: true),
                requiredMask: FilmEngineFeature.monochrome | FilmEngineFeature.grain
                    | FilmEngineFeature.grainMottle,
                expectsLocalTone: false),
            ParityCase(
                name: "all-on",
                stock: stock(
                    mtf: true, flare: true, halation: true,
                    interimage: true, grain: true),
                options: options(
                    tone: true, flare: true, halation: true,
                    couplers: true, grain: true, mottle: true),
                requiredMask: allMask, expectsLocalTone: true),
        ]
    }

    private func withoutGrain(
        _ source: FotufilmEngine.Options
    ) -> FotufilmEngine.Options {
        var result = source
        result.grainScale = 0
        return result
    }

    private func representativeHDRScene(width: Int, height: Int) -> [Float] {
        var result = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let u = Float(x) / Float(max(width - 1, 1))
                let v = Float(y) / Float(max(height - 1, 1))
                let sweep = exp2(-5 + 8 * u)
                let checker: Float = ((x / 7 + y / 5) & 1) == 0 ? 0.72 : 1.28
                let highlight = (x - width * 3 / 4) * (x - width * 3 / 4)
                        + (y - height / 3) * (y - height / 3) < 36
                    ? Float(5.5) : 0
                result[offset] = sweep * checker * (0.55 + 0.9 * v) + highlight
                result[offset + 1] = sweep * (1.15 - 0.45 * v) + 0.62 * highlight
                result[offset + 2] = sweep * (0.42 + 0.7 * (1 - u)) + 0.24 * highlight
                result[offset + 3] = 1
            }
        }
        return result
    }

    private func deliverX420(
        master values: [Float], harness: Harness
    ) throws -> X420Codes {
        let master = try rgba16Texture(
            device: harness.device, width: Self.width, height: Self.height)
        let stored = values.map(Float16.init)
        stored.withUnsafeBytes { bytes in
            master.replace(
                region: MTLRegionMake2D(0, 0, Self.width, Self.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: Self.width * MemoryLayout<SIMD4<Float16>>.stride)
        }
        let luma = try planeTexture(
            device: harness.device, format: .r16Unorm,
            width: Self.width, height: Self.height)
        let chroma = try planeTexture(
            device: harness.device, format: .rg16Unorm,
            width: Self.width / 2, height: Self.height / 2)
        let commands = try XCTUnwrap(harness.queue.makeCommandBuffer())
        try harness.digitalDelivery.encode(
            master: master, luma: luma, chroma: chroma,
            output: .hdrHLGRec2020, commandBuffer: commands)
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed,
                       commands.error?.localizedDescription ?? "")

        var lumaWords = [UInt16](repeating: 0, count: Self.width * Self.height)
        lumaWords.withUnsafeMutableBytes { bytes in
            luma.getBytes(
                bytes.baseAddress!, bytesPerRow: Self.width * 2,
                from: MTLRegionMake2D(0, 0, Self.width, Self.height),
                mipmapLevel: 0)
        }
        var chromaWords = [UInt16](
            repeating: 0, count: Self.width / 2 * Self.height / 2 * 2)
        chromaWords.withUnsafeMutableBytes { bytes in
            chroma.getBytes(
                bytes.baseAddress!, bytesPerRow: Self.width * 2,
                from: MTLRegionMake2D(
                    0, 0, Self.width / 2, Self.height / 2),
                mipmapLevel: 0)
        }
        func code(_ word: UInt16) -> Int {
            Int((UInt32(word) + 32) / 64)
        }
        return X420Codes(
            luma: lumaWords.map(code), chroma: chromaWords.map(code))
    }

    private func canonicalX420(master: [Float]) -> X420Codes {
        var hlg = [Float](repeating: 0, count: master.count)
        master.withUnsafeBufferPointer { source in
            hlg.withUnsafeMutableBufferPointer { destination in
                FilmOutputConversion.rec2020HLG.convert(
                    source, from: 0, count: source.count, into: destination)
            }
        }
        func encoded(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let offset = (y * Self.width + x) * 4
            let signal = SIMD3(hlg[offset], hlg[offset + 1], hlg[offset + 2])
            let luma = 0.2627 * signal.x + 0.6780 * signal.y + 0.0593 * signal.z
            return SIMD3(
                luma, (signal.z - luma) / 1.8814,
                (signal.x - luma) / 1.4746)
        }
        func lumaCode(_ value: Float) -> Int {
            Int(floor(min(max(value, 0), 1) * 876 + 64.5))
        }
        func chromaCode(_ value: Float) -> Int {
            Int(floor(min(max(value, -0.5), 0.5) * 896 + 512.5))
        }

        var luma = [Int](repeating: 0, count: Self.width * Self.height)
        var chroma = [Int](
            repeating: 0, count: Self.width / 2 * Self.height / 2 * 2)
        for blockY in 0..<(Self.height / 2) {
            for blockX in 0..<(Self.width / 2) {
                let x = blockX * 2
                let y = blockY * 2
                let a = encoded(x, y)
                let b = encoded(x + 1, y)
                let c = encoded(x, y + 1)
                let d = encoded(x + 1, y + 1)
                luma[y * Self.width + x] = lumaCode(a.x)
                luma[y * Self.width + x + 1] = lumaCode(b.x)
                luma[(y + 1) * Self.width + x] = lumaCode(c.x)
                luma[(y + 1) * Self.width + x + 1] = lumaCode(d.x)
                let destination = (blockY * (Self.width / 2) + blockX) * 2
                chroma[destination] = chromaCode((a.y + b.y + c.y + d.y) * 0.25)
                chroma[destination + 1] = chromaCode(
                    (a.z + b.z + c.z + d.z) * 0.25)
            }
        }
        return X420Codes(luma: luma, chroma: chroma)
    }

    private func codeMetrics(_ actual: [Int], _ expected: [Int]) -> CodeMetrics {
        precondition(actual.count == expected.count)
        var maximum = 0
        var total: UInt64 = 0
        for (lhs, rhs) in zip(actual, expected) {
            let error = abs(lhs - rhs)
            maximum = max(maximum, error)
            total += UInt64(error)
        }
        return CodeMetrics(
            maximum: maximum,
            mean: Double(total) / Double(max(actual.count, 1)))
    }

    private func rgba16Texture(
        device: MTLDevice, width: Int, height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height,
            mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func planeTexture(
        device: MTLDevice, format: MTLPixelFormat,
        width: Int, height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height,
            mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func readRGBA16(_ texture: MTLTexture) -> [Float16] {
        var result = [Float16](
            repeating: 0, count: texture.width * texture.height * 4)
        result.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!, bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0)
        }
        return result
    }

    private func codes(_ values: [Float16]) -> [UInt16] {
        values.map { value in
            UInt16((min(max(Float(value), 0), 1) * 65_535).rounded())
        }
    }

    private func assertUniform(
        _ values: [Float], tolerance: Float, label: String
    ) {
        for channel in 0..<3 {
            let anchor = values[channel]
            var maximum: Float = 0
            for pixel in 1..<(values.count / 4) {
                maximum = max(maximum, abs(values[pixel * 4 + channel] - anchor))
            }
            XCTAssertLessThanOrEqual(
                maximum, tolerance,
                "\(label) channel \(channel) drifted by \(maximum)")
        }
    }

    private func displayDeltaE(
        _ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>
    ) -> Double {
        func displayed(_ value: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(
                min(max(ColorScience.displayShoulder(value.x), 0), 1),
                min(max(ColorScience.displayShoulder(value.y), 0), 1),
                min(max(ColorScience.displayShoulder(value.z), 0), 1))
        }
        let difference = cieLab(displayed(lhs)) - cieLab(displayed(rhs))
        return sqrt(difference.x * difference.x
                    + difference.y * difference.y
                    + difference.z * difference.z)
    }

    /// Display-P3/D65 linear light to CIE Lab. Delta-E 76 is deliberately conservative here;
    /// it is a regression bound on the displayed print, not a claim about HDR appearance modelling.
    private func cieLab(_ p3: SIMD3<Float>) -> SIMD3<Double> {
        let red = Double(p3.x), green = Double(p3.y), blue = Double(p3.z)
        let x = (0.4865709486482162 * red + 0.2656676931690931 * green
                 + 0.1982172852343625 * blue) / 0.95047
        let y = 0.2289745640697488 * red + 0.6917385218365064 * green
            + 0.0792869140937450 * blue
        let z = (0.0451133818589026 * green + 1.043944368900976 * blue) / 1.08883
        let epsilon = 216.0 / 24_389.0
        let kappa = 24_389.0 / 27.0
        func f(_ value: Double) -> Double {
            value > epsilon ? pow(value, 1.0 / 3.0) : (kappa * value + 16) / 116
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
#endif
