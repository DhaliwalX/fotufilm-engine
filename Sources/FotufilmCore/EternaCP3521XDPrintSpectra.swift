// Characteristic curves digitized from the manufacturer's published data sheet.

import Foundation

/// Fujifilm's higher-density release print, read from the ETERNA-CP
/// 3521XD pages of Fujifilm's motion picture film manual (KB-0707E,
/// November 2007).
///
/// The manual publishes the characteristic curves and nothing spectral,
/// so this file holds the curves alone; the stock borrows 3513DI's spectra.
/// The curves are the publisher's vector paths. The same manual draws
/// 3513DI's in the same frame and inks, and that drawing, read the same
/// way, matches the 3513DI curves fitted from Fujifilm's brochure to
/// 0.0137 D RMS or better per record once each is aligned at 1.0 above
/// D-min.
enum EternaCP3521XDPrintSpectra {
    /// The red record (2854 K tungsten 1/100 s, ECP-2B, Status A), fitted to the engine's
    /// softplus H&D family at RMS 0.0282 D (worst 0.0588 D) from the 0.081 D foot the sheet
    /// draws to 4.424 D. The plot holds its records apart along an exposure axis with no
    /// origin; the engine anchors each at its own LAD aim, which absorbs that.
    static let redCurve = CharacteristicCurve(
        dMin: 0.08145, gamma: 7.8, toe: 3.52809, toeWidth: 0.232236, shoulder: 4.08488, shoulderWidth: 0.093767)

    /// The green record (2854 K tungsten 1/100 s, ECP-2B, Status A), fitted to the engine's
    /// softplus H&D family at RMS 0.0254 D (worst 0.0480 D) from the 0.080 D foot the sheet
    /// draws to 4.859 D. The plot holds its records apart along an exposure axis with no
    /// origin; the engine anchors each at its own LAD aim, which absorbs that.
    static let greenCurve = CharacteristicCurve(
        dMin: 0.0797436, gamma: 4.95, toe: 2.33172, toeWidth: 0.242163, shoulder: 3.29732, shoulderWidth: 0.102849)

    /// The blue record (2854 K tungsten 1/100 s, ECP-2B, Status A), fitted to the engine's
    /// softplus H&D family at RMS 0.0254 D (worst 0.0535 D) from the 0.140 D foot the sheet
    /// draws to 4.671 D. The plot holds its records apart along an exposure axis with no
    /// origin; the engine anchors each at its own LAD aim, which absorbs that.
    static let blueCurve = CharacteristicCurve(
        dMin: 0.139644, gamma: 7.3, toe: 1.55147, toeWidth: 0.253581, shoulder: 2.17227, shoulderWidth: 0.105622)
}
