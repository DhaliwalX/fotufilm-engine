#if canImport(CoreImage)
import XCTest
import CoreImage
import CoreGraphics
@testable import FotufilmCore
@testable import FotufilmImaging

final class PrintEncodingTests: XCTestCase {
    func testEngineOutputConverterPacksRowsAndProvidesColorTag() throws {
        let source: [Float] = [1, 0, 0, 1]
        var destination = [UInt16](repeating: 0, count: source.count)
        source.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destination in
                PrintEncoding.encodeRows(
                    source, rows: 0..<1, width: 1, into: destination,
                    converter: FilmOutputConversion.sRGBSDR)
            }
        }

        XCTAssertEqual(destination[3], 65535)
        XCTAssertGreaterThan(destination[0], destination[1])
        XCTAssertNotNil(PrintEncoding.colorSpace(for: .sRGB))
        XCTAssertNotNil(PrintEncoding.colorSpace(for: .rec2020HLG))
        XCTAssertNil(PrintEncoding.colorSpace(for: .init(rawValue: "client-log")))
    }

    func testNonFiniteOutputIsRepairedBeforePacking() {
        let source: [Float] = [0.2, 0.4, 0.6, 1]
        let broken = AnyFilmOutputConverter(colorSpace: .displayP3) {
            _, _, _, destination in
            destination[0] = .nan
            destination[1] = .infinity
            destination[2] = -.infinity
            destination[3] = 1
        }
        var converted = [UInt16](repeating: 1, count: 4)
        source.withUnsafeBufferPointer { source in
            converted.withUnsafeMutableBufferPointer { destination in
                PrintEncoding.encodeRows(
                    source, rows: 0..<1, width: 1, into: destination,
                    converter: broken)
            }
        }
        XCTAssertEqual(converted, [0, 0, 0, 65535])

        let invalid: [Float] = [.nan, .nan, .nan, 1]
        for transfer in [PrintEncoding.Transfer.srgb, .shoulderedSRGB, .hlg] {
            var packed = [UInt16](repeating: 1, count: 4)
            invalid.withUnsafeBufferPointer { source in
                packed.withUnsafeMutableBufferPointer { destination in
                    PrintEncoding.encodeRows(
                        source, rows: 0..<1, width: 1, into: destination,
                        transfer: transfer)
                }
            }
            XCTAssertEqual(packed, [0, 0, 0, 65535], "\(transfer)")
        }
    }

    func coreImageEncode(_ linear: [Float]) -> [Float] {
        let count = linear.count / 4
        let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let data = linear.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: count * 16,
                            size: CGSize(width: count, height: 1),
                            format: .RGBAf, colorSpace: linearSpace)
        let context = CIContext(options: [.workingColorSpace: linearSpace,
                                          .workingFormat: CIFormat.RGBAf])
        var out = [Float](repeating: 0, count: count * 4)
        out.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!, rowBytes: count * 16,
                           bounds: image.extent, format: .RGBAf,
                           colorSpace: sRGBSpace)
        }
        return out
    }

    func testMatchesCoreImagesOwnConversion() {
        var linear: [Float] = []
        for step in 0...256 {
            let v = Float(step) / 256
            linear += [v, v * 0.5, v * 0.25, 1]
        }
        let reference = coreImageEncode(linear)
        var worst: Float = 0
        for index in stride(from: 0, to: linear.count, by: 4) {
            for channel in 0..<3 {
                let mine = PrintEncoding.encode(linear[index + channel])
                worst = max(worst, abs(mine - reference[index + channel]))
            }
        }
        XCTAssertLessThan(worst, 1.0 / 65535,
                          "the encode curve disagrees with Core Image by \(worst)")
    }

    func testEndpointsAndKnee() {
        XCTAssertEqual(PrintEncoding.encode(0), 0, accuracy: 1e-7)
        XCTAssertEqual(PrintEncoding.encode(1), 1, accuracy: 1e-6)
        let below = PrintEncoding.encode(0.0031308 - 1e-6)
        let above = PrintEncoding.encode(0.0031308 + 1e-6)
        XCTAssertEqual(below, above, accuracy: 1e-4)
        XCTAssertEqual(PrintEncoding.encode(-5), 0, accuracy: 1e-7)
        XCTAssertEqual(PrintEncoding.encode(12), 1, accuracy: 1e-6)
    }

    func testReversalSDRShoulderPreservesMoreHighlightSeparation() {
        let standardLow = ColorScience.displayShoulder(
            1, knee: FilmSDRDelivery.standardShoulderKnee)
        let standardHigh = ColorScience.displayShoulder(
            2, knee: FilmSDRDelivery.standardShoulderKnee)
        let reversalLow = ColorScience.displayShoulder(
            1, knee: FilmSDRDelivery.reversalShoulderKnee)
        let reversalHigh = ColorScience.displayShoulder(
            2, knee: FilmSDRDelivery.reversalShoulderKnee)
        XCTAssertGreaterThan(reversalHigh - reversalLow,
                             standardHigh - standardLow)
        XCTAssertLessThan(reversalLow, standardLow)
        XCTAssertEqual(ColorScience.displayShoulder(
            FilmSDRDelivery.reversalShoulderKnee,
            knee: FilmSDRDelivery.reversalShoulderKnee),
            FilmSDRDelivery.reversalShoulderKnee)
    }

    func testSixteenBitImageIsAcceptedAndCarriesItsValues() throws {
        let width = 8, height = 4
        let buffer = UnsafeMutableBufferPointer<UInt16>.allocate(
            capacity: width * height * 4)
        buffer.initialize(repeating: 0)
        for index in stride(from: 0, to: buffer.count, by: 4) {
            buffer[index] = 65535
            buffer[index + 1] = 32768
            buffer[index + 2] = 0
            buffer[index + 3] = 65535
        }
        let image = try XCTUnwrap(PrintEncoding.makeImage(
            takingOwnershipOf: buffer, width: width, height: height,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
            "CoreGraphics rejected the export's bitmap format")
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        XCTAssertEqual(image.bitsPerComponent, 16)

        var readback = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &readback, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertEqual(Int(readback[0]), 255, "red channel did not survive")
        XCTAssertEqual(Double(readback[1]), 128, accuracy: 2, "green channel did not survive")
        XCTAssertEqual(Int(readback[2]), 0, "blue channel did not survive")
        XCTAssertEqual(Int(readback[3]), 255, "alpha did not survive")
    }

    func testFailedImageStillReleasesItsBuffer() {
        let buffer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: 4)
        buffer.initialize(repeating: 0)
        XCTAssertNil(PrintEncoding.makeImage(
            takingOwnershipOf: buffer, width: 64, height: 64,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
    }

    func testRowsLandWhereTheyAreAddressed() {
        let width = 4, height = 6
        var destination = [UInt16](repeating: 0, count: width * height * 4)
        var strip = [Float](repeating: 0, count: width * 2 * 4)
        for index in stride(from: 0, to: strip.count, by: 4) {
            strip[index] = 1; strip[index + 1] = 1; strip[index + 2] = 1
        }
        strip.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { out in
                PrintEncoding.encodeRows(source, rows: 2..<4, width: width, into: out)
            }
        }
        for row in 0..<height {
            let value = destination[(row * width) * 4]
            if row == 2 || row == 3 {
                XCTAssertEqual(value, 65535, "row \(row) should have been written")
            } else {
                XCTAssertEqual(value, 0, "row \(row) should have been left alone")
            }
        }
    }

    func testHLGChunksLandAtTheAddressedRows() {
        let width = 4, height = 75, stripHeight = 70
        var destination = [UInt16](repeating: 0, count: width * height * 4)
        let strip = [Float](repeating: 1, count: width * stripHeight * 4)
        strip.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { output in
                PrintEncoding.encodeRows(
                    source, rows: 3..<(3 + stripHeight), width: width,
                    into: output, transfer: .hlg)
            }
        }
        for row in 0..<height {
            let alpha = destination[(row * width) * 4 + 3]
            XCTAssertEqual(alpha, (3..<(3 + stripHeight)).contains(row)
                           ? 65535 : 0, "wrong HLG destination row \(row)")
        }
    }

    func testHLGBranchesMeetAndReachTheEndpoints() {
        XCTAssertEqual(PrintEncoding.encodeHLG(0), 0, accuracy: 1e-7)
        XCTAssertEqual(PrintEncoding.encodeHLG(1.0 / 12), 0.5, accuracy: 1e-6)
        let below = PrintEncoding.encodeHLG(1.0 / 12 - 1e-6)
        let above = PrintEncoding.encodeHLG(1.0 / 12 + 1e-6)
        XCTAssertEqual(below, above, accuracy: 1e-5)
        XCTAssertEqual(PrintEncoding.encodeHLG(1), 1, accuracy: 1e-5)
        XCTAssertEqual(PrintEncoding.encodeHLG(-3), 0, accuracy: 1e-7)
        XCTAssertEqual(PrintEncoding.encodeHLG(9), 1, accuracy: 1e-5)
    }

    func testDiffuseWhiteLandsOnReferenceWhite() {
        let signal = PrintEncoding.encodeHLG(1 / PrintEncoding.hdrHeadroom)
        XCTAssertEqual(signal, PrintEncoding.hlgReferenceWhiteSignal, accuracy: 1e-6)
        XCTAssertEqual(PrintEncoding.hdrHeadroom, 3.7745, accuracy: 1e-3)
        // The scene side's one HLG authority (`HLGSceneTransfer` — the ingest curve and the
        // core output conversion both read it) and this package's encode must be the same
        // numbers, or a clip written here would not read back to the light it recorded.
        XCTAssertEqual(PrintEncoding.hdrHeadroom, HLGSceneTransfer.headroom)
        XCTAssertEqual(PrintEncoding.hlgReferenceWhiteSignal,
                       HLGSceneTransfer.diffuseWhiteSignal)
        for signal in stride(from: Float(0), through: 1, by: 0.05) {
            XCTAssertEqual(PrintEncoding.encodeHLG(
                               HLGSceneTransfer.sceneLight(signal)),
                           signal, accuracy: 1e-5,
                           "encode and scene read disagree at \(signal)")
        }
    }

    func testShouldersAgreeBelowTheKneeAndPartAboveIt() {
        for step in 0...90 {
            let x = Float(step) / 100
            XCTAssertEqual(PrintEncoding.shoulder(x), PrintEncoding.hdrShoulder(x),
                           accuracy: 1e-7,
                           "the shoulders disagree at \(x), below the knee")
            XCTAssertEqual(PrintEncoding.hdrShoulder(x), x, accuracy: 1e-7,
                           "the HDR shoulder is not the identity at \(x)")
        }
        for x in [Float(1), 2, 8, 1000] {
            XCTAssertLessThan(PrintEncoding.shoulder(x), 1)
            XCTAssertGreaterThan(PrintEncoding.hdrShoulder(x), PrintEncoding.shoulder(x))
            XCTAssertLessThan(PrintEncoding.hdrShoulder(x), PrintEncoding.hdrDisplayCeiling)
        }
        XCTAssertEqual(PrintEncoding.hdrShoulder(2), 1.7638, accuracy: 1e-3)
    }

    func testHDRShoulderPreservesCalibratedChromaticity() {
        let patches: [SIMD3<Float>] = [
            SIMD3(0.8, 0.2, 0.1),
            SIMD3(4, 1, 0.2),
            SIMD3(1, 4, 0.2),
            SIMD3(0.2, 1, 4),
            SIMD3(2.2, 1.4, 0.9),
        ]
        for patch in patches {
            let rolled = PrintEncoding.hdrShoulderPreservingHue(patch)
            let peak = max(patch.x, max(patch.y, patch.z))
            if peak <= 0.9 {
                XCTAssertEqual(rolled, patch)
            } else {
                let scale = rolled.x / patch.x
                XCTAssertEqual(rolled.y, patch.y * scale, accuracy: 1e-6)
                XCTAssertEqual(rolled.z, patch.z * scale, accuracy: 1e-6)
                XCTAssertEqual(max(rolled.x, max(rolled.y, rolled.z)),
                               PrintEncoding.hdrShoulder(peak), accuracy: 1e-6)
            }
        }
    }

    func testEncodeRowsCarriesEachTransfer() {
        let width = 2
        func encoded(_ value: Float, _ transfer: PrintEncoding.Transfer) -> UInt16 {
            var strip = [Float](repeating: 0, count: width * 4)
            for index in stride(from: 0, to: strip.count, by: 4) {
                strip[index] = value
                strip[index + 1] = value
                strip[index + 2] = value
            }
            var destination = [UInt16](repeating: 0, count: width * 4)
            strip.withUnsafeBufferPointer { source in
                destination.withUnsafeMutableBufferPointer { out in
                    PrintEncoding.encodeRows(source, rows: 0..<1, width: width,
                                             into: out, transfer: transfer)
                }
            }
            return destination[0]
        }
        let knee: Float = 0.9
        let hlgKnee = encoded(knee, .hlg)
        XCTAssertGreaterThan(hlgKnee, 0)
        XCTAssertLessThan(hlgKnee, 65535)
        XCTAssertEqual(
            encoded(knee, .shoulderedSRGB),
            UInt16((PrintEncoding.encode(knee) * 65535).rounded()),
            "the SDR chain bent something the shoulder should have passed")
        XCTAssertEqual(encoded(1, .srgb), 65535)

        let sdrWhite = PrintEncoding.encode(PrintEncoding.shoulder(1))
        let hdrWhite = Float(encoded(1, .hlg)) / 65535
        XCTAssertEqual(encoded(1, .shoulderedSRGB),
                       UInt16((sdrWhite * 65535).rounded()))
        XCTAssertEqual(PrintEncoding.hdrShoulder(1), 0.9966, accuracy: 1e-3)
        XCTAssertLessThan(hdrWhite, PrintEncoding.hlgReferenceWhiteSignal,
                          "the shoulder should still bend diffuse white a little")
    }

    func testEncodeIgnoresAlpha() {
        let width = 4
        func encode(_ rgb: SIMD3<Float>, alpha: Float,
                    transfer: PrintEncoding.Transfer) -> [UInt16] {
            var strip = [Float](repeating: 0, count: width * 4)
            for index in stride(from: 0, to: strip.count, by: 4) {
                strip[index] = rgb.x
                strip[index + 1] = rgb.y
                strip[index + 2] = rgb.z
                strip[index + 3] = alpha
            }
            var destination = [UInt16](repeating: 0, count: width * 4)
            strip.withUnsafeBufferPointer { source in
                destination.withUnsafeMutableBufferPointer { out in
                    PrintEncoding.encodeRows(source, rows: 0..<1, width: width,
                                             into: out, transfer: transfer)
                }
            }
            return destination
        }
        let print = SIMD3<Float>(0.94, 0.61, 0.32)
        for transfer in [PrintEncoding.Transfer.hlg, .shoulderedSRGB] {
            XCTAssertEqual(encode(print, alpha: 2.4, transfer: transfer),
                           encode(print, alpha: 1, transfer: transfer),
                           "alpha must not change the encoded print")
            XCTAssertEqual(encode(print, alpha: 0, transfer: transfer),
                           encode(print, alpha: 1, transfer: transfer),
                           "alpha must not change the encoded print")
        }
    }

    func testNeutralHLGStillRoundTripsThroughColorManagement() throws {
        let patches: [SIMD3<Float>] = [
            SIMD3(repeating: 0.02), SIMD3(repeating: 0.18),
            SIMD3(repeating: 0.5), SIMD3(repeating: 0.9),
            SIMD3(repeating: 1), SIMD3(repeating: 2), SIMD3(repeating: 4),
            SIMD3(repeating: 20), SIMD3(repeating: 200),
        ]
        var developed: [Float] = []
        for patch in patches { developed += [patch.x, patch.y, patch.z, 1] }
        let pixels = UnsafeMutableBufferPointer<UInt16>.allocate(
            capacity: developed.count)
        pixels.initialize(repeating: 0)
        developed.withUnsafeBufferPointer {
            PrintEncoding.encodeRows($0, rows: 0..<1, width: patches.count,
                                     into: pixels, transfer: .hlg)
        }
        let hlgSpace = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.itur_2100_HLG))
        let image = try XCTUnwrap(PrintEncoding.makeImage(
            takingOwnershipOf: pixels, width: patches.count, height: 1,
            colorSpace: hlgSpace))
        let linearP3 = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        var decoded = [Float](repeating: 0, count: developed.count)
        decoded.withUnsafeMutableBytes { raw in
            CIContext(options: [
                .workingColorSpace: linearP3,
                .workingFormat: CIFormat.RGBAf,
            ]).render(
                CIImage(cgImage: image), toBitmap: raw.baseAddress!,
                rowBytes: patches.count * 16,
                bounds: CGRect(x: 0, y: 0, width: patches.count, height: 1),
                format: .RGBAf, colorSpace: linearP3)
        }
        for (pixel, patch) in patches.enumerated() {
            let expected = PrintEncoding.hdrShoulderPreservingHue(patch)
            for channel in 0..<3 {
                XCTAssertEqual(decoded[pixel * 4 + channel], expected[channel],
                               accuracy: 5e-3,
                               "HLG still changed \(patch) in channel \(channel)")
            }
        }
    }

    func testReferenceHLGEncoderPreservesCalibratedColour() throws {
        let patches: [SIMD3<Float>] = [
            SIMD3(4, 1, 0.2), SIMD3(1, 4, 0.2), SIMD3(0.2, 1, 4),
            SIMD3(2.2, 1.4, 0.9), SIMD3(repeating: 2),
        ]
        var signals: [Float] = []
        for patch in patches {
            let encoded = HLGTransfer.encodeRGB(
                r: patch.x, g: patch.y, b: patch.z)
            signals += [encoded.r, encoded.g, encoded.b, 1]
        }
        let data = signals.withUnsafeBufferPointer { Data(buffer: $0) }
        let hlg = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.itur_2100_HLG))
        let image = CIImage(
            bitmapData: data, bytesPerRow: patches.count * 16,
            size: CGSize(width: patches.count, height: 1),
            format: .RGBAf, colorSpace: hlg)
        let linearP3 = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        var decoded = [Float](repeating: 0, count: signals.count)
        decoded.withUnsafeMutableBytes { bytes in
            CIContext(options: [
                .workingColorSpace: linearP3,
                .workingFormat: CIFormat.RGBAf,
            ]).render(
                image, toBitmap: bytes.baseAddress!,
                rowBytes: patches.count * 16, bounds: image.extent,
                format: .RGBAf, colorSpace: linearP3)
        }
        for (pixel, patch) in patches.enumerated() {
            let expected = PrintEncoding.hdrShoulderPreservingHue(patch)
            let actual = SIMD3<Float>(decoded[pixel * 4],
                                      decoded[pixel * 4 + 1],
                                      decoded[pixel * 4 + 2])
            XCTAssertEqual(actual.x / actual.y, expected.x / expected.y,
                           accuracy: 0.04,
                           "reference HLG encoder shifted red/green in \(patch)")
            XCTAssertEqual(actual.y / actual.z, expected.y / expected.z,
                           accuracy: 0.04,
                           "reference HLG encoder shifted green/blue in \(patch)")
        }
    }

}
#endif
