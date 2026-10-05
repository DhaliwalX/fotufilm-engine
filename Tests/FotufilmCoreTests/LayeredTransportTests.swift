import Foundation
import XCTest
@testable import FotufilmCore

enum TransportFixtures {
    /// Invented construction for numerical tests, not a measured commercial film.
    static var stack: LayeredTransport {
        LayeredTransport(constructionID: "synthetic-layered-negative",
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
        LayeredTransport(constructionID: "analytic-mirror",
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
                // The three direct captures are Legacy's exposure; returned light comes on top.
                for i in legacy.indices where i % 4 != 3 {
                    let sum = plan.components.prefix(3).reduce(Float(0)) { $0 + $1.exposure[i] }
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

    func testReturnedLightAddsToAWholeDirectCaptureAndScalesWithTheAmount() throws {
        var model = TransportFixtures.stack
        model.returnedToDirect[0] = SpectralGrid.wavelengths.map { Double($0 - 375) / 1000 }
        for sourceColour: Float in [0, 0.5, 1] {
            let compiled = try TransportKernelCompiler.compile(model, sourceColour: sourceColour)
            XCTAssertLessThanOrEqual(compiled.maximumEdgeError, 0.005)
            for endpoint in [compiled.core, compiled.saturated] {
                for c in 0..<3 { for b in 0..<SpectralGrid.count {
                    let values = endpoint.map { $0[c][b] }
                    XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0.isFinite })
                    XCTAssertEqual(values[c], 1, "the direct capture stays whole")
                    XCTAssertEqual(values[..<3].reduce(0, +), 1)
                } }
            }
            if sourceColour == 0 {
                for c in 0..<3 { for b in stride(from: 0, to: SpectralGrid.count, by: 7) {
                    let returned = compiled.saturated.dropFirst(3).reduce(0.0) { $0 + Double($1[c][b]) }
                    XCTAssertEqual(returned * compiled.maximumReturnedRatio,
                                   LayeredTransport.sample(model.returnedToDirect[c], b), accuracy: 1e-5)
                } }
            }
            let amounts = [0.0, 0.5, 1, 2].map { compiled.interpolation(amount: $0) }
            XCTAssertEqual(amounts[0], 0)
            XCTAssertEqual(amounts[2], Float(compiled.maximumReturnedRatio), accuracy: 1e-7)
            XCTAssertEqual(amounts[1], amounts[2] / 2, accuracy: 1e-7)
            XCTAssertEqual(amounts[3], amounts[2] * 2, accuracy: 1e-7)
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

    func testTransportPipelineMatchesDirectBandsAndMetalAgrees() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        // A shoulder at stride 1 and a tail on a coarse grid, on a frame no stride divides.
        let kernel = try TransportRadialKernel(radiusMM: [0.006, 0.03, 0.4], mass: [0.6, 0.3, 0.1])
        let pitch = 0.004, width = 77, height = 45
        let table = try kernel.transportTable(pixelPitchMM: pitch)
        let bands = try kernel.stencils(pixelPitchMM: pitch)
        XCTAssertTrue(bands.contains { $0.stencil.stride >= 8 })
        func frame(_ fill: Float) -> ImageBuffer {
            var frame = ImageBuffer(width: width, height: height, fill: fill)
            frame.planes.append(Array(repeating: fill, count: width * height))
            return frame
        }
        var impulse = frame(0)
        impulse.planes[0][22 * width + 38] = 10; impulse.planes[1][0] = 3
        impulse.planes[2][width * height - 1] = 5; impulse.planes[3][10 * width + 70] = 2
        var reference = frame(0.25)
        for band in bands { for c in 0..<4 {
            let filtered = Self.directBand(impulse.planes[c], width: width, height: height, stencil: band.stencil)
            for i in filtered.indices { reference.planes[c][i] += band.weight * filtered[i] }
        } }
        var cpu = frame(0.25)
        try LayeredTransportRenderer.transport(impulse, stencils: table, into: &cpu)
        let cpuError = zip(reference.planes.flatMap { $0 }, cpu.planes.flatMap { $0 }).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(cpuError, 2e-6)
        // A uniform field stays uniform, edges included.
        let field = ImageBuffer(width: width, height: height,
            planes: [Float(0.02), 0.7, 40].map { Array(repeating: $0, count: width * height) })
        var spread = ImageBuffer(width: width, height: height)
        try LayeredTransportRenderer.transport(field, stencils: table, into: &spread)
        for c in 0..<3 { for value in spread.planes[c] { XCTAssertEqual(value, field.planes[c][0], accuracy: field.planes[c][0] * 2e-5) } }
        guard TransportBackend.metal.isAvailable else { throw XCTSkip("Metal unavailable; CPU assertions passed") }
        var metal = frame(0.25)
        try LayeredTransportRenderer.transport(impulse, stencils: table, into: &metal, backend: .metal)
        let metalError = zip(cpu.planes.flatMap { $0 }, metal.planes.flatMap { $0 }).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(metalError, 2e-6)
    }

    /// One band the direct way: stride x stride box averages with edge pixels repeated, the
    /// stencil over the clamped grid, then the cubic B-spline at pixel centres.
    private static func directBand(_ plane: [Float], width: Int, height: Int, stencil: TransportStencil) -> [Float] {
        let s = stencil.stride, r = stencil.radius, side = 2 * r + 1
        let gw = (width + s - 1) / s, gh = (height + s - 1) / s
        var reduced = [Double](repeating: 0, count: gw * gh), blurred = reduced
        for y in 0..<gh { for x in 0..<gw {
            var sum = 0.0
            for dy in 0..<s { for dx in 0..<s {
                sum += Double(plane[min(y * s + dy, height - 1) * width + min(x * s + dx, width - 1)])
            } }
            reduced[y * gw + x] = sum / Double(s * s)
        } }
        for y in 0..<gh { for x in 0..<gw {
            var sum = 0.0
            for dy in -r...r { for dx in -r...r {
                sum += Double(stencil.weights[(dy + r) * side + dx + r])
                    * reduced[min(max(y + dy, 0), gh - 1) * gw + min(max(x + dx, 0), gw - 1)]
            } }
            blurred[y * gw + x] = sum
        } }
        func at(_ x: Int, _ y: Int) -> Double { blurred[min(max(y, 0), gh - 1) * gw + min(max(x, 0), gw - 1)] }
        func weights(_ f: Double) -> [Double] {
            [(1 - f) * (1 - f) * (1 - f) / 6, (3 * f * f * f - 6 * f * f + 4) / 6,
             (-3 * f * f * f + 3 * f * f + 3 * f + 1) / 6, f * f * f / 6]
        }
        var output = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            if s == 1 { output[y * width + x] = Float(at(x, y)); continue }
            let px = (Double(x) + 0.5) / Double(s) - 0.5, py = (Double(y) + 0.5) / Double(s) - 0.5
            let x0 = Int(floor(px)), y0 = Int(floor(py))
            let wx = weights(px - Double(x0)), wy = weights(py - Double(y0))
            var value = 0.0
            for j in 0..<4 { for i in 0..<4 { value += wy[j] * wx[i] * at(x0 + i - 1, y0 + j - 1) } }
            output[y * width + x] = Float(value)
        } }
        return output
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
        // Without returned light, which only adds to a uniform field.
        options.halationModel = .layered; options.halationScale = 0
        for scale: Float in [1, 7] {
            options.sceneIlluminantSpectrum = lamp.map { $0 * scale }
            let layered = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: source)
            for c in 0..<3 {
                XCTAssertEqual(layered.planes[c][0], legacy.planes[c][0], accuracy: 0.00005)
            }
        }
    }

