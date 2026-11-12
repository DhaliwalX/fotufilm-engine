import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class WebNativeEditNegativeReadingTests: XCTestCase {
    private typealias Negative = WebNativeEdit.Negative

    private let border = SIMD3<Float>(0.4, 0.6, 0.2)
    private let dense = SIMD3<Float>(1.1, 1.0, 0.9)
    private let roll = ApproximateNegativeScan.RollBalance(
        colour: [0.94, 1.08], frames: 12, level: 1.2, slopes: [0.9, 1.1])

    private func stock(_ id: String = "gold200") throws -> FilmStock {
        try XCTUnwrap(FilmStock.presets[id], "stock \(id) is not installed")
    }

    func testAnEditSavedWithTheFirstReadingKeepsIt() throws {
        let stock = try stock()
        let edits = [
            Negative(), Negative(crosstalk: 0.6, scanLight: .screen),
            Negative(roll: roll, crosstalk: 1),
            // What only the current reading takes changes nothing of the first.
            Negative(roll: roll, crosstalk: 0.4, reading: 1, camera: "scanner",
                     balance: ApproximateNegativeScan.BalanceMode.none, neutral: [0.05, 0.06, 0.03]),
        ]
        for edit in edits {
            XCTAssertFalse(edit.readsModel)
            let rolled = ApproximateNegativeScan.denseEnd(dense, roll: edit.roll)
            XCTAssertEqual(
                edit.balance(stock: stock, border: border, denseEnd: dense),
                ApproximateNegativeScan.balance(stock: stock, denseEnd: rolled, correction: edit.correction))
            XCTAssertEqual(edit.plain(border: border, denseEnd: dense),
                           PlainNegativeScan(border: border, denseEnd: rolled, correction: edit.correction))
            XCTAssertEqual(
                edit.balance(stock: stock, border: border, denseEnd: nil),
                ApproximateNegativeScan.balance(stock: stock, denseEnd: nil, correction: edit.correction))
        }
    }

    func testTheCurrentReadingIsTheScanModelsThroughTheEditsSetup() throws {
        let stock = try stock()
        let neutral: [Float] = [0.05, 0.06, 0.03]
        let picked = SIMD3<Float>((0..<3).map { -log10(neutral[$0] / border[$0]) })
        let source = NegativeScanSource(kelvin: 5200)
        typealias Mode = ApproximateNegativeScan.BalanceMode
        let cases: [(Negative, NegativeScanSetup, Float, Mode, SIMD3<Float>?)] = [
            (Negative(reading: 2), NegativeScanSetup(light: .white, camera: .generic), 1, .frame, nil),
            (Negative(roll: roll, crosstalk: 0.5, scanLight: .screen, reading: 2, camera: "scanner",
                      balance: .roll, neutral: neutral),
             NegativeScanSetup(light: .screen, camera: .scanner), 0.5, .roll, picked),
            (Negative(roll: roll, crosstalk: 0, scanLight: .rgb, reading: 2,
                      balance: ApproximateNegativeScan.BalanceMode.none),
             NegativeScanSetup(light: .rgb, camera: .generic), 0, .none, nil),
            (Negative(reading: 2, neutral: neutral),
             NegativeScanSetup(light: .white, camera: .generic), 1, .frame, picked),
        ]
        for (edit, setup, separation, mode, picked) in cases {
            XCTAssertTrue(edit.readsModel)
            XCTAssertEqual(edit.setup(source: source), setup)
            XCTAssertEqual(edit.separation, separation)
            let tones = ApproximateNegativeScan.Tones(denseEnd: dense, picked: picked)
            XCTAssertEqual(edit.tones(border: border, denseEnd: dense), tones)
            XCTAssertEqual(
                edit.balance(stock: stock, border: border, denseEnd: dense, source: source),
                ApproximateNegativeScan.balance(stock: stock, setup: setup, separation: separation,
                                                mode: mode, tones: tones, roll: edit.roll))
            XCTAssertEqual(
                edit.plain(border: border, denseEnd: dense, source: source),
                PlainNegativeScan(border: border, setup: setup, separation: separation, mode: mode,
                                  tones: tones, roll: edit.roll))
        }
    }

    func testTheCurrentReadingIsNotTheFirst() throws {
        let stock = try stock()
        XCTAssertNotEqual(Negative(reading: 2).balance(stock: stock, border: border, denseEnd: dense),
                          Negative().balance(stock: stock, border: border, denseEnd: dense))
        XCTAssertNotEqual(Negative(reading: 2).plain(border: border, denseEnd: dense),
                          Negative().plain(border: border, denseEnd: dense))
    }

    func testTheSetupIsTheEditsLightAndCameraElseWhatTheFileSays() throws {
        XCTAssertEqual(Negative(reading: 2).setup(), NegativeScanSetup(light: .white, camera: .generic))
        XCTAssertEqual(Negative(scanLight: .halogen, reading: 2, camera: "scanner").setup(),
                       NegativeScanSetup(light: .halogen, camera: .scanner))
        // A file that names a measured camera and its decoder's matrix is read as that camera,
        // unless the edit says what took the scan.
        let profile = try XCTUnwrap(CameraSpectralProfileStore.profile(id: "sony-ilce-7cm2"))
        let source = NegativeScanSource(
            camera: CameraIdentity(spectralProfileID: profile.id), kelvin: 5400, white: [0.34, 0.36],
            matrix: [1.18, -0.09, -0.09, -0.04, 1.52, -0.48, 0.01, -0.25, 1.24])
        XCTAssertEqual(Negative(reading: 2).setup(source: source).camera, .profile(profile.id))
        XCTAssertEqual(Negative(reading: 2).setup(source: source), source.setup(light: .white))
        XCTAssertEqual(Negative(reading: 2, camera: "generic").setup(source: source),
                       NegativeScanSetup(light: .white, camera: .generic))
    }

    func testANeutralThatCannotBeReadIsNotPicked() {
        for neutral in [[0.05, 0.06], [0.05, 0, 0.03], [0.05, .nan, 0.03]] as [[Float]] {
            XCTAssertNil(Negative(reading: 2, neutral: neutral).tones(border: border, denseEnd: dense).picked)
        }
        XCTAssertNil(Negative(reading: 2, neutral: [0.05, 0.06, 0.03])
            .tones(border: SIMD3(0.4, 0, 0.2), denseEnd: dense).picked)
        XCTAssertNil(Negative(reading: 2).tones(border: border, denseEnd: nil).denseEnd)
    }

    /// The stray light a reading takes off: the edit's share of the frame's light, or what
    /// the scan's holder shows where the edit leaves it to be measured.
    func testAnEditsFlareIsItsShareOfTheFramesLightElseTheHolders() throws {
        let border = SIMD3<Float>(0.8, 0.45, 0.2), light = SIMD3<Float>(0.2, 0.1, 0.04)
        let holder = SIMD3<Float>(0.001, 0.0006, 0.0002)
        typealias Negative = WebNativeEdit.Negative
        func stray(_ edit: Negative, holder: SIMD3<Float>? = holder) -> SIMD3<Float> {
            edit.strayLight(border: border, frameLight: light, holder: holder)
        }
        XCTAssertEqual(stray(Negative(reading: 2)), holder)
        XCTAssertEqual(stray(Negative(reading: 2), holder: nil), .zero)
        XCTAssertEqual(stray(Negative(reading: 2, flare: 0.01)), light * 0.01)
        XCTAssertEqual(stray(Negative(reading: 2, flare: 0)), .zero)
        XCTAssertEqual(Negative(reading: 2, flare: 0.01)
            .strayLight(border: border, frameLight: nil, holder: holder), .zero)
        // The first reading takes none off, whatever it is handed.
        XCTAssertEqual(stray(Negative(flare: 0.01)), .zero)
        XCTAssertEqual(stray(Negative()), .zero)
        // No more than a reading takes, and nothing that is not a number.
        XCTAssertEqual(stray(Negative(reading: 2), holder: SIMD3(0.7, .nan, -1)),
                       SIMD3(ApproximateNegativeScan.flareLimit * 0.8, 0, 0))

        // An edit keeps its flare, and one it could not have is refused.
        let kept = try JSONDecoder().decode(
            Negative.self, from: JSONEncoder().encode(Negative(reading: 2, flare: 0.0125)))
        XCTAssertEqual(kept.flare, 0.0125)
        XCTAssertNil(try JSONDecoder().decode(Negative.self, from: Data(#"{"flare":null}"#.utf8)).flare)
        for invalid in [#"{"flare":0.03}"#, #"{"flare":-0.01}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(Negative.self, from: Data(invalid.utf8)))
        }
        XCTAssertNotEqual(Negative(reading: 2, flare: 0.01).readingKey, Negative(reading: 2).readingKey)

        // A picked neutral is read net of the stray light, as the scan's samples are.
        let picked = Negative(reading: 2, neutral: [0.2, 0.1, 0.05])
        let tones = picked.tones(border: border, denseEnd: nil, flare: holder)
        let read = try XCTUnwrap(tones.picked)
        for c in 0..<3 {
            XCTAssertEqual(read[c], -log10(([0.2, 0.1, 0.05][c] - holder[c]) / (border[c] - holder[c])),
                           accuracy: 1e-6)
        }
        XCTAssertNil(picked.tones(border: border, denseEnd: nil, flare: SIMD3(0.3, 0, 0)).picked)
    }

    func testEditsThatReadAlikeShareAKeyAndOthersDoNot() {
        let base = Negative(roll: roll, crosstalk: 0.5, scanLight: .screen, reading: 2, camera: "scanner",
                            balance: .roll, neutral: [0.05, 0.06, 0.03])
        // What a reading does not turn on leaves the key alone.
        var same = base
        same.border = [0.4, 0.6, 0.2]
        same.lightFrame = "lamp"
        same.attachments = ["notes": Data([1])]
        XCTAssertEqual(same.readingKey, base.readingKey)
        var changes: [Negative] = []
        for change in [
            { $0.reading = nil }, { $0.camera = nil }, { $0.balance = .frame }, { $0.neutral = nil },
            { $0.neutral = [0.05, 0.06, 0.031] }, { $0.roll = nil }, { $0.roll?.colour = [0.94, 1.09] },
            { $0.roll?.level = 1.3 }, { $0.roll?.slopes = nil }, { $0.crosstalk = nil },
            { $0.crosstalk = 0.6 }, { $0.scanLight = nil },
        ] as [(inout Negative) -> Void] {
            var changed = base
            change(&changed)
            changes.append(changed)
        }
        XCTAssertEqual(Set(changes.map(\.readingKey) + [base.readingKey]).count, changes.count + 1)
    }
}
