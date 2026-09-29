import Foundation

/// A small picture of a still that has not been opened, for the photo strip
/// (`HostPlatform.thumbnails`): the file's embedded preview where it has one, so a batch of
/// photographs shows at once and only the one being edited is decoded.
protocol HostThumbnailer {
    /// Upright RGBA8 Display P3 codes, no longer than `maxEdge` on the long edge.
    func thumbnail(_ url: URL, maxEdge: Int) throws -> (pixels: [UInt8], width: Int, height: Int)
}