    func testUniformColoursGainOnlyTheirReturnedLight() throws {
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
            // Returned light is added to the direct capture, so the field only brightens, evenly.
            var previous = zero.planes.map { $0[0] }.reduce(0, +)
            for amount: Float in [1, 10] {
                options.halationScale = amount
                let output = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: image)
                let total = output.planes.map { $0[0] }.reduce(0, +)
                XCTAssertGreaterThan(total, previous, "colour \(colour) amount \(amount)")
                previous = total
                for c in 0..<3 { for i in 0..<63 {
                    XCTAssertEqual(output.planes[c][i], output.planes[c][0], accuracy: 0.00005)
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
        // The base's haze blurs the returned light only.
        options.stage = .full; options.halationHazeMM = 0.05
        let hazed = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: image)
        XCTAssertTrue(hazed.planes.flatMap { $0 }.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(zip(hazed.planes[0], full.planes[0]).map { abs($0 - $1) }.max() ?? 0, 0)
    }

    /// With no returned light a uniform field is untouched by the film's optics, so Layered
    /// develops it as Legacy does; the returned light only adds to it.
    private func assertUniformFieldsMatchLegacy(stock: FilmStock, options configured: FotufilmEngine.Options,
                                                file: StaticString = #filePath, line: UInt = #line) throws -> [Float] {
        var options = configured
        options.layeredTransport = TransportFixtures.stack
        var legacy = options; legacy.layeredTransport = nil
        var outputs = [Float]()
        for colour: [Float] in [[0.18, 0.18, 0.18], [2, 0.04, 0.1], [0.2, 1.5, 0.05], [0.002, 0.003, 0.004]] {
            let image = ImageBuffer(width: 9, height: 7, planes: colour.map { Array(repeating: $0, count: 63) })
            let expected = try FotufilmEngine(stock: stock, options: legacy).processChecked(linearRGB: image)
            options.halationScale = 0
            let layered = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: image)
            for c in 0..<3 {
                XCTAssertEqual(layered.planes[c][31], expected.planes[c][31], accuracy: 0.00005,
                               "colour \(colour)", file: file, line: line)
            }
            options.halationScale = 1
            let returned = try FotufilmEngine(stock: stock, options: options).processChecked(linearRGB: image)
            XCTAssertGreaterThan((0..<3).map { returned.planes[$0][31] }.reduce(0, +),
                                 (0..<3).map { expected.planes[$0][31] }.reduce(0, +),
                                 "colour \(colour)", file: file, line: line)
            outputs += (0..<3).map { expected.planes[$0][31] }
        }
        return outputs
    }

    func testDonorStocksCarryTheirFourthRecordThroughTransport() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        var stock = TestStocks.negative; stock.adjacencyStrength = 0
        var options = TransportFixtures.quiet; options.couplerScale = 1
        let plain = try assertUniformFieldsMatchLegacy(stock: stock, options: options)
        stock.donorLayers = [TestStocks.donor]
        let donated = try assertUniformFieldsMatchLegacy(stock: stock, options: options)
        XCTAssertGreaterThan(zip(plain, donated).map { abs($0 - $1) }.max() ?? 0, 0.002,
                             "the fourth record changes what develops")
    }

