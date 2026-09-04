import XCTest
@testable import FotufilmCore
@testable import FotufilmImaging

final class DNGOpcodeTests: XCTestCase {

    // MARK: - What it reads

    func testAThreePlaneWarpIsReadAsOneCurvePerColour() throws {
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [
                (kr: [1.0, 0.10, 0.01, 0.001], kt: [0, 0]),
                (kr: [1.0, 0.20, 0.02, 0.002], kt: [0, 0]),
                (kr: [1.0, 0.30, 0.03, 0.003], kt: [0, 0]),
            ])])
            .data()

        let read = try XCTUnwrap(DNGOpcodes.read(file))
        XCTAssertTrue(read.hasGeometry)
        XCTAssertFalse(read.hasVignetting)
        XCTAssertEqual(read.declined, [])
        let warp = try XCTUnwrap(read.correction.planeWarp)
        XCTAssertEqual(warp.red.k1, 0.10, accuracy: 1e-7)
        XCTAssertEqual(warp.green.k1, 0.20, accuracy: 1e-7)
        XCTAssertEqual(warp.blue.k1, 0.30, accuracy: 1e-7)
        XCTAssertEqual(warp.blue.k3, 0.003, accuracy: 1e-9)
    }

    func testASinglePlaneWarpMovesAllThreeColoursTogether() throws {
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [
                (kr: [1.0, -0.05, 0, 0], kt: [0, 0]),
            ])])
            .data()

        let warp = try XCTUnwrap(DNGOpcodes.read(file)?.correction.planeWarp)
        XCTAssertEqual(warp.red, warp.green)
        XCTAssertEqual(warp.green, warp.blue)
        XCTAssertEqual(warp.green.k1, -0.05, accuracy: 1e-7)
    }

    func testAWarpSaysWhereACornerReadsFrom() throws {
        // A destination point at the corner of a barrel-corrected frame reads from further out than
        // it sits, which is the whole visible consequence of the opcode.
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [
                (kr: [1.0, 0.05, 0, 0], kt: [0, 0]),
            ])])
            .data()

        let correction = try XCTUnwrap(DNGOpcodes.read(file)?.correction)
        let sample = correction.sample(atRadius: 1)
        XCTAssertEqual(sample.green, 1.05, accuracy: 1e-6)
        XCTAssertEqual(correction.sample(atRadius: 0.5).green,
                       0.5 * (1 + 0.05 * 0.25), accuracy: 1e-6)
    }

    func testTheFalloffIsReadAsAGainToTheTenthPower() throws {
        let k: [Double] = [0.4, 0.15, 0.06, 0.02, 0.01]
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList2: [.vignette(k: k)])
            .data()

        let read = try XCTUnwrap(DNGOpcodes.read(file))
        XCTAssertTrue(read.hasVignetting)
        XCTAssertFalse(read.hasGeometry)
        // Every term is in play at the corner, so a reader that dropped the last one shows up here.
        XCTAssertEqual(read.correction.vignetting.gain(1),
                       Float(1 + k.reduce(0, +)), accuracy: 1e-5)
        XCTAssertEqual(read.correction.vignetting.gain(0), 1, accuracy: 1e-6)
        let half = read.correction.vignetting.gain(0.5)
        var expected = 1.0
        var power = 0.25
        for term in k {
            expected += term * power
            power *= 0.25
        }
        XCTAssertEqual(half, Float(expected), accuracy: 1e-5)
    }

    func testBothOpcodesTogetherMakeOneCorrection() throws {
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList2: [.vignette(k: [0.5, 0, 0, 0, 0])])
            .with(opcodeList3: [.warp(planes: [
                (kr: [1.0, 0.02, 0, 0], kt: [0, 0]),
            ])])
            .data()

        let read = try XCTUnwrap(DNGOpcodes.read(file))
        XCTAssertTrue(read.hasGeometry)
        XCTAssertTrue(read.hasVignetting)
        let sample = read.correction.sample(atRadius: 1)
        XCTAssertEqual(sample.green, 1.02, accuracy: 1e-6)
        XCTAssertEqual(sample.gain, 1.5, accuracy: 1e-5)
    }

    func testOpcodesAreFoundInTheSubdirectoryTheRawImageLivesIn() throws {
        // The common shape: the first directory is a small JPEG preview, and the real frame with all
        // its correction data hangs off it as a SubIFD.
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [
                (kr: [1.0, 0.07, 0, 0], kt: [0, 0]),
            ])])
            .asSubdirectoryOfAPreview()
            .data()

        let warp = try XCTUnwrap(DNGOpcodes.read(file)?.correction.planeWarp)
        XCTAssertEqual(warp.green.k1, 0.07, accuracy: 1e-7)
    }

    func testTheBigEndianFlavourOfTheContainerReadsTheSame() throws {
        // The opcode stream is big-endian whatever the file is; only the directories flip. Reading
        // the same picture both ways is what proves the two byte orders are kept apart.
        let coefficients: [Double] = [1.0, 0.09, 0.004, 0]
        let little = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [(kr: coefficients, kt: [0, 0])])])
            .data()
        let big = DNGBuilder(activeArea: (4000, 3000), bigEndian: true)
            .with(opcodeList3: [.warp(planes: [(kr: coefficients, kt: [0, 0])])])
            .data()

        XCTAssertNotEqual(little, big, "the two files must actually differ")
        XCTAssertEqual(DNGOpcodes.read(little)?.correction,
                       DNGOpcodes.read(big)?.correction)
        XCTAssertEqual(try XCTUnwrap(DNGOpcodes.read(big)?.correction.planeWarp)
                        .green.k1, 0.09, accuracy: 1e-7)
    }

    // MARK: - What it refuses

    func testADecentredLensIsRefusedRatherThanHalfCorrected() throws {
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [
                (kr: [1.0, 0.05, 0, 0], kt: [1e-4, 0]),
            ])])
            .data()

        let read = try XCTUnwrap(DNGOpcodes.read(file))
        XCTAssertNil(read.correction.planeWarp)
        XCTAssertFalse(read.hasGeometry)
        XCTAssertEqual(read.declined.count, 1)
        XCTAssertTrue(read.correction.isIdentity)
    }

    func testAnOffCentreOpticalCentreIsRefused() throws {
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [(kr: [1.0, 0.05, 0, 0],
                                                kt: [0, 0])],
                                      centre: (0.48, 0.5))])
            .data()

        let read = try XCTUnwrap(DNGOpcodes.read(file))
        XCTAssertNil(read.correction.planeWarp)
        XCTAssertEqual(read.declined.count, 1)
    }

    func testACentreOffByARoundingErrorIsStillTheCentre() throws {
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [(kr: [1.0, 0.05, 0, 0],
                                                kt: [0, 0])],
                                      centre: (0.4999, 0.5001))])
            .data()

        XCTAssertNotNil(DNGOpcodes.read(file)?.correction.planeWarp)
    }

    func testAnOffCentreFalloffIsRefusedToo() throws {
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList2: [.vignette(k: [0.5, 0, 0, 0, 0],
                                          centre: (0.5, 0.55))])
            .data()

        let read = try XCTUnwrap(DNGOpcodes.read(file))
        XCTAssertTrue(read.correction.isIdentity)
        XCTAssertEqual(read.declined.count, 1)
    }

    func testAnOpcodeThatChangesNothingIsNotACorrection() {
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [(kr: [1.0, 0, 0, 0],
                                                kt: [0, 0])])])
            .data()

        XCTAssertNil(DNGOpcodes.read(file))
    }

    func testOpcodesThisAppHasNoUseForArePassedOver() throws {
        // Opcode 2 is WarpFisheye and 5 is FixBadPixelsConstant. Neither belongs in a radial table,
        // and a reader that mistook one for another would corrupt every frame from that camera.
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [
                .raw(id: 2, payload: [UInt8](repeating: 0x7F, count: 64)),
                .warp(planes: [(kr: [1.0, 0.05, 0, 0], kt: [0, 0])]),
                .raw(id: 5, payload: [UInt8](repeating: 0x11, count: 12)),
            ])
            .data()

        let read = try XCTUnwrap(DNGOpcodes.read(file))
        XCTAssertEqual(read.declined, [])
        XCTAssertEqual(try XCTUnwrap(read.correction.planeWarp).green.k1,
                       0.05, accuracy: 1e-7)
    }

    // MARK: - The crop the decoder actually hands back

    func testTheCurveIsRestatedAgainstTheFrameTheDecoderDelivers() throws {
        // The opcodes are written against the whole active area; the picture that comes out is the
        // default crop inside it. Here the crop is half the size, so a radius of 1 in the delivered
        // frame is a radius of 0.5 to the opcode — and the correction there has to match.
        let file = DNGBuilder(activeArea: (4000, 3000),
                              crop: (origin: (1000, 750), size: (2000, 1500)))
            .with(opcodeList3: [.warp(planes: [
                (kr: [1.0, 0.4, 0.2, 0.1], kt: [0, 0]),
            ])])
            .data()

        let warp = try XCTUnwrap(DNGOpcodes.read(file)?.correction.planeWarp)
        for r in stride(from: Float(0), through: 1, by: 0.125) {
            let uncropped = 1 + 0.4 * pow(r / 2, 2) + 0.2 * pow(r / 2, 4)
                + 0.1 * pow(r / 2, 6)
            XCTAssertEqual(warp.green.factor(r), uncropped, accuracy: 1e-6,
                           "at r = \(r)")
        }
    }

    func testTheFalloffIsRestatedAgainstTheSameFrame() throws {
        let file = DNGBuilder(activeArea: (4000, 3000),
                              crop: (origin: (1000, 750), size: (2000, 1500)))
            .with(opcodeList2: [.vignette(k: [0.4, 0.3, 0.2, 0.1, 0.05])])
            .data()

        let vignetting = try XCTUnwrap(DNGOpcodes.read(file)?.correction.vignetting)
        let k: [Double] = [0.4, 0.3, 0.2, 0.1, 0.05]
        for r in stride(from: Float(0), through: 1, by: 0.25) {
            var expected = 1.0
            var power = Double(r / 2) * Double(r / 2)
            for term in k {
                expected += term * power
                power *= Double(r / 2) * Double(r / 2)
            }
            XCTAssertEqual(vignetting.gain(r), Float(expected), accuracy: 1e-5,
                           "at r = \(r)")
        }
    }

    func testACropTheSameSizeAsTheFrameChangesNothing() throws {
        let plain = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [(kr: [1.0, 0.4, 0.2, 0.1],
                                                kt: [0, 0])])])
            .data()
        let cropped = DNGBuilder(activeArea: (4000, 3000),
                                 crop: (origin: (0, 0), size: (4000, 3000)))
            .with(opcodeList3: [.warp(planes: [(kr: [1.0, 0.4, 0.2, 0.1],
                                                kt: [0, 0])])])
            .data()

        XCTAssertEqual(DNGOpcodes.read(plain)?.correction,
                       DNGOpcodes.read(cropped)?.correction)
    }

    func testACropPushedToOneSideLeavesTheCurveAlone() throws {
        // An off-centre crop moves the optical centre rather than scaling the radius, and the
        // renderer corrects about the middle of the frame. Rescaling as though it were centred
        // would tilt the correction across the picture, so the crop is ignored instead.
        let file = DNGBuilder(activeArea: (4000, 3000),
                              crop: (origin: (0, 0), size: (2000, 1500)))
            .with(opcodeList3: [.warp(planes: [(kr: [1.0, 0.4, 0, 0],
                                                kt: [0, 0])])])
            .data()

        let warp = try XCTUnwrap(DNGOpcodes.read(file)?.correction.planeWarp)
        XCTAssertEqual(warp.green.k1, 0.4, accuracy: 1e-7)
    }

    // MARK: - Files that are not what they claim

    func testBytesThatAreNotATIFFAreDeclinedRatherThanGuessedAt() {
        XCTAssertNil(DNGOpcodes.read(Data()))
        XCTAssertNil(DNGOpcodes.read(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])))
        XCTAssertNil(DNGOpcodes.read(Data(repeating: 0, count: 4096)))
        // A TIFF header over nothing at all.
        XCTAssertNil(DNGOpcodes.read(Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])))
    }

    func testATruncatedFileIsDeclinedAtEveryLength() {
        // Every prefix of a valid file is a file some reader will be handed one day — a part
        // download, a copy that ran out of disk. None of them may read past their own end.
        let whole = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList2: [.vignette(k: [0.5, 0, 0, 0, 0])])
            .with(opcodeList3: [.warp(planes: [(kr: [1.0, 0.05, 0, 0],
                                                kt: [0, 0])])])
            .data()

        for length in 0..<whole.count {
            let read = DNGOpcodes.read(whole.prefix(length))
            if let read {
                XCTAssertFalse(read.correction.planeWarp?.green.k1 == 0.05
                               && read.correction.vignetting.isIdentity,
                               "a partial file read as a whole one at \(length) bytes")
            }
        }
        XCTAssertNotNil(DNGOpcodes.read(whole))
    }

    func testAnOpcodeThatLiesAboutItsLengthIsDeclined() {
        var list = OpcodeBuilder.warp(planes: [(kr: [1.0, 0.05, 0, 0],
                                                kt: [0, 0])]).bytes()
        // The length field sits at bytes 16..<20 of the first opcode, after the stream's own count,
        // the id and the two header words.
        list[16] = 0x7F
        list[17] = 0xFF
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(rawOpcodeList3: list)
            .data()

        XCTAssertNil(DNGOpcodes.read(file))
    }

    func testAnAbsurdOpcodeCountIsDeclinedWithoutTryingToReadIt() {
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(rawOpcodeList3: [0xFF, 0xFF, 0xFF, 0xFF])
            .data()

        XCTAssertNil(DNGOpcodes.read(file))
    }

    func testACoefficientThatIsNotANumberIsDeclined() {
        let file = DNGBuilder(activeArea: (4000, 3000))
            .with(opcodeList3: [.warp(planes: [
                (kr: [1.0, .nan, 0, 0], kt: [0, 0]),
            ])])
            .data()

        XCTAssertNil(DNGOpcodes.read(file))
    }
}

