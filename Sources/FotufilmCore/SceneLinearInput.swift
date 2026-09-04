import Foundation

#if !arch(x86_64)
/// Converts interleaved source RGBA into the film engine's linear Rec.2020 float contract.
///
/// A converter owns the interpretation of its input. It may receive already-linear working-space
/// pixels, transfer-encoded HLG/PQ, another set of primaries, or camera-profile output, but it must
/// write one linear Rec.2020 RGBA value per input value. Alpha is preserved unless the converter
/// explicitly defines another transport meaning for it.
public protocol FilmInputConverter: Sendable {
    func convert(
        _ source: UnsafeBufferPointer<Float>,
        from sourceOffset: Int,
        count: Int,
        into destination: UnsafeMutableBufferPointer<Float>
    )
}

/// How a document asks the app to interpret a still image's dynamic range.
///
/// Automatic preserves the decoded range. Standard range is the explicit opt-in for display-
/// referred SDR preparation.
public enum FilmSourceInterpretation: String, CaseIterable, Codable,
                                      Identifiable, Sendable {
    case automatic
    case fullRange
    case standardRange

    public var id: String { rawValue }

    /// Resolves the document-level choice to the conversion performed at the engine boundary.
    /// Camera raw always keeps its scene-linear latitude; it has no display-referred rendering to
    /// reinterpret as SDR.
    public func resolvedConversion(isRaw: Bool) -> FilmInputConversion {
        if isRaw { return .preserveHDR }
        switch self {
        case .automatic, .fullRange:
            return .preserveHDR
        case .standardRange:
            return .platformToneMap
        }
    }
}

/// Runtime type erasure for clients that select converters from plug-ins or configuration.
public struct AnyFilmInputConverter: FilmInputConverter {
    private let conversion: @Sendable (
        UnsafeBufferPointer<Float>, Int, Int, UnsafeMutableBufferPointer<Float>
    ) -> Void

    public init<Converter: FilmInputConverter>(_ converter: Converter) {
        conversion = { source, offset, count, destination in
            converter.convert(source, from: offset, count: count, into: destination)
        }
    }

    public init(
        conversion: @escaping @Sendable (
            UnsafeBufferPointer<Float>, Int, Int, UnsafeMutableBufferPointer<Float>
        ) -> Void
    ) {
        self.conversion = conversion
    }

    public func convert(
        _ source: UnsafeBufferPointer<Float>,
        from sourceOffset: Int,
        count: Int,
        into destination: UnsafeMutableBufferPointer<Float>
    ) {
        conversion(source, sourceOffset, count, destination)
    }
}

/// How decoded source light is prepared for the film engine's linear Rec.2020 contract.
///
/// Container decoding and ICC/color-space conversion are platform responsibilities. Once pixels
/// are in the engine working space, this policy is shared by the app, CLI, web and other clients.
public enum FilmInputConversion: String, CaseIterable, Identifiable, FilmInputConverter {
    /// Preserve scene exposure, including values above diffuse white.
    case preserveHDR
    /// The platform decoder already converted HDR range to SDR before supplying working-space RGB.
    case platformToneMap
    /// Convert full-range working-space RGB to SDR with the engine's hue-preserving shoulder.
    ///
    /// No document-level interpretation resolves to this one — `FilmSourceInterpretation`'s
    /// standard-range choice hands the range mapping to the platform decoder instead, because a
    /// still arrives already decoded. It is here for the clients that select a converter directly
    /// rather than through an interpretation: the CLI, the web build, and anything reaching the
    /// engine boundary through `AnyFilmInputConverter`.
    case engineLinearToneMap
    public var id: String { rawValue }

    public func convert(
        _ source: UnsafeBufferPointer<Float>,
        from sourceOffset: Int,
        count: Int,
        into destination: UnsafeMutableBufferPointer<Float>
    ) {
        switch self {
        case .engineLinearToneMap:
            SceneLinearInput.toneMapToSDR(
                source, from: sourceOffset, count: count, into: destination)
        case .preserveHDR, .platformToneMap:
            SceneLinearInput.widen(
                source, from: sourceOffset, count: count, into: destination)
        }
    }
}

/// Preparation of stored scene-linear values for the film engine.
public enum SceneLinearInput {
    /// Runs a built-in or client-supplied conversion at the engine input boundary.
    public static func prepare<Converter: FilmInputConverter>(
        _ source: UnsafeBufferPointer<Float>,
        from sourceOffset: Int,
        count: Int,
        into destination: UnsafeMutableBufferPointer<Float>,
        using converter: Converter
    ) {
        converter.convert(source, from: sourceOffset, count: count,
                          into: destination)
    }

    /// Spreads a per-element span across cores.
    ///
    /// Every chunk writes a disjoint run of `destination` and reads nothing another chunk writes,
    /// so the result is bit-identical to the serial loop; this buys time, not a different picture.
    /// The chunk is a whole number of RGBA pixels, so a per-pixel body can divide by four and stay
    /// on a pixel boundary. A frame small enough not to repay a thread hop runs where it is.
    private static func spanning(_ count: Int, _ body: (Int, Int) -> Void) {
        let chunk = 1 << 20
        let chunks = (count + chunk - 1) / chunk
        guard chunks > 1 else { return body(0, count) }
        DispatchQueue.concurrentPerform(iterations: chunks) { index in
            let first = index * chunk
            body(first, min(count, first + chunk) - first)
        }
    }

    /// Copies full-precision samples without changing their exposure. Values above 1 are scene
    /// light, so output-range compression must happen after the film has developed them.
    public static func widen(
        _ source: UnsafeBufferPointer<Float>,
        from sourceOffset: Int,
        count: Int,
        into destination: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(sourceOffset >= 0 && count >= 0)
        precondition(sourceOffset + count <= source.count)
        precondition(count <= destination.count)
        spanning(count) { first, span in
            for index in first..<(first + span) {
                destination[index] = source[sourceOffset + index]
            }
        }
    }

    /// Converts recovered HDR scene light to an SDR scene before the film sees it. Reference
    /// midtones pass unchanged; the top quarter of the SDR range bends toward display white.
    /// Scaling all three channels by the peak's gain preserves highlight hue.
    public static func toneMapToSDR(
        _ source: UnsafeBufferPointer<Float>,
        from sourceOffset: Int,
        count: Int,
        into destination: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(sourceOffset >= 0 && count >= 0 && count.isMultiple(of: 4))
        precondition(sourceOffset + count <= source.count)
        precondition(count <= destination.count)
        let knee: Float = 0.75
        let room: Float = 1 - knee
        spanning(count) { first, span in
        for pixel in (first / 4)..<((first + span) / 4) {
            let sourceBase = sourceOffset + pixel * 4
            let destinationBase = pixel * 4
            let red = source[sourceBase]
            let green = source[sourceBase + 1]
            let blue = source[sourceBase + 2]
            let peak = max(0, max(red, max(green, blue)))
            let scale: Float
            if peak > knee {
                let over = peak - knee
                let rolled = knee + room * over / (over + room)
                scale = rolled / peak
            } else {
                scale = 1
            }
            destination[destinationBase] = red * scale
            destination[destinationBase + 1] = green * scale
            destination[destinationBase + 2] = blue * scale
            destination[destinationBase + 3] = source[sourceBase + 3]
        }
        }
    }
}
#endif