    func testTheDonorIsSolvedAtItsOwnDepthWithGreensOptics() throws {
        let model = TransportFixtures.stack
        // At green's depth the donor is green's receiver exactly.
        let atGreen = try TransportKernelCompiler.compile(model, donorDepthMM: model.recordDepthMM[1])
        for endpoint in [atGreen.core, atGreen.saturated] {
            XCTAssertEqual(endpoint.first?.count, 4)
            for k in endpoint.indices { XCTAssertEqual(endpoint[k][3], endpoint[k][1]) }
        }
        // Deeper, nearer the support, its returned light spreads less than green's but it
        // keeps green's return strength: it is green light that reaches it.
        let deeper = try TransportKernelCompiler.compile(model, donorDepthMM: 0.0118)
        var differs = false
        for b in 0..<SpectralGrid.count {
            let values = deeper.saturated.map { $0[3][b] }
            XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0.isFinite })
            XCTAssertEqual(values[1], 1, "the donor's direct capture is green's core, whole")
            XCTAssertEqual(values.dropFirst(3).reduce(0, +),
                           deeper.saturated.dropFirst(3).map { $0[1][b] }.reduce(0, +), accuracy: 2e-6)
            XCTAssertEqual(deeper.saturated[1][3][b], deeper.saturated[1][1][b], accuracy: 1e-6)
            XCTAssertEqual(deeper.core[1][3][b], 1)
            differs = differs || deeper.saturated.indices.contains { deeper.saturated[$0][3][b] != deeper.saturated[$0][1][b] }
        }
        XCTAssertTrue(differs)
        XCTAssertThrowsError(try TransportKernelCompiler.compile(model, donorDepthMM: 1))
    }

    /// A frame exposes each component from the scene as its head's light, spread, would be.
    func testAFrameExposesEveryComponentAsItsHeadDoes() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        let (width, height) = (61, 37)
        var image = ImageBuffer(width: width, height: height)
        for i in 0..<width * height { for c in 0..<3 {
            image.planes[c][i] = Float((i * 7 + c * 13) % 23) / 23 * 0.6 + (i == 900 ? 40 : 0)
        } }
        for donated in [false, true] {
            var stock = TestStocks.negative
            if donated { stock.donorLayers = [TestStocks.donor] }
            var options = TransportFixtures.quiet
            options.cameraPreflash = 0.03
            let compilation = try TransportKernelCompiler.compile(
                TransportFixtures.stack, donorDepthMM: donated ? 0.0118 : nil)
            let tables = try SpectralRuntime.transportExposureTables(
                stock: stock, options: options, compilation: compilation)
            let invocation = try FilmEngineInvocation(validating: stock, options: options,
                                                      width: width, height: height)
            let channels = donated ? 4 : 3, n = width * height
            var reference = ImageBuffer(width: width, height: height)
            if donated { reference.planes.append(Array(repeating: 0, count: n)) }
            var components = [(head: FilmEngineInvocation, stencils: [Float])]()
            for k in compilation.kernels.indices {
                let table = tables.table(component: k, interpolation: 0.7)
                var head = invocation
                head.featureMask &= FilmEngineFeature.flare | FilmEngineFeature.diffusion
                head.featureMask |= FilmEngineFeature.lightOut
                head.clearTransportOptics(keepLens: true)
                head.sharePreflash(among: compilation.kernels.count)
                head.setTransportExposure(table)
                let stencils = try compilation.kernels[k].transportTable(pixelPitchMM: 0.004)
                var light = try LayeredTransportRenderer.run(image: image, invocation: head, developOnly: true)
                if donated {
                    var fourth = head
                    fourth.setTransportExposure(LayeredTransportRenderer.fourthRecord(of: table))
                    light.planes.append(try LayeredTransportRenderer.run(
                        image: image, invocation: fourth, developOnly: true).planes[0])
                }
                try LayeredTransportRenderer.transport(light, stencils: stencils, into: &reference)
                components.append((head, stencils))
            }
            let expected = reference.planes.flatMap { $0 }
            for backend in [TransportBackend.cpu, .metal] where backend.isAvailable {
                var sum = [Float](repeating: 0, count: n * channels)
                try LayeredTransportRenderer.exposeFrame(LayeredTransportRenderer.interleaved(image),
                    width: width, height: height, channels: channels, components: components,
                    backend: backend, into: &sum)
                let error = zip(expected, sum).map { abs($0 - $1) / max(abs($0), 1e-3) }.max() ?? 0
                XCTAssertLessThan(error, 2e-5, "\(backend) donated \(donated)")
            }
        }
    }

    func testPreflashExposesTheFilmOnce() throws {
        guard TransportBackend.cpu.isAvailable else { throw XCTSkip("Halide unavailable") }
        var stock = TestStocks.negative; stock.adjacencyStrength = 0
        var options = TransportFixtures.quiet
        options.cameraPreflash = 0.05
        _ = try assertUniformFieldsMatchLegacy(stock: stock, options: options)
    }
}