// MARK: - Building a DNG by hand

private struct OpcodeBuilder {
    var id: UInt32
    var payload: [UInt8]

    static func warp(planes: [(kr: [Double], kt: [Double])],
                     centre: (Double, Double) = (0.5, 0.5)) -> OpcodeBuilder {
        var payload = beLong(UInt32(planes.count))
        for plane in planes {
            for value in plane.kr { payload += beDouble(value) }
            for value in plane.kt { payload += beDouble(value) }
        }
        payload += beDouble(centre.0) + beDouble(centre.1)
        return OpcodeBuilder(id: 1, payload: payload)
    }

    static func vignette(k: [Double],
                         centre: (Double, Double) = (0.5, 0.5)) -> OpcodeBuilder {
        var payload: [UInt8] = []
        for value in k { payload += beDouble(value) }
        payload += beDouble(centre.0) + beDouble(centre.1)
        return OpcodeBuilder(id: 3, payload: payload)
    }

    static func raw(id: UInt32, payload: [UInt8]) -> OpcodeBuilder {
        OpcodeBuilder(id: id, payload: payload)
    }

    func bytes() -> [UInt8] { Self.list([self]) }

    static func list(_ opcodes: [OpcodeBuilder]) -> [UInt8] {
        var out = beLong(UInt32(opcodes.count))
        for opcode in opcodes {
            out += beLong(opcode.id)
            out += beLong(0x0104_0000)                  // the DNG version it needs
            out += beLong(0)                            // flags
            out += beLong(UInt32(opcode.payload.count))
            out += opcode.payload
        }
        return out
    }

