#if canImport(Metal)
import XCTest
@testable import FotufilmCore
@testable import FotufilmMetal
import Metal

final class HandwrittenMetalSpatialExecutorTests: XCTestCase {
    func testGPUFlareMeanChainsIntoSpatialGraphWithoutReadback() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let measurements = try XCTUnwrap(
            HandwrittenMetalGlobalMeasurements(device: device))
        let executor = try XCTUnwrap(
            HandwrittenMetalSpatialExecutor(device: device, maximumInFlightFrames: 2))
        XCTAssertTrue(HandwrittenMetalSpatialExecutor.capabilities.contains(
            .onGPUFlareMeasurement))

        let width = 96
        let height = 54
        var stock = TestStocks.negative
        stock.flare = 0.2
        var options = FotufilmEngine.Options()
        options.localTone = false
        options.flareScale = 1
        options.grainScale = 0
        options.halationScale = 0
        options.couplerScale = 0
        let invocation = FilmEngineInvocation(
            stock: stock, options: options, width: width, height: height)
        XCTAssertNotEqual(invocation.featureMask & FilmEngineFeature.flare, 0)
        let resources = try measurements.makeResources(
            invocation: invocation, mode: .encodedDisplayP3RGBA8,
            frameWidth: width, frameHeight: height)
        let gpuMean = try XCTUnwrap(resources.flareMean)
        let key = #function
        try executor.prepareChecked(
            key: key, stock: stock, options: options,
            frameWidth: width, frameHeight: height)

        let exposureValues = recordExposure(width: width, height: height)
        let source = try texture(
            device: device, width: width, height: height,
            usage: [.shaderRead], values: exposureValues)
        let gpuOutput = try texture(
            device: device, width: width, height: height,
            usage: [.shaderRead, .shaderWrite])
        let cpuOutput = try texture(
            device: device, width: width, height: height,
            usage: [.shaderRead, .shaderWrite])
        let zeroOutput = try texture(
            device: device, width: width, height: height,
            usage: [.shaderRead, .shaderWrite])

        // Both encoders are recorded before the command buffer is committed. Accessing `gpuMean`
        // here only binds its private buffer; no CPU mapping or completion wait occurs between them.
        let gpuCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(measurements.encodeFlareMean(
            recordExposure: source, resources: resources,
            commandBuffer: gpuCommand))
        XCTAssertTrue(executor.encodeDevelopedDensity(
            recordExposure: source, densityOutput: gpuOutput,
            key: key, frameIndex: 0x1234, flareMean: gpuMean,
            commandBuffer: gpuCommand))
        XCTAssertEqual(gpuCommand.status, .notEnqueued)
        gpuCommand.commit()
        gpuCommand.waitUntilCompleted()
        XCTAssertEqual(gpuCommand.status, .completed, "\(String(describing: gpuCommand.error))")

