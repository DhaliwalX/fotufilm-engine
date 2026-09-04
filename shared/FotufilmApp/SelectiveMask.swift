import CoreGraphics
import CoreImage
import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// What a selection actually is, once the surface has finished asking for it: a weight per colour,
/// and a way to lay one develop over another through it.
///
/// The phone's selective takeover and the desktop session's selective panel are different surfaces
/// — a finger with a loupe against a pointer and a column of rows — but they are the same
/// operation underneath, and it is the operation that is hard to get right. The mask is a colour
/// cube built on the CPU: every colour the emulsion is about to be given is weighed against the
/// sample, by chroma for a colour selection and by tone for a light one, and the weight comes back
/// as grey for the blend to read. Lifted here so there is one of it rather than one per platform.
enum SelectiveMask {
    static let cubeDimension = 32

    /// The mask over `source` — the *undeveloped* scene, not the print: the selection names
    /// something in the photograph, and the film moves colours around on its way to paper.
    ///
    /// Returns nil where there is nothing to select by, which for a colour or light selection means
    /// nothing has been sampled yet.
    static func image(over source: CIImage, extent: CGRect,
                      state: SelectiveState,
                      subjects: SubjectMask.Reading?,
                      colorSpace: CGColorSpace) -> CIImage? {
        if state.kind == .subject {
            guard let subjects else { return nil }
            let chosen = state.subjectInstance.map { IndexSet(integer: $0) }
                ?? subjects.allInstances
            guard let mask = subjects.mask(of: chosen) else { return nil }
            return SubjectMask.fitted(mask, to: source,
                                      edge: state.subjectEdge,
                                      feather: state.subjectFeather)
        }
        guard state.samplePoint != nil else { return nil }
        let data = cube(kind: state.kind,
                        target: SIMD3(state.sampleRed, state.sampleGreen,
                                      state.sampleBlue),
                        range: state.range, softness: state.softness)
        guard let masked = CIFilter(
            name: "CIColorCubeWithColorSpace", parameters: [
                kCIInputImageKey: source,
                "inputCubeDimension": cubeDimension,
                "inputCubeData": data,
                "inputColorSpace": colorSpace,
            ])?.outputImage else { return nil }
        // A pixel of blur, so the selection's edge is not the cube's quantisation.
        return masked
            .applyingFilter("CIGaussianBlur",
                            parameters: [kCIInputRadiusKey: 2.0])
            .cropped(to: extent)
    }

    /// The selection's print laid over the ground's through the mask — or, showing the mask, the
    /// selection painted white over the dimmed photograph, which is the only way to see what a
    /// range and a softness are really selecting.
    static func composite(ground: CGImage, selection: CGImage?,
                          scene: CIImage?, state: SelectiveState,
                          subjects: SubjectMask.Reading?,
                          showMask: Bool, context: CIContext,
                          colorSpace: CGColorSpace) -> CGImage? {
        let base = CIImage(cgImage: ground)
        let extent = base.extent
        // The mask is read off the scene where there is one — the film has not moved those colours
        // yet — and off the print where there is not.
        let source = scene.map { fitted($0, to: extent) } ?? base
        guard let mask = image(over: source, extent: extent, state: state,
                               subjects: subjects, colorSpace: colorSpace)
        else { return nil }

        let output: CIImage?
        if showMask {
            let dimmed = base.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: -0.3,
                kCIInputSaturationKey: 0.4,
            ])
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
                .cropped(to: extent)
            output = CIFilter(name: "CIBlendWithMask", parameters: [
                kCIInputImageKey: white,
                kCIInputBackgroundImageKey: dimmed,
                kCIInputMaskImageKey: mask,
            ])?.outputImage
        } else {
            guard let selection else { return nil }
            output = CIFilter(name: "CIBlendWithMask", parameters: [
                kCIInputImageKey: CIImage(cgImage: selection),
                kCIInputBackgroundImageKey: base,
                kCIInputMaskImageKey: mask,
            ])?.outputImage
        }
        guard let output else { return nil }
        return context.createCGImage(output, from: extent, format: .RGBA8,
                                     colorSpace: colorSpace)
    }

    private static func fitted(_ image: CIImage, to extent: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0,
              source.size != extent.size else { return image }
        return image
            .transformed(by: CGAffineTransform(
                scaleX: extent.width / source.width,
                y: extent.height / source.height))
            .cropped(to: extent)
    }

    /// The cube itself: `dimension³` entries of weight against the sample.
    static func cube(kind: SelectiveState.MaskKind, target: SIMD3<Double>,
                     range: Double, softness: Double) -> Data {
        /// The working space's own luminance. These are Rec.2020's weights: the cube's samples are
        /// working-space values, and reading them with Rec.709's would put the mask's luma and
        /// chroma axes on a different luminance from everything it masks.
        func luma(_ c: SIMD3<Double>) -> Double {
            let w = ColorScience.luminanceWeights
            return Double(w.0) * c.x + Double(w.1) * c.y + Double(w.2) * c.z
        }
        /// Chroma about the colour's own luminance, the same opponent reading the engine's
        /// saturation control makes.
        func chroma(_ c: SIMD3<Double>) -> SIMD2<Double> {
            let y = max(luma(c), 1e-4)
            return SIMD2((c.x - y) / (y + 0.25), (c.z - y) / (y + 0.25))
        }
        func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
            guard b > a else { return x < a ? 0 : 1 }
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }

        let targetLuma = luma(target)
        let targetChroma = chroma(target)
        let n = cubeDimension
        var values = [Float32]()
        values.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let c = SIMD3(Double(r), Double(g), Double(b))
                        / Double(n - 1)
                    let distance: Double
                    switch kind {
                    case .color:
                        let d = chroma(c) - targetChroma
                        distance = (d.x * d.x + d.y * d.y).squareRoot()
                    case .light:
                        distance = abs(luma(c) - targetLuma)
                    case .subject:
                        distance = 0
                    }
                    let outer = range
                    let inner = outer * (1 - softness)
                    let weight = Float32(1 - smoothstep(inner, outer, distance))
                    values.append(weight)
                    values.append(weight)
                    values.append(weight)
                    values.append(1)
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
