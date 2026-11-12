#if os(Linux) && canImport(CFotufilmCodecs)
import XCTest
@testable import FotufilmHost
import FotufilmCore

/// The portable codecs Linux opens and exports photographs with: every still written is read back
/// as the linear Rec. 2020 light it encodes, upright, with the capture records the policy keeps.
final class PortableCodecsTests: XCTestCase {
    private let width = 48, height = 32

    /// Display P3 codes: a ramp per channel across, a band per row group down.
    private func code(_ x: Int, _ y: Int, _ c: Int) -> Double {
        let ramp = Double(x) / Double(width - 1)
        switch (y * 4 / height, c) {
        case (0, _): return ramp
        case (1, 0), (2, 1), (3, 2): return ramp
        default: return 0.25
        }
    }

    private func still(deep: Bool, capture: Data? = nil,
                       metadata: HostMetadataPolicy = .default) -> HostStill {
        var eight = [UInt8](repeating: 255, count: width * height * 4)
        var sixteen = [UInt16](repeating: 65535, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 {
            eight[(y * width + x) * 4 + c] = UInt8((code(x, y, c) * 255).rounded())
            sixteen[(y * width + x) * 4 + c] = UInt16((code(x, y, c) * 65535).rounded())
        } } }
        return HostStill(pixels: deep ? .display16(sixteen) : .display8(eight), width: width,
                         height: height, capture: capture.map { ["exif": $0] }, metadata: metadata)
    }

    /// The light a Display P3 code stands for, in the engine's working space.
    private func expected(_ x: Int, _ y: Int, deep: Bool) -> SIMD3<Float> {
        let quantised = { (v: Double) in deep ? (v * 65535).rounded() / 65535 : (v * 255).rounded() / 255 }
        let p3 = SIMD3((0..<3).map { Float(ColorScience.srgbToLinear(Float(quantised(code(x, y, $0))))) })
        return ColorScience.linearDisplayP3ToRec2020(p3)
    }

    private func temporary(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fotufilm-codecs-\(UUID().uuidString).\(ext)")
    }

    private func worst(_ image: HostImage, deep: Bool) -> Float {
        let rgba = image.scene(width: image.width, height: image.height)
        var worst: Float = 0
        for y in 0..<height { for x in 0..<width {
            let want = expected(x, y, deep: deep)
            for c in 0..<3 { worst = max(worst, abs(rgba[(y * width + x) * 4 + c] - want[c])) }
        } }
        return worst
    }

    func testStillsReadBackAsTheirLight() throws {
        let encoder = PortableStillEncoder()
        XCTAssertTrue(Set(["image/png", "image/jpeg", "image/tiff"]).isSubset(of: encoder.types))
        XCTAssertFalse(encoder.writesHDR)
        let cases: [(type: String, ext: String, deep: Bool, tolerance: Float)] = [
            ("image/png", "png", false, 2e-4), ("image/tiff", "tif", true, 2e-4),
            ("image/png", "png", true, 2e-4), ("image/jpeg", "jpg", false, 0.03),
            ("image/heic", "heic", false, 0.06),
        ]
        for entry in cases where encoder.types.contains(entry.type) {
            let url = temporary(entry.ext)
            defer { try? FileManager.default.removeItem(at: url) }
            let written = try encoder.write(still(deep: entry.deep), type: entry.type, quality: 0.95,
                                            to: url)
            XCTAssertEqual(written.width, width)
            let image = try PortableImageDecoder().decode(url)
            XCTAssertEqual([image.width, image.height], [width, height], entry.type)
            XCTAssertFalse(image.isRAW)
            XCTAssertEqual(image.contentHeadroom, 1)
            XCTAssertLessThan(worst(image, deep: entry.deep), entry.tolerance,
                              "\(entry.type) deep \(entry.deep)")
        }
    }

    /// A little-endian Exif record: make, orientation, and a GPS directory with a latitude ref.
    private func exif(orientation: UInt16) -> Data {
        var bytes: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0]
        func u16(_ v: UInt16) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        let make = Array("Fotufilm Test\0".utf8)
        let first = 8, gps = first + 2 + 3 * 12 + 4, makeAt = gps + 2 + 12 + 4
        u16(3)
        u16(0x010F); u16(2); u32(UInt32(make.count)); u32(UInt32(makeAt))
        u16(0x0112); u16(3); u32(1); u16(orientation); u16(0)
        u16(0x8825); u16(4); u32(1); u32(UInt32(gps))
        u32(0)
        u16(1)
        u16(0x0001); u16(2); u32(2); bytes += [UInt8(ascii: "N"), 0, 0, 0]
        u32(0)
        bytes += make
        return Data(bytes)
    }

    func testExportsKeepTheRecordsThePolicyKeeps() throws {
        let record = exif(orientation: 1)
        func exported(_ policy: HostMetadataPolicy) throws -> PortableCodecs.Decoded {
            let url = temporary("jpg")
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try PortableStillEncoder().write(still(deep: false, capture: record, metadata: policy),
                                                 type: "image/jpeg", quality: 0.9, to: url)
            return try PortableCodecs.decode(url, options: 0)
        }
        let gpsPointer = Data([0x25, 0x88]), make = Data("Fotufilm Test".utf8)
        let kept = try exported(.preserve)
        XCTAssertNotNil(kept.exif?.range(of: make))
        XCTAssertNotNil(kept.exif?.range(of: gpsPointer))
        let unlocated = try exported(.preserveWithoutLocation)
        XCTAssertNotNil(unlocated.exif?.range(of: make))
        XCTAssertNil(unlocated.exif?.range(of: gpsPointer))
        XCTAssertNil(try exported(.strip).exif)
    }

    /// A JPEG whose Exif record says to turn it a quarter clockwise opens upright.
    func testOrientationTurnsThePicture() throws {
        let url = temporary("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try PortableStillEncoder().write(still(deep: false), type: "image/jpeg", quality: 1,
                                             to: url)
        var jpeg = try Data(contentsOf: url)
        let record = Data("Exif\0\0".utf8) + exif(orientation: 6)
        let length = UInt16(record.count + 2)
        jpeg.insert(contentsOf: [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + record, at: 2)
        try jpeg.write(to: url)
        let image = try PortableImageDecoder().decode(url)
        XCTAssertEqual([image.width, image.height], [height, width])
        let rgba = image.scene(width: image.width, height: image.height)
        // The stored top-left (black in every band's ramp) lands top-right; the stored top-right
        // (white) lands bottom-right.
        let topRight = (image.width - 1) * 4, bottomRight = ((image.height - 1) * image.width + image.width - 1) * 4
        XCTAssertLessThan(rgba[topRight + 1], 0.02)
        XCTAssertGreaterThan(rgba[bottomRight + 1], 0.9)
    }

    /// A scan with a colour profile is read through it; only an untagged one reads as linear
    /// samples.
    func testScansReadThroughTheirProfile() throws {
        let url = temporary("tif")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try PortableStillEncoder().write(still(deep: true), type: "image/tiff", quality: 1, to: url)
        let scan = try PortableScanDecoder().decodeScan(url)
        XCTAssertLessThan(worst(scan, deep: true), 2e-4)
        // Only a camera's RAW says what took it and how it was decoded.
        XCTAssertEqual(scan.scanSource, NegativeScanCapture())
    }

    /// A linear DNG of one colour from a camera named `make` and `model`, whose channels are
    /// sRGB's primaries, each at its level of `neutral` under white.
    private func dng(make: String, model: String, colour: SIMD3<Float>,
                     neutral: SIMD3<Float>) -> Data {
        var entries: [(tag: UInt16, type: UInt16, count: UInt32, value: [UInt8])] = []
        func bytes<T: FixedWidthInteger>(_ values: [T]) -> [UInt8] {
            values.flatMap { value in withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        }
        func short(_ tag: UInt16, _ values: [UInt16]) {
            entries.append((tag, 3, UInt32(values.count), bytes(values)))
        }
        func long(_ tag: UInt16, _ values: [UInt32]) {
            entries.append((tag, 4, UInt32(values.count), bytes(values)))
        }
        func byte(_ tag: UInt16, _ values: [UInt8]) {
            entries.append((tag, 1, UInt32(values.count), values))
        }
        func ascii(_ tag: UInt16, _ text: String) {
            let value = Array(text.utf8) + [0]
            entries.append((tag, 2, UInt32(value.count), value))
        }
        func rational(_ tag: UInt16, signed: Bool, _ values: [Float]) {
            let value = values.flatMap { bytes([Int32(($0 * 1_000_000).rounded()), 1_000_000]) }
            entries.append((tag, signed ? 10 : 5, UInt32(values.count), value))
        }
        let sample = (0..<3).map { UInt16((colour[$0] * neutral[$0] * 65535).rounded()) }
        let samples = [UInt16]((0..<width * height).flatMap { _ in sample })
        let toSRGB: [Float] = [3.2404542, -1.5371385, -0.4985314, -0.969266, 1.8760108, 0.041556,
                               0.0556434, -0.2040259, 1.0572252]
        long(254, [0])
        long(256, [UInt32(width)])
        long(257, [UInt32(height)])
        short(258, [16, 16, 16])
        short(259, [1])
        short(262, [34892])
        ascii(271, make)
        ascii(272, model)
        long(273, [0])  // The strip's offset, set below.
        short(274, [1])
        short(277, [3])
        long(278, [UInt32(height)])
        long(279, [UInt32(samples.count * 2)])
        short(284, [1])
        byte(50706, [1, 4, 0, 0])
        byte(50707, [1, 1, 0, 0])
        ascii(50708, "\(make) \(model)")
        long(50717, [65535])
        rational(50721, signed: true, (0..<9).map { toSRGB[$0] * neutral[$0 / 3] })
        rational(50728, signed: false, [neutral.x, neutral.y, neutral.z])
        short(50778, [21])

        let directory = 8, directoryLength = 2 + entries.count * 12 + 4
        var overflow = 0
        for entry in entries where entry.value.count > 4 {
            overflow += entry.value.count + entry.value.count % 2
        }
        let strip = directory + directoryLength + overflow
        var file: [UInt8] = [0x49, 0x49, 42, 0] + bytes([UInt32(directory)])
        file += bytes([UInt16(entries.count)])
        // Values too long for an entry follow the directory, the strip after them.
        var extra: [UInt8] = []
        for entry in entries {
            file += bytes([entry.tag, entry.type]) + bytes([entry.count])
            var value = entry.tag == 273 ? bytes([UInt32(strip)]) : entry.value
            if value.count > 4 {
                file += bytes([UInt32(directory + directoryLength + extra.count)])
                extra += value + (value.count % 2 == 1 ? [0] : [])
            } else {
                value += [UInt8](repeating: 0, count: 4 - value.count)
                file += value
            }
        }
        file += bytes([UInt32(0)]) + extra + bytes(samples)
        return Data(file)
    }

    /// A camera RAW's scan says its camera, the white it was decoded on and the matrix its
    /// balanced channels were mixed with, from the decode that made its picture.
    func testARAWScanSaysItsCameraWhiteAndMatrix() throws {
        let url = temporary("dng")
        defer { try? FileManager.default.removeItem(at: url) }
        let colour = SIMD3<Float>(0.4, 0.2, 0.1)
        try dng(make: "SONY", model: "ILCE-7CM2", colour: colour,
                neutral: SIMD3(0.5, 1, 0.25)).write(to: url)
        let scan = try PortableScanDecoder().decodeScan(url)
        let source = try XCTUnwrap(scan.scanSource)
        XCTAssertEqual(source.camera, CameraIdentity(make: "SONY", model: "ILCE-7CM2"))
        XCTAssertEqual(try XCTUnwrap(source.kelvin), 6500, accuracy: 300)
        let white = try XCTUnwrap(source.white)
        XCTAssertEqual(white.count, 2)
        XCTAssertEqual(white[0], 0.3127, accuracy: 0.003)
        XCTAssertEqual(white[1], 0.3290, accuracy: 0.003)
        // The camera's channels are sRGB's balanced on its white: the matrix is sRGB's into
        // Rec. 2020, and the picture is that matrix of the colour.
        let matrix = try XCTUnwrap(source.matrix)
        XCTAssertEqual(matrix.count, 9)
        let expected = ColorScience.linearSRGBToRec2020(colour)
        let rgba = scan.scene(width: scan.width, height: scan.height)
        let centre = (scan.height / 2 * scan.width + scan.width / 2) * 4
        for row in 0..<3 {
            XCTAssertEqual(matrix[row * 3] + matrix[row * 3 + 1] + matrix[row * 3 + 2], 1,
                           accuracy: 1e-4)
            let mixed = matrix[row * 3] * colour.x + matrix[row * 3 + 1] * colour.y
                + matrix[row * 3 + 2] * colour.z
            XCTAssertEqual(mixed, expected[row], accuracy: 0.002)
            XCTAssertEqual(rgba[centre + row], mixed, accuracy: 0.002)
        }
        // A measured camera is read through its own channels and this decode's matrix.
        let setup = source.setup(light: .white)
        XCTAssertEqual(setup.camera, .profile("sony-ilce-7cm2"))
        XCTAssertEqual(setup.matrix?.count, 3)
        XCTAssertEqual(setup.matrix?[1].y, matrix[4])

        // A camera nobody measured says as much, and is read as the generic one.
        try dng(make: "Unmeasured", model: "Camera", colour: colour,
                neutral: SIMD3(0.5, 1, 0.25)).write(to: url)
        let unmeasured = try XCTUnwrap(try PortableScanDecoder().decodeScan(url).scanSource)
        XCTAssertEqual(unmeasured.camera, CameraIdentity(make: "Unmeasured", model: "Camera"))
        XCTAssertEqual(unmeasured.matrix, matrix)
        XCTAssertEqual(unmeasured.setup(light: .white).camera, .generic)
    }

    func testCapabilitiesOfferImportAndExport() {
        let capabilities = HostPlatform.current.capabilities
        XCTAssertEqual(capabilities["importPath"] as? Bool, true)
        XCTAssertEqual(capabilities["negativeScans"] as? Bool, true)
        XCTAssertTrue((capabilities["imageExportTypes"] as? [String] ?? []).contains("image/tiff"))
        XCTAssertEqual(capabilities["hdrExport"] as? Bool, false)
    }
}
#endif
