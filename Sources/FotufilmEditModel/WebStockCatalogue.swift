import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// The film library as the web editor reads it (`web/src/stock-index.js`): each film's name, its
/// output media, and its settings catalogue. The browser build writes these as files
/// (tools/build-wasm.sh); a native host answers them from the loaded packs.
public enum WebStockCatalogue {
    /// Output media for one film, with the screen conversions a negative offers.
    public static func media(for stock: FilmStock) -> [String: Any] {
        ["default": PrintPaper.default(for: stock).id,
         "choices": PrintPaper.choices(for: stock).map { medium -> [String: Any] in
             var entry: [String: Any] = ["id": medium.id, "name": medium.name, "detail": medium.detail]
             if medium == .screen && !stock.isReflectionPrint {
                 let fixed = DigitalReferenceStyle.autoLevels.receiverLevels(for: stock)
                 entry["screenConversions"] = DigitalReferenceStyle.allCases.map { style -> [String: Any] in
                     var conversion: [String: Any] = ["id": style.id, "name": style.name, "detail": style.detail]
                     if style == .autoLevels {
                         // Native-solved affine samples; browser hosts interpolate the small table
                         // rather than reproducing film characteristic curves in JavaScript.
                         conversion["meter"] = ["min": 0.5, "max": 12.0,
                             "adjustments": (0...512).map { i -> [Float] in
                                 let levels = style.receiverLevels(for: stock,
                                     sceneHighlightStops: 0.5 + Float(i) * 11.5 / 512)
                                 return [levels.scale / fixed.scale, levels.shift - fixed.shift]
                             }]
                     }
                     return conversion
                 }
             }
             return entry
         }]
    }

    /// Every loaded film as one merged `loadStockIndex` entry, in id order, for a native host. Its
    /// default medium is an editor edit's, Digital Reference as the Mac app's editor opens a film
    /// on it, which is what a host develops when the edit names none (`WebNativeEdit.document`).
    /// The browser's own catalogue keeps the medium its base pack was built on.
    public static func entries() throws -> [[String: Any]] {
        let stocks = FilmStock.presets
        let definitions = FilmStock.presetDefinitions
        let profiles = try JSONSerialization.jsonObject(
            with: WebProfileCatalogue.data(definitions)) as? [String: Any] ?? [:]
        return stocks.keys.sorted().compactMap { id in
            guard let stock = stocks[id], let profile = profiles[id] as? [String: Any] else { return nil }
            let media = media(for: stock)
            var entry: [String: Any] = [
                "id": id, "name": stock.name, "layeredTransport": stock.donorLayers.isEmpty,
                "profile": profile, "available": profile["available"] ?? [],
                "media": media["choices"]!,
                "defaultMedium": PrintPaper.editorDefault.resolved(for: stock).id,
                // What Match Film prints on: the film's own medium, and whether it has only that.
                "filmMedium": PrintPaper.default(for: stock).id,
                "reflectionPrint": stock.isReflectionPrint,
            ]
            if let format = profile["nativeFormat"] { entry["nativeFormat"] = format }
            return entry
        }
    }
}
