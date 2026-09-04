import Foundation

/// Built-in filters parameterized by published specification: mired shift, cutoff wavelength,
/// neutral density, or peak colour-compensating density. Strong cooling filters also use nominal
/// peak transmittance because ideal Planckian conversion understates real dye loss.
extension LensFilter {

    // MARK: Colour conversion — the strong amber and blue filters

    /// Amber conversion filters for tungsten film in daylight.
    public static let wratten85B = conversion(
        id: "w85b", name: "85B", fromKelvin: 5500, toKelvin: 3200)
    public static let wratten85 = conversion(
        id: "w85", name: "85", fromKelvin: 5500, toKelvin: 3400)
    public static let wratten85C = conversion(
        id: "w85c", name: "85C", fromKelvin: 5500, toKelvin: 3800)

    /// Blue conversion filters for daylight film under tungsten illumination.
    public static let wratten80A = conversion(
        id: "w80a", name: "80A", fromKelvin: 3200, toKelvin: 5500)
    public static let wratten80B = conversion(
        id: "w80b", name: "80B", fromKelvin: 3400, toKelvin: 5500)
    public static let wratten80C = conversion(
        id: "w80c", name: "80C", fromKelvin: 3800, toKelvin: 5500)
    public static let wratten80D = conversion(
        id: "w80d", name: "80D", fromKelvin: 4200, toKelvin: 5500)

    // MARK: Light balancing — the 81 and 82 series

    /// Constructs a light-balancing filter from its mired shift at a reference illuminant.
    public static func lightBalancing(id: String, name: String, miredShift: Float,
                                      referenceKelvin: Float = 5500) -> LensFilter {
        let target = 1e6 / (1e6 / referenceKelvin + miredShift)
        return conversion(id: id, name: name, fromKelvin: referenceKelvin, toKelvin: target)
    }

    public static let wratten81 = lightBalancing(id: "w81", name: "81", miredShift: 9)
    public static let wratten81A = lightBalancing(id: "w81a", name: "81A", miredShift: 18)
    public static let wratten81B = lightBalancing(id: "w81b", name: "81B", miredShift: 27)
    public static let wratten81C = lightBalancing(id: "w81c", name: "81C", miredShift: 35)
    public static let wratten81EF = lightBalancing(id: "w81ef", name: "81EF", miredShift: 53)
    public static let wratten82 = lightBalancing(id: "w82", name: "82", miredShift: -10)
    public static let wratten82A = lightBalancing(id: "w82a", name: "82A", miredShift: -21)
    public static let wratten82B = lightBalancing(id: "w82b", name: "82B", miredShift: -32)
    public static let wratten82C = lightBalancing(id: "w82c", name: "82C", miredShift: -45)

    // MARK: Black-and-white contrast filters

    /// Sharp-cut filters named by the wavelength at half peak transmittance.
    public static let wratten8 = cutOn(id: "w8", name: "#8 Yellow (K2)", halfHeightNM: 495)
    public static let wratten12 = cutOn(id: "w12", name: "#12 Minus Blue", halfHeightNM: 512)
    public static let wratten15 = cutOn(id: "w15", name: "#15 Deep Yellow", halfHeightNM: 522)
    public static let wratten16 = cutOn(id: "w16", name: "#16 Orange", halfHeightNM: 533)
    public static let wratten21 = cutOn(id: "w21", name: "#21 Orange", halfHeightNM: 548)
    public static let wratten23A = cutOn(id: "w23a", name: "#23A Light Red", halfHeightNM: 573)
    public static let wratten25 = cutOn(id: "w25", name: "#25 Red", halfHeightNM: 597)
    public static let wratten29 = cutOn(id: "w29", name: "#29 Deep Red", halfHeightNM: 623)
    public static let wratten70 = cutOn(id: "w70", name: "#70 Dark Red", halfHeightNM: 662)

