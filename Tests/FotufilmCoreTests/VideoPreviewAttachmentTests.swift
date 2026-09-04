import XCTest
@testable import FotufilmImaging

final class VideoPreviewAttachmentTests: XCTestCase {
    private enum Reading: Equatable { case standard, hlg, appleLog }

    private func plan(attached: Bool, previous: Reading?, reading: Reading,
                      composition: Bool = false, deepInput: Bool = false,
                      declaredHeadroom: Float? = nil)
        -> VideoPreviewAttachment.Plan {
        VideoPreviewAttachment.plan(
            attached: attached, previousReading: previous, reading: reading,
            composition: composition, deepInput: deepInput,
            declaredHeadroom: declaredHeadroom)
    }

    func testANewReadingOfALoadedClipRebuildsTheTap() {
        XCTAssertTrue(
            plan(attached: true, previous: .hlg, reading: .standard).rebuilds,
            """
            switching a loaded clip's interpretation did not rebuild the tap — this is the \
            no-op that left the preview reading the clip the old way
            """)
        XCTAssertTrue(
            plan(attached: true, previous: .standard, reading: .hlg).rebuilds)
    }

    func testTheFirstAttachRebuilds() {
        XCTAssertTrue(
            plan(attached: false, previous: .standard, reading: .standard).rebuilds)
        XCTAssertTrue(plan(attached: false, previous: nil, reading: .hlg).rebuilds)
    }

    func testRepeatingTheReadingAlreadyAttachedDoesNothing() {
        XCTAssertFalse(
            plan(attached: true, previous: .hlg, reading: .hlg).rebuilds)
    }

    func testAReadingThatDeclaresNothingTakesTheHeadroomAway() {
        XCTAssertEqual(
            plan(attached: true, previous: .hlg, reading: .standard,
                 declaredHeadroom: nil).sceneHeadroom, 1,
            """
            a reading that declares no headroom left one standing — an SDR develop metering \
            phantom headroom is exactly the over-darkened preview this came from
            """)
        XCTAssertEqual(VideoPreviewAttachment.sceneHeadroom(declaredBy: nil), 1)
    }

    func testADeclaringReadingCarriesItsCeiling() {
        XCTAssertEqual(
            plan(attached: false, previous: nil, reading: .hlg,
                 declaredHeadroom: PrintEncoding.hdrHeadroom).sceneHeadroom,
            PrintEncoding.hdrHeadroom)
        XCTAssertEqual(
            VideoPreviewAttachment.sceneHeadroom(declaredBy: 2.5), 2.5)
    }

    func testAComposedRoadNeverAsksForTheDeepContainer() {
        XCTAssertFalse(
            plan(attached: false, previous: nil, reading: .standard,
                 composition: true, deepInput: true).deepTap,
            "a composed road asked the decoder for half float")
        XCTAssertTrue(
            plan(attached: false, previous: nil, reading: .hlg,
                 composition: false, deepInput: true).deepTap,
            "an uncomposed deep source was read at eight bits")
        XCTAssertFalse(
            plan(attached: false, previous: nil, reading: .standard,
                 composition: false, deepInput: false).deepTap)
    }

    func testTheCompositionFollowsTheReading() {
        XCTAssertTrue(
            plan(attached: false, previous: nil, reading: .standard,
                 composition: true).usesComposition)
        XCTAssertFalse(
            plan(attached: false, previous: nil, reading: .hlg,
                 composition: false).usesComposition)
    }

    func testALateDescriptionOfAnOlderReadingIsDropped() {
        XCTAssertTrue(VideoPreviewAttachment.accepts(generation: 2, applied: 1))
        XCTAssertFalse(
            VideoPreviewAttachment.accepts(generation: 1, applied: 2),
            "a description of the reading being replaced overwrote the current one")
        XCTAssertFalse(VideoPreviewAttachment.accepts(generation: 1, applied: 1))
        // The first attach, against a develop nothing has described yet.
        XCTAssertTrue(VideoPreviewAttachment.accepts(generation: 1, applied: 0))
    }
}