final class LayeredConstructionControlTests: XCTestCase {
    private func captured(_ model: LayeredTransport, band: Int = 40) throws -> Double {
        try LayeredTransportSolver.solve(model, receiver: 0, band: band).captured
    }

    func testRemovingTheBackingKeepsTheFilmsRecordBalance() throws {
        let stock = try XCTUnwrap(FilmStock.named("portra400"))
        let film = try XCTUnwrap(stock.layeredTransport)
        let open = try film.adjusted(antiHalation: 0, baseThickness: 1, pressurePlate: 0)
        let compiled = try TransportKernelCompiler.compile(open, reference: film, edgeTolerance: 0.02)
        let band = 54
        // A record's returned ratio is its saturated returned kernels (after the three cores),
        // scaled back from the largest ratio.
        func ratio(_ c: Int) -> Double {
            compiled.maximumReturnedRatio * compiled.kernels.indices.dropFirst(3)
                .reduce(0.0) { $0 + Double(compiled.saturated[$1][c][band]) }
        }
        XCTAssertGreaterThan(ratio(0), 0.2); XCTAssertLessThan(ratio(0), 0.35)
        XCTAssertEqual(ratio(1) / ratio(0), film.returnedToDirect[1][0] / film.returnedToDirect[0][0],
                       accuracy: 1e-4)
    }

