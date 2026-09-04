#if canImport(CoreImage)
import XCTest
import CoreImage
import CoreGraphics
@testable import FotufilmImaging

final class ProcessedHDRExposureTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])

    private func image(_ pixels: [Float], width: Int, height: Int) -> CIImage {
        CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) },
                bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                format: .RGBAf, colorSpace: linearSpace)
    }

    func testReferencePlacementPreservesHDRRatiosAndAlphaAtEveryRenderSize() throws {
        let width = 512, height = 32
        var sdr = [Float](repeating: 1, count: width * height * 4)
        var hdr = sdr
        for pixel in 0..<(width * height) {
            let x = pixel % width
            let reference: Float = x < 384 ? 0.03 + Float(x) / 384 * 0.5 : 0.95
            let lift: Float = x < 384 ? 2 : 8
            for channel in 0..<3 {
                sdr[pixel * 4 + channel] = reference
                hdr[pixel * 4 + channel] = reference * lift
            }
        }
        let gain = ProcessedHDRExposure.referenceGain(
            expandedHDR: image(hdr, width: width, height: height),
            sdrReference: image(sdr, width: width, height: height), context: context)
        XCTAssertEqual(gain, 0.5, accuracy: 1e-4)

        // The scene being rendered can be a crop or a preview smaller than the measurement.
        // The original pair sets one gain for all of them, including associated-alpha samples.
        let sample: [Float] = [4, 2, 1, 0.5]
        for side in [16, 192, 512] {
            let pixels = Array(repeating: sample, count: side * side).flatMap { $0 }
            let normalized = ProcessedHDRExposure.applying(
                gain, to: image(pixels, width: side, height: side))
            let result = try XCTUnwrap(ImageResampling.rasterizeLinearFloat(
                normalized, width: side, height: side,
                context: context, colorSpace: linearSpace))
            for channel in 0..<4 {
                XCTAssertEqual(result[channel], channel == 3 ? sample[channel] : sample[channel] * gain,
                               accuracy: 1e-4)
            }
            XCTAssertGreaterThan(result[0], 1, "HDR highlights must survive placement")
        }
    }

    func testReferenceGainAgreesAcrossSourceResolutionsAndContexts() {
        let softwareContext = CIContext(options: [
            .useSoftwareRenderer: true, .cacheIntermediates: false,
        ])
        var gains: [Float] = []
        for width in [192, 256, 768] {
            let height = width / 8
            var sdr = [Float](repeating: 1, count: width * height * 4)
            var hdr = sdr
            for pixel in 0..<(width * height) {
                let position = (Float(pixel % width) + 0.5) / Float(width)
                // Cross both reference-window boundaries. A varying midtone lift makes
                // changes in the selected samples observable instead of always yielding 0.5.
                let reference = 0.002 + position * 0.996
                let lift: Float = reference <= 0.7 ? 1.8 + 0.2 * position : 8
                for channel in 0..<3 {
                    sdr[pixel * 4 + channel] = reference
                    hdr[pixel * 4 + channel] = reference * lift
                }
            }
            for renderingContext in [context, softwareContext] {
                let gain = ProcessedHDRExposure.referenceGain(
                    expandedHDR: image(hdr, width: width, height: height),
                    sdrReference: image(sdr, width: width, height: height),
                    context: renderingContext)
                XCTAssertGreaterThan(gain, 0.5)
                XCTAssertLessThan(gain, 0.57)
                if let reference = gains.first {
                    XCTAssertEqual(gain, reference, accuracy: 1e-3,
                                   "source width \(width): gains \(gains), current \(gain)")
                }
                gains.append(gain)
            }
        }
    }

    func testPlacementEligibilityRequiresProcessedSourceWithDeclaredHeadroom() {
        for isRaw in [false, true] {
            XCTAssertFalse(ProcessedHDRExposure.isEligible(
                isRaw: isRaw, declaredHeadroom: nil))
            XCTAssertEqual(ProcessedHDRExposure.isEligible(
                isRaw: isRaw, declaredHeadroom: 4), !isRaw)
        }
    }

    func testUnusableOrUnliftedReferenceLeavesExposureUnchanged() {
        let sample: [Float] = [0.18, 0.18, 0.18, 1]
        let pixels = Array(repeating: sample, count: 64).flatMap { $0 }
        let original = image(pixels, width: 8, height: 8)
        XCTAssertEqual(ProcessedHDRExposure.referenceGain(
            expandedHDR: original, sdrReference: original, context: context), 1)
        let differentGeometry = image(pixels, width: 16, height: 4)
        XCTAssertEqual(ProcessedHDRExposure.referenceGain(
            expandedHDR: original, sdrReference: differentGeometry, context: context), 1)
        XCTAssertTrue(ProcessedHDRExposure.applying(1, to: original) === original)
    }
}
#endif
