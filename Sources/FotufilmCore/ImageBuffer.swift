import Foundation

/// Planar three-channel float image.
public struct ImageBuffer {
    public let width: Int
    public let height: Int
    public var planes: [[Float]]

    public var pixelCount: Int { width * height }

    public init(width: Int, height: Int, fill: Float = 0) {
        self.width = width
        self.height = height
        self.planes = Array(repeating: [Float](repeating: fill, count: width * height), count: 3)
    }

    public init(width: Int, height: Int, planes: [[Float]]) {
        precondition(planes.count == 3 && planes.allSatisfy { $0.count == width * height })
        self.width = width
        self.height = height
        self.planes = planes
    }

    /// Build from interleaved RGB floats (row-major, 3 floats per pixel).
    public init(width: Int, height: Int, interleavedRGB: [Float]) {
        precondition(interleavedRGB.count == width * height * 3)
        self.width = width
        self.height = height
        var r = [Float](repeating: 0, count: width * height)
        var g = r
        var b = r
        for i in 0..<(width * height) {
            r[i] = interleavedRGB[i * 3]
            g[i] = interleavedRGB[i * 3 + 1]
            b[i] = interleavedRGB[i * 3 + 2]
        }
        self.planes = [r, g, b]
    }

    public func interleavedRGB() -> [Float] {
        var out = [Float](repeating: 0, count: pixelCount * 3)
        for i in 0..<pixelCount {
            out[i * 3] = planes[0][i]
            out[i * 3 + 1] = planes[1][i]
            out[i * 3 + 2] = planes[2][i]
        }
        return out
    }

    public subscript(x: Int, y: Int) -> (Float, Float, Float) {
        let i = y * width + x
        return (planes[0][i], planes[1][i], planes[2][i])
    }
}

public enum Blur {
    /// Three iterated box blurs approximating a Gaussian of standard deviation `sigma` (in pixels).
    public static func approximateGaussian(_ plane: inout [Float], width: Int, height: Int, sigma: Float) {
        guard sigma > 0.3 else { return }
        let w = sqrt(12 * sigma * sigma / 3 + 1)
        let radius = max(1, Int((w - 1) / 2))
        if let result = HalideBackend.approximateGaussian(
            plane, width: width, height: height, radius: radius
        ) {
            plane = result
            return
        }
        var temp = plane
        for _ in 0..<3 {
            boxBlurHorizontal(src: plane, dst: &temp, width: width, height: height, radius: radius)
            boxBlurVertical(src: temp, dst: &plane, width: width, height: height, radius: radius)
        }
    }

    /// Exact separable Gaussian for small sigmas (grain clumps, coupler
    /// diffusion) where kernel accuracy matters more than speed.
    public static func gaussian(_ plane: inout [Float], width: Int, height: Int, sigma: Float) {
        guard sigma > 0.15 else { return }
        let radius = max(1, Int(ceil(3 * sigma)))
        if let result = HalideBackend.gaussian(
            plane, width: width, height: height, sigma: sigma, radius: radius
        ) {
            plane = result
            return
        }
        var kernel = [Float](repeating: 0, count: 2 * radius + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let v = exp(-Float(i * i) / (2 * sigma * sigma))
            kernel[i + radius] = v
            sum += v
        }
        for i in kernel.indices { kernel[i] /= sum }

        var temp = [Float](repeating: 0, count: plane.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var acc: Float = 0, weight: Float = 0
                for k in -radius...radius {
                    let xs = x + k
                    guard xs >= 0, xs < width else { continue }
                    let w = kernel[k + radius]
                    acc += plane[row + xs] * w
                    weight += w
                }
                temp[row + x] = acc / max(weight, 1e-12)
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0, weight: Float = 0
                for k in -radius...radius {
                    let ys = y + k
                    guard ys >= 0, ys < height else { continue }
                    let w = kernel[k + radius]
                    acc += temp[ys * width + x] * w
                    weight += w
                }
                plane[y * width + x] = acc / max(weight, 1e-12)
            }
        }
    }

    private static func boxBlurHorizontal(src: [Float], dst: inout [Float], width: Int, height: Int, radius: Int) {
        for y in 0..<height {
            let row = y * width
            var acc: Float = 0
            for x in 0...min(radius, width - 1) {
                acc += src[row + x]
            }
            for x in 0..<width {
                let lower = max(0, x - radius)
                let upper = min(width - 1, x + radius)
                dst[row + x] = acc / Float(upper - lower + 1)
                let leaving = x - radius
                let entering = x + radius + 1
                if leaving >= 0 { acc -= src[row + leaving] }
                if entering < width { acc += src[row + entering] }
            }
        }
    }

    private static func boxBlurVertical(src: [Float], dst: inout [Float], width: Int, height: Int, radius: Int) {
        for x in 0..<width {
            var acc: Float = 0
            for y in 0...min(radius, height - 1) {
                acc += src[y * width + x]
            }
            for y in 0..<height {
                let lower = max(0, y - radius)
                let upper = min(height - 1, y + radius)
                dst[y * width + x] = acc / Float(upper - lower + 1)
                let leaving = y - radius
                let entering = y + radius + 1
                if leaving >= 0 { acc -= src[leaving * width + x] }
                if entering < height { acc += src[entering * width + x] }
            }
        }
    }
}