    /// The band filters: the tricolour separation pair and the greens. Their peak transmittance
    /// is stated because a dye narrow enough to pass a third of the spectrum absorbs inside its
    /// own passband as well — these are dark filters, and their cost is most of what makes them
    /// awkward to shoot.
    public static let wratten11 = band(id: "w11", name: "#11 Yellow-Green",
                                       lowNM: 480, highNM: 640, peakTransmittance: 0.60)
    public static let wratten47 = band(id: "w47", name: "#47 Tricolour Blue",
                                       lowNM: 402, highNM: 494, peakTransmittance: 0.28)
    public static let wratten47B = band(id: "w47b", name: "#47B Deep Blue",
                                        lowNM: 396, highNM: 470, peakTransmittance: 0.22)
    public static let wratten58 = band(id: "w58", name: "#58 Tricolour Green",
                                       lowNM: 482, highNM: 600, peakTransmittance: 0.26)
    public static let wratten61 = band(id: "w61", name: "#61 Deep Green",
                                       lowNM: 492, highNM: 578, peakTransmittance: 0.18)

    // MARK: Ultraviolet

    /// UV absorbers have little spectral effect because the model starts at 380 nm and bundled film
    /// sensitivities are already low there. Their modeled effects are transmission loss and added
    /// veiling glare from two surfaces.
    public static let wratten2B = cutOn(id: "w2b", name: "#2B UV", halfHeightNM: 391,
                                        edgeWidthNM: 4)
    public static let wratten2E = cutOn(id: "w2e", name: "#2E UV", halfHeightNM: 415,
                                        edgeWidthNM: 5)

    // MARK: Neutral density

    public static let nd03 = neutralDensity(0.3)
    public static let nd06 = neutralDensity(0.6)
    public static let nd09 = neutralDensity(0.9)
    public static let nd12 = neutralDensity(1.2)
    public static let nd18 = neutralDensity(1.8)
    public static let nd30 = neutralDensity(3.0)

    // MARK: Colour compensating

    /// The six colour-compensating hues at a stated peak density. The additive three are built
    /// the way the Wratten book builds them, as two subtractive dyes laid together, so a CC20R is
    /// a CC20M and a CC20Y in one piece of gelatin and behaves like one.
    public enum CCHue: String, Sendable, CaseIterable {
        case red, green, blue, cyan, magenta, yellow

        var absorptions: [CCAbsorption] {
            switch self {
            case .cyan: return [.cyan]
            case .magenta: return [.magenta]
            case .yellow: return [.yellow]
            case .red: return [.magenta, .yellow]
            case .green: return [.cyan, .yellow]
            case .blue: return [.cyan, .magenta]
            }
        }

        var code: String {
            switch self {
            case .red: return "R"
            case .green: return "G"
            case .blue: return "B"
            case .cyan: return "C"
            case .magenta: return "M"
            case .yellow: return "Y"
            }
        }
    }

    public static func cc(_ hue: CCHue, density: Float) -> LensFilter {
        let code = String(format: "CC%02.0f%@", density * 100, hue.code)
        return colorCompensating(hue.absorptions, density: density,
                                 id: code.lowercased(), name: code)
    }

    // MARK: Didymium

    public static let didymiumEnhancer = didymium(id: "didymium", name: "Didymium Enhancer")

    // MARK: The catalogue

    /// Everything above, in the order a filter drawer is laid out: conversion, balancing,
    /// contrast, density, compensation.
    public static let catalogue: [LensFilter] = [
        wratten80A, wratten80B, wratten80C, wratten80D,
        wratten85, wratten85B, wratten85C,
        wratten81, wratten81A, wratten81B, wratten81C, wratten81EF,
        wratten82, wratten82A, wratten82B, wratten82C,
        wratten8, wratten11, wratten12, wratten15, wratten16, wratten21,
        wratten23A, wratten25, wratten29, wratten70,
        wratten47, wratten47B, wratten58, wratten61,
        wratten2B, wratten2E,
        nd03, nd06, nd09, nd12, nd18, nd30,
        didymiumEnhancer,
    ] + CCHue.allCases.flatMap { hue in
        [Float(0.05), 0.10, 0.20, 0.30, 0.40, 0.50].map { cc(hue, density: $0) }
    }

    public static func catalogued(_ id: String) -> LensFilter? {
        catalogue.first { $0.id == id }
    }
}