    private static func beLong(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
         UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func beDouble(_ value: Double) -> [UInt8] {
        let pattern = value.bitPattern
        return (0..<8).map { UInt8(truncatingIfNeeded: pattern >> (56 - 8 * $0)) }
    }
}

private struct DNGBuilder {
    private var activeArea: (width: Int, height: Int)
    private var crop: (origin: (Int, Int), size: (Int, Int))?
    private var bigEndian: Bool
    private var opcodeList2: [UInt8]?
    private var opcodeList3: [UInt8]?
    private var behindAPreview = false

    init(activeArea: (Int, Int), crop: (origin: (Int, Int), size: (Int, Int))? = nil,
         bigEndian: Bool = false) {
        self.activeArea = (activeArea.0, activeArea.1)
        self.crop = crop
        self.bigEndian = bigEndian
    }

    func with(opcodeList2 opcodes: [OpcodeBuilder]) -> DNGBuilder {
        var copy = self
        copy.opcodeList2 = OpcodeBuilder.list(opcodes)
        return copy
    }

    func with(opcodeList3 opcodes: [OpcodeBuilder]) -> DNGBuilder {
        var copy = self
        copy.opcodeList3 = OpcodeBuilder.list(opcodes)
        return copy
    }

    func with(rawOpcodeList3 bytes: [UInt8]) -> DNGBuilder {
        var copy = self
        copy.opcodeList3 = bytes
        return copy
    }