    func testTheFilmsOwnSettingsLeaveItsConstructionAlone() throws {
        let model = TransportFixtures.stack
        XCTAssertEqual(try model.adjusted(antiHalation: 1, baseThickness: 1, pressurePlate: 0), model)
        // An opaque backing hides a plate behind it.
        XCTAssertEqual(try TransportFixtures.mirror.adjusted(antiHalation: 1, baseThickness: 1, pressurePlate: 1),
                       TransportFixtures.mirror)
        XCTAssertThrowsError(try model.adjusted(antiHalation: -1, baseThickness: 1, pressurePlate: 0))
        XCTAssertThrowsError(try model.adjusted(antiHalation: 1, baseThickness: 1, pressurePlate: 2))
    }

    func testEachControlMovesTheReturnedLightTheWayItsPhysicsDoes() throws {
        let model = TransportFixtures.stack
        let film = try captured(model)
        // Less absorption, and a plate behind the open back, return more light.
        XCTAssertGreaterThan(try captured(model.adjusted(antiHalation: 0.5, baseThickness: 1, pressurePlate: 0)), film)
        XCTAssertLessThan(try captured(model.adjusted(antiHalation: 1.5, baseThickness: 1, pressurePlate: 0)), film)
        let plated = try captured(model.adjusted(antiHalation: 1, baseThickness: 1, pressurePlate: 0.5))
        XCTAssertGreaterThan(plated, film)
        XCTAssertGreaterThan(try captured(model.adjusted(antiHalation: 1, baseThickness: 1, pressurePlate: 1)), plated)
        // A thicker base carries the same light farther.
        let thin = try LayeredTransportSolver.solve(model, receiver: 0, band: 40)
        let thick = try LayeredTransportSolver.solve(
            model.adjusted(antiHalation: 1, baseThickness: 2, pressurePlate: 0), receiver: 0, band: 40)
        XCTAssertGreaterThan(try XCTUnwrap(thick.kernel).quantile(0.5), try XCTUnwrap(thin.kernel).quantile(0.5))
        // A perfect plate lets nothing out of the back: what escapes leaves through the front.
        let open = try LayeredTransportSolver.solve(
            model.adjusted(antiHalation: 0, baseThickness: 1, pressurePlate: 0), receiver: 0, band: 40)
        let mirrored = try LayeredTransportSolver.solve(
            model.adjusted(antiHalation: 0, baseThickness: 1, pressurePlate: 1), receiver: 0, band: 40)
        XCTAssertLessThan(mirrored.escaped, open.escaped)
    }

