#if canImport(Vision)
import Foundation
import CoreGraphics
import CoreVideo
import Vision

/// Subjects as the Mac app finds them: Vision's foreground-instance model over the framed
/// picture.
struct VisionSubjectDetector: HostSubjectDetector {
    /// Runs the model over 8-bit Display P3 pixels.
    func detect(_ pixels: [UInt8], width: Int, height: Int) -> HostSubject? {
        guard #available(macOS 14.0, iOS 17.0, *) else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty else { return nil }
        let mask = observation.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let (labelWidth, labelHeight) = (CVPixelBufferGetWidth(mask), CVPixelBufferGetHeight(mask))
        let stride = CVPixelBufferGetBytesPerRow(mask)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var labels = [UInt8](repeating: 0, count: labelWidth * labelHeight)
        for y in 0..<labelHeight {
            for x in 0..<labelWidth { labels[y * labelWidth + x] = bytes[y * stride + x] }
        }
        return HostSubject(labels: labels, width: labelWidth, height: labelHeight)
    }
}
#endif
