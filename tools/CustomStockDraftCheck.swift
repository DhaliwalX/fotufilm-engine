import Foundation
import FotufilmCore

@main
struct CustomStockDraftCheck {
    static func main() throws {
        var stock = FilmStock.noFilm
        stock.spectralProfile = .color(peaksNM: [650, 550, 450], dyeFamily: .kodakNegative)
        stock.spectralProfile.minimumDensity = SpectralGrid.wavelengths.map { 0.8 - ($0 - 380) / 800 }
        stock.spectralProfile.imageDyeDensity = stock.spectralProfile.imageDyeDensity.map { $0.map { $0 * 1.7 } }
        let definition = FilmStockDefinition(id: "draft-fixture", stock: stock)
        let draft = CustomStockDraft.recovered(from: definition)
        let decoded = try JSONDecoder().decode(CustomStockDraft.self, from: JSONEncoder().encode(draft))
        let restored = decoded.spectralSpec.profile
        precondition(restored.minimumDensity == stock.spectralProfile.minimumDensity)
        precondition(restored.imageDyeDensity == stock.spectralProfile.imageDyeDensity)
        precondition(restored.layerSensitivity == stock.spectralProfile.layerSensitivity)
        precondition(decoded == draft)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as! [String: Any]
        legacy.removeValue(forKey: "minimumDensitySpectrum")
        let legacyDraft = try JSONDecoder().decode(CustomStockDraft.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyDraft.minimumDensitySpectrum == nil)
        print("Custom stock drafts preserve independent base, absolute dyes and capture samples; older drafts decode.")
    }
}
