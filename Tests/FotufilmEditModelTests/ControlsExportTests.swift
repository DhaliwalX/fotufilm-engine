import XCTest
import FotufilmCore
@testable import FotufilmEditModel

final class ControlsExportTests: XCTestCase {
    private var engineRoot: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testEveryGeneratedFileIsCurrent() throws {
        for output in ControlsExport.outputs(engineRoot: engineRoot, consumerRoot: nil) {
            let existing = try? String(contentsOf: output.path, encoding: .utf8)
            XCTAssertNotNil(existing, "\(output.path.lastPathComponent) has not been generated")
            let expected = output.render(existing: existing)
            XCTAssertNotNil(expected, "\(output.path.lastPathComponent) lost its generated regions")
            XCTAssertEqual(existing, expected,
                           "\(output.path.lastPathComponent) is stale; run swift run fotufilm-controls")
        }
    }

    func testTheManifestRoundTrips() throws {
        let text = ControlsManifest.encoded()
        let decoded = try JSONDecoder().decode(ControlsManifest.self, from: Data(text.utf8))
        XCTAssertEqual(decoded, ControlsManifest.current)
        XCTAssertEqual(decoded.controls.count, EditorControlCatalogue.all.count)
        XCTAssertEqual(decoded.bridgeSlots.count, EditorControlCatalogue.bridgeSlotCount)
    }

    func testTheBridgeHeaderNamesEverySlotOnce() {
        let header = ControlsExport.bridgeSlotsHeader()
        for entry in EditorControlCatalogue.bridgeSlots {
            XCTAssertTrue(header.contains("FOTUFILM_BRIDGE_\(entry.symbol) = \(entry.slot),"), entry.symbol)
        }
        XCTAssertTrue(header.contains("FOTUFILM_BRIDGE_PARAMETER_COUNT = \(EditorControlCatalogue.bridgeSlotCount),"))
    }

    func testTheFxplugHeaderKeepsTheShippedIDs() {
        let header = ControlsExport.fxplugIDsHeader()
        for (symbol, id) in [("kFotufilmParam_Exposure", 6), ("kFotufilmParam_Stage", 1),
                             ("kFotufilmParam_StockID", 27), ("kFotufilmParam_Status", 37),
                             ("kFotufilmParam_HalationModel", 88), ("kFotufilmParam_LensGroup", 72),
                             ("kFotufilmParam_InputGroup", 85), ("kFotufilmParam_Retired33", 33),
                             ("kFotufilmParam_TextureStageFirst", 40), ("kFotufilmParam_TextureStageLimit", 72)] {
            XCTAssertTrue(header.contains("\(symbol) = \(id),"), symbol)
        }
    }

    func testTheMotionTemplatePublishesEveryFinalCutControl() {
        let template = ControlsExport.motionTemplate()
        for (control, host) in EditorControlCatalogue.hostParameters(on: .finalcut) {
            guard let id = host.fxplugID else { continue }
            let path = "channel=\"./\(host.group.topLevel.fxplugID!)/\(id)\""
            XCTAssertTrue(template.contains(path), "\(control.field) is not published at \(path)")
            XCTAssertTrue(template.contains("id=\"\(id)\""), "\(control.field) has no channel")
        }
        XCTAssertTrue(template.contains("channel=\"./37\" name=\"Status\""))
        XCTAssertTrue(template.contains("name=\"Halation Stage\" id=\"41\""))
        XCTAssertFalse(template.contains("channel=\"./27\""), "a hidden identity is published")
        XCTAssertTrue(template.contains("pluginDynamicParams=\"0\""))
    }

    func testTheWebControlsCarryOnlyConfigurationSlots() {
        let script = ControlsExport.webControls()
        let inc = ControlsExport.wasmControls()
        XCTAssertTrue(script.contains("key: 'exposure'"))
        XCTAssertTrue(script.contains("kind: 'exp2'"))
        XCTAssertTrue(inc.contains("FOTUFILM_CONFIG_EXPOSURE_GAIN"))
        XCTAssertFalse(script.contains("key: 'halation'"))
        let count = script.components(separatedBy: "{ key:").count - 1
        XCTAssertTrue(inc.contains("kFotufilmWasmControlCount = \(count);"))
    }

    func testTheKotlinStateCarriesEveryPersistedKey() {
        let kotlin = ControlsExport.kotlinEditState()
        for control in EditorControlCatalogue.all {
            guard case .edit = control.scope, let key = control.persistence.key else { continue }
            XCTAssertTrue(kotlin.contains("val \(key):"), key)
        }
        XCTAssertTrue(kotlin.contains("val temperatureMired: Double = \(ControlsExport.kotlinDouble(WarmthAxis.neutralMired)),"))
        XCTAssertTrue(kotlin.contains("val halation: Double = 1.0,"))
        XCTAssertTrue(kotlin.contains("val expiredYears: Double = 0.0,"))
    }

    func testTheDocumentationRegionsCoverEveryAppGroup() {
        let regions = ControlsExport.documentationRegions()
        for group in EditorControlGroup.allCases where group != .pipeline {
            XCTAssertNotNil(regions[group.rawValue], group.rawValue)
        }
        XCTAssertTrue(regions["film"]!.contains("<td>Grain</td>"))
        XCTAssertTrue(regions["resolve"]!.contains("<td>Film Frame Coverage (%)</td>"))
        let replaced = ControlsExport.replaceRegion(
            named: "film", in: "<table>\n  <tbody data-controls=\"film\">\n    old\n  </tbody>\n</table>", with: "<tr/>")
        XCTAssertEqual(replaced, "<table>\n  <tbody data-controls=\"film\">\n    <tr/>\n  </tbody>\n</table>")
    }
}
