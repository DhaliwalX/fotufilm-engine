import Foundation

/// One protocol for native-reference checks and the browser's isolated WASI reactor.
public enum WebRenderRequest {
    public static func prepare(_ data: Data) throws -> Data {
        struct Envelope: Decodable { var kind: String? }
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.kind {
        case "print-frame": return try decoder.decode(WebPrintFrameRequest.self, from: data).prepare()
        case "auto-adjust": return try decoder.decode(WebAutoAdjustmentRequest.self, from: data).prepare()
        case "lens": return try decoder.decode(WebLensRequest.self, from: data).prepare()
        case "lens-plan":
            return try JSONEncoder().encode(decoder.decode(WebLensRequest.self, from: data).plan())
        case "lens-catalogue", "lens-match":
            return try decoder.decode(WebLensCatalogueRequest.self, from: data)
                .prepare(matching: envelope.kind == "lens-match")
        case nil, "film": return try decoder.decode(WebProfileRequest.self, from: data).prepare()
        default: throw InvalidRequest.unknownKind
        }
    }
    private enum InvalidRequest: Error { case unknownKind }
}
