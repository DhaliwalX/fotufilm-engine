import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import FotufilmCore
@testable import FotufilmImaging

final class LensCorpusHarness: XCTestCase {
    private var corpus: [URL] {
        get throws {
            guard let root = ProcessInfo.processInfo.environment["FOTUFILM_LENS_CORPUS"]
            else { throw XCTSkip("Set FOTUFILM_LENS_CORPUS to a directory of captures") }
            let extensions: Set<String> = ["arw", "cr2", "cr3", "nef", "raf", "orf",
                                           "rw2", "dng", "heic", "jpg", "jpeg"]
            guard let walk = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)
            else { throw XCTSkip("\(root) is not readable") }
            let files = walk.compactMap { $0 as? URL }
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
            if files.isEmpty { throw XCTSkip("no captures under \(root)") }
            return files
        }
    }

    private var limit: Int {
        ProcessInfo.processInfo.environment["FOTUFILM_LENS_CORPUS_LIMIT"]
            .flatMap(Int.init) ?? 12
    }

    private func mapped(_ url: URL) throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private func hint(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.identifier
    }

    private func spread(_ files: [URL], _ count: Int) -> [URL] {
        guard files.count > count else { return files }
        let stride = Double(files.count) / Double(count)
        return (0..<count).map { files[Int(Double($0) * stride)] }
    }

    // MARK: - The reader against real containers

    func testNoRealCaptureIsMistakenForCarryingACorrection() throws {
        var read = 0, claimed: [String] = []
        for url in try corpus {
            guard let data = try? mapped(url) else { continue }
            read += 1
            guard let embedded = DNGOpcodes.read(data) else { continue }
            claimed.append("\(url.lastPathComponent): geometry="
                           + "\(embedded.hasGeometry) falloff=\(embedded.hasVignetting)")
        }
        XCTAssertGreaterThan(read, 0, "the corpus produced no readable file")
        // A DNG in the corpus may legitimately carry opcodes, so this reports rather than fails on
        // any find — but a claim on a file with no opcode list at all is the bug being watched for.
        for claim in claimed { print("carries opcodes — \(claim)") }
        let nonDNG = try corpus.filter { $0.pathExtension.lowercased() != "dng" }
            .map(\.lastPathComponent)
        for claim in claimed {
            let name = String(claim.prefix(while: { $0 != ":" }))
            XCTAssertFalse(nonDNG.contains(name),
                           "\(name) is not a DNG and cannot carry DNG opcodes")
        }
        print("read \(read) captures")
    }

    func testEveryPrefixOfARealCaptureIsSurvivable() throws {
        for url in spread(try corpus, 4) {
            let data = try mapped(url)
            // Dense over the header and the first directories, then sparse through the body.
            var lengths = Array(0...4096)
            lengths += stride(from: 8192, to: min(data.count, 1 << 20), by: 4096)
            lengths += stride(from: 1 << 20, to: data.count, by: 1 << 20)
            for length in lengths {
                _ = DNGOpcodes.read(data.prefix(length))
            }
        }
    }

    func testCorruptedRealCapturesAreSurvivable() throws {
        var generator = SystemRandomNumberGenerator()
        for url in spread(try corpus, 2) {
            // Only the head is worth damaging: everything the reader looks at lives in the
            // directories, and rewriting 40 MB of sensor data would just be slow.
            var head = Data(try mapped(url).prefix(1 << 18))
            for _ in 0..<400 {
                var damaged = head
                for _ in 0..<32 {
                    let at = Int.random(in: 0..<damaged.count, using: &generator)
                    damaged[damaged.startIndex + at] =
                        UInt8.random(in: 0...255, using: &generator)
                }
                // Cut as well as damaged. Damage alone mostly makes offsets that still land inside
                // a file this size; it is the short file behind a large offset that overruns, and a
                // half-written card copy is both at once.
                _ = DNGOpcodes.read(damaged.prefix(
                    Int.random(in: 8...damaged.count, using: &generator)))
            }
            // A file that is nothing but its own header, repeatedly.
            head.append(head)
            _ = DNGOpcodes.read(head)
        }
    }

    // MARK: - What the app reads off a real file

    func testRealCapturesCarryTheMetadataTheLensPathNeeds() throws {
        var described = 0
        var lenses: Set<String> = []
        for url in try corpus {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [String: Any] else { continue }
            let exif = properties[kCGImagePropertyExifDictionary as String]
                as? [String: Any] ?? [:]
            let auxiliary = properties[kCGImagePropertyExifAuxDictionary as String]
                as? [String: Any]
            guard let model = (exif[kCGImagePropertyExifLensModel as String] as? String)
                    ?? (auxiliary?["LensModel"] as? String),
                  !model.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            described += 1
            lenses.insert(model)

            let focal = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?
                .floatValue
            let aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?
                .floatValue
            // A profile is read at these two numbers, so a nonsense one is worse than a missing one.
            if let focal {
                XCTAssertTrue((1...2000).contains(focal),
                              "\(url.lastPathComponent) focal \(focal)")
            }
            if let aperture {
                XCTAssertTrue((0.7...100).contains(aperture),
                              "\(url.lastPathComponent) f/\(aperture)")
            }
        }
        XCTAssertGreaterThan(described, 0, "no capture named the lens it was taken with")
        print("named lenses: \(lenses.sorted().joined(separator: " · "))")
    }

    func testARealRawIsOnlyRecognisedWhenItsTypeIsNamed() throws {
        var checked = 0
        for url in spread(try corpus.filter { $0.pathExtension.lowercased() == "arw" }, 3) {
            let data = try mapped(url)
            checked += 1
            XCTAssertTrue(RawDecode.isRaw(data: data, identifierHint: hint(for: url)),
                          "\(url.lastPathComponent) with its type named")
            XCTAssertFalse(RawDecode.isRaw(data: data, identifierHint: nil),
                           "\(url.lastPathComponent) recognised from bytes alone")

            let named = try XCTUnwrap(RawDecode.filter(data: data,
                                                       identifierHint: hint(for: url)))
            XCTAssertNotEqual(named.nativeSize, .zero)
            // The decoder is the one holding the lens profiles, so this is the fact the app's
            // stand-down rule rests on.
            XCTAssertTrue(named.isLensCorrectionSupported,
                          "\(url.lastPathComponent) offers no decoder correction to stand down from")

            let unnamed = RawDecode.filter(data: data, identifierHint: nil)
            XCTAssertEqual(unnamed?.nativeSize ?? .zero, .zero,
                           "an unhinted \(url.pathExtension) decoded after all — "
                           + "if this starts passing the hint is no longer needed")
        }
        XCTAssertGreaterThan(checked, 0, "no ARW in the corpus")
    }

    func testTheRawFamilyIsNotAWorkingHint() throws {
        var checked = 0
        for url in spread(try corpus.filter { $0.pathExtension.lowercased() == "arw" }, 3) {
            let data = try mapped(url)
            checked += 1
            let named = try XCTUnwrap(
                RawDecode.filter(data: data, identifierHint: hint(for: url)))
            XCTAssertNotEqual(named.nativeSize, .zero, url.lastPathComponent)

            XCTAssertNil(RawDecode.filter(data: data,
                                          identifierHint: UTType.rawImage.identifier),
                         "\(url.lastPathComponent) opened under the bare family")
            XCTAssertNil(RawDecode.metadata(data: data,
                                            identifierHint: UTType.rawImage.identifier),
                         "\(url.lastPathComponent) measured under the bare family")
            // The family is still recognised *as* raw — it is the gate's answer that stays right
            // while the decoder's turns to nothing.
            XCTAssertTrue(RawDecode.isRaw(data: data,
                                          identifierHint: UTType.rawImage.identifier))
        }
        XCTAssertGreaterThan(checked, 0, "no ARW in the corpus")
    }

    func testWhetherTheDecoderOffersToCorrectTheseFiles() throws {
        var offered = 0, asked = 0
        for url in spread(try corpus.filter { RawDecode.isRaw(url: $0) }, limit) {
            let data = try mapped(url)
            guard RawDecode.isRaw(data: data, identifierHint: hint(for: url)),
                  let filter = RawDecode.filter(data: data,
                                                identifierHint: hint(for: url))
            else { continue }
            asked += 1
            // A filter that decodes nothing still answers every question about itself, so the
            // answers below are only worth reading once it is known to have opened the file.
            XCTAssertNotEqual(filter.nativeSize, .zero,
                              "\(url.lastPathComponent) opened into an empty decoder")
            if filter.isLensCorrectionSupported {
                offered += 1
                // The setting must actually take, or `supersedesDecoder` is a no-op dressed up as a
                // decision.
                filter.isLensCorrectionEnabled = false
                XCTAssertFalse(filter.isLensCorrectionEnabled,
                               "\(url.lastPathComponent) ignored being switched off")
                filter.isLensCorrectionEnabled = true
                XCTAssertTrue(filter.isLensCorrectionEnabled,
                              "\(url.lastPathComponent) ignored being switched on")
            }
        }
        XCTAssertGreaterThan(asked, 0, "no raw file could be opened for decode")
        print("decoder offers lens correction on \(offered) of \(asked) raw files")
    }

    func testCorrectingARealRawChangesThePictureWithoutBreakingIt() throws {
        try XCTSkipUnless(LensCorrectionFilter.isAvailable,
                          "Core Image kernel language unavailable")
        let context = CIContext(options: [.workingColorSpace: NSNull(),
                                          .outputColorSpace: NSNull()])
        let stack = LensCorrectionStack([
            LensCorrection(distortion: .poly3(k1: -0.06),
                           vignetting: .radial(k1: -0.35, k2: 0, k3: 0),
                           lateralChroma: .linear(red: 1.004, blue: 0.996))
        ])
        var tested = 0
        for url in spread(try corpus.filter { $0.pathExtension.lowercased() == "arw" },
                          min(limit, 4)) {
            guard let decoded = RawDecode.image(data: try mapped(url),
                                                identifierHint: hint(for: url),
                                                recipe: RawDecode.Recipe(
                                                    targetLongEdge: 1024,
                                                    correctsLens: false)) else { continue }
            XCTAssertFalse(decoded.extent.isEmpty,
                           "\(url.lastPathComponent) decoded to nothing")
            tested += 1
            let corrected = LensCorrectionFilter.apply(decoded, stack: stack)
            XCTAssertEqual(corrected.extent, decoded.extent,
                           "\(url.lastPathComponent) changed size")

            let before = pixels(decoded, in: context)
            let after = pixels(corrected, in: context)
            XCTAssertEqual(before.count, after.count)

            // The corner is where a barrel correction and a falloff both do their most, so it is
            // where a stack that reached the pixels is easiest to tell from one that didn't.
            var moved = 0, transparent = 0, wild = 0
            for index in stride(from: 0, to: before.count, by: 4) {
                if abs(before[index + 1] - after[index + 1]) > 0.002 { moved += 1 }
                // A hole in the frame reaches the export, and so does a non-finite pixel. Counted
                // rather than asserted one by one, so a real failure reports a number instead of
                // sixteen thousand identical lines.
                if after[index + 3] != 1 { transparent += 1 }
                if !after[index].isFinite { wild += 1 }
            }
            XCTAssertGreaterThan(moved, before.count / 4 / 20,
                                 "\(url.lastPathComponent): the correction barely touched it")
            XCTAssertEqual(transparent, 0, "\(url.lastPathComponent) went transparent")
            XCTAssertEqual(wild, 0, "\(url.lastPathComponent) went non-finite")
        }
        XCTAssertGreaterThan(tested, 0, "no raw file decoded")
    }

    private let probeSize = 128

    private func pixels(_ image: CIImage, in context: CIContext) -> [Float] {
        var out = [Float](repeating: 0, count: probeSize * probeSize * 4)
        // Sampled down to a fixed square so the two renders are comparable pixel for pixel whatever
        // the file's own shape is. Clamped first because a downsample this steep reaches outside the
        // frame at the border and would come back clear there — which is the sampling saying so, not
        // a hole in the picture. A hole inside the frame is still a hole after clamping.
        let scaled = image.clampedToExtent().transformed(by: CGAffineTransform(
            scaleX: CGFloat(probeSize) / image.extent.width,
            y: CGFloat(probeSize) / image.extent.height))
        out.withUnsafeMutableBytes { raw in
            context.render(scaled, toBitmap: raw.baseAddress!,
                           rowBytes: probeSize * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: probeSize, height: probeSize),
                           format: .RGBAf, colorSpace: nil)
        }
        return out
    }
}
