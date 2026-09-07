/// Lateral development transport and its response. Existing stock packs retain their original
/// Gaussian/log-exposure model until a different model is explicitly selected or calibrated.
public enum AdjacencyModel: String, Codable, Sendable, CaseIterable {
    case gaussian
    /// A two-Gaussian approximation to diffusion with removal, with a bounded Nelson density
    /// response. This is an analytical approximation, not a stock-specific kinetic calibration.
    case screenedDiffusion = "screened-diffusion"

    // Fit to 1 / (1 + (ell*k)^2) and the exponential line-spread step response. Positive
    // weights sum to one; summing 2-D Gaussians preserves isotropy. The authored radius keeps
    // its reference Gaussian-sigma meaning: ell = radius / sqrt(2).
    public static let screenedPrimaryShare: Float = 0.2753401713
    static let screenedPrimarySigma: Float = 0.4338526089 / 1.4142135624
    static let screenedSecondarySigma: Float = 1.4816463071 / 1.4142135624
}