    func asSubdirectoryOfAPreview() -> DNGBuilder {
        var copy = self
        copy.behindAPreview = true
        return copy
    }

    func data() -> Data {
        var entries: [(tag: UInt16, type: UInt16, count: UInt32, value: [UInt8])] = []
        entries.append((254, 4, 1, long(0)))            // NewSubFileType: the full image
        if let crop {
            entries.append((50719, 3, 2, short(UInt16(crop.origin.0))
                            + short(UInt16(crop.origin.1))))
            entries.append((50720, 3, 2, short(UInt16(crop.size.0))
                            + short(UInt16(crop.size.1))))
        }
        entries.append((50829, 3, 4, short(0) + short(0)
                        + short(UInt16(activeArea.height))
                        + short(UInt16(activeArea.width))))
        if let opcodeList2 { entries.append((51009, 7, UInt32(opcodeList2.count), opcodeList2)) }
        if let opcodeList3 { entries.append((51022, 7, UInt32(opcodeList3.count), opcodeList3)) }
        entries.sort { $0.tag < $1.tag }

        if !behindAPreview {
            return Data(header(firstDirectory: 8) + directory(entries, at: 8).bytes)
        }
        // IFD0 is a reduced-resolution preview carrying nothing but a pointer to the real one, whose
        // offset can only be known once the preview's own size is.
        let previewEntries: [(tag: UInt16, type: UInt16, count: UInt32, value: [UInt8])] = [
            (254, 4, 1, long(1)),                        // a preview, not the image
            (330, 4, 1, long(0)),                        // SubIFDs — patched below
        ]
        let previewSize = directory(previewEntries, at: 8).bytes.count
        let imageOffset = 8 + previewSize
        var preview = directory([(254, 4, 1, long(1)),
                                 (330, 4, 1, long(UInt32(imageOffset)))], at: 8)
        XCTAssertEqual(preview.bytes.count, previewSize)
        preview.bytes += directory(entries, at: imageOffset).bytes
        return Data(header(firstDirectory: 8) + preview.bytes)
    }

