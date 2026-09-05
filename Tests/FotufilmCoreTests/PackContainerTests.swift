import XCTest
@testable import FotufilmCore

final class PackContainerTests: XCTestCase {
    private let key = FilmPackKey.random()

    func testPluginStockDirectoryIsLoadedOutsideTheMainBundle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = FilmStockPack.embeddedStockDirectories
        defer {
            FilmStockPack.embeddedStockDirectories = previous
            try? FileManager.default.removeItem(at: directory)
        }
        let id = "plugin-resource-" + UUID().uuidString
        try JSONEncoder().encode(sample(id: id))
            .write(to: directory.appendingPathComponent("film.json"))
        FilmStockPack.embeddedStockDirectories = [directory]
        let paths = FilmStockPack.searchPaths
        let embeddedIndex = try XCTUnwrap(paths.firstIndex(of: directory))
        let localIndex = try XCTUnwrap(paths.firstIndex(of:
            URL(fileURLWithPath: "Stocks", isDirectory: true)))
        XCTAssertLessThan(embeddedIndex, localIndex)
        let pack = try FilmStockPack.load(sealed: [], bundled: [])
        XCTAssertEqual(pack.stocks[id]?.name, "Sample \(id)")

        let customDirectory = directory.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        var custom = sample(id: id)
        custom.name = "Custom override"
        try JSONEncoder().encode(custom)
            .write(to: customDirectory.appendingPathComponent("film.json"))
        let previousEnvironment = ProcessInfo.processInfo.environment["FOTUFILM_STOCKS"]
        defer {
            if let previousEnvironment { setenv("FOTUFILM_STOCKS", previousEnvironment, 1) }
            else { unsetenv("FOTUFILM_STOCKS") }
        }
        setenv("FOTUFILM_STOCKS", customDirectory.path, 1)
        let overridden = try FilmStockPack.load(sealed: [], bundled: [])
        XCTAssertEqual(overridden.stocks[id]?.name, "Custom override")
    }

    private func keyring() -> FilmPackKeyring {
        let ring = FilmPackKeyring()
        for kind in [FilmPackKind.vault, .community, .local] {
            ring.register(key, kind: kind, id: 1)
        }
        return ring
    }

    private func sample(id: String) -> FilmStockDefinition {
        FilmStockDefinition(
            id: id,
            stock: FilmStock(
                name: "Sample \(id)",
                sensitivity: [[0.9, 0.1, 0], [0.2, 0.7, 0.1], [0, 0.05, 0.95]],
                spectralProfile: .color(peaksNM: [650, 550, 450],
                                        dyeFamily: .kodakNegative),
                curves: (0..<3).map { _ in
                    CharacteristicCurve(dMin: 0.2, gamma: 0.6, toe: -1.2,
                                        toeWidth: 0.24, shoulder: 4.2,
                                        shoulderWidth: 1.2,
                                        secondary: CharacteristicCurveComponent(
                                            gamma: 0.15, toe: -0.4, toeWidth: 0.18,
                                            shoulder: 1.6, shoulderWidth: 0.3))
                },
                emulsionDiffusionMM: [0.009, 0.008, 0.007],
                emulsionDiffusionSecondaryMM: [0.003, 0.0025, 0.002],
                emulsionDiffusionPrimaryShare: [0.4, 0.5, 0.6],
                couplerInhibition: [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
                couplerReleaseGamma: [1.2, 1.4, 1.6],
                couplerDiffusionMM: 0.08,
                grainStrength: 0.012,
                grainSizeMM: 0.005,
                grainLayerWeights: [0.7, 1, 1.35],
                halationStrength: [0.05, 0.02, 0.008],
                halationReturnMatrix: [[0.0012, 0, 0.00003],
                                       [0.000002, 0.00002, 0],
                                       [0, 0, 0]],
                paperCurve: CharacteristicCurve(dMin: 0.07, gamma: 2.6, toe: -0.52,
                                                toeWidth: 0.16, shoulder: 0.42,
                                                shoulderWidth: 0.14)))
    }

    func testOnlyTheCurrentSchemaAndSpectralGridAreAccepted() throws {
        for version in [-1, 0, FilmStockDefinition.currentSchemaVersion + 1] {
            var definition = sample(id: "bad-version")
            definition.schemaVersion = version
            XCTAssertThrowsError(try definition.validate())
        }
        for count in [41, 80, 82] {
            var definition = sample(id: "bad-grid")
            definition.spectral = .samples(
                layerSensitivity: Array(repeating: Array(repeating: 0.1, count: count), count: 3),
                imageDyeDensity: Array(repeating: Array(repeating: 0.1, count: count), count: 3))
            let data = try JSONEncoder().encode(definition)
            let decoded = try JSONDecoder().decode(FilmStockDefinition.self, from: data)
            XCTAssertThrowsError(try decoded.validate())
        }
    }

    func testCouplerGeometryRequiresExplicitInterlayerTransmission() throws {
        let old = Data(#"{"rangeUM":4.2,"release":[0.8,0.7,0.5]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CouplerGeometry.self, from: old))
        let malformed = Data(#"{"interlayerTransmission":[0.3],"release":[0.8,0.7,0.5]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CouplerGeometry.self, from: malformed))
        let geometry = CouplerGeometry(interlayerTransmission: [0.3, 0.35], release: [0.8, 0.7, 0.5])
        let data = try JSONEncoder().encode(geometry)
        XCTAssertEqual(try JSONDecoder().decode(CouplerGeometry.self, from: data), geometry)
    }

    func testRoundTrip() throws {
        var tungsten = sample(id: "one")
        tungsten.referenceIlluminantKelvin = 3200
        let manifest = FilmPackManifest(packID: "test", name: "Test Pack",
                                        author: "Nobody",
                                        stocks: [tungsten, sample(id: "two")])
        let sealed = try FilmPackContainer.seal(manifest, kind: .community,
                                                keyID: 1, key: key)
        let (reopened, head) = try FilmPackContainer.open(sealed, keyring: keyring())

        XCTAssertEqual(head.kind, .community)
        XCTAssertEqual(head.keyID, 1)
        XCTAssertEqual(reopened.packID, "test")
        XCTAssertEqual(reopened.stocks.map(\.id), ["one", "two"])
        let stock = try XCTUnwrap(reopened.stocks.first?.stock)
        XCTAssertEqual(stock.curves[0].secondary?.gamma, 0.15)
        XCTAssertEqual(stock.emulsionDiffusionSecondaryMM, [0.003, 0.0025, 0.002])
        XCTAssertEqual(stock.emulsionDiffusionPrimaryShare, [0.4, 0.5, 0.6])
        XCTAssertEqual(stock.couplerReleaseGamma, [1.2, 1.4, 1.6])
        XCTAssertEqual(stock.referenceIlluminantKelvin, 3200)
        XCTAssertFalse(sealed.contains(Array("peaksNM".utf8)))
        XCTAssertFalse(sealed.contains(Array("Sample one".utf8)))
    }

    func testPackVersionsRoundTripAndRequireNewerApp() throws {
        let manifest = FilmPackManifest(packID: "versioned", name: "Versioned",
            version: "2.1.0", minimumMacAppVersion: "1.10", stocks: [sample(id: "one")])
        let sealed = try FilmPackContainer.seal(manifest, kind: .community, keyID: 1, key: key)
        for current in ["1.10", "1.10.0", "2.0"] {
            let opened = try FilmPackContainer.open(sealed, keyring: keyring(), macAppVersion: current).manifest
            XCTAssertEqual(opened.version, "2.1.0")
            XCTAssertEqual(opened.minimumMacAppVersion, "1.10")
        }
        for current in ["1.9", "1.9.99", "", "unknown"] {
            XCTAssertThrowsError(try FilmPackContainer.open(sealed, keyring: keyring(), macAppVersion: current)) {
                guard case FilmPackRelease.Failure.requiresMacApp("1.10") = $0 else {
                    return XCTFail("Expected an app update notice, got \($0)")
                }
            }
        }
    }

    func testLegacyPacksRemainReadable() throws {
        let manifest = FilmPackManifest(packID: "legacy", name: "Legacy", stocks: [sample(id: "one")])
        let encoded = try JSONEncoder().encode(manifest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["version"])
        XCTAssertNil(json["minimumMacAppVersion"])
        let sealed = try FilmPackContainer.seal(manifest, kind: .community, keyID: 1, key: key)
        XCTAssertNil(try FilmPackContainer.open(sealed, keyring: keyring(), macAppVersion: "1.0").manifest.version)
    }

    func testCompatibilityIsReadBeforeFutureStockSchema() throws {
        // This structure deliberately cannot decode as a full FilmPackManifest.
        let data = Data(#"{"version":"2.0","minimumMacAppVersion":"9.0","stocks":"future schema"}"#.utf8)
        let release = try JSONDecoder().decode(FilmPackRelease.self, from: data)
        XCTAssertThrowsError(try release.requireMacApp(version: "1.6"))
    }

    func testInvalidReleaseVersionsAreRefused() {
        for version in ["", "1..2", "1.2.3.4", "-1", "1.beta", "１.２", "99999999999999999999999999"] {
            XCTAssertThrowsError(try FilmPackRelease(version: version).validate())
            XCTAssertThrowsError(try FilmPackRelease(minimumMacAppVersion: version).validate())
        }
    }

    func testWrongKeyIsRefused() throws {
        let sealed = try FilmPackContainer.seal(
            FilmPackManifest(packID: "test", name: "Test", stocks: [sample(id: "one")]),
            kind: .community, keyID: 1, key: key)
        let stranger = FilmPackKeyring()
        stranger.register(.random(), kind: .community, id: 1)
        XCTAssertThrowsError(try FilmPackContainer.open(sealed, keyring: stranger))
    }

    func testRelabellingAVaultPackFails() throws {
        var sealed = try FilmPackContainer.seal(
            FilmPackManifest(packID: "ours", name: "Ours", stocks: [sample(id: "one")]),
            kind: .vault, keyID: 1, key: key)
        XCTAssertEqual(try FilmPackContainer.peek(sealed).kind, .vault)

        sealed[5] = FilmPackKind.community.rawValue
        XCTAssertEqual(try FilmPackContainer.peek(sealed).kind, .community)
        XCTAssertThrowsError(try FilmPackContainer.open(sealed, keyring: keyring()))
    }

    func testJunkIsNotReportedAsDamage() {
        let junk = Data("this is not a pack at all".utf8)
        XCTAssertThrowsError(try FilmPackContainer.peek(junk)) { error in
            guard case FilmPackContainer.Failure.notAContainer = error else {
                return XCTFail("expected notAContainer, got \(error)")
            }
        }
    }

    func testVaultStocksCannotBeShared() {
        var pack = FilmStockPack()
        pack.stocks["house-stock"] = sample(id: "house-stock")
        pack.origins["house-stock"] = .vault

        XCTAssertThrowsError(try FilmStockPack.sealForSharing(
            stockIDs: ["house-stock"], packID: "leak", name: "Leak",
            pack: pack, keyring: keyring())) { error in
            guard case FilmStockPack.ExportRefusal.notShareable = error else {
                return XCTFail("expected notShareable, got \(error)")
            }
        }
    }

    func testInstalledStocksCannotBeShared() {
        var pack = FilmStockPack()
        pack.stocks["example"] = sample(id: "example")
        pack.origins["example"] = .installed

        XCTAssertThrowsError(try FilmStockPack.sealForSharing(
            stockIDs: ["example"], packID: "leak", name: "Leak",
            pack: pack, keyring: keyring()))
    }

    func testAuthoredStocksCanBeShared() throws {
        var pack = FilmStockPack()
        pack.stocks["mine.my-film"] = sample(id: "my-film")
        pack.origins["mine.my-film"] = .local(packID: "mine")

        let data = try FilmStockPack.sealForSharing(
            stockIDs: ["mine.my-film"], packID: "sent", name: "Sent",
            pack: pack, keyring: keyring())
        let manifest = try FilmPackContainer.open(data, keyring: keyring()).manifest

        XCTAssertEqual(try FilmPackContainer.peek(data).kind, .community)
        XCTAssertEqual(manifest.stocks.map(\.id), ["my-film"])
    }

    func testVaultPackIsRefusedOutsideTheBundle() throws {
        let sealed = try FilmPackContainer.seal(
            FilmPackManifest(packID: "ours", name: "Ours", stocks: [sample(id: "one")]),
            kind: .vault, keyID: 1, key: key)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stray.\(FilmStockPack.sealedPathExtension)")
        try sealed.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try FilmStockPack.load(sealed: url, trustedVault: false)) { error in
            guard case FilmStockPack.LoadError.refused = error else {
                return XCTFail("expected refused, got \(error)")
            }
        }
    }

    func testMalformedStockIsRejectedRatherThanTrapping() throws {
        var broken = sample(id: "broken")
        broken.spectral = .samples(layerSensitivity: [[0.1, 0.2], [0.1, 0.2], [0.1, 0.2]],
                                   imageDyeDensity: [[0.1, 0.2], [0.1, 0.2], [0.1, 0.2]])
        XCTAssertThrowsError(try broken.validate())
    }

    func testFilmReferenceIlluminantDefaultsToDaylightAndRejectsInvalidValues() throws {
        var daylight = sample(id: "daylight")
        // Simulate an older pack written before this optional field existed.
        daylight.referenceIlluminantKelvin = nil
        XCTAssertNil(daylight.referenceIlluminantKelvin)
        XCTAssertEqual(daylight.stock.referenceIlluminantKelvin, 5500)

        var broken = daylight
        broken.referenceIlluminantKelvin = 1500
        XCTAssertThrowsError(try broken.validate()) { error in
            guard let failure = error as? FilmStockDefinition.ValidationFailure else {
                return XCTFail("expected validation failure, got \(error)")
            }
            XCTAssertEqual(failure.field,
                           "daylight.referenceIlluminantKelvin")
        }
    }

    func testMalformedHalationProfileIsRejectedAtThePackBoundary() {
        var broken = sample(id: "bad-halation-profile")
        broken.halationProfile = HalationProfile(
            roundTripOpticalDepth: [0.8, 1.0],
            angularExponent: [1, 1, 1],
            diffuseShare: [0.1, 0.1, 0.1],
            diffuseSigmaMM: [0.01, 0.01, 0.01],
            bounceRetention: [0.1, 0.1, 0.1])
        XCTAssertThrowsError(try broken.validate()) { error in
            guard let failure = error as? FilmStockDefinition.ValidationFailure else {
                return XCTFail("expected validation failure, got \(error)")
            }
            XCTAssertEqual(failure.field,
                           "bad-halation-profile.halationProfile.roundTripOpticalDepth")
        }
    }

    func testMalformedEstimatedHalationProfileIsRejectedAtThePackBoundary() {
        var broken = sample(id: "bad-estimated-halation-profile")
        broken.estimatedHalationProfile = HalationProfile(
            roundTripOpticalDepth: [0.8, 1.0],
            angularExponent: [1, 1, 1],
            diffuseShare: [0, 0, 0],
            diffuseSigmaMM: [0, 0, 0],
            bounceRetention: [0, 0, 0])
        XCTAssertThrowsError(try broken.validate()) { error in
            guard let failure = error as? FilmStockDefinition.ValidationFailure else {
                return XCTFail("expected validation failure, got \(error)")
            }
            XCTAssertEqual(
                failure.field,
                "bad-estimated-halation-profile.estimatedHalationProfile.roundTripOpticalDepth")
        }
    }

    func testMalformedHalationRecordDepthIsRejectedAtThePackBoundary() {
        var broken = sample(id: "bad-halation-depth")
        broken.halationProfile = HalationProfile(
            roundTripOpticalDepth: [0.8, 1.0, 1.2],
            angularExponent: [1, 1, 1],
            diffuseShare: [0, 0, 0],
            diffuseSigmaMM: [0, 0, 0],
            bounceRetention: [0, 0, 0],
            recordDepthMM: [0, 0.006])
        XCTAssertThrowsError(try broken.validate()) { error in
            guard let failure = error as? FilmStockDefinition.ValidationFailure else {
                return XCTFail("expected validation failure, got \(error)")
            }
            XCTAssertEqual(failure.field,
                           "bad-halation-depth.halationProfile.recordDepthMM")
        }
    }

    func testStockCoatingMoreLayersThanTheRendererCarriesIsRejectedWithAReason() throws {
        var extraLayer = sample(id: "four-layer")
        let fourth = extraLayer.curves[1]
        extraLayer.curves.append(fourth)

        XCTAssertThrowsError(try extraLayer.validate()) { error in
            guard let failure = error as? FilmStockDefinition.ValidationFailure else {
                return XCTFail("expected a named validation failure, got \(error)")
            }
            XCTAssertEqual(failure.field, "four-layer.curves")
            XCTAssertTrue(failure.reason.contains("4 dye-forming capture layers"),
                          "the reason should say what it counted: \(failure.reason)")
            XCTAssertTrue(failure.reason.contains("donorLayers"),
                          "the reason should point at the donor path: \(failure.reason)")
        }

        // And the per-layer fields are checked against that declared count, so a stock whose
        // layer count is supported but whose per-layer arrays disagree still fails by name.
        var ragged = sample(id: "ragged")
        ragged.halationStrength = [0.01, 0.01]
        XCTAssertThrowsError(try ragged.validate()) { error in
            guard let failure = error as? FilmStockDefinition.ValidationFailure else {
                return XCTFail("expected a named validation failure, got \(error)")
            }
            XCTAssertEqual(failure.field, "ragged.halationStrength")
        }
    }

    func testDonorLayerValidation() throws {
        func donor(inhibition: [Float] = [0.6, 0, 0],
                   releaseGamma: Float = 1.8,
                   samples: Int = SpectralGrid.count)
            -> FilmStockDefinition.DonorLayerSpec {
            var sensitivity = [Float](repeating: 0, count: samples)
            if !sensitivity.isEmpty { sensitivity[samples / 2] = 1 }
            let layer = DonorCaptureLayer(
                name: "CL", sensitivity: sensitivity,
                curve: sample(id: "x").curves[1].curve,
                inhibition: inhibition, releaseGamma: releaseGamma, depthUM: 11)
            return FilmStockDefinition.DonorLayerSpec(layer)
        }

        var one = sample(id: "one-donor")
        one.donorLayers = [donor()]
        XCTAssertNoThrow(try one.validate())

        var two = sample(id: "two-donors")
        two.donorLayers = [donor(), donor()]
        XCTAssertThrowsError(try two.validate()) { error in
            guard let failure = error as? FilmStockDefinition.ValidationFailure else {
                return XCTFail("expected a named validation failure, got \(error)")
            }
            XCTAssertEqual(failure.field, "two-donors.donorLayers")
        }

        var ragged = sample(id: "ragged-donor")
        ragged.donorLayers = [donor(samples: 12)]
        XCTAssertThrowsError(try ragged.validate()) { error in
            guard let failure = error as? FilmStockDefinition.ValidationFailure else {
                return XCTFail("expected a named validation failure, got \(error)")
            }
            XCTAssertEqual(failure.field, "ragged-donor.donorLayers[0].sensitivity")
        }

        var negative = sample(id: "negative-donor")
        negative.donorLayers = [donor(inhibition: [-0.1, 0, 0])]
        XCTAssertThrowsError(try negative.validate())

        var invalidGamma = sample(id: "invalid-donor-gamma")
        invalidGamma.donorLayers = [donor(releaseGamma: 0)]
        XCTAssertThrowsError(try invalidGamma.validate())
    }

    func testCouplerReleaseGammaValidation() {
        var ragged = sample(id: "ragged-release-gamma")
        ragged.couplerReleaseGamma = [1.8, 1.8]
        XCTAssertThrowsError(try ragged.validate()) { error in
            guard let failure = error as? FilmStockDefinition.ValidationFailure else {
                return XCTFail("expected a named validation failure, got \(error)")
            }
            XCTAssertEqual(failure.field, "ragged-release-gamma.couplerReleaseGamma")
        }

        var invalid = sample(id: "invalid-release-gamma")
        invalid.couplerReleaseGamma = [1.8, 0, 1.8]
        XCTAssertThrowsError(try invalid.validate())
    }

    func testPlainJSONLoaderRunsPhysicalValidation() throws {
        var broken = sample(id: "broken")
        broken.couplerInhibition[0][1] = -0.1
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONEncoder().encode(broken).write(
            to: directory.appendingPathComponent("broken.json"))

        XCTAssertThrowsError(try FilmStockPack.load(directory: directory)) { error in
            guard case FilmStockPack.LoadError.malformed = error else {
                return XCTFail("expected malformed stock, got \(error)")
            }
        }
    }

    func testInhibitorsCannotPromoteOrPassMoreThanTheyReceive() {
        var matrix = sample(id: "matrix")
        matrix.couplerInhibition[2][0] = -0.01
        XCTAssertThrowsError(try matrix.validate())

        // A barrier is a fraction that survives the crossing. Above 1 it would hand the next layer
        // more inhibitor than reached it. (Exactly 0 is legal — that is a sealed interlayer.)
        var amplifying = sample(id: "amplifying-interlayer")
        amplifying.couplerGeometry = CouplerGeometry(
            interlayerTransmission: [1.4, 0.5], release: [0.8, 0.7, 0.6])
        XCTAssertThrowsError(try amplifying.validate())

        var negativeRelease = sample(id: "negative-release")
        negativeRelease.couplerGeometry = CouplerGeometry(
            interlayerTransmission: CouplerGeometry.transmission(forRangeUM: 4.2),
            release: [0.8, -0.1, 0.6])
        XCTAssertThrowsError(try negativeRelease.validate())
    }

    func testNonFiniteValuesAreRejected() {
        var broken = sample(id: "broken")
        broken.grainStrength = .nan
        XCTAssertThrowsError(try broken.validate())

        var alsoBroken = sample(id: "also")
        alsoBroken.halationStrength = [.infinity, 0, 0]
        XCTAssertThrowsError(try alsoBroken.validate())
    }

    func testGrainSizeApproachingZeroIsRejected() {
        var broken = sample(id: "broken")
        broken.grainSizeMM = 1e-9
        XCTAssertThrowsError(try broken.validate())
    }

    func testIdsCannotEscapeTheirDirectory() {
        var broken = sample(id: "../../etc/passwd")
        broken.id = "../../etc/passwd"
        XCTAssertThrowsError(try broken.validate())
    }

    func testAValidStockPasses() throws {
        try sample(id: "fine").validate()
    }
}
