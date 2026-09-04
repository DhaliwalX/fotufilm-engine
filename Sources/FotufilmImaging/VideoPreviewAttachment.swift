import Foundation

/// Derives live-preview attachment settings from a clip reading. A change in reading requires a
/// rebuild because it can change pixel format, decoder depth, composition, and scene headroom.
public enum VideoPreviewAttachment {
    /// What the tap and the develop are to be built from.
    public struct Plan: Equatable, Sendable {
        /// Whether the tap has to be built again for this reading.
        public var rebuilds: Bool
        /// Whether the item keeps a colour-managed composition in front of the tap. When false,
        /// any composition a previous reading left has to come off, or the decoder's frames
        /// would arrive through it.
        public var usesComposition: Bool
        /// Whether the tap asks the decoder for the deep container.
        public var deepTap: Bool
        /// What the reading puts on `Options.sceneHeadroom`.
        public var sceneHeadroom: Float

        public init(rebuilds: Bool, usesComposition: Bool, deepTap: Bool,
                    sceneHeadroom: Float) {
            self.rebuilds = rebuilds
            self.usesComposition = usesComposition
            self.deepTap = deepTap
            self.sceneHeadroom = sceneHeadroom
        }
    }

    /// Returns true when no tap exists or its reading differs from the requested reading.
    public static func rebuilds<Reading: Equatable>(
        attached: Bool, previousReading: Reading?, reading: Reading
    ) -> Bool {
        !attached || previousReading != reading
    }

    /// - Parameters:
    ///   - attached: whether a tap is already running.
    ///   - previousReading: the reading it was built for, if any.
    ///   - reading: the reading now asked for.
    ///   - composition: whether a colour-managed composition is available for this reading.
    ///   - deepInput: `VideoDecodeDepth`'s verdict on the source.
    ///   - declaredHeadroom: what the reading's container declares, if it declares anything.
    public static func plan<Reading: Equatable>(
        attached: Bool, previousReading: Reading?, reading: Reading,
        composition: Bool, deepInput: Bool, declaredHeadroom: Float?
    ) -> Plan {
        Plan(rebuilds: rebuilds(attached: attached,
                                previousReading: previousReading,
                                reading: reading),
             usesComposition: composition,
             // The compositor works in eight bits, so asking it for half float buys a padded
             // frame at four times the bytes and no more range.
             deepTap: composition ? false : deepInput,
             sceneHeadroom: sceneHeadroom(declaredBy: declaredHeadroom))
    }

    /// Returns declared headroom, or 1 to clear any previous reading's headroom.
    public static func sceneHeadroom(declaredBy declared: Float?) -> Float {
        declared ?? 1
    }

    /// Whether a description of a reading still describes the tap.
    ///
    /// Two attaches commit in order, but the work that tells the develop about them is queued
    /// from separate tasks and can arrive the other way round. The later commit wins.
    public static func accepts(generation: UInt64, applied: UInt64) -> Bool {
        generation > applied
    }
}
