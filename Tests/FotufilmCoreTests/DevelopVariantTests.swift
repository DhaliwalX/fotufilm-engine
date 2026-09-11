import XCTest
import FotufilmHalide

final class DevelopVariantTests: XCTestCase {
    func testEveryDevelopFeatureCombinationHasADistinctKernel() {
        let stages = [
            FOTUFILM_FRAME_FLARE, FOTUFILM_FRAME_MTF,
            FOTUFILM_FRAME_HALATION, FOTUFILM_FRAME_COUPLERS,
            FOTUFILM_FRAME_ADJACENCY, FOTUFILM_FRAME_GRAIN,
            FOTUFILM_FRAME_MTF_LUMA, FOTUFILM_FRAME_COUPLER_DIFFUSION,
            FOTUFILM_FRAME_DISC_GRAIN, FOTUFILM_FRAME_GRAIN_MOTTLE,
            FOTUFILM_FRAME_PRINT_MTF, FOTUFILM_FRAME_DENSITY_IN,
            FOTUFILM_FRAME_TEXTURE, FOTUFILM_FRAME_DIFFUSION,
            FOTUFILM_FRAME_DONOR_LAYER, FOTUFILM_FRAME_HALATION_ANNULAR,
            FOTUFILM_FRAME_RECORD_EXPOSURE_IN, FOTUFILM_FRAME_LIGHT_OUT,
        ].map(Int32.init)
        var masks: [Int32] = [0]
        for stage in stages { masks += masks.map { $0 | stage } }
        let variants = Set(masks.map(fotufilm_develop_variant))
        XCTAssertEqual(variants.count, masks.count)
        XCTAssertEqual(variants.min(), 0)
        XCTAssertEqual(variants.max(), Int32(masks.count - 1))
        XCTAssertTrue(masks.allSatisfy { fotufilm_develop_features($0) == $0 })
    }

    func testPhotographicStagesAreNotDroppedByBrowserDispatch() {
        let base = Int32(FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_COUPLERS)
        for stage in [FOTUFILM_FRAME_PRINT_MTF, FOTUFILM_FRAME_DIFFUSION,
                      FOTUFILM_FRAME_DONOR_LAYER, FOTUFILM_FRAME_GRAIN_MOTTLE].map(Int32.init) {
            XCTAssertNotEqual(fotufilm_develop_variant(base),
                              fotufilm_develop_variant(base | stage))
        }
        XCTAssertNotEqual(fotufilm_develop_variant(Int32(FOTUFILM_FRAME_PRINT_MTF)),
                          fotufilm_develop_variant(Int32(FOTUFILM_FRAME_LIGHT_OUT)))
    }

    func testDeliveryAndFilmTypeFlagsDoNotChangeDevelopKernel() {
        let base = Int32(FOTUFILM_FRAME_HALATION | FOTUFILM_FRAME_PRINT_MTF)
        let delivery = Int32(FOTUFILM_FRAME_REVERSAL | FOTUFILM_FRAME_MONOCHROME
            | FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_ENCODE_OUT)
        XCTAssertEqual(fotufilm_develop_features(base | delivery), base)
        XCTAssertEqual(fotufilm_develop_variant(base | delivery),
                       fotufilm_develop_variant(base))
    }
}
