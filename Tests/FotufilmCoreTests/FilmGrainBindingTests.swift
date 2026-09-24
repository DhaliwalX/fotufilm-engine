import Foundation
import XCTest
@testable import FotufilmCore
import FotufilmHalide

final class FilmGrainBindingTests: XCTestCase {
    func testInvocationKeepsFilmBankThroughConcurrentCacheEvictionAndReleasesIt() throws {
        var options = FotufilmEngine.Options()
        options.grainModel = .film
        options.localTone = false
        options.format = FilmFormat(name: "Film binding parity", frameHeightMM: 0.4)
        var held: FilmEngineInvocation? = try FilmEngineInvocation(validating: TestStocks.negative,
            options: options, width: 9, height: 7)
        weak var binding = held?.filmTileBinding
        XCTAssertNotNil(binding)
        let configuration = try XCTUnwrap(held?.configuration)
        let exposure = try XCTUnwrap(held?.spectral.exposure)
        let original = try XCTUnwrap(FilmGrain.registeredTiles(configuration: configuration))
        let originalBlock = try XCTUnwrap(held?.filmTileBinding).configurationBlock(
            pxPerMM: 100, amount: 0.7, look: FilmGrain.Look(size: 1.3, softness: 1.7))
        let before = FotufilmEngine.isHalideBackendAvailable
            ? try render(configuration: configuration, exposure: exposure) : nil
        var copied = held
        held = nil

        // Empty populations make cache churn cheap; the live frame above has real Film grain.
        // More than four independent preparations exercise eviction while its value copy lives.
        let prefix = UUID().uuidString
        DispatchQueue.concurrentPerform(iterations: 6) { index in
            var stock = TestStocks.negative
            stock.name = "Film binding churn \(prefix) \(index)"
            stock.grainStrength = 0
            _ = FilmGrain.registered(stock: stock, reference: nil)
        }
        XCTAssertNotNil(binding)
        let retained = try XCTUnwrap(FilmGrain.registeredTiles(configuration: configuration))
        XCTAssertTrue(retained.elementsEqual(original), "Cache eviction changed the canonical bank")
        XCTAssertTrue(try XCTUnwrap(copied?.filmTileBinding).packed().elementsEqual(original))
        let retainedBlock = try XCTUnwrap(copied?.filmTileBinding).configurationBlock(
            pxPerMM: 100, amount: 0.7, look: FilmGrain.Look(size: 1.3, softness: 1.7))
        XCTAssertEqual(retainedBlock.map(\.bitPattern), originalBlock.map(\.bitPattern))
        if let before {
            let after = try render(configuration: configuration, exposure: exposure)
            XCTAssertTrue(after.map(\.bitPattern).elementsEqual(before.map(\.bitPattern)),
                "The C renderer lost the bank while the frame was alive")
        }

        copied = nil
        XCTAssertNil(binding, "Only the bounded cache and active frames may retain tile bindings")
        XCTAssertNil(FilmGrain.registeredTiles(configuration: configuration))
        if let before {
            let released = try render(configuration: configuration, exposure: exposure)
            XCTAssertFalse(released.map(\.bitPattern).elementsEqual(before.map(\.bitPattern)),
                "The C registration must be removed after its last frame and cache owner release it")
        }
    }

    private func render(configuration: [Float], exposure: SpectralLUT) throws -> [Float] {
        let width = 9, height = 7, count = width * height
        let source = (0..<count).map { Float($0 % 17) * 0.035 + 0.02 }
        var r = [Float](repeating: .nan, count: count), g = r, b = r
        var configuration = configuration
        configuration[Int(FOTUFILM_CONFIG_RECORD_INPUT)] = 1
        let status = source.withUnsafeBufferPointer { input in
            r.withUnsafeMutableBufferPointer { red in
                g.withUnsafeMutableBufferPointer { green in
                    b.withUnsafeMutableBufferPointer { blue in
                        configuration.withUnsafeBufferPointer { cfg in
                            exposure.values.withUnsafeBufferPointer { table in
                                fotufilm_halide_develop(input.baseAddress, input.baseAddress, input.baseAddress,
                                    red.baseAddress, green.baseAddress, blue.baseAddress,
                                    Int32(width), Int32(height), cfg.baseAddress, table.baseAddress,
                                    Int32(exposure.dimension), FilmEngineFeature.grain | FilmEngineFeature.exactMath,
                                    94_731)
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(status, 0)
        return r + g + b
    }
}
