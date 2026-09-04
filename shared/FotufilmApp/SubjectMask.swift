import CoreImage
import CoreVideo
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// Subject detection for the selective mask: the salient things standing in front of a photograph,
/// found by Vision's foreground-instance model — the same lift the Photos app makes when a long
/// press pulls a subject out of its background.
enum SubjectMask {

    /// A finished detection, held so that touches can be answered from it
    /// without going back to the model.
    struct Reading {
        fileprivate let observation: VNInstanceMaskObservation
        /// Kept only so the benchmark can price Vision's own scaling against
        /// this file's; nothing on the drawing path needs it.
        fileprivate let handler: VNImageRequestHandler
        /// Per-pixel instance numbers at the model's own resolution, 0 for background.
        fileprivate let labels: [UInt8]
        fileprivate let width: Int
        fileprivate let height: Int

        /// How many separate things the model found.
        var instances: Int { observation.allInstances.count }

        /// Everything it found, which is what a selection means before a
        /// finger has named anything in particular.
        var allInstances: IndexSet { observation.allInstances }

        /// The instance under `unit` — a place in the picture, origin top left, the same
        /// coordinates the sample point is kept in — or nil where the touch landed on the
        /// background.
        func instance(at unit: CGPoint) -> Int? {
            guard width > 0, height > 0 else { return nil }
            let x = min(max(Int(unit.x * Double(width)), 0), width - 1)
            let y = min(max(Int(unit.y * Double(height)), 0), height - 1)
            let label = labels[y * width + x]
            return label == 0 ? nil : Int(label)
        }

        /// How much of each cell of a `width` x `height` grid the detector claimed for anything at
        /// all, 0…1, origin top left.
        func coverage(width targetWidth: Int,
                      height targetHeight: Int) -> [Float] {
            guard self.width > 0, self.height > 0,
                  targetWidth > 0, targetHeight > 0 else {
                return [Float](repeating: 0, count: max(0, targetWidth * targetHeight))
            }
            var out = [Float](repeating: 0, count: targetWidth * targetHeight)
            for y in 0..<targetHeight {
                let top = y * self.height / targetHeight
                let bottom = max(top + 1, (y + 1) * self.height / targetHeight)
                for x in 0..<targetWidth {
                    let left = x * self.width / targetWidth
                    let right = max(left + 1, (x + 1) * self.width / targetWidth)
                    var claimed = 0, total = 0
                    for row in top..<min(bottom, self.height) {
                        let base = row * self.width
                        for column in left..<min(right, self.width) {
                            if labels[base + column] != 0 { claimed += 1 }
                            total += 1
                        }
                    }
                    out[y * targetWidth + x] =
                        total > 0 ? Float(claimed) / Float(total) : 0
                }
            }
            return out
        }

        /// The soft mask for `chosen`, at the model's own resolution: grey with alpha 1, which is
        /// the form `CIBlendWithMask` reads — it interpolates on the mask's premultiplied colour,
        /// not on its alpha, so a white-through-grey mask is the whole contract.
        func mask(of chosen: IndexSet) -> CIImage? {
            guard !chosen.isEmpty,
                  let buffer = try? observation.generateMask(forInstances: chosen)
            else { return nil }
            return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        }

        /// Produces Vision's scaled mask for benchmark comparison.
        func scaledMaskForComparison() -> CVPixelBuffer? {
            try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler)
        }
    }

    /// Runs the model over `image`.
    static func detect(
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> Reading? {
        let handler = VNImageRequestHandler(cgImage: image,
                                            orientation: orientation,
                                            options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty else { return nil }

        let labels = observation.instanceMask
        let width = CVPixelBufferGetWidth(labels)
        let height = CVPixelBufferGetHeight(labels)
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(labels) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(labels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var copied = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * stride
            for x in 0..<width { copied[y * width + x] = bytes[row + x] }
        }
        return Reading(observation: observation, handler: handler,
                       labels: copied, width: width, height: height)
    }

    /// Puts a detected mask over `guide` — the photograph at the size the composite is being made
    /// at — and returns a mask in the guide's extent.
    static func fitted(_ mask: CIImage, to guide: CIImage,
                       edge: Double, feather: Double) -> CIImage {
        let extent = guide.extent
        guard extent.width > 0, extent.height > 0,
              mask.extent.width > 0, mask.extent.height > 0 else { return mask }

        let stretched = mask.transformed(by: CGAffineTransform(
            scaleX: extent.width / mask.extent.width,
            y: extent.height / mask.extent.height))

        var fitted = guide.applyingFilter(
            "CIEdgePreserveUpsampleFilter", parameters: [
                "inputSmallImage": stretched,
                "inputSpatialSigma": 3.0,
                "inputLumaSigma": 0.15,
            ])

        let long = max(extent.width, extent.height)
        let shift = abs(edge) * long * 0.008
        if shift >= 0.5 {
            fitted = fitted.clampedToExtent().applyingFilter(
                edge > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum",
                parameters: [kCIInputRadiusKey: shift])
        }
        let softness = feather * long * 0.006
        if softness >= 0.5 {
            fitted = fitted.clampedToExtent().applyingFilter(
                "CIGaussianBlur", parameters: [kCIInputRadiusKey: softness])
        }
        return fitted.cropped(to: extent)
    }
}

#if canImport(UIKit)
extension CGImagePropertyOrientation {
    /// The turn a `UIImage` is carrying, in the terms Vision asks for.
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
#endif
