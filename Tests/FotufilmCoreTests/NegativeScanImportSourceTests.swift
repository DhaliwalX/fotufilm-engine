import XCTest
@testable import FotufilmCore
@testable import FotufilmImaging
#if canImport(CoreImage)
import CoreImage

/// What a scan's file says of its camera and decoder, read off a raw file written here: flat
/// patches of known sensor values behind a Bayer mosaic, as a DNG.
final class NegativeScanImportSourceTests: XCTestCase {
    private static let patch = 32
    /// The system's decoder reads no raw file under 256 samples a side.
    private static let columns = 8, rows = 8
    /// The white the file says the camera recorded, as its three channels read a neutral.
    private static let neutral = SIMD3<Float>(0.52, 1, 0.64)

    /// The sensor's reading of each patch, of full scale: the first as neutral as the file's
    /// white, the rest orange film from clear to dense.
    private static let patches: [SIMD3<Float>] = {
        var generator = SplitMix64(seed: 23)
        return [0.3 * neutral] + (1..<columns * rows).map { _ in
            let depth = Float.random(in: 0...1.2, using: &generator)
            let colour = SIMD3<Float>(Float.random(in: -0.15...0.15, using: &generator),
                                      Float.random(in: -0.15...0.15, using: &generator),
                                      Float.random(in: -0.15...0.15, using: &generator))
            let density = depth * SIMD3<Float>(0.7, 1, 1.25) + colour
            return SIMD3(0.3 * pow(10, -density.x), 0.4 * pow(10, -density.y),
                         0.22 * pow(10, -density.z))
        }
    }()

