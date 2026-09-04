import Foundation

/// Converts between the halation multiplier stored by the engine and the stop scale displayed by
/// the editor. Zero stops preserves the stock value; the lower endpoint disables halation.
public enum HalationAmount {
    /// The drawn travel, in stops about the stock's authored look.
    ///
    /// Six stops down is 1/64 and six stops up is 64×. The lower endpoint represents off.
    public static let travel: ClosedRange<Double> = EditorControlUnit.offStops...6

    /// What the row admits without destroying it. The Resolve plugin types multiples up to 100,
    /// and a look graded there has to survive a round trip through this row rather than being
    /// clamped to the drawn track on first touch.
    public static let admitted: ClosedRange<Double> =
        EditorControlUnit.offStops...log2(100)

    /// The stored multiple, as the row draws it.
    ///
    /// A multiple at or under a sixty-fourth appears as off. It is not off — the render still has a
    /// sliver of halo in it — but it is below the bottom of the track, and a row that drew it as
    /// the bottom while calling it a number would be claiming a precision the track does not have.
    /// Such a value only arrives from outside the row, and only a drag replaces it.
    public static func stops(fromScale scale: Double) -> Double {
        guard scale > 0 else { return EditorControlUnit.offStops }
        return max(log2(scale), EditorControlUnit.offStops)
    }

    /// The drawn stops, as the edit stores them.
    public static func scale(fromStops stops: Double) -> Double {
        stops <= EditorControlUnit.offStops ? 0 : exp2(stops)
    }
}
