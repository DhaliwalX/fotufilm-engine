import XCTest
@testable import FotufilmHost
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

final class HostBatchExportTests: XCTestCase {
    func testSizesFollowTheCroppedLongEdge() {
        XCTAssertEqual(HostService.batchEdges("full", longEdge: 6000),
                       [nil, 4500, 3840, 3000, 2048, 1600, 1500])
        XCTAssertEqual(HostService.batchEdges("0.5", longEdge: 6000).first, 3000)
        XCTAssertEqual(HostService.batchEdges("2048", longEdge: 6000), [2048, 1600, 1500])
        // A size at or past the picture's own is the whole picture.
        XCTAssertEqual(HostService.batchEdges("3840", longEdge: 1200), [nil, 900])
        // Fractions under 640 pixels are not offered as stand-ins.
        XCTAssertEqual(HostService.batchEdges("full", longEdge: 1000), [nil, 750])
    }

    func testDestinationsNeverOverwrite() {
        let folder = URL(fileURLWithPath: "/exports", isDirectory: true)
        let existing: Set<String> = ["/exports/a-gold200.jpg"]
        let names = HostService.batchDestinations(
            ["a-gold200.jpg", "A-gold200.jpg", "b/c:d.jpg", ".hidden.png", ""], in: folder,
            // Case-insensitive, as the Mac's file system compares names.
            exists: { existing.contains($0.path.lowercased()) })
            .map(\.lastPathComponent)
        XCTAssertEqual(names, ["a-gold200 2.jpg", "A-gold200 3.jpg", "b-c-d.jpg", "hidden.png", "photo"])
    }

    func testPlanFollowsMemory() {
        XCTAssertEqual(HostService.BatchPlan.forMachine(memory: 8 << 30, cores: 8),
                       .init(ahead: 1, decoders: 1, encoders: 1))
        XCTAssertEqual(HostService.BatchPlan.forMachine(memory: 16 << 30, cores: 10),
                       .init(ahead: 1, decoders: 1, encoders: 2))
        XCTAssertEqual(HostService.BatchPlan.forMachine(memory: 48 << 30, cores: 14),
                       .init(ahead: 2, decoders: 2, encoders: 3))
    }

    #if canImport(ImageIO)
    /// Open photographs and files not opened yet export together, each with its own edit and at
    /// the size asked of its own crop; a file that cannot be read fails alone.
    func testExportsEveryPhotographIntoOneFolder() throws {
        let engine: HostEngine
        do { engine = try HostEngine() } catch { throw XCTSkip("\(error)") }
        let service = engine.service
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-batch-\(UUID().uuidString)", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wide = root.appendingPathComponent("wide.png")
        let tall = root.appendingPathComponent("tall.png")
        try writeRamp(to: wide, width: 160, height: 100)
        try writeRamp(to: tall, width: 90, height: 140)
        // Already there: the batch numbers its file rather than replacing it.
        try Data("keep".utf8).write(to: output.appendingPathComponent("wide-gold200.jpg"))

        let opened = try service.call("importPath", params: Data(#"{"path": "\#(wide.path)"}"#.utf8),
                                      payload: nil)
        let handle = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: opened.json) as? [String: Any])?["handle"] as? Int)
        let edit = #""profileRequest": {"controls": {}}"#
        let request = """
        {"directory": "\(output.path)", "type": "image/jpeg", "quality": 0.9, "size": "0.5",
         "items": [
          {"handle": \(handle), "name": "wide.png", "filename": "wide-gold200.jpg",
           "edit": {"stock": "gold200", "params": {}}, \(edit)},
          {"path": "\(tall.path)", "name": "tall.png", "filename": "tall-portra400.jpg",
           "edit": {"stock": "portra400", "params": {},
                    "crop": [[0, 0], [1, 0], [1, 0.5], [0, 0.5]]}, \(edit)},
          {"path": "\(root.path)/missing.png", "name": "missing.png", "filename": "missing.jpg",
           "edit": {"stock": "gold200", "params": {}}, \(edit)}
         ]}
        """
        var reports: [[String: Any]] = []
        let answer = try service.call("exportBatch", params: Data(request.utf8), payload: nil) {
            reports.append($0)
        }
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: answer.json) as? [String: Any])
        let written = try XCTUnwrap(result["written"] as? [[String: Any]])
        XCTAssertEqual(written.map { $0["filename"] as? String }, ["wide-gold200 2.jpg", "tall-portra400.jpg"])
        XCTAssertEqual(written.map { $0["width"] as? Int }, [80, 45])
        XCTAssertEqual(written.map { $0["height"] as? Int }, [50, 35])
        let failed = try XCTUnwrap(result["failed"] as? [[String: Any]])
        XCTAssertEqual(failed.map { $0["name"] as? String }, ["missing.png"])
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("wide-gold200.jpg"),
                                  encoding: .utf8), "keep")
        for file in written {
            let path = try XCTUnwrap(file["path"] as? String)
            let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            XCTAssertEqual(image?.width, file["width"] as? Int)
        }
        XCTAssertEqual(reports.last?["done"] as? Int, 3)
        XCTAssertEqual(reports.compactMap { $0["current"] as? Int }, [1, 2])
    }

    private func writeRamp(to url: URL, width: Int, height: Int) throws {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(x * 255 / (width - 1))
                let i = (y * width + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    #endif
}
