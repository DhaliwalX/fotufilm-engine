import Foundation
import XCTest
@testable import FotufilmCore

enum TransportFixtures {
    /// Invented construction for numerical tests, not a measured commercial film.
    static var stack: LayeredTransport {
        LayeredTransport(constructionID: "synthetic-layered-negative", provenance: "illustrative",
            layers: [
                .init(id: "blue", thicknessMM: 0.006, refractiveIndex: [1.52], absorptionPerMM: [0.4]),
                .init(id: "green", thicknessMM: 0.006, refractiveIndex: [1.52], absorptionPerMM: [0.4]),
                .init(id: "red", thicknessMM: 0.006, refractiveIndex: [1.52], absorptionPerMM: [0.4]),
                .init(id: "support", thicknessMM: 0.130, refractiveIndex: [1.48], absorptionPerMM: [0.2])],
            recordDepthMM: [0.015, 0.009, 0.003], angularExponent: [[2.2], [2], [1.8]],
            captureProbability: [[0.35], [0.4], [0.5]],
            returnedToDirect: [[0.05], [0.02], [0.008]], coreSigmaMM: [0.004, 0.003, 0.0024])
    }
    static var mirror: LayeredTransport {
        LayeredTransport(constructionID: "analytic-mirror", provenance: "illustrative",
            layers: [.init(id: "slab", thicknessMM: 0.02, refractiveIndex: [1], absorptionPerMM: [0])],
            rearReflectance: [1], recordDepthMM: [0.005, 0.005, 0.005],
            angularExponent: [[1], [1], [1]], captureProbability: [[1], [1], [1]],
            returnedToDirect: [[0.05], [0.02], [0.008]], coreSigmaMM: [0, 0, 0])
    }
    static var quiet: FotufilmEngine.Options {
        var o = FotufilmEngine.Options()
        o.grainScale = 0; o.couplerScale = 0; o.flareScale = 0
        return o
    }
}

final class LayeredTransportTests: XCTestCase {
    func testTransportComponentsUseTheSameCaptureLightAsLegacyForEveryFilmReference() throws {
        for reference: Float in [3200, 5500, 6504] {
            var stock = TestStocks.negative
            stock.referenceIlluminantKelvin = reference
            for capture: Float? in [nil, 4300] {
                var options = TransportFixtures.quiet
                options.localTone = false
                options.sceneIlluminantKelvin = capture
                options.layeredTransport = TransportFixtures.stack
                let plan = try LayeredTransportRenderer.renderPlan(
                    stock: stock, options: options, width: 9, height: 7)
                let legacy = FilmEngineInvocation(stock: stock, options: options.withoutLayeredTransport,
                                                  width: 9, height: 7).spectral.exposure.values
                var maximumError: Float = 0
                for i in legacy.indices where i % 4 != 3 {
                    let sum = plan.components.reduce(Float(0)) { $0 + $1.exposure[i] }
                    maximumError = max(maximumError, abs(sum - legacy[i]))
                }
                XCTAssertLessThan(maximumError, 2e-5,
                                  "reference \(reference), capture \(String(describing: capture))")
            }
        }
    }

    func testMirrorMatchesAnalyticMoffatAndConservesPower() throws {
        let result = try LayeredTransportSolver.solve(TransportFixtures.mirror, receiver: 0, band: 20,
                                                     angularSamples: 4096)
        let kernel = try XCTUnwrap(result.kernel)
        XCTAssertEqual(result.captured, 1, accuracy: 1e-12)
        XCTAssertLessThan(result.accountingResidual, 1e-12)
        // q=1, unit-index slab: E(r)=r²/(r²+(2d)²), d=0.015 mm.
        for r in [0.01, 0.03, 0.09, 0.3] {
            XCTAssertEqual(kernel.encircledEnergy(radiusMM: r), r*r/(r*r+0.03*0.03), accuracy: 0.0003)
        }
    }

    func testAbsorbingBackingAndIndexMatchedBoundary() throws {
        var model = TransportFixtures.mirror
        model.rearReflectance = [0]
        let black = try LayeredTransportSolver.solve(model, receiver: 0, band: 0)
        XCTAssertNil(black.kernel); XCTAssertEqual(black.absorbed, 1, accuracy: 1e-12)
        model.rearReflectance = nil
        let matched = try LayeredTransportSolver.solve(model, receiver: 0, band: 0)
        XCTAssertNil(matched.kernel); XCTAssertEqual(matched.escaped, 1, accuracy: 1e-12)
        XCTAssertThrowsError(try TransportKernelCompiler.compile(model))
    }

