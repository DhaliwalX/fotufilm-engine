import Foundation

/// CPU implementation of the kernel's per-pixel exposure stage: white balance, scene adjustments,
/// and spectral recovery. Veiling-glare measurement uses this type to avoid per-pixel closure
/// calls. Keep its operation order aligned with the GPU kernel; the glare mean is compared
/// bit-for-bit and changes if arithmetic is reassociated.
struct ExposureSampler {
    let gain: Float
    let balance: SIMD3<Float>
    let highlights: Float
    let shadows: Float
    let saturation: Float
    let vibrance: Float
    /// True when all scene adjustments are identities and tone-grid sampling can be skipped.
    let neutral: Bool
    let values: UnsafePointer<Float>
    let dimension: Int
    let luma: (Float, Float, Float)
    let gridWidth: Int
    let gridHeight: Int
    let frameWidth: Float
    let frameHeight: Float
    let planeA: UnsafePointer<Float>
    let planeB: UnsafePointer<Float>

    /// Mirrors recover_exposure: the scene arrives in the Rec.2020 working space and steps into
    /// the exposure table's own basis, whose cube encloses the spectral locus. That cube's edge
    /// is the scene path's only boundary — at the end of physical light, not at a display or
    /// working gamut. A colour outside it is walked toward its own luminance axis until the
    /// binding channel reaches zero — the most saturated real light of the same luminance and
    /// hue — and a colour with non-positive luminance is no light at all. The arithmetic and
    /// its order match the kernel's exactly.
    @inline(__always)
    func layerExposure(_ scene: SIMD3<Float>) -> SIMD3<Double> {
        let y = luma.0 * scene.x + luma.1 * scene.y + luma.2 * scene.z
        guard y > 0 else { return .zero }
        let domain = ColorScience.linearRec2020ToExposureDomain(scene)
        var projected = domain
        if domain.x < 0 || domain.y < 0 || domain.z < 0 {
            var s: Float = 1
            if domain.x < 0 { s = min(s, y / (y - domain.x)) }
            if domain.y < 0 { s = min(s, y / (y - domain.y)) }
            if domain.z < 0 { s = min(s, y / (y - domain.z)) }
            projected = SIMD3(y + s * (domain.x - y),
                              y + s * (domain.y - y),
                              y + s * (domain.z - y))
        }
        let rgb = SIMD3<Float>(max(projected.x, 0), max(projected.y, 0),
                               max(projected.z, 0))
        let brightest: Float = max(rgb.x, max(rgb.y, rgb.z))
        // Dim colours must also sample the cube face: interior interpolation does not
        // preserve the reconstructed spectrum along a brightness ray.
        let radiance: Float = max(1e-6, brightest)
        let chromaticity = SIMD3<Float>(rgb.x / radiance, rgb.y / radiance,
                                        rgb.z / radiance)
        let sampled: SIMD3<Float> = SpectralLUT.sample(
            chromaticity, values: values, dimension: dimension)
        let scale: Float = radiance * gain
        let layer = SIMD3<Float>(sampled.x * scale, sampled.y * scale,
                                 sampled.z * scale)
        return SIMD3<Double>(Double(max(layer.x, 0)), Double(max(layer.y, 0)),
                             Double(max(layer.z, 0)))
    }

    /// The regional tone base under pixel `x`, `y`, bilinear across the two grid planes.
    @inline(__always)
    func toneBase(_ stops: Float, _ x: Int, _ y: Int) -> Float {
        let gx = min(max((Float(x) + 0.5) * Float(gridWidth)
                         / frameWidth - 0.5, 0), Float(gridWidth - 1))
        let gy = min(max((Float(y) + 0.5) * Float(gridHeight)
                         / frameHeight - 0.5, 0), Float(gridHeight - 1))
        let x0 = min(max(Int(gx), 0), max(gridWidth - 2, 0))
        let y0 = min(max(Int(gy), 0), max(gridHeight - 2, 0))
        let x1 = min(x0 + 1, gridWidth - 1)
        let y1 = min(y0 + 1, gridHeight - 1)
        let fx = min(max(gx - Float(x0), 0), 1)
        let fy = min(max(gy - Float(y0), 0), 1)
        @inline(__always)
        func bilinear(_ plane: UnsafePointer<Float>) -> Float {
            let top = (1 - fx) * plane[y0 * gridWidth + x0]
                + fx * plane[y0 * gridWidth + x1]
            let bottom = (1 - fx) * plane[y1 * gridWidth + x0]
                + fx * plane[y1 * gridWidth + x1]
            return (1 - fy) * top + fy * bottom
        }
        return bilinear(planeA) * stops + bilinear(planeB)
    }

    /// The exposure the scene pixel at `x`, `y` put on the film. `x` and `y` are read only when
    /// the scene adjustments are active; a neutral sampler ignores them.
    @inline(__always)
    func exposure(_ scene: SIMD3<Float>, x: Int, y: Int) -> SIMD3<Double> {
        if neutral { return layerExposure(scene * balance) }
        // Unclamped, like the kernel: out-of-P3 components are real colour on their way to the
        // Rec.2020 seam, and everything here is linear.
        // Balance first, as the kernel does, so the metering, the luminance and the
        // colourfulness below all read the adapted scene.
        let r0 = scene.x * balance.x
        let g0 = scene.y * balance.y
        let b0 = scene.z * balance.z
        let metered = (luma.0 * r0 + luma.1 * g0 + luma.2 * b0) * gain
        let stops = log(max(metered, 1e-6)) * (1 / 0.6931472)
        let keyed = toneBase(stops, x, y)
        let high = min(max(keyed * (1.0 / 6.0), 0), 1)
        let low = min(max(-keyed * (1.0 / 6.0), 0), 1)
        let highMask = high * high * (3 - 2 * high)
        let lowMask = low * low * (3 - 2 * low)
        let toneGain = exp2(3 * (highlights * highMask
                                 + shadows * lowMask))
        let r1 = r0 * toneGain, g1 = g0 * toneGain, b1 = b0 * toneGain
        let luma1 = luma.0 * r1 + luma.1 * g1 + luma.2 * b1
        let peak = max(r1, max(g1, b1))
        let colourfulness = (peak - min(r1, min(g1, b1)))
            / max(peak, 1e-6)
        let chroma = saturation
            * (1 + vibrance * (1 - colourfulness))
        let adjusted = SIMD3<Float>(
            luma1 + chroma * (r1 - luma1),
            luma1 + chroma * (g1 - luma1),
            luma1 + chroma * (b1 - luma1))
        return layerExposure(adjusted)
    }
}
