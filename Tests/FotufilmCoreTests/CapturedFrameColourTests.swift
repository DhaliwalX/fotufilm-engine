#if canImport(CoreVideo)
import XCTest
import CoreVideo
@testable import FotufilmImaging

final class CapturedFrameColourTests: XCTestCase {
    private typealias Attachments = CapturedFrameColour.Attachments

    private var wellFormedHLG: Attachments {
        Attachments(yCbCrMatrix: CapturedFrameColour.rec2020Matrix,
                    colorPrimaries: CapturedFrameColour.rec2020Primaries,
                    transferFunction: CapturedFrameColour.hlgTransferFunction)
    }

    func testAWellFormedHLGFrameIsAccepted() {
        XCTAssertTrue(CapturedFrameColour.isCompatible(wellFormedHLG, with: .hlg))
    }

    func testAFrameThatSaysNothingIsNotHLG() {
        XCTAssertFalse(
            CapturedFrameColour.isCompatible(Attachments(), with: .hlg),
            "a frame with no colour attachments at all passed as HLG")
        var noTransfer = wellFormedHLG
        noTransfer.transferFunction = nil
        XCTAssertFalse(
            CapturedFrameColour.isCompatible(noTransfer, with: .hlg),
            "a frame that never said it was HLG passed as HLG")
    }

    func testAContradictingTransferFunctionIsRejected() {
        var wrong = wellFormedHLG
        wrong.transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2 as String
        XCTAssertFalse(CapturedFrameColour.isCompatible(wrong, with: .hlg))
    }

    func testDescribingAttachmentsMayBeAbsentButNotWrong() {
        var quiet = wellFormedHLG
        quiet.colorPrimaries = nil
        quiet.yCbCrMatrix = nil
        XCTAssertTrue(CapturedFrameColour.isCompatible(quiet, with: .hlg),
                      "an HLG frame was rejected for not restating its primaries")

        var wrongPrimaries = wellFormedHLG
        wrongPrimaries.colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        XCTAssertFalse(CapturedFrameColour.isCompatible(wrongPrimaries, with: .hlg))

        var wrongMatrix = wellFormedHLG
        wrongMatrix.yCbCrMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        XCTAssertFalse(CapturedFrameColour.isCompatible(wrongMatrix, with: .hlg))
    }

    func testALogFrameIsNotReadAsHLG() throws {
        guard #available(iOS 17.2, macOS 14.2, *) else {
            throw XCTSkip("the log transfer key needs iOS 17.2 / macOS 14.2")
        }
        var log = wellFormedHLG
        log.logTransferFunction = CapturedFrameColour.appleLogTransferFunction
        XCTAssertFalse(CapturedFrameColour.isCompatible(log, with: .hlg))
    }

    func testAppleLogNeedsItsOwnKeyStated() throws {
        guard #available(iOS 17.2, macOS 14.2, *) else {
            throw XCTSkip("the log transfer key needs iOS 17.2 / macOS 14.2")
        }
        let stated = Attachments(
            yCbCrMatrix: CapturedFrameColour.rec2020Matrix,
            logTransferFunction: CapturedFrameColour.appleLogTransferFunction)
        XCTAssertTrue(CapturedFrameColour.isCompatible(stated, with: .appleLog))

        XCTAssertFalse(
            CapturedFrameColour.isCompatible(Attachments(), with: .appleLog),
            "a frame that never said it was Apple Log passed as Apple Log")
        XCTAssertFalse(
            CapturedFrameColour.isCompatible(wellFormedHLG, with: .appleLog),
            "an HLG frame passed as Apple Log")
    }

    func testNoFrameIsBothReadings() throws {
        guard #available(iOS 17.2, macOS 14.2, *) else {
            throw XCTSkip("the log transfer key needs iOS 17.2 / macOS 14.2")
        }
        let candidates = [
            wellFormedHLG,
            Attachments(yCbCrMatrix: CapturedFrameColour.rec2020Matrix,
                        logTransferFunction:
                            CapturedFrameColour.appleLogTransferFunction),
            Attachments(),
        ]
        for attachments in candidates {
            let hlg = CapturedFrameColour.isCompatible(attachments, with: .hlg)
            let log = CapturedFrameColour.isCompatible(attachments, with: .appleLog)
            XCTAssertFalse(hlg && log, "\(attachments) passed as both readings")
        }
    }
}
#endif
