import Foundation
#if canImport(CoreImage)
import CoreImage
#endif
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

    /// The light's gains at a unit point of the frame, from the top left: bilinear between cell
    /// centres, the edges holding their outermost cell, as `flatten` stretches the map.
    public func gain(x: Float, y: Float) -> SIMD3<Float> {
        guard width > 0, height > 0, gains.count == width * height * 3 else { return .one }
        let fx = min(max(x * Float(width) - 0.5, 0), Float(width - 1))
        let fy = min(max(y * Float(height) - 0.5, 0), Float(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        func cell(_ cx: Int, _ cy: Int) -> SIMD3<Float> {
            let i = (cy * width + cx) * 3
            return SIMD3(gains[i], gains[i + 1], gains[i + 2])
        }
        let top = cell(x0, y0) * (1 - tx) + cell(x1, y0) * tx
        let bottom = cell(x0, y1) * (1 - tx) + cell(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }

    /// Measures a photograph of the bare light source held as linear sRGB RGBA rows, for hosts
    /// without Core Image: each cell's mean light, softened by its neighbours as the Core Image
    /// measurement's blur softens it.
    public init(linearSRGB rgba: [Float], width: Int, height: Int) throws {
        guard width >= 8, height >= 8, rgba.count >= width * height * 4 else {
            throw Failure.unreadable
        }
        let scale = Float(Self.cells) / Float(max(width, height))
        let w = max(2, Int((Float(width) * scale).rounded()))
        let h = max(2, Int((Float(height) * scale).rounded()))
        var sums = [Double](repeating: 0, count: w * h * 3)
        var counts = [Double](repeating: 0, count: w * h * 3)
        for y in 0..<height {
            let cy = min(h - 1, y * h / height)
            for x in 0..<width {
                let cx = min(w - 1, x * w / width), cell = (cy * w + cx) * 3
                for c in 0..<3 {
                    let value = rgba[(y * width + x) * 4 + c]
                    guard value.isFinite, value > 0 else { continue }
                    sums[cell + c] += Double(value)
                    counts[cell + c] += 1
                }
            }
        }
        var means = [Float](repeating: 0, count: w * h * 3)
        for i in means.indices where counts[i] > 0 { means[i] = Float(sums[i] / counts[i]) }
        // A 1-2-1 pass each way: a light source varies slowly, and the cells' edges must not show.
        var soft = means
        for cy in 0..<h { for cx in 0..<w { for c in 0..<3 {
            var total: Float = 0, weight: Float = 0
            for dy in -1...1 { for dx in -1...1 {
                let x = cx + dx, y = cy + dy
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                let value = means[(y * w + x) * 3 + c]
                guard value > 0 else { continue }
                let k = Float((dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1))
                total += value * k
                weight += k
            } }
            soft[(cy * w + cx) * 3 + c] = weight > 0 ? total / weight : 0
        } } }
        var gains = [Float](repeating: 1, count: w * h * 3)
        for c in 0..<3 {
            let lit = stride(from: c, to: soft.count, by: 3).map { soft[$0] }
                .filter { $0.isFinite && $0 > 0 }.sorted()
            guard !lit.isEmpty else { throw Failure.unreadable }
            let median = lit[lit.count / 2]
            for i in 0..<(w * h) {
                let value = soft[i * 3 + c]
                gains[i * 3 + c] = value.isFinite && value > 0 ? min(max(value / median, 0.05), 20) : 1
            }
        }
        self.init(width: w, height: h, gains: gains)
    }

    public enum Failure: LocalizedError {
        case unreadable
        public var errorDescription: String? { "The light source photograph could not be read." }
    }
}

#if canImport(CoreImage)
extension NegativeLightFrame {
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
