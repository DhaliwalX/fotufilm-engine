import CoreVideo
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Writes the finished float print into Apple's recommended high-bit-depth RGB input for ProRes.
/// AVAssetWriter performs neither scaling nor color matching for this format, so both operations
/// are complete before this boundary and the pixel-buffer attachments describe the encoded signal.
enum ProResRecording {
    static func write(
        print source: UnsafePointer<Float>, width: Int, height: Int,
        hdr: Bool,
        sdrShoulderKnee: Float = FilmSDRDelivery.standardShoulderKnee,
        into destination: CVPixelBuffer
    ) -> Bool {
        guard width > 0, height > 0,
              CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_64ARGB,
              CVPixelBufferGetWidth(destination) == width,
              CVPixelBufferGetHeight(destination) == height
        else { return false }

        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let base = CVPixelBufferGetBaseAddress(destination) else { return false }
        let destinationRowBytes = CVPixelBufferGetBytesPerRow(destination)
        let developed = UnsafeBufferPointer(start: source,
                                            count: width * height * 4)
        let converter: AnyFilmOutputConverter = hdr
            ? AnyFilmOutputConverter(FilmOutputConversion.rec2020HLG)
            : AnyFilmOutputConverter(FilmDisplayP3SDRConversion(
                shoulderKnee: sdrShoulderKnee))
        let workers = height >= 128 ? min(8, height) : 1
        let band = (height + workers - 1) / workers

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let first = worker * band
            let last = min(height, first + band)
            guard first < last else { return }
            let encoded = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * 4)
            defer { encoded.deallocate() }
            for row in first..<last {
                converter.convert(
                    developed, from: row * width * 4, count: width * 4,
                    into: encoded)
                let output = (base + row * destinationRowBytes)
                    .assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    output[x * 4] = UInt16.max.bigEndian
                    output[x * 4 + 1] = code(encoded[x * 4]).bigEndian
                    output[x * 4 + 2] = code(encoded[x * 4 + 1]).bigEndian
                    output[x * 4 + 3] = code(encoded[x * 4 + 2]).bigEndian
                }
            }
        }

        attachColorMetadata(to: destination, hdr: hdr)
        return true
    }

    private static func code(_ value: Float) -> UInt16 {
        UInt16((min(max(value, 0), 1) * Float(UInt16.max)).rounded())
    }

    private static func attachColorMetadata(to buffer: CVPixelBuffer, hdr: Bool) {
        let primaries = hdr ? kCVImageBufferColorPrimaries_ITU_R_2020
                            : kCVImageBufferColorPrimaries_P3_D65
        let transfer = hdr ? kCVImageBufferTransferFunction_ITU_R_2100_HLG
                           : kCVImageBufferTransferFunction_sRGB
        let matrix = hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020
                         : kCVImageBufferYCbCrMatrix_ITU_R_709_2
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              matrix, .shouldPropagate)
    }
}
