import XCTest
@testable import FotufilmCore

final class FilmOutputConversionTests: XCTestCase {
    private struct ChannelSwapConverter: FilmOutputConverter {
        var colorSpace: FilmOutputColorSpace { .linearSRGB }

        func convert(
            _ developed: UnsafeBufferPointer<Float>,
            from sourceOffset: Int,
            count: Int,
            into destination: UnsafeMutableBufferPointer<Float>
        ) {
            precondition(count.isMultiple(of: 4))
            for pixel in 0..<(count / 4) {
                let source = sourceOffset + pixel * 4
                let output = pixel * 4
                destination[output] = developed[source + 2]
                destination[output + 1] = developed[source + 1]
                destination[output + 2] = developed[source]
                destination[output + 3] = developed[source + 3]
            }
        }
    }

    private func convert(
        _ source: [Float], using converter: some FilmOutputConverter
    ) -> [Float] {
        var destination = [Float](repeating: 0, count: source.count)
        source.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destination in
                DevelopedPrintOutput.convert(
                    source, from: 0, count: source.count,
                    into: destination, using: converter)
            }
        }
        return destination
    }

    func testBuiltInDeliveriesDeclareTheirContainerColorSpace() {
        let expected: [(FilmOutputConversion, FilmOutputColorSpace)] = [
            (.linearDisplayP3, .linearDisplayP3),
            (.displayP3, .displayP3),
            (.displayP3SDR, .displayP3),
            (.linearSRGB, .linearSRGB),
            (.sRGBSDR, .sRGB),
            (.rec709SDR, .rec709),
            (.linearRec2020, .linearRec2020),
            (.rec2020HLG, .rec2020HLG),
        ]

        XCTAssertEqual(expected.map(\.0), FilmOutputConversion.allCases)
        for (conversion, colorSpace) in expected {
            XCTAssertEqual(conversion.colorSpace, colorSpace)
        }
    }

    func testClientSuppliedOutputConverterRunsAtEngineBoundary() {
        let converter = AnyFilmOutputConverter(ChannelSwapConverter())
        let output = convert([0.1, 0.2, 0.3, 0.8], using: converter)

        XCTAssertEqual(converter.colorSpace, .linearSRGB)
        XCTAssertEqual(output[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(output[1], 0.2, accuracy: 1e-6)
        XCTAssertEqual(output[2], 0.1, accuracy: 1e-6)
        XCTAssertEqual(output[3], 0.8, accuracy: 1e-6)
    }

    func testClientCanIdentifyCustomOutputColorSpace() {
        let custom = FilmOutputColorSpace(rawValue: "com.example.camera-log")
        let converter = AnyFilmOutputConverter(
            colorSpace: custom,
            conversion: { source, offset, count, destination in
                for index in 0..<count {
                    destination[index] = source[offset + index]
                }
            })

        XCTAssertEqual(converter.colorSpace, custom)
        XCTAssertFalse(FilmOutputColorSpace.builtIn.contains(custom))
    }

    func testLinearDisplayP3PreservesHDRAndRelightAlpha() {
        let source: [Float] = [0.5, 1, 4, 2]
        XCTAssertEqual(convert(source, using: FilmOutputConversion.linearDisplayP3),
                       source)
    }

    func testSRGBOutputConvertsPrimariesAndBoundsCodeValues() {
        let output = convert([1, 0, 0, 1],
                             using: FilmOutputConversion.sRGBSDR)
        XCTAssertEqual(output[3], 1)
        for component in output.prefix(3) {
            XCTAssertGreaterThanOrEqual(component, 0)
            XCTAssertLessThanOrEqual(component, 1)
        }
        XCTAssertNotEqual(output[0], output[1],
                          "gamut conversion must not turn red into neutral")
    }

    func testRec709SDRRelightsAndUsesTheVideoDeliveryCurve() {
        let source: [Float] = [0.18, 0.18, 0.18, 2]
        let output = convert(source, using: FilmOutputConversion.rec709SDR)
        let expected: Float = 1.099 * pow(0.36, 0.45) - 0.099
        for channel in 0..<3 {
            XCTAssertEqual(output[channel], expected, accuracy: 2e-5)
        }
        XCTAssertEqual(output[3], 1)
    }

    func testRec2020HLGPlacesDiffuseWhiteAtReferenceWhite() {
        let output = convert([1, 1, 1, 1],
                             using: FilmOutputConversion.rec2020HLG)
        for channel in 0..<3 {
            XCTAssertEqual(output[channel], 0.74960, accuracy: 2e-4)
            XCTAssertLessThan(output[channel], 0.75)
            XCTAssertGreaterThan(output[channel], 0.749)
        }
        XCTAssertEqual(output[3], 1)
    }

    func testWhiteSurvivesTheDeliveryMatrix() {
        let white = convert([1, 1, 1, 1], using: FilmOutputConversion.linearRec2020)
        for channel in 0..<3 {
            XCTAssertEqual(white[channel], 1, accuracy: 1e-6,
                           "channel \(channel) of white did not survive P3 to Rec.2020")
        }
    }

    func testLinearRec2020PreservesNeutralAndChangesWidePrimaries() {
        let neutral = convert([0.18, 0.18, 0.18, 1],
                              using: FilmOutputConversion.linearRec2020)
        for component in neutral.prefix(3) {
            XCTAssertEqual(component, 0.18, accuracy: 5e-5)
        }
        let red = convert([1, 0, 0, 1],
                          using: FilmOutputConversion.linearRec2020)
        // ColorScience's digits, which are the matrix the whole engine now shares. The values
        // this replaces were a six-place hand copy that disagreed with both other spellings.
        XCTAssertEqual(red[0], 0.753833, accuracy: 1e-6)
        XCTAssertEqual(red[1], 0.045744, accuracy: 1e-6)
        XCTAssertEqual(red[2], -0.001210, accuracy: 1e-6)
    }
}
