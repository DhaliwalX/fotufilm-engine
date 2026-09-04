import Foundation

/// Validates whether viewfinder buffers and converters can be reused for an arriving frame.
/// Deep planar frames require a converter built for the same reading; matching geometry and stride
/// alone are insufficient.
public enum FrameResources {
    /// Bytes a pixel takes on the frame path: sixteen on the HDR path's linear float RGBA.
    public static let deepStride = 16
    /// And four on the SDR path's RGBA8.
    public static let shallowStride = 4

    /// Whether frames at this stride arrive planar, and so are readable only through a converter.
    public static func needsConverter(stride: Int) -> Bool {
        stride == deepStride
    }

    /// Whether a set of resources already built can read the frame now arriving.
    ///
    /// `builtConverter` is the reading the existing converter was built for, or nil where there
    /// is no converter — which on the deep path is a mismatch, not agreement.
    public static func canReuse<Reading: Equatable>(
        builtWidth: Int, builtHeight: Int, builtStride: Int,
        builtConverter: Reading?, buffersReady: Bool,
        width: Int, height: Int, stride: Int, reading: Reading
    ) -> Bool {
        guard buffersReady, builtWidth == width, builtHeight == height,
              builtStride == stride else { return false }
        return needsConverter(stride: stride)
            ? builtConverter == reading
            : builtConverter == nil
    }

    /// Whether a freshly built set can actually read a frame at this stride. A deep path without
    /// its converter is not half-built, it is unusable.
    public static func isUsable(stride: Int, buffersReady: Bool,
                                hasConverter: Bool) -> Bool {
        buffersReady && (!needsConverter(stride: stride) || hasConverter)
    }
}
