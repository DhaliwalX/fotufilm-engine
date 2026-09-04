#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class NativeRealtimeRendererTests: XCTestCase {
    private enum NativeRenderFailure: Error {
        case preparation
        case processing
    }

    private struct HaloSignature {
        var energy = 0.0
        var radiusMoment = 0.0
        var profile = [Double](repeating: 0, count: 12)

        var meanRadius: Double { energy > 0 ? radiusMoment / energy : 0 }
    }

    private static let spatialTestFormat = FilmFormat(
        name: "Native spatial test", frameHeightMM: 0.5)

    private func textureOptions(
        _ stages: TextureStages, hdr: Bool = false,
        format: FilmFormat = spatialTestFormat
    ) -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.stage = .texture
        options.textureStages = stages
        options.format = format
        options.flareScale = 0
        if hdr { options.sceneHeadroom = HLGSceneTransfer.headroom }
        return options
    }

    private func renderNativeSDR(
        _ pixels: [UInt8], width: Int, height: Int,
        stock: FilmStock = TestStocks.negative,
        options: FotufilmEngine.Options, key: String,
        frameIndex: UInt64 = 0, passes: Int = 1
    ) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(NativeRealtimeFilmRenderer.shared)
        let input = try XCTUnwrap(device.makeBuffer(
            bytes: pixels, length: pixels.count, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(
            length: pixels.count, options: .storageModeShared))
        let prepared = renderer.prepare(
            key: key, stock: stock, options: options,
            frameWidth: width, frameHeight: height)
        XCTAssertTrue(prepared, "native SDR table preparation failed")
        guard prepared else { throw NativeRenderFailure.preparation }
        for pass in 0..<max(passes, 1) {
            let processed = renderer.processRGBA8(
                input: input, output: output, width: width, height: height,
                key: key, frameIndex: frameIndex + UInt64(pass))
            XCTAssertTrue(processed, "native SDR processing failed")
            guard processed else { throw NativeRenderFailure.processing }
        }
        let samples = output.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: samples, count: pixels.count))
    }

    private func renderNativeHDR(
        _ pixels: [Float16], width: Int, height: Int,
        stock: FilmStock = TestStocks.negative,
        options: FotufilmEngine.Options, key: String,
        frameIndex: UInt64 = 0, passes: Int = 1,
        averagingFrames: Int = 1
    ) throws -> [Float] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(NativeRealtimeHDRFilmRenderer.shared)
        let bytes = pixels.count * MemoryLayout<Float16>.stride
        let input = try pixels.withUnsafeBytes { raw in
            try XCTUnwrap(device.makeBuffer(
                bytes: raw.baseAddress!, length: bytes, options: .storageModeShared))
        }
        let output = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let prepared = renderer.prepare(
            key: key, stock: stock, options: options,
            frameWidth: width, frameHeight: height)
        XCTAssertTrue(prepared, "native HDR table preparation failed")
        guard prepared else { throw NativeRenderFailure.preparation }
        let warmupPasses = max(passes - 1, 0)
        for pass in 0..<warmupPasses {
            let processed = renderer.processLinearHalf(
                input: input, output: output, width: width, height: height,
                key: key, frameIndex: frameIndex + UInt64(pass))
            XCTAssertTrue(processed, "native HDR processing failed")
            guard processed else { throw NativeRenderFailure.processing }
        }
        let frames = max(averagingFrames, 1)
        var average = [Double](repeating: 0, count: pixels.count)
        for frame in 0..<frames {
            let processed = renderer.processLinearHalf(
                input: input, output: output, width: width, height: height,
                key: key,
                frameIndex: frameIndex + UInt64(warmupPasses + frame))
            XCTAssertTrue(processed, "native HDR processing failed")
            guard processed else { throw NativeRenderFailure.processing }
            let samples = output.contents().assumingMemoryBound(to: Float16.self)
            for index in 0..<pixels.count {
                average[index] += Double(samples[index])
            }
        }
        return average.map { Float($0 / Double(frames)) }
    }

    private func renderOracleSDR(
        _ pixels: [UInt8], width: Int, height: Int,
        options: FotufilmEngine.Options, frameIndex: UInt64
    ) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(
            HalideMetalFilmRenderer.shared, "Halide Metal unavailable")
        let input = try XCTUnwrap(device.makeBuffer(
            bytes: pixels, length: pixels.count, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(
            length: pixels.count, options: .storageModeShared))
        let processed = renderer.processRGBA8(
            input: input, output: output, width: width, height: height,
            stock: TestStocks.negative, options: options,
            frameIndex: frameIndex)
        XCTAssertTrue(processed, "Halide SDR oracle failed")
        guard processed else { throw NativeRenderFailure.processing }
        let samples = output.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: samples, count: pixels.count))
    }

    private func renderOracleHDR(
        _ pixels: [Float], width: Int, height: Int,
        options: FotufilmEngine.Options, frameIndex: UInt64
    ) throws -> [Float] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(
            HalideMetalFilmRenderer.shared, "Halide Metal unavailable")
        let bytes = pixels.count * MemoryLayout<Float>.stride
        let input = try pixels.withUnsafeBytes { raw in
            try XCTUnwrap(device.makeBuffer(
                bytes: raw.baseAddress!, length: bytes, options: .storageModeShared))
        }
        let output = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let processed = renderer.processLinearFloat(
            input: input, output: output, width: width, height: height,
            stock: TestStocks.negative, options: options,
            frameIndex: frameIndex)
        XCTAssertTrue(processed, "Halide HDR oracle failed")
        guard processed else { throw NativeRenderFailure.processing }
        let samples = output.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: samples, count: pixels.count))
    }

    private func rmsDifference<T: BinaryFloatingPoint>(
        _ first: [T], _ second: [T]
    ) -> Double {
        precondition(first.count == second.count && first.count.isMultiple(of: 4))
        var squared = 0.0
        for index in 0..<first.count where index % 4 != 3 {
            let difference = Double(first[index]) - Double(second[index])
            squared += difference * difference
        }
        return sqrt(squared / Double(first.count / 4 * 3))
    }

    private func haloSignature<T: BinaryFloatingPoint>(
        enabled: [T], disabled: [T], width: Int, height: Int,
        highlight: (x: Range<Int>, y: Range<Int>), scale: Double
    ) -> HaloSignature {
        precondition(enabled.count == disabled.count)
        let weights = ColorScience.luminanceWeights
        var signature = HaloSignature()
        for y in 0..<height {
            for x in 0..<width {
                guard !highlight.x.contains(x) || !highlight.y.contains(y) else {
                    continue
                }
                let dx = x < highlight.x.lowerBound
                    ? highlight.x.lowerBound - x
                    : max(x - highlight.x.upperBound + 1, 0)
                let dy = y < highlight.y.lowerBound
                    ? highlight.y.lowerBound - y
                    : max(y - highlight.y.upperBound + 1, 0)
                let radius = hypot(Double(dx), Double(dy))
                guard radius > 0, radius < 96 else { continue }
                let index = (y * width + x) * 4
                let red = (Double(enabled[index]) - Double(disabled[index])) * scale
                let green = (Double(enabled[index + 1])
                             - Double(disabled[index + 1])) * scale
                let blue = (Double(enabled[index + 2])
                            - Double(disabled[index + 2])) * scale
                let delta = max(Double(weights.0) * red
                                + Double(weights.1) * green
                                + Double(weights.2) * blue, 0)
                signature.energy += delta
                signature.radiusMoment += delta * radius
                signature.profile[min(Int(radius / 8),
                                      signature.profile.count - 1)] += delta
            }
        }
        return signature
    }

    private func profileSimilarity(_ first: [Double], _ second: [Double]) -> Double {
        let dot = zip(first, second).reduce(0.0) { $0 + $1.0 * $1.1 }
        let firstNorm = sqrt(first.reduce(0.0) { $0 + $1 * $1 })
        let secondNorm = sqrt(second.reduce(0.0) { $0 + $1 * $1 })
        return dot / max(firstNorm * secondNorm, .leastNonzeroMagnitude)
    }

    func testSDRSpatialTextureIsANoOpOnAUniformField() throws {
        let width = 96, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            pixels[pixel * 4] = 201
            pixels[pixel * 4 + 1] = 83
            pixels[pixel * 4 + 2] = 31
            pixels[pixel * 4 + 3] = 255
        }
        let spatial: TextureStages = [
            .emulsionMTF, .halation, .adjacency, .enlarger,
        ]
        let enabled = textureOptions(spatial)
        var disabled = enabled
        disabled.textureStages = .none
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: enabled,
            width: width, height: height)
        let expected = FilmEngineFeature.mtf | FilmEngineFeature.halation
            | FilmEngineFeature.adjacency | FilmEngineFeature.printMTF
        XCTAssertEqual(invocation.featureMask & expected, expected,
                       "the uniform-field fixture did not activate every spatial stage")

        let flat = try renderNativeSDR(
            pixels, width: width, height: height, options: enabled,
            key: #function + "-spatial", frameIndex: 10, passes: 2)
        let pointwise = try renderNativeSDR(
            pixels, width: width, height: height, options: disabled,
            key: #function + "-pointwise", frameIndex: 11)
        // The invariant is exact in linear light. This path is delivered through an 8-bit
        // stochastic cube, so a sample sitting on a cube threshold may move by two codes even
        // when the field mean is unchanged; bound both the quantized excursion and its bias.
        var absoluteDifference = 0
        for index in 0..<flat.count {
            if index % 4 == 3 {
                XCTAssertEqual(flat[index], pointwise[index])
            } else {
                absoluteDifference += abs(Int(flat[index]) - Int(pointwise[index]))
                XCTAssertLessThanOrEqual(
                    abs(Int(flat[index]) - Int(pointwise[index])), 2,
                    "uniform SDR component \(index) moved under spatial processing")
            }
        }
        XCTAssertLessThanOrEqual(
            Double(absoluteDifference) / Double(width * height * 3), 0.01,
            "uniform SDR field accumulated a visible spatial bias")
    }

    func testHDRSpatialTextureIsANoOpOnAUniformField() throws {
        let width = 96, height = 64
        let colour = SIMD4<Float16>(2.0, 0.7, 0.2, 1)
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            pixels[pixel * 4] = colour.x
            pixels[pixel * 4 + 1] = colour.y
            pixels[pixel * 4 + 2] = colour.z
            pixels[pixel * 4 + 3] = colour.w
        }
        let spatial: TextureStages = [
            .emulsionMTF, .halation, .adjacency, .enlarger,
        ]
        let enabled = textureOptions(spatial, hdr: true)
        var disabled = enabled
        disabled.textureStages = .none
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: enabled,
            width: width, height: height)
        let expected = FilmEngineFeature.mtf | FilmEngineFeature.halation
            | FilmEngineFeature.adjacency | FilmEngineFeature.printMTF
        XCTAssertEqual(invocation.featureMask & expected, expected,
                       "the HDR uniform-field fixture did not activate every spatial stage")

        let flat = try renderNativeHDR(
            pixels, width: width, height: height, options: enabled,
            key: #function + "-spatial", frameIndex: 20, passes: 2)
        let pointwise = try renderNativeHDR(
            pixels, width: width, height: height, options: disabled,
            key: #function + "-pointwise", frameIndex: 21)
        for index in 0..<flat.count {
            let tolerance: Float = index % 4 == 3 ? 0 : 0.002
            XCTAssertEqual(
                flat[index], pointwise[index], accuracy: tolerance,
                "uniform HDR component \(index) moved under spatial processing")
        }
    }

    func testSDRMTFAdjacencyAndGrainAreNotSilentlyNeutralized() throws {
        let width = 128, height = 96
        var edge = [UInt8](repeating: 0, count: width * height * 4)
        var flat = edge
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * width + x
                let value: UInt8 = ((x / 4 + y / 4) & 1) == 0 ? 32 : 224
                edge[pixel * 4] = value
                edge[pixel * 4 + 1] = value
                edge[pixel * 4 + 2] = value
                edge[pixel * 4 + 3] = 255
                flat[pixel * 4] = 128
                flat[pixel * 4 + 1] = 128
                flat[pixel * 4 + 2] = 128
                flat[pixel * 4 + 3] = 255
            }
        }
        let cases: [(name: String, stage: TextureStages, bit: Int32,
                     pixels: [UInt8])] = [
            ("MTF", .emulsionMTF, FilmEngineFeature.mtf, edge),
            ("adjacency", .adjacency, FilmEngineFeature.adjacency, edge),
            ("grain", .grain, FilmEngineFeature.grain, flat),
        ]
        for item in cases {
            let enabled = textureOptions(item.stage)
            var disabled = enabled
            disabled.textureStages = .none
            let invocation = FilmEngineInvocation(
                stock: TestStocks.negative, options: enabled,
                width: width, height: height)
            XCTAssertNotEqual(
                invocation.featureMask & item.bit, 0,
                "\(item.name) fixture is not configured to run its stage")
            let textured = try renderNativeSDR(
                item.pixels, width: width, height: height, options: enabled,
                key: #function + "-\(item.name)-on", frameIndex: 40)
            let pointwise = try renderNativeSDR(
                item.pixels, width: width, height: height, options: disabled,
                key: #function + "-\(item.name)-off", frameIndex: 40)
            let difference = rmsDifference(
                textured.map(Double.init), pointwise.map(Double.init))
            XCTExpectFailure(
                "The compact native schedule currently omits \(item.name).",
                strict: true
            ) {
                XCTAssertGreaterThan(
                    difference, 0.05,
                    "enabled \(item.name) produced the pointwise SDR result")
            }
        }
    }

    func testHDRMTFAdjacencyAndGrainAreNotSilentlyNeutralized() throws {
        let width = 128, height = 96
        var edge = [Float16](repeating: 0, count: width * height * 4)
        var flat = edge
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * width + x
                let value: Float16 = ((x / 4 + y / 4) & 1) == 0 ? 0.03 : 2.0
                edge[pixel * 4] = value
                edge[pixel * 4 + 1] = value
                edge[pixel * 4 + 2] = value
                edge[pixel * 4 + 3] = 1
                flat[pixel * 4] = 0.18
                flat[pixel * 4 + 1] = 0.18
                flat[pixel * 4 + 2] = 0.18
                flat[pixel * 4 + 3] = 1
            }
        }
        let cases: [(name: String, stage: TextureStages, bit: Int32,
                     pixels: [Float16])] = [
            ("MTF", .emulsionMTF, FilmEngineFeature.mtf, edge),
            ("adjacency", .adjacency, FilmEngineFeature.adjacency, edge),
            ("grain", .grain, FilmEngineFeature.grain, flat),
        ]
        for item in cases {
            let enabled = textureOptions(item.stage, hdr: true)
            var disabled = enabled
            disabled.textureStages = .none
            let invocation = FilmEngineInvocation(
                stock: TestStocks.negative, options: enabled,
                width: width, height: height)
            XCTAssertNotEqual(
                invocation.featureMask & item.bit, 0,
                "\(item.name) fixture is not configured to run its stage")
            let textured = try renderNativeHDR(
                item.pixels, width: width, height: height, options: enabled,
                key: #function + "-\(item.name)-on", frameIndex: 50)
            let pointwise = try renderNativeHDR(
                item.pixels, width: width, height: height, options: disabled,
                key: #function + "-\(item.name)-off", frameIndex: 50)
            let difference = rmsDifference(textured, pointwise)
            XCTExpectFailure(
                "The compact native HDR schedule currently omits \(item.name).",
                strict: true
            ) {
                XCTAssertGreaterThan(
                    difference, 1e-4,
                    "enabled \(item.name) produced the pointwise HDR result")
            }
        }
    }

    func testSDRHalationEnergyAndShapeTrackTheHalideOracle() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide oracle unavailable")
        guard HalideMetalFilmRenderer.shared != nil else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let width = 384, height = 256
        let highlight = (x: 176..<208, y: 112..<144)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                let value: UInt8 = highlight.x.contains(x) && highlight.y.contains(y)
                    ? 245 : 10
                pixels[pixel] = value
                pixels[pixel + 1] = value
                pixels[pixel + 2] = value
                pixels[pixel + 3] = 255
            }
        }
        var enabled = FotufilmEngine.Options()
        enabled.format = .super8
        enabled.grainScale = 0
        enabled.halationScale = 2
        var disabled = enabled
        disabled.halationScale = 0
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: enabled,
            width: width, height: height)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.halation, 0,
                          "halation fixture is not spatial at this resolution")

        let nativeEnabled = try renderNativeSDR(
            pixels, width: width, height: height, options: enabled,
            key: #function + "-native-on", frameIndex: 70, passes: 2)
        let nativeDisabled = try renderNativeSDR(
            pixels, width: width, height: height, options: disabled,
            key: #function + "-native-off", frameIndex: 71)
        let oracleEnabled = try renderOracleSDR(
            pixels, width: width, height: height,
            options: enabled, frameIndex: 71)
        let oracleDisabled = try renderOracleSDR(
            pixels, width: width, height: height,
            options: disabled, frameIndex: 71)
        let native = haloSignature(
            enabled: nativeEnabled.map(Double.init),
            disabled: nativeDisabled.map(Double.init),
            width: width, height: height, highlight: highlight,
            scale: 1 / 255)
        let oracle = haloSignature(
            enabled: oracleEnabled.map(Double.init),
            disabled: oracleDisabled.map(Double.init),
            width: width, height: height, highlight: highlight,
            scale: 1 / 255)
        XCTAssertGreaterThan(native.energy, 0.1,
                             "native SDR halation has no measurable outside energy")
        XCTAssertGreaterThan(oracle.energy, 0.1,
                             "Halide SDR fixture has no measurable outside energy")
        let energyRatio = native.energy / oracle.energy
        XCTAssertTrue(
            0.35...3 ~= energyRatio,
            "native/Oracle SDR halo energy ratio \(energyRatio) is unreasonable")
        let radiusRatio = native.meanRadius / oracle.meanRadius
        XCTAssertTrue(
            0.6...1.7 ~= radiusRatio,
            "native/Oracle SDR halo radius ratio \(radiusRatio) is unreasonable")
        let similarity = profileSimilarity(native.profile, oracle.profile)
        XCTAssertGreaterThan(
            similarity, 0.9,
            "native/Oracle SDR radial-profile similarity is only \(similarity)")
    }

    func testHDRHalationEnergyAndShapeTrackTheHalideOracle() throws {
        try XCTSkipUnless(FotufilmEngine.isHalideBackendAvailable,
                          "Halide oracle unavailable")
        guard HalideMetalFilmRenderer.shared != nil else {
            throw XCTSkip("Halide Metal unavailable")
        }
        let width = 384, height = 256
        let highlight = (x: 176..<208, y: 112..<144)
        var halfPixels = [Float16](repeating: 0, count: width * height * 4)
        var floatPixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                let value: Float = highlight.x.contains(x) && highlight.y.contains(y)
                    ? 1 : 0.01
                halfPixels[pixel] = Float16(value)
                halfPixels[pixel + 1] = Float16(value)
                halfPixels[pixel + 2] = Float16(value)
                halfPixels[pixel + 3] = 1
                floatPixels[pixel] = value
                floatPixels[pixel + 1] = value
                floatPixels[pixel + 2] = value
                floatPixels[pixel + 3] = 1
            }
        }
        var enabled = FotufilmEngine.Options()
        enabled.format = .super8
        enabled.grainScale = 0
        enabled.sceneHeadroom = HLGSceneTransfer.headroom
        enabled.halationScale = 2
        var disabled = enabled
        disabled.halationScale = 0
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: enabled,
            width: width, height: height)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.halation, 0,
                          "HDR halation fixture is not spatial at this resolution")

        let nativeEnabled = try renderNativeHDR(
            halfPixels, width: width, height: height, options: enabled,
            key: #function + "-native-on", frameIndex: 80, passes: 2,
            averagingFrames: 32)
        let nativeDisabled = try renderNativeHDR(
            halfPixels, width: width, height: height, options: disabled,
            key: #function + "-native-off", frameIndex: 81,
            averagingFrames: 32)
        let oracleEnabled = try renderOracleHDR(
            floatPixels, width: width, height: height,
            options: enabled, frameIndex: 81)
        let oracleDisabled = try renderOracleHDR(
            floatPixels, width: width, height: height,
            options: disabled, frameIndex: 81)
        let native = haloSignature(
            enabled: nativeEnabled, disabled: nativeDisabled,
            width: width, height: height, highlight: highlight, scale: 1)
        let oracle = haloSignature(
            enabled: oracleEnabled, disabled: oracleDisabled,
            width: width, height: height, highlight: highlight, scale: 1)
        XCTAssertGreaterThan(native.energy, 0.01,
                             "native HDR halation has no measurable outside energy")
        XCTAssertGreaterThan(oracle.energy, 0.01,
                             "Halide HDR fixture has no measurable outside energy")
        let energyRatio = native.energy / oracle.energy
        XCTAssertTrue(
            0.35...3 ~= energyRatio,
            "native/Oracle HDR halo energy ratio \(energyRatio) is unreasonable")
        let radiusRatio = native.meanRadius / oracle.meanRadius
        XCTAssertTrue(
            0.6...1.7 ~= radiusRatio,
            "native/Oracle HDR halo radius ratio \(radiusRatio) is unreasonable")
        let similarity = profileSimilarity(native.profile, oracle.profile)
        XCTAssertGreaterThan(
            similarity, 0.9,
            "native/Oracle HDR radial-profile similarity is only \(similarity)")
    }

    func testHDRHalationSpreadsAHighlightWithoutChangingResolution() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = NativeRealtimeHDRFilmRenderer.shared else {
            throw XCTSkip("Metal HDR renderer unavailable")
        }
        let width = 512, height = 288
        let values = width * height * 4
        let bytes = values * MemoryLayout<Float16>.size
        let input = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let withHalo = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let withoutHalo = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let pixels = input.contents().assumingMemoryBound(to: Float16.self)
        for index in 0..<(width * height) {
            pixels[index * 4] = 0.01
            pixels[index * 4 + 1] = 0.01
            pixels[index * 4 + 2] = 0.01
            pixels[index * 4 + 3] = 1
        }
        for y in 0..<height {
            for x in 248..<264 {
                let index = (y * width + x) * 4
                pixels[index] = 2
                pixels[index + 1] = 2
                pixels[index + 2] = 2
            }
        }
        var enabled = FotufilmEngine.Options()
        enabled.format = .super8
        enabled.sceneHeadroom = HLGSceneTransfer.headroom
        var disabled = enabled
        disabled.halationScale = 0
        let enabledKey = #function + "-enabled"
        let disabledKey = #function + "-disabled"
        XCTAssertTrue(renderer.prepare(
            key: enabledKey, stock: TestStocks.negative, options: enabled,
            frameWidth: width, frameHeight: height))
        XCTAssertTrue(renderer.prepare(
            key: disabledKey, stock: TestStocks.negative, options: disabled,
            frameWidth: width, frameHeight: height))
        XCTAssertTrue(renderer.processLinearHalf(
            input: input, output: withHalo, width: width, height: height,
            key: enabledKey, frameIndex: 30))
        XCTAssertTrue(renderer.processLinearHalf(
            input: input, output: withHalo, width: width, height: height,
            key: enabledKey, frameIndex: 31))
        XCTAssertTrue(renderer.processLinearHalf(
            input: input, output: withoutHalo, width: width, height: height,
            key: disabledKey, frameIndex: 31))

        let halo = withHalo.contents().assumingMemoryBound(to: Float16.self)
        let plain = withoutHalo.contents().assumingMemoryBound(to: Float16.self)
        var changedOutsideHighlight = 0
        for y in 96..<192 {
            for x in 200..<312 where x < 248 || x >= 264 {
                let index = (y * width + x) * 4
                if halo[index] != plain[index]
                    || halo[index + 1] != plain[index + 1]
                    || halo[index + 2] != plain[index + 2] {
                    changedOutsideHighlight += 1
                }
            }
        }
        XCTAssertGreaterThan(changedOutsideHighlight, 0,
                             "HDR halation did not spread beyond the highlight")
        XCTAssertEqual(withHalo.length, bytes)
    }

    func testSDRHalationSpreadsAHighlightWithoutChangingResolution() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = NativeRealtimeFilmRenderer.shared else {
            throw XCTSkip("Metal renderer unavailable")
        }
        let width = 512, height = 288, bytes = width * height * 4
        let input = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let withHalo = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let withoutHalo = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let pixels = input.contents().assumingMemoryBound(to: UInt8.self)
        for index in 0..<(width * height) {
            pixels[index * 4] = 12
            pixels[index * 4 + 1] = 12
            pixels[index * 4 + 2] = 12
            pixels[index * 4 + 3] = 255
        }
        for y in 0..<height {
            for x in 248..<264 {
                let index = (y * width + x) * 4
                pixels[index] = 255
                pixels[index + 1] = 255
                pixels[index + 2] = 255
            }
        }
        var enabled = FotufilmEngine.Options()
        enabled.format = .super8
        var disabled = enabled
        disabled.halationScale = 0
        let enabledKey = #function + "-enabled"
        let disabledKey = #function + "-disabled"
        XCTAssertTrue(renderer.prepare(
            key: enabledKey, stock: TestStocks.negative, options: enabled,
            frameWidth: width, frameHeight: height))
        XCTAssertTrue(renderer.prepare(
            key: disabledKey, stock: TestStocks.negative, options: disabled,
            frameWidth: width, frameHeight: height))
        // The first call seeds the pipelined field; the second uses the previous frame's blur.
        XCTAssertTrue(renderer.processRGBA8(
            input: input, output: withHalo, width: width, height: height,
            key: enabledKey, frameIndex: 20))
        XCTAssertTrue(renderer.processRGBA8(
            input: input, output: withHalo, width: width, height: height,
            key: enabledKey, frameIndex: 21))
        XCTAssertTrue(renderer.processRGBA8(
            input: input, output: withoutHalo, width: width, height: height,
            key: disabledKey, frameIndex: 21))

        let halo = withHalo.contents().assumingMemoryBound(to: UInt8.self)
        let plain = withoutHalo.contents().assumingMemoryBound(to: UInt8.self)
        var changedOutsideHighlight = 0
        for y in 96..<192 {
            for x in 200..<312 where x < 248 || x >= 264 {
                let index = (y * width + x) * 4
                if halo[index] != plain[index]
                    || halo[index + 1] != plain[index + 1]
                    || halo[index + 2] != plain[index + 2] {
                    changedOutsideHighlight += 1
                }
            }
        }
        XCTAssertGreaterThan(changedOutsideHighlight, 0,
                             "halation did not spread beyond the highlight")
        XCTAssertEqual(withHalo.length, bytes)
    }

    func testSDRRendererIsDeterministicForASeededFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = NativeRealtimeFilmRenderer.shared else {
            throw XCTSkip("Metal renderer unavailable")
        }
        let width = 31, height = 17, bytes = width * height * 4
        let input = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let first = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let second = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let pixels = input.contents().assumingMemoryBound(to: UInt8.self)
        for index in 0..<(width * height) {
            pixels[index * 4] = UInt8((index * 29 + 11) & 255)
            pixels[index * 4 + 1] = UInt8((index * 47 + 23) & 255)
            pixels[index * 4 + 2] = UInt8((index * 71 + 37) & 255)
            pixels[index * 4 + 3] = 255
        }
        let key = #function
        var options = FotufilmEngine.Options()
        options.seed = 0x0123_4567_89AB_CDEF
        XCTAssertNotEqual(
            FilmEngineInvocation(
                stock: TestStocks.negative, options: options,
                width: width, height: height).featureMask
                & FilmEngineFeature.grain,
            0, "seeded SDR fixture did not request grain")
        XCTAssertTrue(renderer.prepare(
            key: key, stock: TestStocks.negative, options: options,
            frameWidth: width, frameHeight: height))
        XCTAssertTrue(renderer.processRGBA8(
            input: input, output: first, width: width, height: height,
            key: key, frameIndex: 42))
        XCTAssertTrue(renderer.processRGBA8(
            input: input, output: second, width: width, height: height,
            key: key, frameIndex: 42))
        XCTAssertEqual(Data(bytes: first.contents(), count: bytes),
                       Data(bytes: second.contents(), count: bytes))
    }

    func testHDRRendererIsDeterministicAndKeepsFiniteHalfValues() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = NativeRealtimeHDRFilmRenderer.shared else {
            throw XCTSkip("Metal HDR renderer unavailable")
        }
        let width = 29, height = 19
        let values = width * height * 4
        let bytes = values * MemoryLayout<Float16>.size
        let input = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let first = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let second = try XCTUnwrap(device.makeBuffer(
            length: bytes, options: .storageModeShared))
        let pixels = input.contents().assumingMemoryBound(to: Float16.self)
        for index in 0..<(width * height) {
            pixels[index * 4] = Float16(Float((index * 29) % 997) / 997 * 3.7)
            pixels[index * 4 + 1] = Float16(Float((index * 47) % 991) / 991 * 3.7)
            pixels[index * 4 + 2] = Float16(Float((index * 71) % 983) / 983 * 3.7)
            pixels[index * 4 + 3] = 1
        }
        var options = FotufilmEngine.Options()
        options.seed = 0x0FED_CBA9_7654_3210
        options.sceneHeadroom = HLGSceneTransfer.headroom
        XCTAssertNotEqual(
            FilmEngineInvocation(
                stock: TestStocks.negative, options: options,
                width: width, height: height).featureMask
                & FilmEngineFeature.grain,
            0, "seeded HDR fixture did not request grain")
        let key = #function
        XCTAssertTrue(renderer.prepare(
            key: key, stock: TestStocks.negative, options: options,
            frameWidth: width, frameHeight: height))
        XCTAssertTrue(renderer.processLinearHalf(
            input: input, output: first, width: width, height: height,
            key: key, frameIndex: 77, inputGain: 0.92))
        XCTAssertTrue(renderer.processLinearHalf(
            input: input, output: second, width: width, height: height,
            key: key, frameIndex: 77, inputGain: 0.92))
        XCTAssertEqual(Data(bytes: first.contents(), count: bytes),
                       Data(bytes: second.contents(), count: bytes))
        let output = first.contents().assumingMemoryBound(to: Float16.self)
        for index in 0..<values {
            XCTAssertTrue(Float(output[index]).isFinite)
        }

        // Components near zero used to share one oversized cube cell and visibly desaturate red.
        // Compare the temporal mean against the exact pointwise invocation that baked the cube.
        let scene = ColorScience.linearDisplayP3ToRec2020(SIMD3(0.55, 0.02, 0.02))
        for index in 0..<(width * height) {
            pixels[index * 4] = Float16(max(scene.x, 0))
            pixels[index * 4 + 1] = Float16(max(scene.y, 0))
            pixels[index * 4 + 2] = Float16(max(scene.z, 0))
            pixels[index * 4 + 3] = 1
        }
        let floatBytes = values * MemoryLayout<Float>.size
        let exactInput = try XCTUnwrap(device.makeBuffer(
            length: floatBytes, options: .storageModeShared))
        let exactOutput = try XCTUnwrap(device.makeBuffer(
            length: floatBytes, options: .storageModeShared))
        let exactPixels = exactInput.contents().assumingMemoryBound(to: Float.self)
        for index in 0..<(width * height) {
            exactPixels[index * 4] = max(scene.x, 0) * 0.92
            exactPixels[index * 4 + 1] = max(scene.y, 0) * 0.92
            exactPixels[index * 4 + 2] = max(scene.z, 0) * 0.92
            exactPixels[index * 4 + 3] = 1
        }
        XCTAssertTrue(renderer.processLinearFloatReference(
            input: exactInput, output: exactOutput,
            width: width, height: height, stock: TestStocks.negative,
            options: options))
        var mean = SIMD3<Double>.zero
        let frames = 32
        for frame in 0..<frames {
            XCTAssertTrue(renderer.processLinearHalf(
                input: input, output: first, width: width, height: height,
                key: key, frameIndex: UInt64(500 + frame), inputGain: 0.92))
            let samples = first.contents().assumingMemoryBound(to: Float16.self)
            for index in 0..<(width * height) {
                mean += SIMD3(Double(samples[index * 4]),
                              Double(samples[index * 4 + 1]),
                              Double(samples[index * 4 + 2]))
            }
        }
        mean /= Double(width * height * frames)
        let exact = exactOutput.contents().assumingMemoryBound(to: Float.self)
        let expected = SIMD3(Double(exact[0]), Double(exact[1]), Double(exact[2]))
        for channel in 0..<3 {
            XCTAssertEqual(mean[channel], expected[channel], accuracy: 0.008,
                           "HDR cube shifted saturated red channel \(channel)")
        }
    }
}
#endif
