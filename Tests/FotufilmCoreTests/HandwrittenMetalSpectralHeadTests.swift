#if canImport(Metal)
import XCTest
@testable import FotufilmCore
import FotufilmMetal
import Metal

final class HandwrittenMetalSpectralHeadTests: XCTestCase {
    func testCPUFlareExposureMatchesMetalAcrossDimAndHDRColors() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let endpoint = try XCTUnwrap(HandwrittenMetalFrameEndpoints(device: device))
        let colors: [SIMD3<Float>] = [
            .zero, SIMD3(repeating: 0.18), SIMD3(1, 0, 0), SIMD3(0, 0.1, 1),
            SIMD3(0.9, 0.2, 0.2), SIMD3(-0.1, 0.8, 0.4), SIMD3(0.5, -0.02, 1),
        ]
        let pixels: [Float16] = [Float(0.001), 0.01, 0.1, 1, 4, 16].flatMap { scale in
            colors.flatMap { color -> [Float16] in
                let rgb = color * scale
                return [Float16(rgb.x), Float16(rgb.y), Float16(rgb.z), 1]
            }
        }
        let quantized = pixels.map(Float.init)
        let width = pixels.count / 4
        let input = try buffer(device: device, values: pixels)
        let output = try texture(device: device, format: .rgba32Float, width: width, height: 1)
        for stock in [TestStocks.negative, TestStocks.reversal] {
            let invocation = FilmEngineInvocation(
                stock: stock, options: neutralOptions(), width: width, height: 1)
            try endpoint.prepareChecked(
                key: stock.name, invocation: invocation, mode: .linearRec2020RGBA16Float,
                frameWidth: width, frameHeight: 1)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(endpoint.encodeHead(
                input: input, recordExposure: output, key: stock.name, commandBuffer: command))
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            let expected = readFloatTexture(output)
            quantized.withUnsafeBufferPointer { storage in
                for pixel in 0..<width {
                    let actual = invocation.measuredFlareMean(
                        linearRGBA: storage.baseAddress! + pixel * 4, width: 1, rows: 1)
                    for channel in 0..<3 {
                        let reference = expected[pixel * 4 + channel]
                        XCTAssertEqual(actual[channel], reference,
                                       accuracy: max(reference * 0.001, 1e-6),
                                       "\(stock.name), pixel \(pixel), record \(channel)")
                    }
                }
            }
        }
    }

    func testDenseSDRCreativeHeadTracksCanonicalEndpointAcrossHalfSeam() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let head = try XCTUnwrap(HandwrittenMetalSpectralHead(device: device))
        let reference = try XCTUnwrap(HandwrittenMetalFrameEndpoints(device: device))
        let levels: [UInt8] = [0, 8, 24, 48, 80, 112, 144, 176, 208, 232, 255]
        let width = levels.count * levels.count * levels.count
        let height = 1
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * 4)
        var ordinal = 0
        for blue in levels {
            for green in levels {
                for red in levels {
                    let alpha: UInt8 = [255, 192, 128, 64][ordinal & 3]
                    pixels.append(UInt8((UInt16(red) * UInt16(alpha) + 127) / 255))
                    pixels.append(UInt8((UInt16(green) * UInt16(alpha) + 127) / 255))
                    pixels.append(UInt8((UInt16(blue) * UInt16(alpha) + 127) / 255))
                    pixels.append(alpha)
                    ordinal += 1
                }
            }
        }

        var options = neutralOptions()
        options.exposureEV = 0.65
        options.whiteBalance = WhiteBalance(kelvin: 4_300, tint: 21)
        options.highlights = 0.42
        options.shadows = -0.31
        options.localTone = true
        options.saturation = 1.18
        options.vibrance = 0.28
        var invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height)
        pixels.withUnsafeBufferPointer { storage in
            invocation.measureToneBase(
                encodedDisplayP3RGBA: storage.baseAddress!,
                width: width, height: height)
        }
        let solved = solvedToneGrid(invocation)
        let measurements = HandwrittenMetalFrameEndpoints.MeasurementResources(
            measuredInvocation: invocation)
        try head.prepareChecked(
            key: "fast-head-sdr-dense", invocation: invocation,
            mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height,
            toneGrid: .cpu(solved))
        try reference.prepareChecked(
            key: "reference-head-sdr-dense", invocation: invocation,
            mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height,
            measurements: measurements)

        let input = try buffer(device: device, values: pixels)
        let actualTexture = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height)
        let referenceTexture = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height)
        let actualCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(head.encode(
            input: input, recordExposure: actualTexture,
            key: "fast-head-sdr-dense", commandBuffer: actualCommand))
        XCTAssertEqual(actualCommand.status, .notEnqueued)
        actualCommand.commit()
        actualCommand.waitUntilCompleted()
        XCTAssertEqual(actualCommand.status, .completed)
        let referenceCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(reference.encodeHead(
            input: input, recordExposure: referenceTexture,
            key: "reference-head-sdr-dense", commandBuffer: referenceCommand))
        referenceCommand.commit()
        referenceCommand.waitUntilCompleted()
        XCTAssertEqual(referenceCommand.status, .completed)

        let actual = readHalfTexture(actualTexture).map(Float.init)
        let expected = readHalfTexture(referenceTexture).map(Float.init)
        let metrics = errorMetrics(actual: actual, expected: expected)
        XCTAssertLessThanOrEqual(
            metrics.maximumAbsolute, 0.04,
            "SDR half seam max=\(metrics.maximumAbsolute), mean=\(metrics.meanAbsolute)")
        XCTAssertLessThanOrEqual(
            metrics.meanAbsolute, 0.003,
            "SDR half seam max=\(metrics.maximumAbsolute), mean=\(metrics.meanAbsolute)")
        // The triangular face lookup and the canonical tetrahedral walk part furthest where
        // the recovered spectrum changes shape fastest across chromaticity. Measured 0.009
        // with the Jakob-Hanika table and 0.0148 with the measured-reflectance prior
        // (2026-09-02); 2% of a record exposure is about 1/35 stop, a fifth of a
        // just-noticeable exposure step, and the mean below is what carries.
        XCTAssertLessThanOrEqual(
            metrics.maximumRelative, 0.02,
            "SDR half seam relative max=\(metrics.maximumRelative), mean=\(metrics.meanRelative)")
        XCTAssertLessThanOrEqual(
            metrics.meanRelative, 0.0009,
            "SDR half seam relative max=\(metrics.maximumRelative), mean=\(metrics.meanRelative)")
    }

    func testDenseHDRHeadPreservesInputGainAndTracksFloatCanonicalEndpoint() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let head = try XCTUnwrap(HandwrittenMetalSpectralHead(device: device))
        let reference = try XCTUnwrap(HandwrittenMetalFrameEndpoints(device: device))
        let levels: [Float] = [-0.16, 0, 0.004, 0.03, 0.18, 0.75, 2.5, 8, 16]
        let width = levels.count * levels.count * levels.count
        let height = 1
        var inputValues = [Float16]()
        inputValues.reserveCapacity(width * 4)
        var ordinal = 0
        for blue in levels {
            for green in levels {
                for red in levels {
                    inputValues.append(Float16(red))
                    inputValues.append(Float16(green))
                    inputValues.append(Float16(blue))
                    inputValues.append(Float16(Float(ordinal % 17) / 16))
                    ordinal += 1
                }
            }
        }
        var options = neutralOptions()
        options.exposureEV = -0.4
        options.sceneHeadroom = 16
        options.whiteBalance = WhiteBalance(kelvin: 8_600, tint: -17)
        options.highlights = -0.23
        options.shadows = 0.19
        options.localTone = false
        options.saturation = 0.82
        options.vibrance = -0.21
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height)
        try head.prepareChecked(
            key: "fast-head-hdr-dense", invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height)
        try reference.prepareChecked(
            key: "reference-head-hdr-dense", invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height)

        let inputGain: Float = 0.625
        let input = try buffer(device: device, values: inputValues)
        let actualTexture = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height)
        let referenceTexture = try texture(
            device: device, format: .rgba32Float,
            width: width, height: height)
        let actualCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(head.encode(
            input: input, recordExposure: actualTexture,
            key: "fast-head-hdr-dense", inputGain: inputGain,
            commandBuffer: actualCommand))
        actualCommand.commit()
        actualCommand.waitUntilCompleted()
        XCTAssertEqual(actualCommand.status, .completed)
        let referenceCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(reference.encodeHead(
            input: input, recordExposure: referenceTexture,
            key: "reference-head-hdr-dense", inputGain: inputGain,
            commandBuffer: referenceCommand))
        referenceCommand.commit()
        referenceCommand.waitUntilCompleted()
        XCTAssertEqual(referenceCommand.status, .completed)

        let actual = readHalfTexture(actualTexture).map(Float.init)
        let expected = readFloatTexture(referenceTexture)
        let metrics = errorMetrics(actual: actual, expected: expected)
        // At the brightest adversarial samples the native-reference normalization can put one
        // half-float value roughly one ULP from the Float32 endpoint. Relative and mean error are
        // the accuracy gates; this absolute ceiling only rejects a materially larger excursion.
        XCTAssertLessThanOrEqual(
            metrics.maximumAbsolute, 0.65,
            "HDR half seam max=\(metrics.maximumAbsolute), mean=\(metrics.meanAbsolute)")
        XCTAssertLessThanOrEqual(
            metrics.meanAbsolute, 0.005,
            "HDR half seam max=\(metrics.maximumAbsolute), mean=\(metrics.meanAbsolute)")
        // Beyond the Rec.2020 cube the exposure table now holds monochromatic mixtures, which
        // are far steeper across chromaticity than the reflectance model, and the adversarial
        // levels include a −0.16 component that lands there; half-precision rounding of a
        // steep face costs more. Measured 0.0085 on 2026-09-03 with the locus-enclosing
        // domain (0.0123 before the face was continued by its own slope); the mean is the
        // accuracy gate and did not move.
        XCTAssertLessThanOrEqual(
            metrics.maximumRelative, 0.01,
            "HDR half seam relative max=\(metrics.maximumRelative), mean=\(metrics.meanRelative)")
        XCTAssertLessThanOrEqual(
            metrics.meanRelative, 0.0008,
            "HDR half seam relative max=\(metrics.maximumRelative), mean=\(metrics.meanRelative)")
    }

    func testSceneLinearFloat32HeadMatchesHalfForRepresentableValuesWithoutQuantizingInput() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let head = try XCTUnwrap(HandwrittenMetalSpectralHead(device: device))
        let levels: [Float] = [
            0.000_123_45, 0.003_456_7, 0.017_891,
            0.071_234, 0.181_234, 0.731_234, 2.345_67, 7.654_3,
        ]
        let width = levels.count * levels.count
        let height = 1
        var floatInput = [Float]()
        floatInput.reserveCapacity(width * 4)
        for green in levels {
            for red in levels {
                floatInput.append(red)
                floatInput.append(green)
                floatInput.append(levels[(floatInput.count / 4) % levels.count])
                floatInput.append(1)
            }
        }
        let halfInput = floatInput.map(Float16.init)
        let quantizedFloatInput = halfInput.map(Float.init)
        var options = neutralOptions()
        options.exposureEV = 0.37
        options.whiteBalance = WhiteBalance(kelvin: 6_700, tint: -9)
        options.saturation = 1.11
        options.vibrance = 0.13
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height)
        try head.prepareChecked(
            key: #function + "-half", invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height)
        try head.prepareChecked(
            key: #function + "-float", invocation: invocation,
            mode: .linearRec2020RGBA32Float,
            frameWidth: width, frameHeight: height)

        let halfOutput = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height)
        let quantizedFloatOutput = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height)
        let fullFloatOutput = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height)
        func encode(_ values: MTLBuffer, output: MTLTexture, key: String) throws {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(head.encode(
                input: values, recordExposure: output, key: key,
                inputGain: 0.93, commandBuffer: command))
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        }
        try encode(
            buffer(device: device, values: halfInput),
            output: halfOutput, key: #function + "-half")
        try encode(
            buffer(device: device, values: quantizedFloatInput),
            output: quantizedFloatOutput, key: #function + "-float")
        try encode(
            buffer(device: device, values: floatInput),
            output: fullFloatOutput, key: #function + "-float")

        let halfResult = readHalfTexture(halfOutput)
        XCTAssertEqual(
            readHalfTexture(quantizedFloatOutput), halfResult,
            "Float32 and Float16 kernels must agree for identical numeric inputs")
        XCTAssertNotEqual(
            readHalfTexture(fullFloatOutput), halfResult,
            "non-half still values must reach spectral exposure without input quantization")

        let shortInput = try XCTUnwrap(device.makeBuffer(
            length: width * 4 * MemoryLayout<Float16>.stride,
            options: .storageModeShared))
        let rejected = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertFalse(head.encode(
            input: shortInput, recordExposure: fullFloatOutput,
            key: #function + "-float", commandBuffer: rejected))
        XCTAssertEqual(rejected.status, .notEnqueued)
    }

    func testPremultipliedAlphaIsUnassociatedAndOutputWRemainsDonorExposure() throws {
        try XCTSkipUnless(
            SpectralRuntime.hasReconstructionModel,
            "spectral reconstruction model required for donor exposure")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let head = try XCTUnwrap(HandwrittenMetalSpectralHead(device: device))
        var stock = TestStocks.negative
        stock.donorLayers = [DonorCaptureLayer(
            name: "Test donor",
            sensitivity: stock.spectralProfile.layerSensitivity[1],
            curve: stock.curves[1], inhibition: [0.4, 0, 0],
            releaseGamma: 1.2)]
        var options = neutralOptions()
        options.localTone = false
        options.couplerScale = 1
        let pixels: [UInt8] = [
            64, 32, 16, 128,
            32, 16, 8, 64,
            64, 32, 16, 255,
            0, 0, 0, 255,
        ]
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: 4, height: 1)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.donorLayer, 0)
        try head.prepareChecked(
            key: "fast-head-donor", invocation: invocation,
            mode: .encodedDisplayP3RGBA8, frameWidth: 4, frameHeight: 1)
        let input = try buffer(device: device, values: pixels)
        let output = try texture(
            device: device, format: .rgba16Float, width: 4, height: 1)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(head.encode(
            input: input, recordExposure: output,
            key: "fast-head-donor", commandBuffer: command))
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let values = readHalfTexture(output)
        for channel in 0..<4 {
            XCTAssertEqual(
                values[channel], values[4 + channel],
                "equal unassociated colours must expose every record equally")
        }
        XCTAssertGreaterThan(Float(values[3]), 0, "W carries the lit donor record")
        XCTAssertNotEqual(values[3], Float16(0.5), "W is not copied input alpha")
        XCTAssertNotEqual(values[3], values[11], "different unassociated RGB changes donor dose")
        XCTAssertEqual(values[15], 0, "black produces no donor exposure")
    }

    func testLocalToneNeverFallsBackToAnIdentityGrid() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let head = try XCTUnwrap(HandwrittenMetalSpectralHead(device: device))
        var options = neutralOptions()
        options.highlights = 0.4
        options.localTone = true
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: 16, height: 9)
        XCTAssertTrue(invocation.localToneActive)
        XCTAssertThrowsError(try head.prepareChecked(
            key: "fast-head-tone-missing", invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: 16, frameHeight: 9)) { error in
                guard case HandwrittenMetalSpectralHead.PreparationError.missingToneGrid = error
                else { return XCTFail("unexpected error: \(error)") }
            }
        try head.prepareChecked(
            key: "fast-head-tone-gpu", invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: 16, frameHeight: 9,
            toneGrid: .gpu)
        let input = try XCTUnwrap(device.makeBuffer(
            length: 16 * 9 * 4 * MemoryLayout<Float16>.stride,
            options: .storageModeShared))
        let output = try texture(
            device: device, format: .rgba16Float, width: 16, height: 9)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertFalse(head.encode(
            input: input, recordExposure: output,
            key: "fast-head-tone-gpu", commandBuffer: command),
            "a GPU-grid key must not encode without the measured resource")
    }

    func testX420HLGAndAppleLogEntriesMatchDecodedLinearHDRInput() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let head = try XCTUnwrap(HandwrittenMetalSpectralHead(device: device))
        let width = 16
        let height = 2
        let lumaCodes: [UInt16] = [
            64, 80, 112, 160, 224, 320, 440, 502,
            576, 640, 704, 768, 816, 864, 912, 940,
        ]
        let lumaValues: [UInt16] = (0..<height).flatMap { row in
            row == 0 ? lumaCodes : Array(lumaCodes.reversed())
        }.map { $0 << 6 }
        let chromaValues = [UInt16](
            repeating: 512 << 6, count: (width / 2) * (height / 2) * 2)
        let luma = try inputTexture(
            device: device, format: .r16Unorm,
            width: width, height: height)
        let chroma = try inputTexture(
            device: device, format: .rg16Unorm,
            width: width / 2, height: height / 2)
        writeWords(lumaValues, into: luma, components: 1)
        writeWords(chromaValues, into: chroma, components: 2)

        var options = neutralOptions()
        options.exposureEV = 0.3
        options.sceneHeadroom = AppleLogCurve.headroom
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height)
        try head.prepareChecked(
            key: "fast-head-x420", invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height)
        for transfer in [
            HandwrittenMetalSpectralHead.HDRCaptureTransfer.hlg,
            .appleLog,
        ] {
            let sceneScale: Float = transfer == .hlg
                ? HLGSceneTransfer.headroom : 1 / AppleLogCurve.diffuseWhite
            let inputGain: Float = 0.91
            let linear: [Float16] = (0..<height).flatMap { row -> [Float16] in
                let codes = row == 0 ? lumaCodes : Array(lumaCodes.reversed())
                return codes.flatMap { code -> [Float16] in
                    let signal = Float(Int(code) - 64) / 876
                    let decoded = transfer == .hlg
                        ? HLGSceneTransfer.sceneLight(min(max(signal, 0), 1))
                        : AppleLogCurve.linear(min(max(signal, 0), 1))
                    let open = max(decoded, 0) * sceneScale * inputGain
                    return [Float16(open), Float16(open), Float16(open), 1]
                }
            }
            let linearInput = try buffer(device: device, values: linear)
            let linearOutput = try texture(
                device: device, format: .rgba16Float,
                width: width, height: height)
            let captureOutput = try texture(
                device: device, format: .rgba16Float,
                width: width, height: height)
            let linearCommand = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(head.encode(
                input: linearInput, recordExposure: linearOutput,
                key: "fast-head-x420", commandBuffer: linearCommand))
            linearCommand.commit()
            linearCommand.waitUntilCompleted()
            let captureCommand = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(head.encodeCapturedHDR(
                luma: luma, chroma: chroma,
                recordExposure: captureOutput, key: "fast-head-x420",
                transfer: transfer, sceneScale: sceneScale,
                inputGain: inputGain, commandBuffer: captureCommand))
            captureCommand.commit()
            captureCommand.waitUntilCompleted()
            XCTAssertEqual(linearCommand.status, .completed)
            XCTAssertEqual(captureCommand.status, .completed)
            let metrics = errorMetrics(
                actual: readHalfTexture(captureOutput).map(Float.init),
                expected: readHalfTexture(linearOutput).map(Float.init))
            XCTAssertLessThanOrEqual(
                metrics.maximumAbsolute, 0.008,
                "\(transfer) x420 decode max=\(metrics.maximumAbsolute), "
                    + "mean=\(metrics.meanAbsolute)")
            XCTAssertLessThanOrEqual(
                metrics.meanAbsolute, 0.0005,
                "\(transfer) x420 decode max=\(metrics.maximumAbsolute), "
                    + "mean=\(metrics.meanAbsolute)")
        }
    }

    func testGPUSolvedToneGridFeedsHeadInSameCommandBuffer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let measurements = try XCTUnwrap(
            HandwrittenMetalGlobalMeasurements(device: device))
        let head = try XCTUnwrap(HandwrittenMetalSpectralHead(device: device))
        let width = 32
        let height = 18
        let values: [Float16] = (0..<(width * height)).flatMap { index in
            let x = Float(index % width) / Float(width - 1)
            let y = Float(index / width) / Float(height - 1)
            return [Float16(0.015 + 3.2 * x),
                    Float16(0.02 + 1.4 * y),
                    Float16(0.01 + 0.8 * (1 - x)), 1]
        }
        var options = neutralOptions()
        options.highlights = 0.45
        options.shadows = -0.2
        options.localTone = true
        let invocation = FilmEngineInvocation(
            stock: TestStocks.negative, options: options,
            width: width, height: height)
        let resources = try measurements.makeResources(
            invocation: invocation, mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height)
        let grid = try XCTUnwrap(resources.toneGrid)
        try head.prepareChecked(
            key: "fast-head-gpu-tone", invocation: invocation,
            mode: .linearRec2020RGBA16Float,
            frameWidth: width, frameHeight: height,
            toneGrid: .gpu)
        let input = try buffer(device: device, values: values)
        let output = try texture(
            device: device, format: .rgba16Float,
            width: width, height: height)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(measurements.encodeToneBase(
            input: input, resources: resources, commandBuffer: command))
        XCTAssertTrue(head.encode(
            input: input, recordExposure: output,
            key: "fast-head-gpu-tone", gpuToneGrid: grid,
            commandBuffer: command))
        XCTAssertEqual(command.status, .notEnqueued)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let result = readHalfTexture(output).map(Float.init)
        XCTAssertTrue(result.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(result.max() ?? 0, 0)
    }

    private func neutralOptions() -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.grainScale = 0
        options.flareScale = 0
        options.halationScale = 0
        options.couplerScale = 0
        options.localTone = false
        options.sceneHeadroom = 1
        return options
    }

    private func solvedToneGrid(
        _ invocation: FilmEngineInvocation
    ) -> HandwrittenMetalSpectralHead.SolvedToneGrid {
        let width = Int(invocation.configuration[FilmEngineInvocation.toneGridSizeOffset])
        let height = Int(invocation.configuration[FilmEngineInvocation.toneGridSizeOffset + 1])
        let count = width * height
        let aStart = FilmEngineInvocation.toneGridAOffset
        let bStart = FilmEngineInvocation.toneGridBOffset
        return .init(
            width: width, height: height,
            a: Array(invocation.configuration[aStart..<(aStart + count)]),
            b: Array(invocation.configuration[bStart..<(bStart + count)]))
    }

    private func errorMetrics(
        actual: [Float], expected: [Float]
    ) -> (maximumAbsolute: Float, meanAbsolute: Float,
          maximumRelative: Float, meanRelative: Float) {
        XCTAssertEqual(actual.count, expected.count)
        var maximumAbsolute: Float = 0
        var totalAbsolute: Double = 0
        var maximumRelative: Float = 0
        var totalRelative: Double = 0
        for index in actual.indices {
            XCTAssertTrue(actual[index].isFinite, "non-finite actual sample \(index)")
            XCTAssertTrue(expected[index].isFinite, "non-finite reference sample \(index)")
            let absolute = abs(actual[index] - expected[index])
            let relative = absolute / max(abs(expected[index]), 0.01)
            maximumAbsolute = max(maximumAbsolute, absolute)
            totalAbsolute += Double(absolute)
            maximumRelative = max(maximumRelative, relative)
            totalRelative += Double(relative)
        }
        let divisor = Double(max(actual.count, 1))
        return (
            maximumAbsolute, Float(totalAbsolute / divisor),
            maximumRelative, Float(totalRelative / divisor))
    }

    private func buffer<T>(device: MTLDevice, values: [T]) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(
                bytes: bytes.baseAddress!, length: bytes.count,
                options: .storageModeShared))
        }
    }

    private func texture(
        device: MTLDevice, format: MTLPixelFormat,
        width: Int, height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func inputTexture(
        device: MTLDevice, format: MTLPixelFormat,
        width: Int, height: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func writeWords(
        _ values: [UInt16], into texture: MTLTexture, components: Int
    ) {
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: texture.width * components * MemoryLayout<UInt16>.stride)
        }
    }

    private func readHalfTexture(_ texture: MTLTexture) -> [Float16] {
        var values = [Float16](
            repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &values,
            bytesPerRow: texture.width * 4 * MemoryLayout<Float16>.stride,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0)
        return values
    }

    private func readFloatTexture(_ texture: MTLTexture) -> [Float] {
        var values = [Float](
            repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &values,
            bytesPerRow: texture.width * 4 * MemoryLayout<Float>.stride,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0)
        return values
    }
}
#endif
