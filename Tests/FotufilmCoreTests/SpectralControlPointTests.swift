import XCTest
@testable import FotufilmCore

final class SpectralControlPointTests: XCTestCase {

    // MARK: - Resampling

    func testResampledPassesThroughItsHandles() {
        let points = [SpectralControlPoint(nm: 380, value: 0),
                      SpectralControlPoint(nm: 550, value: 0.8),
                      SpectralControlPoint(nm: 780, value: 0.1)]
        let row = SpectralCurve.resampled(points)
        XCTAssertEqual(row.count, SpectralGrid.count)
        XCTAssertEqual(row[0], 0, accuracy: 1e-6)
        XCTAssertEqual(row[17], 0.8, accuracy: 1e-6)   // 550 nm is grid slot 17
        XCTAssertEqual(row[40], 0.1, accuracy: 1e-6)
    }

    func testResampledNeverOvershoots() {
        let points = [SpectralControlPoint(nm: 380, value: 0),
                      SpectralControlPoint(nm: 490, value: 0),
                      SpectralControlPoint(nm: 500, value: 1),
                      SpectralControlPoint(nm: 510, value: 0),
                      SpectralControlPoint(nm: 780, value: 0)]
        let row = SpectralCurve.resampled(points)
        for value in row {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1 + 1e-6)
        }
    }

    func testResampledHoldsBeyondTheEnds() {
        let points = [SpectralControlPoint(nm: 500, value: 0.4),
                      SpectralControlPoint(nm: 600, value: 0.6)]
        let row = SpectralCurve.resampled(points)
        XCTAssertEqual(row[0], 0.4, accuracy: 1e-6)
        XCTAssertEqual(row[40], 0.6, accuracy: 1e-6)
    }

    func testResampledSortsAndSurvivesDegenerateInput() {
        XCTAssertEqual(SpectralCurve.resampled([]),
                       [Float](repeating: 0, count: SpectralGrid.count))
        XCTAssertEqual(SpectralCurve.resampled([SpectralControlPoint(nm: 550, value: 0.5)]),
                       [Float](repeating: 0.5, count: SpectralGrid.count))
        // Unordered handles describe the same curve as ordered ones.
        let ordered = SpectralCurve.resampled([
            SpectralControlPoint(nm: 400, value: 0.2),
            SpectralControlPoint(nm: 600, value: 0.9)])
        let shuffled = SpectralCurve.resampled([
            SpectralControlPoint(nm: 600, value: 0.9),
            SpectralControlPoint(nm: 400, value: 0.2)])
        XCTAssertEqual(ordered, shuffled)
        // Two handles on one wavelength collapse instead of folding the curve.
        let collapsed = SpectralCurve.resampled([
            SpectralControlPoint(nm: 550, value: 0.1),
            SpectralControlPoint(nm: 550, value: 0.9)])
        XCTAssertEqual(collapsed, [Float](repeating: 0.9, count: SpectralGrid.count))
    }

    // MARK: - Seeding handles from a sampled record

    func testControlPointRoundTripKeepsADoublePeak() {
        let row: [Float] = SpectralGrid.wavelengths.map { nm in
            let a = (nm - 600) / 18, b = (nm - 650) / 14
            return 0.9 * exp(-0.5 * a * a) + exp(-0.5 * b * b)
        }
        let peak = row.max()!
        let scaled = row.map { $0 / peak }

        let handles = SpectralCurve.controlPoints(from: scaled)
        XCTAssertGreaterThanOrEqual(handles.count, 5)
        XCTAssertLessThan(handles.count, SpectralGrid.count,
                          "simplification kept every sample, so it simplified nothing")
        XCTAssertEqual(handles.first?.nm, 380)
        XCTAssertEqual(handles.last?.nm, 780)

        let rebuilt = SpectralCurve.resampled(handles)
        for (index, value) in scaled.enumerated() {
            XCTAssertEqual(rebuilt[index], value, accuracy: 0.05,
                           "band \(index) drifted in the round trip")
        }
        // The two crests specifically survive.
        XCTAssertEqual(rebuilt[22], scaled[22], accuracy: 0.02)   // 600 nm
        XCTAssertEqual(rebuilt[27], scaled[27], accuracy: 0.02)   // 650 nm
    }

    func testPartitionedDyesSumToOneAndPassThroughUnchanged() {
        let raw = [SpectralGrid.wavelengths.map { Float(0.2 + 0.6 * exp(-pow(($0 - 650) / 60, 2))) },
                   SpectralGrid.wavelengths.map { Float(0.3 + 0.5 * exp(-pow(($0 - 550) / 50, 2))) },
                   SpectralGrid.wavelengths.map { Float(0.1 + 0.7 * exp(-pow(($0 - 445) / 45, 2))) }]
        let once = SpectralGrid.partitionedDyes(raw)
        for band in 0..<SpectralGrid.count {
            XCTAssertEqual(once[0][band] + once[1][band] + once[2][band], 1,
                           accuracy: 1e-4)
        }
        let twice = SpectralGrid.partitionedDyes(once)
        for layer in 0..<3 {
            for band in 0..<SpectralGrid.count {
                XCTAssertEqual(twice[layer][band], once[layer][band], accuracy: 1e-4)
            }
        }
    }

    // MARK: - Lineage

    private let key = FilmPackKey.random()

    private func keyring() -> FilmPackKeyring {
        let ring = FilmPackKeyring()
        for kind in [FilmPackKind.vault, .community, .local] {
            ring.register(key, kind: kind, id: 1)
        }
        return ring
    }

    private func sample(id: String, lineage: String? = nil) -> FilmStockDefinition {
        var definition = FilmStockDefinition(
            id: id,
            stock: FilmStock(
                name: "Sample \(id)",
                sensitivity: [[0.9, 0.1, 0], [0.2, 0.7, 0.1], [0, 0.05, 0.95]],
                spectralProfile: .color(peaksNM: [650, 550, 450],
                                        dyeFamily: .kodakNegative),
                curves: (0..<3).map { _ in
                    CharacteristicCurve(dMin: 0.2, gamma: 0.6, toe: -1.2,
                                        toeWidth: 0.24, shoulder: 4.2,
                                        shoulderWidth: 1.2)
                },
                couplerInhibition: [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
                couplerDiffusionMM: 0.08,
                grainStrength: 0.012,
                grainSizeMM: 0.005,
                grainLayerWeights: [0.7, 1, 1.35],
                halationStrength: [0.05, 0.02, 0.008],
                paperCurve: CharacteristicCurve(dMin: 0.07, gamma: 2.6, toe: -0.52,
                                                toeWidth: 0.16, shoulder: 0.42,
                                                shoulderWidth: 0.14)))
        definition.spectralLineage = lineage
        return definition
    }

    func testLineageToAVaultStockRefusesExport() {
        var pack = FilmStockPack()
        pack.stocks["house-stock"] = sample(id: "house-stock")
        pack.origins["house-stock"] = .vault
        pack.stocks["mine.study"] = sample(id: "study", lineage: "house-stock")
        pack.origins["mine.study"] = .local(packID: "mine")

        XCTAssertThrowsError(try FilmStockPack.sealForSharing(
            stockIDs: ["mine.study"], packID: "leak", name: "Leak",
            pack: pack, keyring: keyring())) { error in
            guard case FilmStockPack.ExportRefusal.lineageNotShareable = error else {
                return XCTFail("expected lineageNotShareable, got \(error)")
            }
        }
    }

    func testLineageToAMissingStockRefusesExport() {
        var pack = FilmStockPack()
        pack.stocks["mine.study"] = sample(id: "study", lineage: "gone")
        pack.origins["mine.study"] = .local(packID: "mine")

        XCTAssertThrowsError(try FilmStockPack.sealForSharing(
            stockIDs: ["mine.study"], packID: "leak", name: "Leak",
            pack: pack, keyring: keyring()))
    }

    func testLineageToACommunityStockExports() throws {
        var pack = FilmStockPack()
        pack.stocks["friends.gift"] = sample(id: "gift")
        pack.origins["friends.gift"] = .community(packID: "friends")
        pack.stocks["mine.study"] = sample(id: "study", lineage: "friends.gift")
        pack.origins["mine.study"] = .local(packID: "mine")

        let data = try FilmStockPack.sealForSharing(
            stockIDs: ["mine.study"], packID: "sent", name: "Sent",
            pack: pack, keyring: keyring())
        let manifest = try FilmPackContainer.open(data, keyring: keyring()).manifest
        XCTAssertEqual(manifest.stocks.map(\.id), ["study"])
    }

    func testLineageSurvivesTheCodableTrip() throws {
        let definition = sample(id: "study", lineage: "somewhere.else")
        let data = try JSONEncoder().encode(definition)
        let reopened = try JSONDecoder().decode(FilmStockDefinition.self, from: data)
        XCTAssertEqual(reopened.spectralLineage, "somewhere.else")

        // A pack written before the field existed decodes to no lineage at all.
        var stripped = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        stripped.removeValue(forKey: "spectralLineage")
        let older = try JSONDecoder().decode(
            FilmStockDefinition.self,
            from: JSONSerialization.data(withJSONObject: stripped))
        XCTAssertNil(older.spectralLineage)
    }

    func testLineageIsValidatedLikeAnIdentifier() {
        var broken = sample(id: "fine", lineage: "../escape")
        XCTAssertThrowsError(try broken.validate())
        broken.spectralLineage = "pack.stock-id"
        XCTAssertNoThrow(try broken.validate())
    }

    func testDrawnStyleSamplesValidate() throws {
        let sensitivity = (0..<3).map { layer -> [Float] in
            let centre: Float = [650, 550, 450][layer]
            return SpectralGrid.wavelengths.map {
                exp(-0.5 * pow(($0 - centre) / 40, 2))
            }
        }
        let dyes = SpectralGrid.partitionedDyes(
            SpectralGrid.familyDyeDensities(.kodakNegative))
        var definition = sample(id: "drawn")
        definition.spectral = .samples(layerSensitivity: sensitivity,
                                       imageDyeDensity: dyes)
        try definition.validate()
    }
}