        var sum = SIMD3<Double>.zero
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            sum += SIMD3(
                Double(exposureValues[offset]),
                Double(exposureValues[offset + 1]),
                Double(exposureValues[offset + 2]))
        }
        let divisor = Double(width * height)
        let cpuMean = SIMD3<Float>(
            Float(sum.x / divisor), Float(sum.y / divisor), Float(sum.z / divisor))
        let cpuCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(executor.encodeDevelopedDensity(
            recordExposure: source, densityOutput: cpuOutput,
            key: key, frameIndex: 0x1234, flareMean: cpuMean,
            commandBuffer: cpuCommand))
        cpuCommand.commit()
        cpuCommand.waitUntilCompleted()
        XCTAssertEqual(cpuCommand.status, .completed, "\(String(describing: cpuCommand.error))")

        let zeroCommand = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(executor.encodeDevelopedDensity(
            recordExposure: source, densityOutput: zeroOutput,
            key: key, frameIndex: 0x1234, flareMean: SIMD3<Float>.zero,
            commandBuffer: zeroCommand))
        zeroCommand.commit()
        zeroCommand.waitUntilCompleted()
        XCTAssertEqual(zeroCommand.status, .completed, "\(String(describing: zeroCommand.error))")

        let gpuValues = values(gpuOutput)
        let cpuValues = values(cpuOutput)
        let zeroValues = values(zeroOutput)
        var maximumError: Float = 0
        var changedByFlare = false
        for index in gpuValues.indices {
            maximumError = max(
                maximumError, abs(Float(gpuValues[index]) - Float(cpuValues[index])))
            if index % 4 < 3, gpuValues[index] != zeroValues[index] {
                changedByFlare = true
            }
        }
        XCTAssertLessThanOrEqual(maximumError, 0.001)
        XCTAssertTrue(changedByFlare, "GPU mean must affect the spatial light stage")
    }

    func testAutomaticSplitPrintSupportedGraphTracksGenericGraph() throws {
        try assertVariant(
            .automatic, expectedName: "ten-dispatch-split-print",
            expectedDispatches: 10, expectedMaximumThreadgroupBytes: 22_816,
            profileDispatches: true)
    }

    func testFusedDevelopPrintSupportedGraphTracksGenericGraph() throws {
        try assertVariant(
            .fusedDevelopPrint, expectedName: "nine-dispatch",
            expectedDispatches: 9, expectedMaximumThreadgroupBytes: 22_816)
    }

    func testCompactBlur15SupportedGraphTracksGenericGraph() throws {
        try assertVariant(
            .compactBlur15, expectedName: "nine-dispatch-compact15",
            expectedDispatches: 9, expectedMaximumThreadgroupBytes: 16_208)
    }

    func testSplitDevelopPrintSupportedGraphTracksGenericGraph() throws {
        try assertVariant(
            .splitDevelopPrint, expectedName: "ten-dispatch-split-print",
            expectedDispatches: 10, expectedMaximumThreadgroupBytes: 22_816)
    }

    func testAdaptiveSeparableBlurSupportedGraphTracksGenericGraph() throws {
        try assertVariant(
            .adaptiveSeparableBlur,
            expectedName: "adaptive-separable-split-print",
            expectedDispatches: 12, expectedMaximumThreadgroupBytes: 13_600)
    }

    func testConcurrentFrontiersSupportedGraphTracksGenericGraph() throws {
        try assertVariant(
            .concurrentFrontiers,
            expectedName: "concurrent-frontiers-split-print",
            expectedDispatches: 10, expectedMaximumThreadgroupBytes: 22_816)
    }

    func testExactSpecializedSupportedGraphTracksGenericGraph() throws {
        try assertVariant(
            .exactSpecialized,
            expectedName: "exact-specialized-split-print",
            expectedDispatches: 10, expectedMaximumThreadgroupBytes: 22_816,
            expectedDevelopThreadgroupBytes: 5_984,
            expectedMTFThreadgroupBytes: 4_896)
    }

    func testExactSpecializedScreenNoGrainGraphTracksGenericGraph() throws {
        try assertVariant(
            .exactSpecialized,
            expectedName: "exact-specialized-no-print-no-grain",
            expectedDispatches: 9, expectedMaximumThreadgroupBytes: 22_816,
            expectedDevelopThreadgroupBytes: 1_104,
            expectedMTFThreadgroupBytes: 4_896,
            grainScale: 0, paper: .screen)
    }

    func testPerceptualMultiresScreenNoGrainGraphTracksGenericGraph() throws {
        try assertVariant(
            .perceptualMultires,
            expectedName: "perceptual-multires-half-fields-screen-no-grain",
            expectedDispatches: 8, expectedMaximumThreadgroupBytes: 23_040,
            expectedDevelopThreadgroupBytes: 1_088,
            expectedMTFThreadgroupBytes: 4_896,
            grainScale: 0, paper: .screen,
            // One binary16 density quantum is the observed ceiling; the mean is 3.01e-5.
            maximumAllowedError: 0.001, meanAllowedError: 0.00004)
    }

    func testPerceptualMultiresGaussianVarianceCompensationPreservesPhysicalSigma() {
        for (sigma, stride): (Float, Int) in [(2, 2), (4, 4), (8, 8), (5.5, 4)] {
            let kernelVariance = HandwrittenMetalSpatialExecutor
                .compensatedGaussianVariance(sigma: sigma, stride: stride)
            // Downsample plus bilinear reconstruction contributes 0.25 reduced-grid pixel².
            // Scaling both terms back by stride² must recover the authored physical variance.
            let reconstructedVariance = (kernelVariance + 0.25)
                * Float(stride * stride)
            XCTAssertEqual(
                reconstructedVariance, sigma * sigma, accuracy: 0.00001,
                "sigma=\(sigma), stride=\(stride)")
        }
        XCTAssertEqual(
            HandwrittenMetalSpatialExecutor.compensatedGaussianVariance(
                sigma: 1.25, stride: 1),
            1.25 * 1.25, accuracy: 0.00001)
    }

    func testLongAdjacencyFallsBackToGeneric() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let executor = try XCTUnwrap(HandwrittenMetalSpatialExecutor(
            device: device, optimizationVariant: .perceptualMultires))
        var stock = try fastPathFixtureStock()
        stock.adjacencyRadiusMM = 0.2
        XCTAssertGreaterThan(stock.adjacencyRadiusMM, 0.15)

        let options = multiresOptions(height: 96)
        try executor.prepareChecked(
            key: #function, stock: stock, options: options,
            frameWidth: 160, frameHeight: 96)
        let plan = try XCTUnwrap(executor.executionPlan(forKey: #function))
        XCTAssertEqual(plan.name, "generic")
        XCTAssertEqual(plan.dispatchCount, 16)
    }

    func testPerceptualMultiresUnsupportedTopologyFallsBackToGeneric() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let executor = try XCTUnwrap(HandwrittenMetalSpatialExecutor(
            device: device, optimizationVariant: .perceptualMultires))
        let stock = try fastPathFixtureStock()

        var grainOptions = multiresOptions(height: 96)
        grainOptions.grainScale = 1
        try executor.prepareChecked(
            key: "unsupported-grain", stock: stock, options: grainOptions,
            frameWidth: 160, frameHeight: 96)
        XCTAssertEqual(
            executor.executionPlan(forKey: "unsupported-grain")?.name, "generic")

        var printOptions = multiresOptions(height: 96)
        printOptions.paper = nil
        try executor.prepareChecked(
            key: "unsupported-print", stock: stock, options: printOptions,
            frameWidth: 160, frameHeight: 96)
        XCTAssertEqual(
            executor.executionPlan(forKey: "unsupported-print")?.name, "generic")

        let geometryOptions = multiresOptions(height: 96)
        try executor.prepareChecked(
            key: "unsupported-geometry", stock: stock, options: geometryOptions,
            frameWidth: 158, frameHeight: 96)
        XCTAssertEqual(
            executor.executionPlan(forKey: "unsupported-geometry")?.name, "generic")
    }

    func testPerceptualMultiresErrorContractAcrossStressFields() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let executor = try XCTUnwrap(HandwrittenMetalSpatialExecutor(
            device: device, maximumInFlightFrames: 2,
            optimizationVariant: .perceptualMultires))
        let stock = try fastPathFixtureStock()
        let width = 160
        let height = 96
        let options = multiresOptions(height: height)
        let selectedKey = #function + "-selected"
        let genericKey = #function + "-generic"
        try executor.prepareChecked(
            key: selectedKey, stock: stock, options: options,
            frameWidth: width, frameHeight: height)
        try executor.prepareChecked(
            key: genericKey, stock: stock, options: options,
            frameWidth: width, frameHeight: height)
        XCTAssertTrue(executor._disableFastPathForTesting(key: genericKey))

        let fields: [(String, [Float16])] = [
            ("neutral", uniformExposure(width: width, height: height)),
            ("edge", edgeExposure(width: width, height: height)),
            ("impulse", impulseExposure(width: width, height: height)),
            ("random", randomExposure(width: width, height: height)),
            ("representative", recordExposure(width: width, height: height)),
        ]
        for (name, field) in fields {
            let source = try texture(
                device: device, width: width, height: height,
                usage: [.shaderRead], values: field)
            let selected = try texture(
                device: device, width: width, height: height,
                usage: [.shaderRead, .shaderWrite])
            let generic = try texture(
                device: device, width: width, height: height,
                usage: [.shaderRead, .shaderWrite])
            try encode(
                executor: executor, queue: queue, source: source,
                destination: selected, key: selectedKey, frameIndex: 0x8877_6655)
            try encode(
                executor: executor, queue: queue, source: source,
                destination: generic, key: genericKey, frameIndex: 0x8877_6655)
            let selectedValues = values(selected)
            let metrics = densityErrorMetrics(selectedValues, values(generic))
            // The contract covers adversarial non-band-limited inputs even though only the
            // physically low-pass halo/inhibitor fields are reduced. Full-rate MTF and nonlinear
            // development are never decimated. Two binary16 density quanta is the hard ceiling.
            XCTAssertLessThanOrEqual(
                metrics.maximum, 0.002, "\(name) max at \(metrics.maximumIndex)")
            XCTAssertLessThanOrEqual(metrics.mean, 0.00008, "\(name) mean")

            if name == "neutral" {
                for channel in 0..<3 {
                    let anchor = Float(selectedValues[channel])
                    var maximumDrift: Float = 0
                    for pixel in 1..<(width * height) {
                        maximumDrift = max(
                            maximumDrift,
                            abs(Float(selectedValues[pixel * 4 + channel]) - anchor))
                    }
                    XCTAssertLessThanOrEqual(
                        maximumDrift, 0.001,
                        "uniform field changed in channel \(channel)")
                }
            }

            if name == "random" {
                let replay = try texture(
                    device: device, width: width, height: height,
                    usage: [.shaderRead, .shaderWrite])
                try encode(
                    executor: executor, queue: queue, source: source,
                    destination: replay, key: selectedKey, frameIndex: 0x8877_6655)
                XCTAssertEqual(values(replay), selectedValues)
            }
        }
    }

    private struct DensityErrorMetrics {
        let maximum: Float
        let maximumIndex: Int
        let mean: Float
    }

    private func multiresOptions(height: Int) -> FotufilmEngine.Options {
        var options = FotufilmEngine.Options()
        options.localTone = false
        options.flareScale = 0
        options.grainScale = 0
        options.paper = .screen
        options.format = FilmFormat(
            name: "Synthetic perceptual multires fixture",
            frameHeightMM: Float(height) / 90)
        return options
    }

    private func fastPathFixtureStock() throws -> FilmStock {
        var stock = try XCTUnwrap(FilmStock.named("example-negative-400"))
        stock.donorLayers = [TestStocks.donor]
        // The specialized schedule is intentionally limited to a half-rate adjacency field.
        // Use representative supported geometry here; a longer synthetic
        // adjacency radius is separately required to select the lossless generic schedule.
        stock.adjacencyRadiusMM = 0.03
        return stock
    }

    private func densityErrorMetrics(
        _ selected: [Float16], _ generic: [Float16]
    ) -> DensityErrorMetrics {
        precondition(selected.count == generic.count)
        var maximum: Float = 0
        var maximumIndex = 0
        var total: Float = 0
        var count = 0
        for index in selected.indices where index % 4 < 3 {
            let error = abs(Float(selected[index]) - Float(generic[index]))
            if error > maximum {
                maximum = error
                maximumIndex = index
            }
            total += error
            count += 1
        }
        return DensityErrorMetrics(
            maximum: maximum, maximumIndex: maximumIndex,
            mean: total / Float(max(count, 1)))
    }

    private func assertVariant(
        _ variant: HandwrittenMetalSpatialExecutor.OptimizationVariant,
        expectedName: String, expectedDispatches: Int,
        expectedMaximumThreadgroupBytes: Int,
        profileDispatches: Bool = false,
        expectedDevelopThreadgroupBytes: Int? = nil,
        expectedMTFThreadgroupBytes: Int? = nil,
        grainScale: Float = 1,
        paper: PrintPaper? = nil,
        maximumAllowedError: Float = 0.012,
        meanAllowedError: Float = 0.0015
    ) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let executor = try XCTUnwrap(
            HandwrittenMetalSpatialExecutor(
                device: device, maximumInFlightFrames: 2,
                optimizationVariant: variant,
                dispatchProfilingEnabled: profileDispatches))
        let stock = try fastPathFixtureStock()
        let width = 160
        let height = 96
        var options = FotufilmEngine.Options()
        options.localTone = false
        options.flareScale = 0
        options.grainScale = grainScale
        options.paper = paper
        // Match UHD 35 mm's vertical pixels/mm at a small test extent. Spatial radii and every
        // decimation decision are therefore the same as the 4K realtime graph.
        options.format = FilmFormat(
            name: "PRO 400H nine-dispatch fixture", frameHeightMM: 96 / 90)

        let fastKey = #function + "-" + variant.rawValue + "-fast"
        let genericKey = #function + "-" + variant.rawValue + "-generic"
        try executor.prepareChecked(
            key: fastKey, stock: stock, options: options,
            frameWidth: width, frameHeight: height)
        try executor.prepareChecked(
            key: genericKey, stock: stock, options: options,
            frameWidth: width, frameHeight: height)
        let selectedPlan = try XCTUnwrap(executor.executionPlan(forKey: fastKey))
        XCTAssertEqual(selectedPlan.name, expectedName)
        XCTAssertEqual(selectedPlan.dispatchCount, expectedDispatches)
        XCTAssertEqual(selectedPlan.threadgroupMemoryBytes.count, expectedDispatches)
        XCTAssertEqual(
            selectedPlan.maximumThreadgroupMemoryBytes,
            expectedMaximumThreadgroupBytes)
        if let expectedDevelopThreadgroupBytes {
            XCTAssertTrue(selectedPlan.threadgroupMemoryBytes.contains(
                expectedDevelopThreadgroupBytes))
        }
        if let expectedMTFThreadgroupBytes {
            XCTAssertEqual(
                selectedPlan.threadgroupMemoryBytes[0], expectedMTFThreadgroupBytes)
        }
        XCTAssertTrue(executor._disableFastPathForTesting(key: genericKey))
        let genericPlan = try XCTUnwrap(executor.executionPlan(forKey: genericKey))
        XCTAssertEqual(genericPlan.name, "generic")
        XCTAssertGreaterThan(genericPlan.dispatchCount, selectedPlan.dispatchCount)

        let source = try texture(
            device: device, width: width, height: height,
            usage: [.shaderRead], values: recordExposure(width: width, height: height))
        let fast = try texture(
            device: device, width: width, height: height,
            usage: [.shaderRead, .shaderWrite])
        let generic = try texture(
            device: device, width: width, height: height,
            usage: [.shaderRead, .shaderWrite])

        try encode(
            executor: executor, queue: queue, source: source, destination: fast,
            key: fastKey, frameIndex: 0x1020_3040)
        if executor.isDispatchProfilingAvailable {
            let profile = try XCTUnwrap(executor.latestDispatchProfile(forKey: fastKey))
            XCTAssertEqual(profile.planName, expectedName)
            XCTAssertEqual(profile.frameIndex, 0x1020_3040)
            XCTAssertEqual(profile.dispatches.count, expectedDispatches)
            XCTAssertTrue(profile.dispatches.allSatisfy {
                $0.endTimestamp >= $0.startTimestamp
            })
        }
        try encode(
            executor: executor, queue: queue, source: source, destination: generic,
            key: genericKey, frameIndex: 0x1020_3040)

        let fastValues = values(fast)
        let genericValues = values(generic)
        var maximumError: Float = 0
        var maximumErrorIndex = 0
        var totalError: Float = 0
        var compared = 0
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                let index = pixel * 4 + channel
                let error = abs(Float(fastValues[index]) - Float(genericValues[index]))
                if error > maximumError {
                    maximumError = error
                    maximumErrorIndex = index
                }
                totalError += error
                compared += 1
            }
            XCTAssertEqual(fastValues[pixel * 4 + 3], 1)
            XCTAssertEqual(genericValues[pixel * 4 + 3], 1)
        }
        XCTAssertLessThanOrEqual(
            maximumError, maximumAllowedError,
            "maximum density error \(maximumError) at \(maximumErrorIndex) "
                + "fast=\(fastValues[maximumErrorIndex]) "
                + "generic=\(genericValues[maximumErrorIndex])")
        XCTAssertLessThanOrEqual(
            totalError / Float(compared), meanAllowedError,
            "mean density error \(totalError / Float(compared))")
    }

    private func encode(
        executor: HandwrittenMetalSpatialExecutor, queue: MTLCommandQueue,
        source: MTLTexture, destination: MTLTexture,
        key: String, frameIndex: UInt64
    ) throws {
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(executor.encodeDevelopedDensity(
            recordExposure: source, densityOutput: destination,
            key: key, frameIndex: frameIndex, commandBuffer: commandBuffer))
        XCTAssertEqual(commandBuffer.status, .notEnqueued)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        if let error = commandBuffer.error { throw error }
    }

    private func texture(
        device: MTLDevice, width: Int, height: Int,
        usage: MTLTextureUsage, values: [Float16]? = nil
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height,
            mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = usage
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        if let values {
            values.withUnsafeBytes { bytes in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0, withBytes: bytes.baseAddress!,
                    bytesPerRow: width * 4 * MemoryLayout<Float16>.stride)
            }
        }
        return texture
    }

    private func values(_ texture: MTLTexture) -> [Float16] {
        var result = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        result.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: texture.width * 4 * MemoryLayout<Float16>.stride,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0)
        }
        return result
    }

    private func uniformExposure(width: Int, height: Int) -> [Float16] {
        var result = [Float16](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            result[pixel * 4] = 0.5
            result[pixel * 4 + 1] = 0.5
            result[pixel * 4 + 2] = 0.5
            result[pixel * 4 + 3] = 0.5
        }
        return result
    }

    private func edgeExposure(width: Int, height: Int) -> [Float16] {
        var result = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let values: SIMD4<Float> = x < width / 2
                    ? SIMD4(0.02, 0.035, 0.06, 0.08)
                    : SIMD4(3.2, 2.4, 1.8, 2.7)
                result[index] = Float16(values.x)
                result[index + 1] = Float16(values.y)
                result[index + 2] = Float16(values.z)
                result[index + 3] = Float16(values.w)
            }
        }
        return result
    }

    private func impulseExposure(width: Int, height: Int) -> [Float16] {
        var result = [Float16](repeating: 0.08, count: width * height * 4)
        let index = ((height / 2) * width + width / 2) * 4
        result[index] = 4
        result[index + 1] = 2
        result[index + 2] = 0.5
        result[index + 3] = 3
        return result
    }

    private func randomExposure(width: Int, height: Int) -> [Float16] {
        var state: UInt32 = 0xC001_D00D
        func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24)
        }
        var result = [Float16](repeating: 0, count: width * height * 4)
        for index in result.indices {
            let sample = next()
            result[index] = Float16(0.01 + 3.5 * sample * sample)
        }
        return result
    }

    private func recordExposure(width: Int, height: Int) -> [Float16] {
        var result = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let checker: Float = ((x / 9 + y / 7) & 1) == 0 ? 0.035 : 1.7
                result[index] = Float16(checker * (0.72 + Float(x % 19) / 31))
                result[index + 1] = Float16(checker * (0.61 + Float(y % 17) / 29))
                result[index + 2] = Float16(checker * (0.48 + Float((x + y) % 23) / 37))
                result[index + 3] = Float16(0.025 + Float((x * 3 + y * 5) % 41) / 37)
            }
        }
        return result
    }
}
#endif
