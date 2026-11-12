import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Names the camera a scanned negative is read as taken with where its edit leaves that to the
/// file (`NegativeScanSource.readCamera`), which the editor shows as what Scanned With found.
public struct WebNegativeCameraRequest: Decodable {
    /// What the scan's file says of its camera and decoder; nil for a file that says nothing.
    public let source: NegativeScanSource?
    /// As `WebProfileRequest.Negative.cameraProfile`.
    public let cameraProfile: String?

    struct Result: Codable, Equatable {
        let id: String
        let name: String?
    }

    public func prepare() throws -> Data {
        WebProfileRequest.Negative.register(cameraProfile: cameraProfile)
        let camera = (source ?? NegativeScanSource()).readCamera
        return try JSONEncoder().encode(Result(id: camera.id, name: camera.name))
    }
}