    func testFresnelPolarizationAndTotalInternalReflection() {
        let normal = LayeredTransportSolver.fresnel(from: 1.5, to: 1, invariant: 0)
        XCTAssertEqual(normal.s, 0.04, accuracy: 1e-12)
        XCTAssertEqual(normal.p, 0.04, accuracy: 1e-12)
        let brewster = LayeredTransportSolver.fresnel(from: 1, to: 1.5,
                                                     invariant: sin(atan(1.5)))
        XCTAssertEqual(brewster.p, 0, accuracy: 1e-12)
        let tir = LayeredTransportSolver.fresnel(from: 1.5, to: 1, invariant: 1.1)
        XCTAssertEqual(tir.s, 1); XCTAssertEqual(tir.p, 1)
    }

    func testWavelengthDependentAbsorptionChangesTheReturnedDistribution() throws {
        var model = TransportFixtures.stack
        model.layers[3].absorptionPerMM = SpectralGrid.wavelengths.map { $0 < 600 ? 4 : 0.02 }
        let blue = try LayeredTransportSolver.solve(model, receiver: 0, band: 14)
        let red = try LayeredTransportSolver.solve(model, receiver: 0, band: 54)
        XCTAssertLessThan(blue.captured, red.captured)
        XCTAssertLessThan(try XCTUnwrap(blue.kernel).quantile(0.9), try XCTUnwrap(red.kernel).quantile(0.9))
        XCTAssertLessThan(blue.accountingResidual, 1e-10)
        XCTAssertLessThan(red.accountingResidual, 1e-10)
    }

    func testReceiverNearRearBoundaryDoesNotSnapOutsideTheStack() throws {
        var model = TransportFixtures.mirror
        model.recordDepthMM[0] = 0.02 - 1e-13
        let solved = try LayeredTransportSolver.solve(model, receiver: 0, band: 0)
        XCTAssertEqual(solved.captured, 1, accuracy: 1e-12)
        let kernel = try XCTUnwrap(solved.kernel)
        XCTAssertLessThan(kernel.quantile(0.9), 1e-10)
        XCTAssertEqual(kernel.edgeSpread(distanceMM: -1), 1, accuracy: 1e-12)
    }

    func testMultilayerRepeatedReturnsAndAngularConvergence() throws {
        let a = try LayeredTransportSolver.solve(TransportFixtures.stack, receiver: 0, band: 0,
                                                angularSamples: 1024)
        let b = try LayeredTransportSolver.solve(TransportFixtures.stack, receiver: 0, band: 0,
                                                angularSamples: 4096)
        XCTAssertGreaterThan(a.captured, 0); XCTAssertGreaterThan(a.unreturnedCapture, 0)
        XCTAssertLessThan(a.accountingResidual, 1e-10)
        XCTAssertLessThan(a.unresolved, 1e-7)
        let ka = try XCTUnwrap(a.kernel), kb = try XCTUnwrap(b.kernel)
        for r in stride(from: 0.05, through: 2.0, by: 0.05) {
            XCTAssertEqual(ka.edgeSpread(distanceMM: r), kb.edgeSpread(distanceMM: r), accuracy: 0.0015)
        }
    }

