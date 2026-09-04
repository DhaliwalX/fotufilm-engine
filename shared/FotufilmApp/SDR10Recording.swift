import CoreVideo
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Writes the finished Display-P3 print into Apple's 10-bit bi-planar video-range container.
enum SDR10Recording {
    static func write(
        print source: UnsafePointer<Float>, width: Int, height: Int,
        shoulderKnee: Float = FilmSDRDelivery.standardShoulderKnee,
        into destination: CVPixelBuffer
    ) -> Bool {
        guard width > 0, height > 0, width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              CVPixelBufferGetPixelFormatType(destination)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(destination) == 2,
              CVPixelBufferGetWidthOfPlane(destination, 0) == width,
              CVPixelBufferGetHeightOfPlane(destination, 0) == height
        else { return false }

        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(destination, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(destination, 1)
        else { return false }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0) / 2
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1) / 2
        let luma = lumaBase.assumingMemoryBound(to: UInt16.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt16.self)
        let developed = UnsafeBufferPointer(start: source,
                                            count: width * height * 4)
        let rows = height / 2
        let workers = rows >= 128 ? min(8, rows) : 1
        let band = (rows + workers - 1) / workers
        let converter = FilmDisplayP3SDRConversion(
            shoulderKnee: shoulderKnee)

        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let first = worker * band
            let last = min(rows, first + band)
            guard first < last else { return }
            let top = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * 4)
            let bottom = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * 4)
            defer {
                top.deallocate()
                bottom.deallocate()
            }
            for chromaY in first..<last {
                let y = chromaY * 2
                converter.convert(
                    developed, from: y * width * 4, count: width * 4,
                    into: top)
                converter.convert(
                    developed, from: (y + 1) * width * 4, count: width * 4,
                    into: bottom)
                let topLuma = luma.advanced(by: y * lumaStride)
                let bottomLuma = topLuma.advanced(by: lumaStride)
                let chromaRow = chroma.advanced(by: chromaY * chromaStride)
                for x in stride(from: 0, to: width, by: 2) {
                    let encoded = SDRVideoTransfer.encode420(
                        topLeft: rgb(top, x), topRight: rgb(top, x + 1),
                        bottomLeft: rgb(bottom, x),
                        bottomRight: rgb(bottom, x + 1))
                    topLuma[x] = code(encoded.luma.x * 876 + 64)
                    topLuma[x + 1] = code(encoded.luma.y * 876 + 64)
                    bottomLuma[x] = code(encoded.luma.z * 876 + 64)
                    bottomLuma[x + 1] = code(encoded.luma.w * 876 + 64)
                    chromaRow[x] = code(encoded.u * 896 + 512)
                    chromaRow[x + 1] = code(encoded.v * 896 + 512)
                }
            }
        }

        CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_P3_D65,
                              .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_sRGB,
                              .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Center,
                              .shouldPropagate)
        return true
    }

    private static func rgb(
        _ row: UnsafeMutableBufferPointer<Float>, _ x: Int
    ) -> SIMD3<Float> {
        SIMD3(row[x * 4], row[x * 4 + 1], row[x * 4 + 2])
    }

    private static func code(_ value: Float) -> UInt16 {
        UInt16(min(max(value.rounded(), 0), 1023)) << 6
    }
}
