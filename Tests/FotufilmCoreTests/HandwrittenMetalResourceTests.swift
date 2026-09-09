#if os(macOS)
import Foundation
import Metal
import XCTest
@testable import FotufilmMetal

final class HandwrittenMetalResourceTests: XCTestCase {
    func testPackageShadersLoadOutsideTheCheckout() throws {
        let probeKey = "FOTUFILM_PACKAGE_SHADER_PROBE"
        if ProcessInfo.processInfo.environment[probeKey] == "1" {
            let shaders: [HandwrittenMetalShaderLibrary.Shader] = [
                .pointwise, .composedPointwise, .frameEndpoints, .globalMeasurements,
                .spectralHead, .cameraPassThrough, .spatial, .digitalDelivery,
                .stillDelivery, .compositeTail,
            ]
            for shader in shaders {
                let source = try HandwrittenMetalShaderLibrary.assembledSource(for: shader)
                XCTAssertFalse(source.isEmpty, shader.rawValue)
                XCTAssertFalse(source.contains("#include \"Handwritten"), shader.rawValue)
            }
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            _ = try XCTUnwrap(HandwrittenMetalFullFrameRenderer(device: device))
            return
        }
        try XCTSkipUnless(MTLCreateSystemDefaultDevice() != nil, "Metal device required")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["-XCTest",
            "FotufilmCoreTests.HandwrittenMetalResourceTests/testPackageShadersLoadOutsideTheCheckout",
            Bundle(for: Self.self).bundlePath]
        child.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment[probeKey] = "1"
        environment.removeValue(forKey: "FOTUFILM_METAL_SHADER_ROOT")
        environment.removeValue(forKey: "FOTUFILM_METAL_LIBRARY_PATH")
        child.environment = environment
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        try child.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, output)
    }
}
#endif
