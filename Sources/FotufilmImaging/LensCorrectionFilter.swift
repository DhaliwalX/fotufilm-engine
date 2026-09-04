#if canImport(CoreImage)
import CoreImage
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Undoes the lens, on the way in.
///
/// The whole correction — distortion, the two chroma channels and the falloff — is folded into one
/// table by `LensCorrectionStack` and then applied in a single pass: one lookup for the radius, three
/// samples for the three channels, one multiply for the light the corners lost. Doing it as one pass
/// matters because each extra resampling of a photograph costs sharpness that cannot be got back.
public enum LensCorrectionFilter {
    /// Samples across the radius. A thousand is far more than the curves need — they are smooth
    /// polynomials — but the table is four kilobytes, so there is nothing to be gained by being
    /// clever about it.
    public static let tableEntries = 1024

    /// The kernel is written in Core Image's own kernel language rather than Metal so that it
    /// compiles at run time. That keeps the whole feature inside Swift sources: no `.metal` file to
    /// add to two build scripts and the Xcode project, and no library to bundle. The language is
    /// deprecated but still compiles and renders; moving to a Metal `CIKernel` would be a build
    /// change and nothing else, since the kernel itself would be line for line the same.
    private static let source = """
    kernel vec4 lensCorrect(sampler src, sampler curve, vec2 centre,
                            float invHalfDiagonal, float lastEntry) {
        vec2 offset = destCoord() - centre;
        float radius = length(offset) * invHalfDiagonal;
        // The table runs from the centre to the corner; anything past the corner (which only a
        // rectangle's own corners reach) holds at the last entry rather than wrapping.
        float u = min(radius, 1.0) * lastEntry + 0.5;
        vec4 curveAt = sample(curve, samplerTransform(curve, vec2(u, 0.5)));
        vec4 red = sample(src, samplerTransform(src, centre + offset * curveAt.r));
        vec4 green = sample(src, samplerTransform(src, centre + offset * curveAt.g));
        vec4 blue = sample(src, samplerTransform(src, centre + offset * curveAt.b));
        return vec4(red.r * curveAt.a, green.g * curveAt.a, blue.b * curveAt.a,
                    green.a);
    }
    """

    private static let kernel: CIKernel? = CIKernel(source: source)

    /// Whether the kernel compiled. Nil would mean the deprecated language had finally gone, and the
    /// caller should leave the photograph alone rather than half-correct it.
    public static var isAvailable: Bool { kernel != nil }

    /// The table as a one-pixel-tall image the kernel can read.
    ///
    /// It carries no colour space on purpose: these are geometry and gain, not colour, and letting
    /// Core Image convert them into the working space would corrupt every number.
    private static func curveImage(_ table: [Float]) -> CIImage? {
        let entries = table.count / 4
        guard entries >= 2 else { return nil }
        let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data,
                       bytesPerRow: entries * 4 * MemoryLayout<Float>.size,
                       size: CGSize(width: entries, height: 1),
                       format: .RGBAf, colorSpace: nil)
    }

    /// Applies `stack` to `image`, which must be in linear light — the falloff is a light gain, and
    /// applying it to an encoded signal would lift the corners by the wrong amount.
    ///
    /// The picture keeps the extent it arrived with. Where the correction reaches past the frame the
    /// edge pixel is held rather than going transparent, so a barrel correction leaves stretched
    /// corners instead of empty wedges; `LensCorrectionStack.sourceReach` tells a caller how far in
    /// to crop if it wants neither.
    public static func apply(_ image: CIImage,
                             stack: LensCorrectionStack) -> CIImage {
        guard !stack.isIdentity, let kernel else { return image }
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.isInfinite == false
        else { return image }
        guard let curve = curveImage(
            stack.resamplingTable(entries: tableEntries)) else { return image }

        let centre = CIVector(x: extent.midX, y: extent.midY)
        let halfDiagonal = 0.5 * sqrt(extent.width * extent.width
                                      + extent.height * extent.height)
        guard halfDiagonal > 0 else { return image }

        // The correction reads outward at the corners under barrel and inward under pincushion, so
        // the region it needs is the frame grown by however far the table reaches.
        let reach = CGFloat(max(stack.sourceReach(), 1))
        let source = image.clampedToExtent()

        let output = kernel.apply(
            extent: extent,
            roiCallback: { index, rect in
                // Index 1 is the table, which is wanted whole however small the tile is.
                guard index == 0 else {
                    return CGRect(x: 0, y: 0, width: tableEntries, height: 1)
                }
                let grown = rect.insetBy(dx: -rect.width * (reach - 1) - 2,
                                         dy: -rect.height * (reach - 1) - 2)
                return grown
            },
            arguments: [source, curve, centre,
                        Float(1 / halfDiagonal), Float(tableEntries - 1)])
        guard let output else { return image }
        return output.cropped(to: extent)
    }
}
#endif
