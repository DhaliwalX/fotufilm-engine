import CoreGraphics
import Foundation
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

private struct EditKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension EditState: Codable {
    static var cataloguedKeys: [(control: EditorControl, key: String)] {
        EditorControlCatalogue.all.compactMap { control in
            guard case .edit = control.scope, let key = control.persistence.key else { return nil }
            return (control, key)
        }
    }

    static let bespokeKeys: [String] = [
        "stockID", "chosenFormatID", "sourceInterpretation", "captureIlluminantKelvin",
        "filmLightKelvin", "grainMottleShare", "couplerGapReach", "paper", "paperFollowsStock",
        "seed", "shutterSeconds", "printLightKelvin", "enlarger", "rotation", "crop", "cornerCrop",
        "grade", "lensProfileID", "lensAdjustment", "lensFilterIDs", "lensFilterMetering", "selective",
    ]

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EditKey.self)
        for (control, key) in Self.cataloguedKeys {
            let coding = EditKey(key)
            switch control.field.access {
            case .number:
                if let stored = try c.decodeIfPresent(Double.self, forKey: coding) {
                    setStoredValue(stored, of: control.field)
                }
            case .flag:
                if let stored = try c.decodeIfPresent(Bool.self, forKey: coding) {
                    setFlag(stored, of: control.field)
                }
            case .curve:
                if let drawn = try c.decodeIfPresent([Double].self, forKey: coding),
                   drawn.count == curve(of: control.field)?.count {
                    setCurve(drawn, of: control.field)
                }
            case .optionalNumber(let path):
                self[keyPath: path] = try c.decodeIfPresent(Double.self, forKey: coding)
            case .derived, .bespoke, .unstored:
                break
            }
        }
        stockID = try c.decodeIfPresent(String.self, forKey: EditKey("stockID")) ?? stockID
        chosenFormatID = try c.decodeIfPresent(String.self, forKey: EditKey("chosenFormatID"))
        sourceInterpretation = try c.decodeIfPresent(
            FilmSourceInterpretation.self, forKey: EditKey("sourceInterpretation"))
            ?? sourceInterpretation
        captureIlluminantKelvin = try c.decodeIfPresent(Double.self, forKey: EditKey("captureIlluminantKelvin"))
        filmLightKelvin = try c.decodeIfPresent(Double.self, forKey: EditKey("filmLightKelvin"))
        grainMottleShare = try c.decodeIfPresent(Double.self, forKey: EditKey("grainMottleShare"))
        couplerGapReach = try c.decodeIfPresent([Double].self, forKey: EditKey("couplerGapReach"))
            ?? couplerGapReach
        paper = try c.decodeIfPresent(String.self, forKey: EditKey("paper"))
            .flatMap(PrintPaper.preset(id:)) ?? .ektacolorEdge
        paperFollowsStock = try c.decodeIfPresent(Bool.self, forKey: EditKey("paperFollowsStock")) ?? false
        seed = try c.decodeIfPresent(UInt64.self, forKey: EditKey("seed")) ?? seed
        shutterSeconds = try c.decodeIfPresent(Double.self, forKey: EditKey("shutterSeconds"))
        printLightKelvin = try c.decodeIfPresent(Double.self, forKey: EditKey("printLightKelvin"))
        enlarger = try c.decodeIfPresent(String.self, forKey: EditKey("enlarger"))
            .flatMap(Enlarger.preset(id:)) ?? .default
        rotation = ((try c.decodeIfPresent(Int.self, forKey: EditKey("rotation")) ?? rotation) % 4 + 4) % 4
        crop = try c.decodeIfPresent(CGRect.self, forKey: EditKey("crop"))
        cornerCrop = try c.decodeIfPresent(QuadrilateralCrop.self, forKey: EditKey("cornerCrop"))
        if cornerCrop?.isValid == false { cornerCrop = nil }
        grade = try c.decodeIfPresent(ColorGrade.self, forKey: EditKey("grade")) ?? grade
        selective = try c.decodeIfPresent(SelectiveState.self, forKey: EditKey("selective"))?.saved
        lensProfileID = try c.decodeIfPresent(String.self, forKey: EditKey("lensProfileID"))
        lensAdjustment = try c.decodeIfPresent(LensAdjustment.self, forKey: EditKey("lensAdjustment"))
            ?? lensAdjustment
        lensFilterIDs = try c.decodeIfPresent([String].self, forKey: EditKey("lensFilterIDs")) ?? lensFilterIDs
        lensFilterMetering = try c.decodeIfPresent(String.self, forKey: EditKey("lensFilterMetering"))
            .flatMap(LensFilterCompensation.init(rawValue:)) ?? lensFilterMetering
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EditKey.self)
        try c.encodeIfPresent(selective?.saved, forKey: EditKey("selective"))
        for (control, key) in Self.cataloguedKeys {
            let coding = EditKey(key)
            switch control.field.access {
            case .number:
                if let stored = storedValue(of: control.field) { try c.encode(stored, forKey: coding) }
            case .flag:
                if let on = flag(of: control.field) { try c.encode(on, forKey: coding) }
            case .curve:
                if let drawn = curve(of: control.field) { try c.encode(drawn, forKey: coding) }
            case .optionalNumber(let path):
                try c.encodeIfPresent(self[keyPath: path], forKey: coding)
            case .derived, .bespoke, .unstored:
                break
            }
        }
        try c.encode(stockID, forKey: EditKey("stockID"))
        try c.encodeIfPresent(chosenFormatID, forKey: EditKey("chosenFormatID"))
        try c.encode(sourceInterpretation, forKey: EditKey("sourceInterpretation"))
        try c.encodeIfPresent(captureIlluminantKelvin, forKey: EditKey("captureIlluminantKelvin"))
        try c.encodeIfPresent(filmLightKelvin, forKey: EditKey("filmLightKelvin"))
        try c.encodeIfPresent(grainMottleShare, forKey: EditKey("grainMottleShare"))
        try c.encode(couplerGapReach, forKey: EditKey("couplerGapReach"))
        try c.encode(paper.id, forKey: EditKey("paper"))
        try c.encode(paperFollowsStock, forKey: EditKey("paperFollowsStock"))
        try c.encode(seed, forKey: EditKey("seed"))
        try c.encodeIfPresent(shutterSeconds, forKey: EditKey("shutterSeconds"))
        try c.encodeIfPresent(printLightKelvin, forKey: EditKey("printLightKelvin"))
        try c.encode(enlarger.id, forKey: EditKey("enlarger"))
        try c.encode(rotation, forKey: EditKey("rotation"))
        try c.encodeIfPresent(crop, forKey: EditKey("crop"))
        try c.encodeIfPresent(cornerCrop, forKey: EditKey("cornerCrop"))
        try c.encode(grade, forKey: EditKey("grade"))
        try c.encodeIfPresent(lensProfileID, forKey: EditKey("lensProfileID"))
        try c.encode(lensAdjustment, forKey: EditKey("lensAdjustment"))
        try c.encode(lensFilterIDs, forKey: EditKey("lensFilterIDs"))
        try c.encode(lensFilterMetering.rawValue, forKey: EditKey("lensFilterMetering"))
    }
}