    func testAnAdjustedReturnRunsFromTheFilmsOwnToThePhysicalLaunch() {
        let ratio = 0.0055, film = 1.6e-4, lossless = 0.27
        let launch = TransportKernelCompiler.launch(capture: 0.5)
        XCTAssertEqual(launch, 1)
        func scaled(_ adjusted: Double) -> Double {
            ratio * TransportKernelCompiler.adjustedReturn(filmRatio: ratio, film: film,
                                                            adjusted: adjusted, lossless: lossless, launch: launch)
        }
        XCTAssertEqual(scaled(film), ratio, accuracy: ratio * 1e-12)
        XCTAssertEqual(scaled(lossless), launch * lossless, accuracy: 1e-12)
        var last = 0.0
        for c in stride(from: 1e-5, through: 0.27, by: 0.003) {
            XCTAssertGreaterThan(scaled(c), last); last = scaled(c)
        }
        // With nothing to remove, the return follows the capture.
        XCTAssertEqual(TransportKernelCompiler.adjustedReturn(filmRatio: ratio, film: 0.2, adjusted: 0.3, lossless: 0.2,
                                                              launch: launch),
                       1.5, accuracy: 1e-12)
    }

    func testHazeBlursTheReturnedBasisAndNeverTheCores() throws {
        let model = TransportFixtures.stack
        let clear = try TransportKernelCompiler.compile(model)
        let hazed = try TransportKernelCompiler.compile(model, hazeMM: 0.05)
        XCTAssertEqual(clear.kernels.count, hazed.kernels.count)
        XCTAssertEqual(clear.saturated, hazed.saturated)
        XCTAssertLessThanOrEqual(hazed.maximumEdgeError, 0.005)
        for k in 0..<3 { XCTAssertEqual(clear.kernels[k], hazed.kernels[k]) }
        // A two-dimensional Gaussian adds twice its variance to the mean squared radius.
        func spread(_ kernel: TransportRadialKernel) -> Double {
            zip(kernel.radiusMM, kernel.mass).reduce(0) { $0 + $1.0 * $1.0 * $1.1 }
        }
        for k in 3..<clear.kernels.count {
            XCTAssertEqual(spread(hazed.kernels[k]) - spread(clear.kernels[k]), 2 * 0.05 * 0.05,
                           accuracy: 0.05 * 2 * 0.05 * 0.05)
        }
        let point = try TransportRadialKernel(radiusMM: [0], mass: [1]).hazed(sigmaMM: 0.1)
        XCTAssertEqual(spread(point), 2 * 0.1 * 0.1, accuracy: 0.05 * 2 * 0.1 * 0.1)
    }

    func testTheEditorsControlsReachALayeredRender() throws {
        var options = TransportFixtures.quiet
        options.localTone = false
        options.layeredTransport = TransportFixtures.stack
        var image = ImageBuffer(width: 48, height: 1, planes: Array(repeating: Array(repeating: 0.02, count: 48), count: 3))
        image.planes[0][24] = 60; image.planes[1][24] = 60; image.planes[2][24] = 60
        let film = try FotufilmEngine(stock: TestStocks.negative, options: options).processChecked(linearRGB: image)
        for adjust: (inout FotufilmEngine.Options) -> Void in [
            { $0.antiHalationScale = 0.25 }, { $0.baseThicknessScale = 2 }, { $0.pressurePlateReflectance = 1 },
        ] {
            var adjusted = options; adjust(&adjusted)
            let render = try FotufilmEngine(stock: TestStocks.negative, options: adjusted).processChecked(linearRGB: image)
            XCTAssertTrue(render.planes.flatMap { $0 }.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(zip(render.planes[0], film.planes[0]).map { abs($0 - $1) }.max() ?? 0, 1e-5)
        }
    }
}
