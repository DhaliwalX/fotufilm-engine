import Foundation
#if canImport(CoreImage)
import CoreImage
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The unevenness of a light source, measured from a photograph of it with no film in the way:
/// a coarse map of how much brighter or darker each part of the frame is than the middle of the
/// light. Dividing a scan made on the same light by it evens the light out.
public struct NegativeLightFrame: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Linear RGB per cell, row by row from the top, 1 at the light's median.
    public let gains: [Float]

    /// Cells along the long edge. A light source varies slowly; film grain and dust must not
    /// survive into the map.
    static let cells = 32

    public init(width: Int, height: Int, gains: [Float]) {
        self.width = width
        self.height = height
        self.gains = gains
    }

    /// Measures a photograph of the bare light source.
    public init(photo: CIImage) throws {
        let extent = photo.extent
        guard extent.width >= 8, extent.height >= 8 else { throw NegativeScanImport.Failure.unreadable }
        let blur = max(extent.width, extent.height) / CGFloat(Self.cells) / 2
        let smooth = photo.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(blur)).cropped(to: extent)
        let scale = CGFloat(Self.cells) / max(extent.width, extent.height)
        let small = smooth.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                             y: -extent.minY)
            .scaledBy(x: scale, y: scale))
        let w = max(2, Int((extent.width * scale).rounded()))
        let h = max(2, Int((extent.height * scale).rounded()))
        let samples = try NegativeScanImport.samples(
            small.cropped(to: CGRect(x: 0, y: 0, width: w, height: h)))
        var gains = [Float](repeating: 1, count: w * h * 3)
        for c in 0..<3 {
            let lit = samples.planes[c].filter { $0.isFinite && $0 > 0 }.sorted()
            guard !lit.isEmpty else { throw NegativeScanImport.Failure.unreadable }
            let median = lit[lit.count / 2]
            for i in 0..<(w * h) {
                let value = samples.planes[c][i]
                gains[i * 3 + c] = value.isFinite && value > 0 ? min(max(value / median, 0.05), 20) : 1
            }
        }
        self.init(width: w, height: h, gains: gains)
    }

    /// The scan with this light divided out.
    public func flatten(_ scan: CIImage) -> CIImage {
        guard width > 0, height > 0, gains.count == width * height * 3 else { return scan }
        var reciprocal = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            for c in 0..<3 { reciprocal[i * 4 + c] = 1 / max(gains[i * 3 + c], 0.05) }
        }
        let data = reciprocal.withUnsafeBufferPointer { Data(buffer: $0) }
        let map = CIImage(bitmapData: data, bytesPerRow: width * 16,
                          size: CGSize(width: width, height: height), format: .RGBAf,
                          colorSpace: NegativeScanImport.linearSpace)
        let extent = scan.extent
        // Cell centres land on the scan's matching points; the edges hold their outermost cell.
        let stretched = map.samplingLinear().clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)
                .scaledBy(x: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .cropped(to: extent)
        return stretched.applyingFilter("CIMultiplyCompositing",
                                        parameters: [kCIInputBackgroundImageKey: scan])
            .cropped(to: extent)
    }
}
#endif
