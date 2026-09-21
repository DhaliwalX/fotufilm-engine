import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

public struct WebPerspectiveRequest: Decodable {
    public let width: Int
    public let height: Int
    public let vertical: Double
    public let horizontal: Double

    public struct Result: Codable {
        public let inverse: [Double]
        public let corners: [[Double]]
    }
    public func prepare() throws -> Data {
        guard width > 0, height > 0, width <= 100_000, height <= 100_000,
              vertical.isFinite, horizontal.isFinite,
              (-15...15).contains(vertical), (-15...15).contains(horizontal) else {
            throw WebProfileRequest.Failure(description: "Invalid perspective dimensions or angle.")
        }
        let active = abs(vertical) > 0.001 || abs(horizontal) > 0.001
        let v = active ? vertical : 0, h = active ? horizontal : 0
        let inverse = PerspectiveProjection.inverse(width: Double(width), height: Double(height), vertical: v, horizontal: h)
        guard inverse.allSatisfy(\.isFinite) else {
            throw WebProfileRequest.Failure(description: "This image is too narrow for perspective correction.")
        }
        return try JSONEncoder().encode(Result(inverse: inverse, corners:
            PerspectiveProjection.corners(width: Double(width), height: Double(height), vertical: v, horizontal: h)
                .map { [$0.x, $0.y] }))
    }
}
