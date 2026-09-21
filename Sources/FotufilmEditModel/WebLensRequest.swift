import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The browser samples this native table in scene-linear light before crop and film.
/// No image data enters the settings worker.
public struct WebLensRequest: Decodable {
    public var adjustment: LensAdjustment

    public func prepare() throws -> Data {
        let values = [adjustment.distortion, adjustment.vignetting,
                      adjustment.redCyan, adjustment.blueYellow]
        guard values.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw InvalidAdjustment.outOfRange
        }
        let table = LensCorrectionStack([adjustment.correction]).resamplingTable()
        var data = Data(capacity: table.count * 4)
        for value in table {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private enum InvalidAdjustment: Error { case outOfRange }
}

/// One protocol for native-reference checks and the browser's isolated WASI reactor.
public enum WebRenderRequest {
    public static func prepare(_ data: Data) throws -> Data {
        struct Envelope: Decodable { var kind: String? }
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.kind {
        case "lens": return try decoder.decode(WebLensRequest.self, from: data).prepare()
        case nil, "film": return try decoder.decode(WebProfileRequest.self, from: data).prepare()
        default: throw InvalidRequest.unknownKind
        }
    }
    private enum InvalidRequest: Error { case unknownKind }
}
