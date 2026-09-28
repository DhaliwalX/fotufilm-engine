import Foundation


/// The pipeline walkthrough: every stage at its off position, then one stage turned back on per
/// step. Spatial stages 2, 3, 4, 5 and 7 are disabled through their source parameters; capture and
/// development use idealized forms because they cannot be disabled; stage 8 reads base-free
/// density. The CLI's stage renders, the browser's stage packs and a native host's pipeline
/// inspector all read this one definition.
public enum PipelineWalk {
    /// Ideal capture: narrow, non-overlapping layer sensitivities on the sRGB
    /// primaries, so each layer records exactly one primary and the emulsion has no
    /// spectral crosstalk at all. Stage 1 cannot be removed — without exposure there
    /// is no latent image — so this stands in for its off position: the difference
    /// against it is what the stock's real, broadly overlapping sensitivities do.
    public static func idealizedCapture(_ profile: FilmSpectralProfile) -> FilmSpectralProfile {
        let centers: [Float] = [600, 540, 460]
        let sigma: Float = 12
        var ideal = profile
        ideal.layerSensitivity = centers.map { center in
            SpectralGrid.wavelengths.map { nm in
                let z = (nm - center) / sigma
                return exp(-0.5 * z * z)
            }
        }
        return ideal
    }

    /// A characteristic curve with the toe and shoulder rolloff taken out: the same
    /// dMin, gamma, toe and shoulder positions, but hard knees instead of softplus
    /// ones, so the working range is a pure straight line. Development cannot be
    /// removed either; this is the curve with its shape removed but its calibration
    /// intact, so mid-gray stays anchored.
    public static func straightLine(_ curve: CharacteristicCurve) -> CharacteristicCurve {
        CharacteristicCurve(dMin: curve.dMin, gamma: curve.gamma,
                            toe: curve.toe, toeWidth: 1e-3,
                            shoulder: curve.shoulder, shoulderWidth: 1e-3)
    }

    /// One frame of the walkthrough: the stock and options that produce it, named.
    public struct Step {
        public let id: String
        public let label: String
        public let stock: FilmStock
        public let options: FotufilmEngine.Options
    }

    /// The walkthrough itself — every stage at its off position, then one stage turned back on per
    /// step, in the order the light meets them.
    ///
    /// This is the single definition of what "stage N off" means. The renderer developing an image
    /// and the exporter sealing packs for the browser both read it, so the two cannot drift: a browser
    /// frame and a native frame for the same step are the same stock and the same options.
    public static func steps(stock: FilmStock, options: FotufilmEngine.Options) -> [Step] {
        var bare = stock
        bare.spectralProfile = idealizedCapture(stock.spectralProfile)
        bare.curves = stock.curves.map(straightLine)
        bare.flare = 0
        bare.emulsionDiffusionMM = stock.emulsionDiffusionMM.map { _ in 0 }
        bare.emulsionDiffusionSecondaryMM = stock.emulsionDiffusionSecondaryMM.map { _ in 0 }
        bare.emulsionDiffusionPrimaryShare = stock.emulsionDiffusionPrimaryShare.map { _ in 1 }
        bare.lumaDiffusionMM = 0
        bare.mtfLumaShare = 0
        bare.adjacencyStrength = 0

        var quiet = options
        // Stage 2 is off by default now, so the walkthrough has to ask for it back —
        // otherwise the step labelled "lens flare" would render without any.
        quiet.flareScale = 0
        quiet.halationScale = 0
        quiet.couplerScale = 0
        quiet.grainScale = 0
        // Stage 8 off: the developed negative read straight, base divided out, with
        // no paper anywhere in the path.
        if !stock.isReversal { quiet.negativeViewing = .scanner }

        var steps: [Step] = []
        // Turned back on in the order the light meets them, so the sequence walks
        // the pipeline rather than the engine's switchability. Everything before
        // stage 8 is therefore a negative: the print is the last thing to happen.
        steps.append(Step(id: "01-bypassed", label: "Every stage at its off position",
                               stock: bare, options: quiet))

        bare.spectralProfile = stock.spectralProfile
        steps.append(Step(id: "02-exposure", label: "Stage 1 — spectral exposure",
                               stock: bare, options: quiet))

        bare.flare = stock.flare
        quiet.flareScale = options.flareScale > 0 ? options.flareScale : 1
        steps.append(Step(id: "03-flare", label: "Stage 2 — lens flare",
                               stock: bare, options: quiet))

        bare.emulsionDiffusionMM = stock.emulsionDiffusionMM
        bare.emulsionDiffusionSecondaryMM = stock.emulsionDiffusionSecondaryMM
        bare.emulsionDiffusionPrimaryShare = stock.emulsionDiffusionPrimaryShare
        bare.lumaDiffusionMM = stock.lumaDiffusionMM
        bare.mtfLumaShare = stock.mtfLumaShare
        steps.append(Step(id: "04-diffusion", label: "Stage 3 — emulsion diffusion",
                               stock: bare, options: quiet))

        quiet.halationScale = options.halationScale
        steps.append(Step(id: "05-halation", label: "Stage 4 — halation",
                               stock: bare, options: quiet))

        quiet.couplerScale = options.couplerScale
        bare.adjacencyStrength = stock.adjacencyStrength
        steps.append(Step(id: "06-couplers", label: "Stage 5 — DIR couplers and adjacency",
                               stock: bare, options: quiet))

        bare.curves = stock.curves
        steps.append(Step(id: "07-development", label: "Stage 6 — H&D development",
                               stock: bare, options: quiet))

        quiet.grainScale = options.grainScale
        steps.append(Step(id: "08-grain", label: "Stage 7 — grain",
                               stock: bare, options: quiet))

        // The developed negative as the print stage actually sees it, base and all,
        // before stage 8 turns it into a positive.
        if !stock.isReversal {
            var onLightBox = quiet
            onLightBox.negativeViewing = .lightBox
            steps.append(Step(id: "09-negative", label: "Stage 8 input — the developed negative",
                               stock: bare, options: onLightBox))
        }

        quiet.negativeViewing = options.negativeViewing
        steps.append(Step(id: "10-print", label: "Stage 8 — output medium",
                               stock: bare, options: quiet))

        return steps
    }
}
