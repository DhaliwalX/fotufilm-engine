import XCTest
@testable import FotufilmCore

final class SceneLinearInputTests: XCTestCase {
    private struct OffsetConverter: FilmInputConverter {
        let offset: Float

        func convert(
            _ source: UnsafeBufferPointer<Float>,
            from sourceOffset: Int,
            count: Int,
            into destination: UnsafeMutableBufferPointer<Float>
        ) {
            precondition(count.isMultiple(of: 4))
            for pixel in 0..<(count / 4) {
                let sourceBase = sourceOffset + pixel * 4
                let destinationBase = pixel * 4
                for channel in 0..<3 {
                    destination[destinationBase + channel] =
                        source[sourceBase + channel] + offset
                }
                destination[destinationBase + 3] = source[sourceBase + 3]
            }
        }
    }

    func testAutomaticSourceInterpretationPreservesDecodedRange() {
        XCTAssertEqual(
            FilmSourceInterpretation.automatic.resolvedConversion(
                isRaw: false),
            .preserveHDR)
    }

    func testSourceInterpretationOverridesResolveAtEngineBoundary() {
        XCTAssertEqual(
            FilmSourceInterpretation.fullRange.resolvedConversion(
                isRaw: false),
            .preserveHDR)
        XCTAssertEqual(
            FilmSourceInterpretation.standardRange.resolvedConversion(
                isRaw: false),
            .platformToneMap)
    }

    func testRawAlwaysUsesSceneLinearInterpretation() {
        for interpretation in FilmSourceInterpretation.allCases {
            XCTAssertEqual(
                interpretation.resolvedConversion(
                    isRaw: true),
                .preserveHDR)
        }
    }

    func testClientSuppliedConverterRunsAtEngineInputBoundary() {
        let source: [Float] = [0.1, 0.2, 0.3, 1]
        var destination = [Float](repeating: 0, count: source.count)
        let converter = AnyFilmInputConverter(OffsetConverter(offset: 0.25))

        source.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destination in
                SceneLinearInput.prepare(
                    source, from: 0, count: source.count,
                    into: destination, using: converter)
            }
        }

        XCTAssertEqual(destination[0], 0.35, accuracy: 0.0002)
        XCTAssertEqual(destination[1], 0.45, accuracy: 0.0002)
        XCTAssertEqual(destination[2], 0.55, accuracy: 0.0002)
        XCTAssertEqual(destination[3], 1, accuracy: 0.0002)
    }

    func testWideningPreservesAboveWhiteExposure() {
        let source: [Float] = [0.5, 1, 2, 4, 8]
        var destination = [Float](repeating: 0, count: source.count)

        source.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destination in
                SceneLinearInput.widen(source, from: 0, count: source.count,
                                       into: destination)
            }
        }

        XCTAssertEqual(destination, source)
    }

    func testFullPrecisionSceneKeepsEverySixteenBitCodeDistinct() {
        let source = (0...UInt16.max).map { Float($0) / Float(UInt16.max) }
        var destination = [Float](repeating: 0, count: source.count)
        source.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destination in
                SceneLinearInput.widen(source, from: 0, count: source.count,
                                       into: destination)
            }
        }
        XCTAssertEqual(Set(destination.map(\.bitPattern)).count, 65_536)
    }

    func testSDRToneMapRunsBeforeFilmAndBoundsHDRLight() {
        let source: [Float] = [
            0.18, 0.09, 0.045, 1,
            1, 0.5, 0.25, 0.8,
            2, 1, 0.5, 1,
            4, 2, 1, 1,
        ]
        var destination = [Float](repeating: 0, count: source.count)

        source.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destination in
                SceneLinearInput.prepare(
                    source, from: 0, count: source.count,
                    into: destination, using: FilmInputConversion.engineLinearToneMap)
            }
        }

        XCTAssertEqual(destination[0], 0.18, accuracy: 0.0002)
        XCTAssertEqual(destination[1], 0.09, accuracy: 0.0002)
        XCTAssertEqual(destination[2], 0.045, accuracy: 0.0002)
        XCTAssertEqual(destination[7], 0.8, accuracy: 0.0002,
                       "tone mapping must not repurpose alpha")
        let peaks = stride(from: 4, to: destination.count, by: 4)
            .map { destination[$0] }
        XCTAssertLessThan(peaks[0], peaks[1])
        XCTAssertLessThan(peaks[1], peaks[2])
        XCTAssertLessThan(peaks[2], 1)
        for base in stride(from: 4, to: destination.count, by: 4) {
            XCTAssertEqual(destination[base] / destination[base + 1], 2,
                           accuracy: 0.001)
            XCTAssertEqual(destination[base + 1] / destination[base + 2], 2,
                           accuracy: 0.001)
        }
    }

}
