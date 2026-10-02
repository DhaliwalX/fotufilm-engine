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
                         // A colour negative's `reads` let them balance its records too.
                         let stops = (0...512).map { -12 + Float($0) * 24 / 512 }
                         var meter: [String: Any] = ["min": -12.0, "max": 12.0,
                             "adjustments": stops.map { stops -> [Float] in
                                 let levels = style.receiverLevels(for: stock,
                                                                   sceneHighlightStops: stops)
                                 return [levels.scale / fixed.scale, levels.shift - fixed.shift]
                             }]
                         // A negative's film is given more exposure where its shadows sit on
                         // the base.
                         if !stock.isReversal, !stock.isReflectionPrint { meter["placesFilm"] = true }
                         if DigitalReferenceStyle.autoLevelsColourRead(for: stock, stops: 0) != nil {
                             meter["reads"] = stops.map {
                                 DigitalReferenceStyle.autoLevelsColourRead(for: stock, stops: $0)!
                             }
                         }
                         conversion["meter"] = meter
                     }
                     return conversion
                 }
             }
             if medium == .labScan && !stock.isReversal && !stock.isReflectionPrint {
                 // Lab Scan's per-frame levels, a contrast per record and a shift, solved before
                 // the edit's exposure on the backlight-adjusted highlight, and the green reads
                 // its density is keyed on the median with.
                 let masking = SIMD3(stock.printingContrastScale(correction: 0, paper: .labScan))
                 let stops = (0...512).map { -6 + Float($0) * 18 / 512 }
                 entry["meter"] = ["min": -6.0, "max": 12.0, "labScan": true,
                     "keyShare": LabScanTiming.keyShare,
                     "adjustments": stops.map { stops -> [Float] in
                         let levels = LabScanTiming.levels(
                             for: stock, sceneHighlightStops: stops, masking: masking)
                         return [levels.scale.x, levels.scale.y, levels.scale.z, levels.shift]
                     },
                     "reads": stops.map { masking.y * LabScanTiming.keyRead(for: stock, stops: $0) }]
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