    /// A DNG of the patches from a camera named `make` and `model`.
    private static func dng(make: String, model: String) -> Data {
        let width = columns * patch, height = rows * patch
        var samples = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = patches[(y / patch) * columns + x / patch]
                // Red, green over green, blue.
                let channel = (y % 2 == 0) ? (x % 2 == 0 ? 0 : 1) : (x % 2 == 0 ? 1 : 2)
                samples[y * width + x] = UInt16((value[channel] * 65535).rounded())
            }
        }
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
            let value = values.flatMap { bytes([Int32(($0 * 10000).rounded()), 10000]) }
            entries.append((tag, signed ? 10 : 5, UInt32(values.count), value))
        }
        long(254, [0])
        long(256, [UInt32(width)])
        long(257, [UInt32(height)])
        short(258, [16])
        short(259, [1])
        short(262, [32803])
        ascii(271, make)
        ascii(272, model)
        long(273, [0])  // The strip's offset, set below.
        short(274, [1])
        short(277, [1])
        long(278, [UInt32(height)])
        long(279, [UInt32(samples.count * 2)])
        short(284, [1])
        short(33421, [2, 2])
        byte(33422, [0, 1, 1, 2])
        byte(50706, [1, 4, 0, 0])
        byte(50707, [1, 1, 0, 0])
        ascii(50708, "\(make) \(model)")
        long(50714, [0])
        long(50717, [65535])
        // XYZ to the camera's channels: a sensor like any, its channels broad and overlapping.
        rational(50721, signed: true, [0.72, -0.21, -0.07, -0.44, 1.23, 0.23, -0.09, 0.19, 0.61])
        rational(50728, signed: false, [neutral.x, neutral.y, neutral.z])
        short(50778, [21])

        let directory = 8, directoryLength = 2 + entries.count * 12 + 4
        var extra: [UInt8] = []
        var file: [UInt8] = [0x49, 0x49, 42, 0] + bytes([UInt32(directory)])
        file += bytes([UInt16(entries.count)])
        // Values too long for an entry follow the directory, the strip after them.
        var overflow = 0
        for entry in entries where entry.value.count > 4 {
            overflow += entry.value.count + entry.value.count % 2
        }
        let strip = directory + directoryLength + overflow
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

    /// The decoded scan's value of each patch, away from its edges.
    private static func decoded(_ data: Data) throws -> [SIMD3<Float>] {
        let image = try NegativeScanImport.decode(data: data, identifierHint: "com.adobe.raw-image")
        let read = try NegativeScanImport.samples(image, colorSpace: NegativeScanImport.filmSpace)
        guard read.width == columns * patch, read.height == rows * patch else {
            throw XCTSkip("The decoder crops this file.")
        }
        return (0..<columns * rows).map { index in
            var sum = SIMD3<Float>.zero
            let inset = patch / 4
            for y in inset..<(patch - inset) {
                for x in inset..<(patch - inset) {
                    let at = ((index / columns) * patch + y) * read.width + (index % columns) * patch + x
                    sum += SIMD3(read.planes[0][at], read.planes[1][at], read.planes[2][at])
                }
            }
            return sum / Float((patch - 2 * inset) * (patch - 2 * inset))
        }
    }

    private func raw(make: String = "SONY", model: String = "ILCE-7CM2") throws -> Data {
        let data = Self.dng(make: make, model: model)
        guard RawDecode.isRaw(data: data, identifierHint: "com.adobe.raw-image"),
              RawDecode.filter(data: data, identifierHint: "com.adobe.raw-image") != nil else {
            throw XCTSkip("This system's raw decoder does not read the file written here.")
        }
        return data
    }

    func testADNGSaysItsCameraAndWhiteAndShowsNoMatrix() throws {
        let data = try raw()
        let source = NegativeScanImport.source(data: data, identifierHint: "com.adobe.raw-image")
        XCTAssertEqual(source.camera, CameraIdentity(make: "SONY", model: "ILCE-7CM2"))
        XCTAssertGreaterThan(try XCTUnwrap(source.kelvin), 1500)
        let white = try XCTUnwrap(source.white)
        XCTAssertEqual(white.count, 2)
        XCTAssertTrue(white.allSatisfy { $0 > 0.1 && $0 < 0.6 })
        // The decoder adapts a DNG's white after the file's own matrix: its tints show the
        // space it adapts in, which is refused, and the scan is read as the generic camera.
        XCTAssertNil(NegativeScanImport.decoderMatrix(data: data,
                                                      identifierHint: "com.adobe.raw-image"))
        XCTAssertNil(source.matrix)
        XCTAssertEqual(source.setup(light: .white).camera, .generic)
        // The edit can still name the camera.
        XCTAssertEqual(source.setup(light: .white, camera: .profile("sony-ilce-7cm2")).camera,
                       .profile("sony-ilce-7cm2"))
    }

    func testTheCameraIsNamedUnderTheFilesTypeOrWithoutOne() throws {
        let data = try raw()
        let camera = CameraIdentity(make: "SONY", model: "ILCE-7CM2")
        XCTAssertEqual(RawDecode.cameraIdentity(data: data), camera)
        XCTAssertEqual(RawDecode.cameraIdentity(data: data, identifierHint: "com.adobe.raw-image"),
                       camera)
        // A type the file is not does not hide the camera its own bytes name.
        XCTAssertEqual(RawDecode.cameraIdentity(data: data, identifierHint: "public.png"), camera)
        XCTAssertNil(RawDecode.cameraIdentity(data: Data([1, 2, 3]),
                                              identifierHint: "com.adobe.raw-image"))
    }

    func testAMatrixFoundIsKeptAndOneNotFoundLookedForAgain() {
        let matrices = NegativeScanImport.DecoderMatrices()
        var looked = 0
        let find: (Float?) -> [Float]? = { value in
            matrices.matrix("camera|white") {
                looked += 1
                return value.map { [Float](repeating: $0, count: 9) }
            }
        }
        XCTAssertNil(find(nil))
        XCTAssertEqual(find(1), [Float](repeating: 1, count: 9))
        XCTAssertEqual(find(2), [Float](repeating: 1, count: 9))
        XCTAssertEqual(looked, 2)
        XCTAssertEqual(matrices.matrix("camera|another") { [2] }, [2])
    }

    func testAMeasuredCamerasSourceIsTheSameAskedAgain() throws {
        let data = try raw()
        let first = NegativeScanImport.source(data: data, identifierHint: "com.adobe.raw-image")
        XCTAssertEqual(NegativeScanImport.source(data: data, identifierHint: "com.adobe.raw-image"),
                       first)
    }

    func testTheScanIsDecodedOnTheWhiteItsSourceSays() throws {
        let data = try raw()
        let decoded = try Self.decoded(data)
        XCTAssertTrue(decoded.allSatisfy { $0.min() > 0 && $0.max() < 1 })
        // The patch as neutral as the file's white is grey, whatever the sensor's channels read.
        let grey = decoded[0]
        XCTAssertEqual(grey.x / grey.y, 1, accuracy: 0.03)
        XCTAssertEqual(grey.z / grey.y, 1, accuracy: 0.03)
        // And no other is.
        XCTAssertGreaterThan(decoded[1].x / decoded[1].y, 1.1)
    }

    func testAnUnmeasuredCamerasMatrixIsNotLookedFor() throws {
        let data = try raw(make: "Unmeasured", model: "Camera")
        let source = NegativeScanImport.source(data: data, identifierHint: "com.adobe.raw-image")
        XCTAssertEqual(source.camera, CameraIdentity(make: "Unmeasured", model: "Camera"))
        XCTAssertNotNil(source.kelvin)
        XCTAssertNil(source.matrix)
        XCTAssertEqual(source.setup(light: .white).camera, .generic)
    }

    func testAFileThatIsNotRawSaysOnlyItsCamera() throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        XCTAssertEqual(NegativeScanImport.source(data: png), NegativeScanSource())
        XCTAssertNil(NegativeScanImport.decoderMatrix(data: png))
    }
}
#endif
