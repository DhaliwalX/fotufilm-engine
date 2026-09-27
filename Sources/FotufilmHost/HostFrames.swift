import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif
/// Print frames for the web editor's native renders: the plan the browser's reactor answers
/// (`WebPrintFrameRequest`), the develop settings a frame implies (`frameRenderEdit` in
/// web/src/print-frame.js), and the finished frame drawn by the renderer the Mac app uses.
enum HostFrames {
    struct Plan {
        var json: [String: Any]
        var configuration: PrintFrameConfiguration
        var renderMedium: String?
    }

    /// The reactor's answer to `frameRequest(edit, width, height)` from web/src/print-frame.js,
    /// whose stock is an id where the reactor reads a definition.
    static func answer(_ request: [String: Any]) throws -> Data {
        var body = request
        body["stock"] = nil
        if let id = request["stock"] as? String, let definition = FilmStock.presetDefinitions[id] {
            body["stock"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition))
        }
        return try JSONDecoder().decode(WebPrintFrameRequest.self,
                                        from: JSONSerialization.data(withJSONObject: body))
            .prepare()
    }

    static func plan(_ request: [String: Any], width: Int, height: Int) throws -> Plan? {
        guard let frame = request["frame"] as? String, frame != "none" else { return nil }
        var body = request
        body["width"] = width
        body["height"] = height
        let data = try answer(body)
        let result = try JSONDecoder().decode(WebPrintFrameRequest.Result.self, from: data)
        guard result.configuration.frame != .none,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Plan(json: json, configuration: result.configuration, renderMedium: result.renderMedium)
    }

    /// The film settings a frame develops with: its medium, a transparency viewed on the
    /// reference light, and a negative in the light box.
    static func settings(_ params: inout [String: Any], for plan: Plan) {
        var profile = params["profileRequest"] as? [String: Any] ?? [:]
        var controls = profile["controls"] as? [String: Any] ?? [:]
        if let medium = plan.renderMedium { profile["medium"] = medium }
        if plan.configuration.frame.viewsTransparency { controls["printLight"] = "reference" }
        if plan.renderMedium == PrintPaper.negative.id { controls["negativeViewing"] = "light-box" }
        profile["controls"] = controls
        params["profileRequest"] = profile
    }

    /// Draws the frame around 8-bit Display P3 pixels and returns the framed picture, or nil
    /// where the platform draws no frames.
    static func frame(_ pixels: [UInt8], width: Int, height: Int,
                      plan: Plan) -> (pixels: [UInt8], width: Int, height: Int)? {
        HostPlatform.current.frames?.frame(pixels, width: width, height: height,
                                           configuration: plan.configuration)
    }
}
