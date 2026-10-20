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
        /// The part of the photograph a film border shows, where this platform draws frames; the
        /// rest of the plan describes the frame around it.
        var crop: PrintFramePlacement.Rect?
    }

    /// The reactor's answer to `frameRequest(edit, width, height)` from web/src/print-frame.js,
    /// whose stock is an id where the reactor reads a definition.
    static func answer(_ request: [String: Any]) throws -> Data {
        var body = request
        body["stock"] = nil
        // An unstated medium is the editor's, as the develop reads it (`WebNativeEdit.document`).
        if body["medium"] as? String == nil { body["medium"] = PrintPaper.editorDefault.id }
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
        return Plan(json: json, configuration: result.configuration, renderMedium: result.renderMedium,
                    crop: HostPlatform.current.frames == nil ? nil : result.crop)
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
    /// where the platform draws no frames. With `edge` the pixels are a developed piece of film
    /// larger than the photograph (`PrintFrameRenderer.render(_:configuration:edge:)`).
    static func frame(_ pixels: [UInt8], width: Int, height: Int, plan: Plan,
                      edge: UnexposedEdge.Margins? = nil) -> (pixels: [UInt8], width: Int, height: Int)? {
        HostPlatform.current.frames?.frame(pixels, width: width, height: height,
                                           configuration: plan.configuration, edge: edge)
    }

    /// The film a Film Border develops around a photograph of this size: its whole strip, on a
    /// platform that draws frames (`PrintFramePlacement.filmStrip`). Nil keeps the drawn rebate.
    /// A develop request for the part of a `width` × `height` photograph `crop` keeps: its subject
    /// selection's point, which is on the whole photograph, moved onto the crop.
    static func cropped(_ body: inout [String: Any], to crop: PrintFramePlacement.Rect,
                        width: Int, height: Int) {
        guard var edit = body["edit"] as? [String: Any],
              var selective = edit["selective"] as? [String: Any],
              let point = selective["point"] as? [Double], point.count == 2 else { return }
        selective["point"] = [(point[0] * Double(width) - crop.x) / crop.width,
                              (point[1] * Double(height) - crop.y) / crop.height]
        edit["selective"] = selective
        body["edit"] = edit
    }

    static func strip(_ plan: Plan, width: Int, height: Int) -> UnexposedEdge.Margins? {
        guard HostPlatform.current.frames != nil else { return nil }
        return PrintFramePlacement.filmStrip(width: width, height: height,
                                             configuration: plan.configuration)
    }
}