    func testPositiveNormalizedSpectralPartitionsAndBoundedAmount() throws {
        var model = TransportFixtures.stack
        model.returnedToDirect[0] = SpectralGrid.wavelengths.map { Double($0 - 375) / 1000 }
        for sourceColour: Float in [0, 0.5, 1] {
            let compiled = try TransportKernelCompiler.compile(model, sourceColour: sourceColour)
            XCTAssertLessThanOrEqual(compiled.maximumEdgeError, 0.005)
            for endpoint in [compiled.core, compiled.saturated] {
                for c in 0..<3 { for b in 0..<SpectralGrid.count {
                    let values = endpoint.map { $0[c][b] }
                    XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0.isFinite })
                    XCTAssertEqual(values.reduce(0, +), 1, accuracy: 2e-6)
                } }
            }
            let amounts = [0.0, 0.5, 1, 2, 20, 1e10].map { compiled.interpolation(amount: $0) }
            XCTAssertEqual(amounts[0], 0)
            XCTAssertEqual(amounts[2], Float(compiled.maximumReturnedShare), accuracy: 1e-7)
            XCTAssertEqual(amounts, amounts.sorted()); XCTAssertLessThanOrEqual(amounts.last!, 1)
            XCTAssertEqual(amounts[1], amounts[2] / 2, accuracy: 1e-7)
        }
    }

    func testPixelIntegrationHasNoSubpixelDeadZoneAndRejectsInvalidSupport() throws {
        let kernel = try TransportRadialKernel(radiusMM: [0.0001], mass: [1])
        let stencil = try kernel.stencil(pixelPitchMM: 0.01)
        XCTAssertEqual(stencil.stride, 1)
        let center = stencil.weights.count / 2
        XCTAssertLessThan(stencil.weights[center], 1)
        XCTAssertGreaterThan(stencil.weights[center + 1], 0)
        XCTAssertEqual(stencil.weights.reduce(0, +), 1, accuracy: 1e-6)
        XCTAssertThrowsError(try kernel.stencil(pixelPitchMM: 0.01, maximumRadius: 1))
        XCTAssertThrowsError(try kernel.stencil(pixelPitchMM: 1e-20))
        let withTail = try TransportRadialKernel(radiusMM: [0.0001, 1], mass: [0.99, 0.01])
        let bands = try withTail.stencils(pixelPitchMM: 0.01)
        XCTAssertEqual(bands.count, 2)
        XCTAssertEqual(bands[0].stencil.stride, 1)
        XCTAssertEqual(bands[0].weight, 0.99, accuracy: 1e-6)
        XCTAssertGreaterThan(bands[1].stencil.stride, 1)
    }

    func testConvolutionPreservesUniformFieldsAndMetalAgrees() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        let kernel = try TransportRadialKernel(radiusMM: [0.01, 0.13], mass: [0.3, 0.7])
        let stencil = try kernel.stencil(pixelPitchMM: 0.008)
        let field = ImageBuffer(width: 37, height: 29,
            planes: [Float(0.02), 0.7, 40].map { Array(repeating: $0, count: 37*29) })
        let cpu = try LayeredTransportRenderer.convolve(field, stencil: stencil)
        for c in 0..<3 { for i in 0..<field.pixelCount {
            XCTAssertEqual(cpu.planes[c][i], field.planes[c][i], accuracy: 0.00005)
        } }
        var impulse = ImageBuffer(width: 37, height: 29)
        impulse.planes[0][14*37+18] = 10; impulse.planes[1][0] = 3
        let reference = try LayeredTransportRenderer.convolve(impulse, stencil: stencil)
        XCTAssertTrue(reference.planes.flatMap { $0 }.allSatisfy { $0 >= 0 && $0.isFinite })
        guard TransportBackend.metal.isAvailable else { throw XCTSkip("Metal unavailable; CPU assertions passed") }
        let metal = try LayeredTransportRenderer.convolve(impulse, stencil: stencil, backend: .metal)
        let error = zip(reference.planes.flatMap { $0 }, metal.planes.flatMap { $0 })
            .map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(error, 0.00002)
    }

    func testMultiBandAccumulationMatchesSequentialConvolve() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        let kernel1 = try TransportRadialKernel(radiusMM: [0.01, 0.04], mass: [0.4, 0.6])
        let stencil1 = try kernel1.stencil(pixelPitchMM: 0.008)
        let kernel2 = try TransportRadialKernel(radiusMM: [0.08, 0.16], mass: [0.3, 0.7])
        let stencil2 = try kernel2.stencil(pixelPitchMM: 0.008)
        let bands = [
            TransportWeightedStencil(weight: 0.35, stencil: stencil1),
            TransportWeightedStencil(weight: 0.65, stencil: stencil2)
        ]

        var impulse = ImageBuffer(width: 37, height: 29)
        impulse.planes[0][14*37+18] = 10; impulse.planes[1][0] = 3; impulse.planes[2][10] = 5

        // Sequential reference
        var reference = ImageBuffer(width: 37, height: 29)
        for band in bands {
            let filtered = try LayeredTransportRenderer.convolve(impulse, stencil: band.stencil)
            for c in 0..<3 { for i in 0..<impulse.pixelCount {
                reference.planes[c][i] += band.weight * filtered.planes[c][i]
            } }
        }

        // Batched CPU accumulation
        var cpuAccum = ImageBuffer(width: 37, height: 29)
        try LayeredTransportRenderer.accumulate(component: impulse, bands: bands, into: &cpuAccum, backend: .cpu)
        for c in 0..<3 { for i in 0..<impulse.pixelCount {
            XCTAssertEqual(cpuAccum.planes[c][i], reference.planes[c][i], accuracy: 0.00005)
        } }

        // Batched Metal accumulation
        guard TransportBackend.metal.isAvailable else { throw XCTSkip("Metal unavailable; CPU assertions passed") }
        var metalAccum = ImageBuffer(width: 37, height: 29)
        try LayeredTransportRenderer.accumulate(component: impulse, bands: bands, into: &metalAccum, backend: .metal)
        let maxMetalDiff = zip(reference.planes.flatMap { $0 }, metalAccum.planes.flatMap { $0 })
            .map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxMetalDiff, 0.0001)
    }

    func testSchemaVersionIsExplicitAndRoundTrips() throws {
        let legacy = FilmStockDefinition(id: "test", stock: TestStocks.negative)
        XCTAssertEqual(legacy.schemaVersion, 2)
        var stock = TestStocks.negative; stock.layeredTransport = TransportFixtures.stack
        let definition = FilmStockDefinition(id: "test", stock: stock)
        XCTAssertEqual(definition.schemaVersion, 3)
        try definition.validate()
        let decoded = try JSONDecoder().decode(FilmStockDefinition.self, from: JSONEncoder().encode(definition))
        try decoded.validate()
        XCTAssertEqual(decoded.stock.layeredTransport, stock.layeredTransport)
        var bad = definition; bad.schemaVersion = 1
        XCTAssertThrowsError(try bad.validate())
        bad = legacy; bad.schemaVersion = 3
        XCTAssertThrowsError(try bad.validate())
    }

    func testStockConstructionPreservesLegacyFieldsAndRendering() throws {
        var legacy = TestStocks.negative
        legacy.halationProfile = HalationProfile(
            roundTripOpticalDepth: [0.8, 1, 1.2], angularExponent: [1, 1, 1],
            diffuseShare: [0.1, 0.1, 0.1], diffuseSigmaMM: [0.01, 0.01, 0.01],
            bounceRetention: [0.1, 0.1, 0.1])
        legacy.estimatedHalationProfile = legacy.halationProfile
        legacy.halationReturnMatrix = [[0.8, 0.1, 0.1], [0.2, 0.7, 0.1], [0.1, 0.2, 0.7]]
        var withConstruction = legacy
        withConstruction.layeredTransport = TransportFixtures.stack
        let definition = FilmStockDefinition(id: "coexisting-models", stock: withConstruction)
        try definition.validate()
        let decoded = try JSONDecoder().decode(FilmStockDefinition.self,
            from: JSONEncoder().encode(definition))
        try decoded.validate()
        XCTAssertEqual(decoded.stock.halationProfile, legacy.halationProfile)
        XCTAssertEqual(decoded.stock.estimatedHalationProfile, legacy.estimatedHalationProfile)
        XCTAssertEqual(decoded.stock.halationReturnMatrix, legacy.halationReturnMatrix)

        var options = TransportFixtures.quiet
        XCTAssertEqual(options.halationModel, .legacy)
        XCTAssertNil(options.transportConstruction(for: decoded.stock))
        options.halationModel = .layered
        XCTAssertEqual(options.transportConstruction(for: decoded.stock), TransportFixtures.stack)
        options.layeredTransport = TransportFixtures.mirror
        XCTAssertEqual(options.transportConstruction(for: decoded.stock), TransportFixtures.mirror)

        // Coexistence must not bypass validation of either Legacy profile or its matrix.
        var bad = decoded; bad.halationProfile?.roundTripOpticalDepth = [-1, 1, 1]
        XCTAssertThrowsError(try bad.validate())
        bad = decoded; bad.estimatedHalationProfile?.roundTripOpticalDepth = [-1, 1, 1]
        XCTAssertThrowsError(try bad.validate())
        bad = decoded; bad.halationReturnMatrix = [[1]]
        XCTAssertThrowsError(try bad.validate())

        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable; schema assertions passed") }
        var source = ImageBuffer(width: 37, height: 29, fill: 0.008)
        for y in 10..<19 { for x in 14..<23 {
            source.planes[0][y * 37 + x] = 16
            source.planes[1][y * 37 + x] = 4
            source.planes[2][y * 37 + x] = 1
        } }
        options = TransportFixtures.quiet
        options.localTone = false; options.frameCoverage = 0.05
        for estimated in [false, true] {
            options.useEstimatedHalationProfile = estimated
            let before = try FotufilmEngine(stock: legacy, options: options).processChecked(linearRGB: source)
            let after = try FotufilmEngine(stock: decoded.stock, options: options).processChecked(linearRGB: source)
            XCTAssertEqual(after.planes, before.planes)
        }
    }

    func testSceneSpectrumWithNo560nmEnergyKeepsCalibratedExposure() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        var options = TransportFixtures.quiet
        var lamp = SpectralGrid.d65
        lamp[Illuminant.anchorIndex] = 0
        options.sceneIlluminantSpectrum = lamp
        let source = ImageBuffer(width: 9, height: 7,
            planes: [Float(0.4), 0.15, 0.08].map { Array(repeating: $0, count: 63) })
        let legacy = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: source)
        options.halationModel = .layered
        for scale: Float in [1, 7] {
            options.sceneIlluminantSpectrum = lamp.map { $0 * scale }
            let layered = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: source)
            for c in 0..<3 {
                XCTAssertEqual(layered.planes[c][0], legacy.planes[c][0], accuracy: 0.00005)
            }
        }
    }

    func testRenderedUniformColoursAreIndependentOfAmount() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        var stock = TestStocks.negative; stock.adjacencyStrength = 0
        var options = TransportFixtures.quiet
        options.layeredTransport = TransportFixtures.stack
        // Uniform saturated and HDR fields catch normalization and out-of-gamut differences.
        for colour: [Float] in [[0.18, 0.18, 0.18], [2, 0.04, 0.1], [0.01, 0.03, 20]] {
            let image = ImageBuffer(width: 9, height: 7,
                planes: colour.map { Array(repeating: $0, count: 63) })
            options.halationScale = 0
            let zero = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: image)
            var legacy = options; legacy.layeredTransport = nil
            let calibrated = try FotufilmEngine(stock: stock, options: legacy).processChecked(linearRGB: image)
            for c in 0..<3 {
                XCTAssertEqual(zero.planes[c][0], calibrated.planes[c][0], accuracy: 0.00005)
            }
            for amount: Float in [1, 10] {
                options.halationScale = amount
                let output = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: image)
                for c in 0..<3 { for i in 0..<63 {
                    XCTAssertEqual(output.planes[c][i], zero.planes[c][i], accuracy: 0.00005)
                } }
            }
        }
    }

    func testSplitStagesTextureIdentityAndUnsupportedCombinations() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        var options = TransportFixtures.quiet
        options.layeredTransport = TransportFixtures.stack
        var image = ImageBuffer(width: 21, height: 17, fill: 0.1)
        image.planes[0][170] = 80; image.planes[1][170] = 4
        let engine = FotufilmEngine(stock: TestStocks.negative, options: options)
        let full = try engine.processChecked(linearRGB: image)
        options.stage = .negative
        let density = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: image)
        options.stage = .print
        let split = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: density)
        let error = zip(full.planes.flatMap{$0}, split.planes.flatMap{$0}).map { abs($0-$1) }.max() ?? 0
        XCTAssertLessThan(error, 0.00005)
        options.stage = .texture; options.textureStages = []
        let identity = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: image)
        let identityError = zip(identity.planes.flatMap{$0}, image.planes.flatMap{$0}).map { abs($0-$1) }.max() ?? 0
        XCTAssertLessThan(identityError, 0.0001)
        options.stage = .full; options.halationHazeMM = 0.01
        XCTAssertThrowsError(try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: image))
        options.halationHazeMM = nil
        var donor = TestStocks.negative; donor.donorLayers = [TestStocks.donor]
        XCTAssertThrowsError(try FotufilmEngine(stock: donor, options: options).processChecked(linearRGB: image))
    }
}
