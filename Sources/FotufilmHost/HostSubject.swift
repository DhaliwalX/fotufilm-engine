import Foundation

/// The subjects standing in front of a photograph, as a `HostSubjectDetector` labels them for a
/// subject selection (the Mac app's `SubjectMask`).
struct HostSubject {
    /// Instance numbers at the model's resolution, 0 for background, origin top left.
    let labels: [UInt8]
    let width: Int
    let height: Int

    /// The subject under a unit point, or every subject when the point is on the background or
    /// there is none, as a 0…1 weight per pixel of a `width` x `height` picture, feathered by
    /// `softness` as the Mac app feathers its fitted mask.
    func weights(at point: [Double]?, width: Int, height: Int, softness: Double) -> [Float] {
        var chosen: UInt8?
        if let point, point.count == 2 {
            let x = min(max(Int(point[0] * Double(self.width)), 0), self.width - 1)
            let y = min(max(Int(point[1] * Double(self.height)), 0), self.height - 1)
            let label = labels[y * self.width + x]
            chosen = label == 0 ? nil : label
        }
        let mask = labels.map { label -> Float in
            label == 0 ? 0 : (chosen == nil || label == chosen ? 1 : 0)
        }
        var weights = [Float](repeating: 0, count: width * height)
        mask.withUnsafeBufferPointer { mask in
            weights.withUnsafeMutableBufferPointer { out in
                let out = out
                SceneGeometry.concurrent(height) { y in
                    let sy = min(max((Double(y) + 0.5) * Double(self.height) / Double(height) - 0.5, 0),
                                 Double(self.height - 1))
                    for x in 0..<width {
                        let sx = min(max((Double(x) + 0.5) * Double(self.width) / Double(width) - 0.5, 0),
                                     Double(self.width - 1))
                        let ix = Int(sx), iy = Int(sy)
                        let fx = Float(sx - Double(ix)), fy = Float(sy - Double(iy))
                        let nx = min(ix + 1, self.width - 1), ny = min(iy + 1, self.height - 1)
                        let a = mask[iy * self.width + ix], b = mask[iy * self.width + nx]
                        let c = mask[ny * self.width + ix], d = mask[ny * self.width + nx]
                        out[y * width + x] = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
                    }
                }
            }
        }
        let radius = Int((softness * Double(max(width, height)) * 0.006).rounded())
        return radius > 0 ? Self.blurred(weights, width: width, height: height, radius: radius) : weights
    }

    /// Two passes of a separable box, close enough to the Mac app's Gaussian for a feather.
    private static func blurred(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        func pass(_ input: [Float], horizontal: Bool) -> [Float] {
            var output = input
            let lines = horizontal ? height : width, length = horizontal ? width : height
            input.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { out in
                    let out = out
                    SceneGeometry.concurrent(lines) { line in
                        func at(_ i: Int) -> Int { horizontal ? line * width + i : i * width + line }
                        var sum: Float = 0
                        for i in -radius...radius { sum += input[at(min(max(i, 0), length - 1))] }
                        for i in 0..<length {
                            out[at(i)] = sum / Float(2 * radius + 1)
                            sum += input[at(min(i + radius + 1, length - 1))]
                            sum -= input[at(max(i - radius, 0))]
                        }
                    }
                }
            }
            return output
        }
        var result = values
        for _ in 0..<2 {
            result = pass(pass(result, horizontal: true), horizontal: false)
        }
        return result
    }
}