    // MARK: layout

    private struct Block { var bytes: [UInt8] }

    private func directory(
        _ entries: [(tag: UInt16, type: UInt16, count: UInt32, value: [UInt8])],
        at offset: Int
    ) -> Block {
        let headerSize = 2 + entries.count * 12 + 4
        var table = short(UInt16(entries.count))
        var heap: [UInt8] = []
        for entry in entries {
            table += short(entry.tag) + short(entry.type) + long(entry.count)
            if entry.value.count <= 4 {
                table += entry.value + [UInt8](repeating: 0,
                                               count: 4 - entry.value.count)
            } else {
                table += long(UInt32(offset + headerSize + heap.count))
                heap += entry.value
                if heap.count % 2 == 1 { heap.append(0) }   // TIFF keeps values word-aligned
            }
        }
        table += long(0)                                     // no directory after this one
        return Block(bytes: table + heap)
    }

    private func header(firstDirectory: UInt32) -> [UInt8] {
        (bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]) + short(42) + long(firstDirectory)
    }

    private func short(_ value: UInt16) -> [UInt8] {
        bigEndian
            ? [UInt8(value >> 8), UInt8(value & 0xFF)]
            : [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private func long(_ value: UInt32) -> [UInt8] {
        let b = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                 UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        return bigEndian ? b : b.reversed()
    }
}
