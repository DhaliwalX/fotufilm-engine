import Foundation
import FotufilmCore
import FotufilmImaging
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers
#endif

let usage = """
fotufilm — physically based film simulation

Usage:
  fotufilm <input> <output> [options]      Process an image
  fotufilm <input> <dir> --stages          Write the pipeline stage by stage
  fotufilm --make-chart <output>           Write a synthetic test chart
  fotufilm <a> <b> --diff <output>         Write A | B | amplified difference
  fotufilm --make-chart <f> --scene spectrum  Write the demo's spectrum scene
  fotufilm --list-stocks                   List stocks and the gauge each is known on
  fotufilm --dump-wasm-pack <f>            Export a stock's kernel inputs for the browser engine
  fotufilm --dump-wasm-stages <f>          Export the same, once per pipeline stage
  fotufilm --dump-spectra                  Write spectral profiles as JSON
  fotufilm --check-stocks                  Validate every installed stock
  fotufilm --seal-pack <dir> --pack-out <f>  Seal a stock directory into a pack
  fotufilm --open-pack <file>              List a sealed pack's contents
  fotufilm --make-pack-key                 Print a fresh pack key

Input may be JPEG/PNG/HEIC (any color space — wide gamut is converted),
16-bit TIFF/PNG, OpenEXR, gain-map HDR (HEIC/JPEG), or camera raw
(DNG, CR2/CR3, NEF, ARW, RAF, ORF, RW2, ...). Raw and HDR sources are
decoded scene-referred, so highlights above diffuse white reach the film
shoulder and drive halation the way they do on real film.

Options:
  --stock <name>     Film stock (default: first installed). See --list-stocks
  --format <name>    Film gauge (default: the gauge the stock is known on).
                     "sensor" cuts the film to the frame the input file says
                     its camera exposed. See --list-formats
  --ev <stops>       Exposure compensation in stops (default: 0)
  --autoexpose       Anchor the log-average scene luminance on mid-gray
  --wb <kelvin>      Scene illuminant, 2000-12000 K (default: 6504, D65).
                     On camera raw this is relative to the file's as-shot
                     balance, so 6504 is "as the camera saw it"
  --tint <n>         Green/magenta off the locus, -100...100 (default: 0)
  --background <c>  Scene-linear Rec.2020 background for associated-alpha input:
                     black, white, or R,G,B (default: black). The source is
                     composited before film processing and the output is opaque
  --depth <8|16>     Output bit depth (default: 8, dithered; 16 for PNG/TIFF)
  --hlg              Write the print as 16-bit Rec.2020 HLG instead of sRGB,
                     which is where a gain-map or HLG source's recovered
                     highlights have somewhere to land. Implies --depth 16.
  --grain <scale>    Grain multiplier, 0 disables (default: 1)
  --grain-model <m>  clump (default) or discs. `discs` lays Boolean discs at
                     the film's clump radius, scaled onto its published
                     granularity, instead of a blurred clump field: the texture
                     survives enlargement, saturates where discs overlap, and
                     only differs once a disc covers a pixel.
                     Costs about 5x the pixels and a one-off minute of
                     pipeline build
  --halation <scale> Halation multiplier, 0 disables (default: 1)
  --halation-colour <f>  How much the halo keeps the source's own colour
                     instead of the stock's layered red, 0-1 (default: 0).
                     The dimmer records are raised to the strongest record's
                     return, so the ring brightens toward the light's colour
  --halation-haze <mm>  The support's impurity scatter, as a Gaussian sigma
                     in millimeters softening the halo's edges (default: the
                     stock's own figure; sheets without one state 0, the
                     clean support)
  --estimated-halation  Use provisional spatial profiles where a stock has no
                     independently calibrated profile (default: off)
  --flare <scale>    Taking-lens veiling glare, 1 enables (default: 0 — a
                     photographed source already carries its own lens's glare)
  --couplers <scale> DIR + adjacency strength; 1 calibrated, overdrive compressed (default: 1)
  --bleach-bypass <f> Fraction of the developed silver the bleach leaves in the
                     negative, 0-1 (default: 0). The print re-times on the
                     denser mid-grey, so what changes is contrast and chroma.
                     Colour negative only
  --mottle <share>   Grain-size mixture override, 0-0.9 (default: the stock's
                     own, usually 0): the variance share of the published
                     granularity carried by a coarse second clump field — the
                     soft mottle under the sharp grain. The RMS anchor holds
                     whatever the split
  --shutter <secs>   Exposure time in seconds (default: instantaneous). When
                     the stock's datasheet publishes a long-exposure table the
                     emulsion leaves the reciprocity law as that table states,
                     frozen past the table's last row; a sheet that states no
                     table holds the law. The print re-times the mid; shadows
                     slide into the toe and any unequal failure casts the ends
  --push <stops>     Push (positive) or pull (negative) development, in stops
                     (default: 0). Must name an exact condition measured for
                     this stock's stated developer, dilution, temperature and
                     agitation; stocks or stop values without measurements are
                     rejected. Pair a push with its exposure change via --ev
  --expired <years>  Years past the process-by date at room temperature
                     (default: 0). One stop per decade slower, blue layer
                     first; base fog and grain rise with it. Add the stop the
                     lab rule asks for with --ev to keep the mids
  --print-light <k>  Colour temperature the finished print is viewed under, in
                     kelvin: daylight series from 4000 K up (5003 = D50 proof
                     light), Planckian below (2856 = tungsten). Greys hold —
                     the read adapts to the light — and the paper dyes'
                     metamerism moves. Default: D50 for paper, calibrated
                     5400 K xenon for cinema print, fixed D65 for screen
  --paper <name>     Output medium: ektacolor-edge (default), endura-premier,
                     crystal-archive, vision-2383, vision-2393,
                     eterna-cp, lab-scan, telecine, screen or negative.
                     Photo and projection variants use analytic example curves.
                     Reversal stocks use screen regardless of the requested medium.
  --negative <how>   Show the developed negative instead of the print it would
                     make: 'lightbox' keeps the base its own orange, 'scanner'
                     divides the base out. Ignored by a reversal stock, which
                     has no negative
  --filter <ids>     Absorbing filters on the front of the lens, comma separated
                     and applied in order: w85b, w80a, w25, nd09, cc20m and the
                     rest of the Wratten catalogue. Integrated spectrally
                     against the stock's own layer sensitivities, so the same
                     filter is a different filter on a different film
  --filter-coating <c>  uncoated, singleLayer or multiCoated (default). Sets
                     what each face reflects, and so what the filter costs in
                     light and adds in veiling glare
  --metering <m>     How the exposure was set behind the filter: ttl (default,
                     the camera's own photopic cell), factor (the published
                     filter factor, worked out against the emulsion) or none
                     (a fixed manual exposure, so the light loss lands on the
                     film)
  --diffusion <f>    A diffusion filter: promist, blackpromist, glimmerglass,
                     blackglimmerglass, fog, blackfog. A share of the light
                     meets a particle and is scattered or absorbed; the share
                     that missed every particle stays sharp
  --diffusion-grade <g>  1/8, 1/4, 1/2, 1 or 2 (default: 1/4)
  --focal <mm>       Lens focal length. Read by the diffusion filter, whose
                     halo is focal length times scattering angle — the reason
                     the same filter glows bigger on a longer lens. Default:
                     the gauge's own normal lens
  --seed <n>         Grain random seed (default: fixed)
  --local-tone <0|1> Regional highlight/shadow keying (default: 1)
  --stages           Instead of one render, write the frame the film would make
                     with only the physics enabled up to each stage, into the
                     directory named as the output. It starts from every stage
                     at its off position and turns them back on one at a time.
                     Stages 2-5 and 7 switch off outright. Stage 8 is skipped by
                     reading the developed negative instead of printing it.
                     Stages 1 and 6 have no true off position -- an emulsion that
                     does not capture or develop makes no image -- so they are
                     bypassed to an idealized form: non-overlapping layer
                     sensitivities, and the same characteristic curve with hard
                     knees instead of a toe and shoulder. Each frame is
                     accompanied by an amplified difference against the one
                     before it, so stages that move the image by a code value or
                     two are still visible

Pack options (--seal-pack / --open-pack):
  --pack-out <path>  Output file when sealing; output directory when opening
  --pack-kind <k>    vault, community or local (default: community)
  --pack-id <id>     Pack identity; imported stock ids are qualified with it
  --pack-version <v> Release version, e.g. 1.0.0
  --minimum-mac-app-version <v> Minimum Mac app version, e.g. 1.6
  --pack-name <s>    Display name
  --pack-author <s>  Credit
  --pack-notes <s>   Free text carried with the pack

The key comes from FOTUFILM_PACK_KEY (64 hex characters) and its id from
FOTUFILM_PACK_KEY_ID, so neither reaches a shell history or a process listing.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

var positional: [String] = []
var flags: [String: String] = [:]
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "--list-stocks" || a == "--list-formats" || a == "--dump-curves"
        || a == "--dump-spectra" || a == "--help" || a == "-h"
        || a == "--autoexpose" || a == "--check-stocks" || a == "--make-pack-key"
        || a == "--stages" || a == "--estimated-halation" || a == "--hlg" {
        flags[a] = ""
    } else if a.hasPrefix("--") {
        guard !args.isEmpty else { fail("Missing value for \(a)\n\n\(usage)") }
        flags[a] = args.removeFirst()
    } else {
        positional.append(a)
    }
}

if flags["--help"] != nil || flags["-h"] != nil {
    print(usage)
    exit(0)
}

if flags["--list-stocks"] != nil {
    for (key, stock) in FilmStock.presets.sorted(by: { $0.key < $1.key }) {
        print("\(key)\t\(stock.name)\t\(FilmFormat.nativeID(forStockID: key))")
    }
    exit(0)
}

if flags["--dump-curves"] != nil {
    var stocks: [String] = []
    for (key, stock) in FilmStock.presets.sorted(by: { $0.key < $1.key }) {
        var layers: [String] = []
        for (layer, curve) in stock.curves.enumerated() {
            var samples: [String] = []
            var x: Float = -3
            while x <= 3.001 {
                samples.append("[\(x),\(stock.developedDensity(layer: layer, logExposure: x))]")
                x += 0.02
            }
            let secondary = curve.secondary.map {
                ",\"secondary\":{\"gamma\":\($0.gamma),\"toe\":\($0.toe)," +
                "\"toeWidth\":\($0.toeWidth),\"shoulder\":\($0.shoulder)," +
                "\"shoulderWidth\":\($0.shoulderWidth)}"
            } ?? ""
            layers.append("""
            {"dMin":\(curve.dMin),"gamma":\(curve.gamma),"toe":\(curve.toe),\
            "toeWidth":\(curve.toeWidth),"shoulder":\(curve.shoulder),\
            "shoulderWidth":\(curve.shoulderWidth)\(secondary),\
            "samples":[\(samples.joined(separator: ","))]}
            """)
        }
        stocks.append("""
        "\(key)":{"name":"\(stock.name)","monochrome":\(stock.isMonochrome),\
        "reversal":\(stock.isReversal),\
        "grainStrength":\(stock.grainStrength),"layers":[\(layers.joined(separator: ","))]}
        """)
    }
    print("{\(stocks.joined(separator: ","))}")
    exit(0)
}

if flags["--dump-spectra"] != nil {
    func arrayJSON(_ values: [Float]) -> String {
        "[" + values.map { String($0) }.joined(separator: ",") + "]"
    }
    var stocks: [String] = []
    for (key, stock) in FilmStock.presets.sorted(by: { $0.key < $1.key }) {
        let sensitivity = stock.spectralProfile.layerSensitivity.map(arrayJSON).joined(separator: ",")
        let dyes = stock.spectralProfile.imageDyeDensity.map(arrayJSON).joined(separator: ",")
        stocks.append("\"\(key)\":{\"name\":\"\(stock.name)\",\"sensitivity\":[\(sensitivity)],\"dyes\":[\(dyes)]}")
    }
    print("{\"wavelengths\":\(arrayJSON(SpectralGrid.wavelengths)),\"stocks\":{\(stocks.joined(separator: ","))}}")
    exit(0)
}

if flags["--list-formats"] != nil {
    for (id, format) in FilmFormat.presets {
        print("\(id)\t\(format.name)\t(\(format.frameHeightMM) mm frame height)")
    }
    print("sensor\tThe camera's own frame\t(read off the input file)")
    exit(0)
}

if flags["--make-pack-key"] != nil {
    print(FilmPackKey.random().hex)
    exit(0)
}

if flags["--check-stocks"] != nil {
    var failures = 0
    for id in FilmStock.allPresetIDs {
        guard let definition = FilmStock.presetDefinitions[id] else { continue }
        do {
            try definition.validate()
        } catch {
            failures += 1
            print("✘ \(error)")
        }
    }
    for warning in FilmStockPack.shared.warnings { print("! \(warning)") }
    let checked = FilmStock.allPresetIDs.count
    if failures == 0 {
        print("\(checked) stock\(checked == 1 ? "" : "s") pass")
        exit(0)
    }
    fail("\(failures) of \(checked) stocks failed validation")
}

/// The key the pack commands work with, out of the environment so it never reaches a shell history
/// or a process listing.
func packKeyFromEnvironment() -> (key: FilmPackKey, id: UInt16) {
    guard let hex = ProcessInfo.processInfo.environment["FOTUFILM_PACK_KEY"] else {
        fail("""
        Set FOTUFILM_PACK_KEY to the 64-character hex key to seal or open with. \
        `fotufilm --make-pack-key` prints a fresh one.
        """)
    }
    guard let key = try? FilmPackKey(hex: hex) else {
        fail("FOTUFILM_PACK_KEY is not a \(FilmPackKey.byteCount)-byte hex key")
    }
    let id = ProcessInfo.processInfo.environment["FOTUFILM_PACK_KEY_ID"]
        .flatMap { UInt16($0) } ?? 1
    return (key, id)
}

if let directory = flags["--seal-pack"] {
    guard let outputPath = flags["--pack-out"] else {
        fail("--seal-pack needs --pack-out <file.\(FilmStockPack.sealedPathExtension)>")
    }
    let kindName = flags["--pack-kind"] ?? "community"
    let kind: FilmPackKind
    switch kindName {
    case "vault": kind = .vault
    case "community": kind = .community
    case "local": kind = .local
    default: fail("Unknown pack kind '\(kindName)'; expected vault, community or local")
    }

    let definitions: [String: FilmStockDefinition]
    do {
        definitions = try FilmStockPack.load(
            directory: URL(fileURLWithPath: directory, isDirectory: true))
    } catch {
        fail("\(error)")
    }
    guard !definitions.isEmpty else {
        fail("No stock JSON found in \(directory)")
    }
    for definition in definitions.values {
        do {
            try definition.validate()
        } catch {
            fail("\(error)")
        }
    }

    let packID = flags["--pack-id"]
        ?? URL(fileURLWithPath: directory).lastPathComponent
    let (key, keyID) = packKeyFromEnvironment()
    let manifest = FilmPackManifest(
        packID: packID,
        name: flags["--pack-name"] ?? packID,
        author: flags["--pack-author"],
        notes: flags["--pack-notes"],
        version: flags["--pack-version"],
        minimumMacAppVersion: flags["--minimum-mac-app-version"],
        stocks: definitions.keys.sorted().compactMap { definitions[$0] })
    do {
        let sealed = try FilmPackContainer.seal(manifest, kind: kind,
                                                keyID: keyID, key: key)
        try sealed.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("Sealed \(manifest.stocks.count) stocks as \(kind) pack "
                + "'\(packID)' (key \(keyID)) into \(outputPath)")
    } catch {
        fail("\(error)")
    }
    exit(0)
}

if let path = flags["--open-pack"] {
    let (key, keyID) = packKeyFromEnvironment()
    let keyring = FilmPackKeyring()
    for kind in [FilmPackKind.vault, .community, .local] {
        keyring.register(key, kind: kind, id: keyID)
    }

    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        fail("Could not read \(path): \(error)")
    }
    do {
        let (manifest, head) = try FilmPackContainer.open(data, keyring: keyring)
        print("pack \(manifest.packID) — \(manifest.name)")
        print("kind \(head.kind), key \(head.keyID), sealed \(manifest.created)")
        if let version = manifest.version { print("version \(version)") }
        if let minimum = manifest.minimumMacAppVersion { print("minimum Mac app \(minimum)") }
        if let author = manifest.author { print("by \(author)") }
        for stock in manifest.stocks {
            print("  \(stock.id)\t\(stock.name)")
        }
        if let outputPath = flags["--pack-out"] {
            let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for stock in manifest.stocks {
                try encoder.encode(stock).write(
                    to: directory.appendingPathComponent("\(stock.id).json"),
                    options: .atomic)
            }
            print("Wrote \(manifest.stocks.count) stocks to \(outputPath)")
        }
    } catch {
        fail("\(error)")
    }
    exit(0)
}

#if canImport(ImageIO)
/// OpenEXR convention stores associated RGB, including additive color where alpha is zero. Core
/// Image cannot represent that color internally because its working images are premultiplied, so
/// expose the same provider once with the alpha sample marked as padding. The ordinary decode still
/// supplies alpha; this image supplies only the RGB that must survive until scene compositing.
func associatedOpenEXRColor(url: URL) -> CIImage? {
    guard url.pathExtension.lowercased() == "exr",
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetType(source) as String? == "com.ilm.openexr-image" else {
        return nil
    }
    let options = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldAllowFloat: true,
    ] as CFDictionary
    guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options),
          let color = AssociatedAlphaImage.colorSamples(from: decoded) else {
        return nil
    }
    return CIImage(cgImage: color)
}

/// Loads any supported image as associated scene-referred linear Rec.2020 RGBA, preserving values
/// above 1 for HDR/raw sources. Association is retained until the caller composites the scene.
func loadLinear(path: String, balance: WhiteBalance)
    -> (rgba: [Float], width: Int, height: Int, remaining: WhiteBalance,
        sceneKelvin: Float?, contentHeadroom: Float) {
    let url = URL(fileURLWithPath: path)
    let isRaw = RawDecode.isRaw(url: url)
    let declaredHeadroom = isRaw ? nil : GainMapHeadroom.declared(url: url)
    let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    var image: CIImage?
    var remaining = balance
    var sceneKelvin: Float?
    var contentHeadroom: Float = 1
    var profileCorrection: CameraProfileCorrection.Resolved?
    var associatedEXRColor: CIImage?
    if isRaw {
        guard let raw = CIRAWFilter(imageURL: url) else {
            fail("Could not read raw file: \(path)")
        }
        let displacement = balance.mired
            - WhiteBalance.kelvinToMired(WhiteBalance.neutralKelvin)
        let asShot = raw.neutralTemperature > 0
            ? WhiteBalance.kelvinToMired(raw.neutralTemperature) : nil
        let placement = asShot.map {
            RawDecode.placement(displacementMired: displacement, asShotMired: $0)
        }
        RawDecode.configure(
            raw,
            recipe: RawDecode.Recipe(neutralKelvin: placement?.neutralKelvin ?? nil))
        remaining = RawDecode.remainingBalance(displacementMired: displacement,
                                               tint: balance.tint,
                                               bakedMired: placement?.bakedMired)
        // The illuminant-aware profile delta — the same wiring as the app's still path: the
        // demosaic is already colorimetric under the as-shot balance, so only the delta of
        // the profile's matrix against its daylight anchor may be applied, and only when the
        // camera resolves and the scene was warm enough for it to differ from identity.
        sceneKelvin = asShot.map(WhiteBalance.miredToKelvin)
        profileCorrection = CameraProfileCorrection.resolve(
            camera: RawDecode.cameraIdentity(url: url),
            sceneKelvin: sceneKelvin)
        image = raw.outputImage
    } else {
        associatedEXRColor = associatedOpenEXRColor(url: url)
        if #available(macOS 14.0, *) {
            image = CIImage(contentsOf: url, options: [.expandToHDR: true])
        }
        if image == nil {
            image = CIImage(contentsOf: url)
        }
        // The declared range, the app's rule exactly (`FilmRender`): the decoded image's own
        // statement when the platform reports one, and the file's own — a gain map's stated
        // ceiling, or the fixed one an HLG/PQ container stands for — when a declaring file
        // decodes to a neutral report. Raw never declares: its above-white light is the
        // negative's own path and is not rolled.
        if #available(macOS 15.0, *), let decoded = image {
            contentHeadroom = max(1, decoded.contentHeadroom)
        }
        if contentHeadroom <= 1, let declaredHeadroom {
            contentHeadroom = declaredHeadroom
        }
    }
    // Share the apps' eligibility rule and compare full-source renditions before crop or resize.
    if #available(macOS 14.0, *),
       ProcessedHDRExposure.isEligible(isRaw: isRaw, declaredHeadroom: declaredHeadroom),
       let hdr = image,
       let reference = CIImage(contentsOf: url, options: [.toneMapHDRtoSDR: true]) {
        let gain = ProcessedHDRExposure.referenceGain(
            expandedHDR: hdr, sdrReference: reference, context: context)
        image = ProcessedHDRExposure.applying(gain, to: hdr)
    }
    guard let ci = image else {
        fail("Could not read image: \(path)")
    }
    let width = Int(ci.extent.width.rounded()), height = Int(ci.extent.height.rounded())
    guard width > 0, height > 0, ci.extent.isInfinite == false else {
        fail("Image has no finite extent: \(path)")
    }
    guard let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else {
        fail("No extended linear Rec.2020 color space available")
    }
    var rgba = [Float](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { buffer in
        context.render(ci, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                       bounds: ci.extent, format: .RGBAf, colorSpace: space)
    }
    if let associatedEXRColor,
       Int(associatedEXRColor.extent.width.rounded()) == width,
       Int(associatedEXRColor.extent.height.rounded()) == height {
        var alpha = [Float](repeating: 1, count: width * height)
        for pixel in 0..<(width * height) { alpha[pixel] = rgba[pixel * 4 + 3] }
        rgba.withUnsafeMutableBytes { buffer in
            context.render(associatedEXRColor, toBitmap: buffer.baseAddress!,
                           rowBytes: width * 16, bounds: associatedEXRColor.extent,
                           format: .RGBAf, colorSpace: space)
        }
        for pixel in 0..<(width * height) { rgba[pixel * 4 + 3] = alpha[pixel] }
    }
    if let corrected = profileCorrection {
        CameraProfileCorrection.apply(corrected.matrix, toRGBA: &rgba)
        print(String(format: "Camera profile: %@ at %.0f K, max deviation %.4f",
                     corrected.profileID, corrected.cct, corrected.maxDeviation))
    }
    return (rgba, width, height, remaining, sceneKelvin, contentHeadroom)
}

func parseLinearBackground(_ value: String?) -> SIMD3<Float> {
    guard let value else { return .zero }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch normalized.lowercased() {
    case "black":
        return .zero
    case "white":
        return SIMD3(repeating: 1)
    default:
        let fields = normalized.split(separator: ",", omittingEmptySubsequences: false)
        let components = fields.compactMap {
            Float($0.trimmingCharacters(in: .whitespaces))
        }
        guard fields.count == 3, components.count == 3,
              components.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            fail("--background takes black, white, or three finite non-negative scene-linear "
                + "Rec.2020 values, for example 0.18,0.18,0.18")
        }
        return SIMD3(components[0], components[1], components[2])
    }
}

/// Exposure shift (in stops) that anchors the geometric-mean luminance of a scene-linear image on
/// 18% mid-gray — what a reflected-light meter does.
func autoExposureEV(rgba: [Float], width: Int, height: Int) -> Float {
    let n = width * height
    let weights = ColorScience.luminanceWeights
    var sumLog: Double = 0
    var counted = 0
    for i in 0..<n {
        let lum = weights.0 * rgba[i * 4] + weights.1 * rgba[i * 4 + 1]
                + weights.2 * rgba[i * 4 + 2]
        if lum > 1e-6 {
            sumLog += log2(Double(lum))
            counted += 1
        }
    }
    guard counted > 0 else { return 0 }
    return Float(log2(0.18) - sumLog / Double(counted))
}

func saveRGBA8(_ pixels: [UInt8], width: Int, height: Int, path: String,
               space: CFString = CGColorSpace.displayP3) {
    var data = pixels
    let colorSpace = CGColorSpace(name: space)!
    guard let ctx = CGContext(
        data: &data, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = ctx.makeImage() else { fail("Could not create output image") }
    writeImage(image, path: path)
}

func writeImage(_ image: CGImage, path: String) {
    let url = URL(fileURLWithPath: path)
    let lower = path.lowercased()
    let type: String
    if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") {
        type = UTType.jpeg.identifier
    } else if lower.hasSuffix(".tif") || lower.hasSuffix(".tiff") {
        type = UTType.tiff.identifier
    } else if lower.hasSuffix(".heic") || lower.hasSuffix(".heif") {
        type = UTType.heic.identifier
    } else {
        type = UTType.png.identifier
    }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
        fail("Could not create destination: \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("Could not write: \(path)") }
}

/// Writes display-linear reflectance as a 16-bit Rec.2020 HLG image — the same print
/// `saveReflectance` writes, given room above diffuse white instead of the SDR shoulder's
/// compression into `[0.9, 1)`.
///
/// This is the delivery half of the range the loader already reads in: a gain-map or HLG source
/// is metered into the film's latitude on the way through, and without this there was nowhere for
/// the result to land but an SDR container.
func saveHLG(_ rgba: [Float], width: Int, height: Int, path: String) {
    let components = width * height * 4
    guard components > 0, rgba.count >= components else {
        fail("Nothing to write to \(path)")
    }
    let pixels = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: components)
    pixels.initialize(repeating: 0)
    rgba.withUnsafeBufferPointer { source in
        PrintEncoding.encodeRows(source, rows: 0..<height, width: width,
                                 into: pixels, transfer: .hlg)
    }
    guard let space = PrintEncoding.colorSpace(for: .rec2020HLG) else {
        pixels.deallocate()
        fail("No Rec.2020 HLG color space available")
    }
    guard let image = PrintEncoding.makeImage(takingOwnershipOf: pixels,
                                              width: width, height: height,
                                              colorSpace: space) else {
        fail("Could not create the HLG output image")
    }
    writeImage(image, path: path)
}

/// Writes display-linear reflectance (interleaved RGBA floats) as an sRGB
/// image at the requested bit depth.
func saveReflectance(_ rgba: [Float], width: Int, height: Int, path: String,
                     depth: Int, seed: UInt64) {
    let n = width * height
    if depth <= 8 {
        var pixels = [UInt8](repeating: 255, count: n * 4)
        let ditherSeed = UInt32(truncatingIfNeeded: seed)
        for i in 0..<n {
            for c in 0..<3 {
                let v = ColorScience.linearToSrgb(ColorScience.displayShoulder(rgba[i * 4 + c]))
                let dither = triangularDither(index: UInt32(i), channel: UInt32(c), seed: ditherSeed)
                pixels[i * 4 + c] = UInt8(clamp(v * 255 + 0.5 + dither, 0, 255))
            }
            pixels[i * 4 + 3] = UInt8(clamp(rgba[i * 4 + 3] * 255 + 0.5, 0, 255))
        }
        saveRGBA8(pixels, width: width, height: height, path: path)
        return
    }
    var pixels = [UInt16](repeating: 65535, count: n * 4)
    for i in 0..<n {
        for c in 0..<3 {
            let v = ColorScience.linearToSrgb(ColorScience.displayShoulder(rgba[i * 4 + c]))
            pixels[i * 4 + c] = UInt16(clamp(v * 65535 + 0.5, 0, 65535))
        }
        pixels[i * 4 + 3] = UInt16(clamp(rgba[i * 4 + 3] * 65535 + 0.5, 0, 65535))
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    let image: CGImage? = pixels.withUnsafeBytes { buffer in
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: width * 8, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                     | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    guard let image else { fail("Could not create 16-bit output image") }
    writeImage(image, path: path)
}
#endif

func makeChart(width: Int = 960, height: Int = 640) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    func put(_ x: Int, _ y: Int, _ r: Float, _ g: Float, _ b: Float) {
        let i = (y * width + x) * 4
        pixels[i] = UInt8(clamp(r * 255, 0, 255))
        pixels[i + 1] = UInt8(clamp(g * 255, 0, 255))
        pixels[i + 2] = UInt8(clamp(b * 255, 0, 255))
        pixels[i + 3] = 255
    }
    for y in 0..<(height / 2) {
        for x in 0..<width {
            let v = Float(x) / Float(width - 1)
            put(x, y, v, v, v)
        }
    }
    for y in (height / 8)..<(height / 4) {
        for x in (width * 3 / 8)..<(width * 5 / 8) {
            put(x, y, 1, 1, 1)
        }
    }
    let patches: [(Float, Float, Float)] = [
        (0.90, 0.10, 0.10), (0.10, 0.75, 0.15), (0.10, 0.20, 0.85),
        (0.95, 0.85, 0.10), (0.80, 0.15, 0.75), (0.10, 0.80, 0.80),
        (0.87, 0.67, 0.53), (0.55, 0.38, 0.28), (0.18, 0.18, 0.18),
    ]
    let cols = 3
    let patchW = width / cols
    let patchH = (height / 2) / 3
    for (idx, p) in patches.enumerated() {
        let px = (idx % cols) * patchW
        let py = height / 2 + (idx / cols) * patchH
        for y in py..<min(py + patchH, height) {
            for x in px..<min(px + patchW, width) {
                put(x, y, p.0, p.1, p.2)
            }
        }
    }
    return pixels
}

/// The demo's spectrum scene, encoded for a PNG.
///
/// The scene itself is `SpectrumScene` in FotufilmCore, because the app's Film Model screen develops
/// the same picture and two copies of it would drift. What stays here is only the encode: the
/// levels are authored scene-linear, and a browser canvas hands its bytes back as sRGB.
func makeSpectrumScene(width: Int, height: Int) -> [UInt8] {
    let scene = SpectrumScene.make(width: width, height: height)
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    func encode(_ v: Float) -> UInt8 {
        UInt8(clamp(ColorScience.linearToSrgb(clamp(v, 0, 1)) * 255 + 0.5, 0, 255))
    }
    for i in 0..<(width * height) {
        pixels[i * 4] = encode(scene.image.planes[0][i])
        pixels[i * 4 + 1] = encode(scene.image.planes[1][i])
        pixels[i * 4 + 2] = encode(scene.image.planes[2][i])
    }
    return pixels
}

#if canImport(ImageIO)
if let chartPath = flags["--make-chart"] {
    var width = 960, height = 640
    if let size = flags["--chart-size"] {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            fail("--chart-size takes WIDTHxHEIGHT, e.g. 1024x683")
        }
        (width, height) = (parts[0], parts[1])
    }
    if flags["--scene"] == "spectrum" {
        // Written sRGB rather than Display P3: the levels in this scene are chosen for what the
        // film should see, and a browser canvas returns whatever it was given as sRGB.
        saveRGBA8(makeSpectrumScene(width: width, height: height),
                  width: width, height: height, path: chartPath, space: CGColorSpace.sRGB)
        print("Wrote the spectrum scene at \(width)x\(height) to \(chartPath)")
        exit(0)
    }
    saveRGBA8(makeChart(width: width, height: height), width: width, height: height, path: chartPath)
    print("Wrote test chart to \(chartPath)")
    exit(0)
}

// A/B evidence for engine levers: two finished renders side by side with their
// amplified difference, plus the numbers the difference amounts to.
if let diffPath = flags["--diff"] {
    guard positional.count == 2 else {
        fail("--diff <out> takes two rendered images: fotufilm <a> <b> --diff <out>")
    }
    let a = loadLinear(path: positional[0], balance: .neutral)
    let b = loadLinear(path: positional[1], balance: .neutral)
    guard a.width == b.width, a.height == b.height else {
        fail("Images differ in size: \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
    }
    let width = a.width, height = a.height, count = width * height
    var peak: Float = 0
    var sum: Double = 0, sumSquares: Double = 0
    var channelSum = [Double](repeating: 0, count: 3)
    var difference = [Float](repeating: 1, count: count * 4)
    for i in 0..<count {
        for c in 0..<3 {
            let d = abs(a.rgba[i * 4 + c] - b.rgba[i * 4 + c])
            difference[i * 4 + c] = d
            peak = max(peak, d)
            sum += Double(d)
            sumSquares += Double(d) * Double(d)
            channelSum[c] += Double(a.rgba[i * 4 + c] - b.rgba[i * 4 + c])
        }
    }
    // Amplify so the largest change appears as display white, exactly as the
    // stage sequence presents its deltas.
    let gain = peak > 1e-6 ? 0.9 / peak : 1
    var composite = [Float](repeating: 1, count: count * 3 * 4)
    for y in 0..<height {
        for x in 0..<width {
            let src = (y * width + x) * 4
            let row = y * width * 3
            for c in 0..<3 {
                composite[(row + x) * 4 + c] = a.rgba[src + c]
                composite[(row + width + x) * 4 + c] = b.rgba[src + c]
                composite[(row + 2 * width + x) * 4 + c] = difference[src + c] * gain
            }
        }
    }
    let depth = Int(flags["--depth"] ?? "8") ?? 8
    saveReflectance(composite, width: width * 3, height: height,
                    path: diffPath, depth: depth, seed: 0)
    let pixels = Double(count * 3)
    print(String(format: "peak %.5f  mean %.5f  rms %.5f  gain %.0fx",
                 peak, sum / pixels, (sumSquares / pixels).squareRoot(), gain))
    print(String(format: "signed channel means  R %+.5f  G %+.5f  B %+.5f",
                 channelSum[0] / Double(count), channelSum[1] / Double(count),
                 channelSum[2] / Double(count)))
    exit(0)
}

// The pack export names its own output and reads no image, so it is the one mode that resolves a
// stock without an input/output pair.
/// Ideal capture: narrow, non-overlapping layer sensitivities on the sRGB
/// primaries, so each layer records exactly one primary and the emulsion has no
/// spectral crosstalk at all. Stage 1 cannot be removed — without exposure there
/// is no latent image — so this stands in for its off position: the difference
/// against it is what the stock's real, broadly overlapping sensitivities do.
func idealizedCapture(_ profile: FilmSpectralProfile) -> FilmSpectralProfile {
    let centers: [Float] = [600, 540, 460]
    let sigma: Float = 12
    var ideal = profile
    ideal.layerSensitivity = centers.map { center in
        SpectralGrid.wavelengths.map { nm in
            let z = (nm - center) / sigma
            return exp(-0.5 * z * z)
        }
    }
    return ideal
}

/// A characteristic curve with the toe and shoulder rolloff taken out: the same
/// dMin, gamma, toe and shoulder positions, but hard knees instead of softplus
/// ones, so the working range is a pure straight line. Development cannot be
/// removed either; this is the curve with its shape removed but its calibration
/// intact, so mid-gray stays anchored.
func straightLine(_ curve: CharacteristicCurve) -> CharacteristicCurve {
    CharacteristicCurve(dMin: curve.dMin, gamma: curve.gamma,
                        toe: curve.toe, toeWidth: 1e-3,
                        shoulder: curve.shoulder, shoulderWidth: 1e-3)
}

/// Produces cumulative pipeline-stage renders and amplified differences.
/// Spatial stages 2, 3, 4, 5, and 7 are disabled through their source parameters. Capture and
/// development use idealized forms because they cannot be disabled; stage 8 reads base-free density.
/// One frame of the walkthrough: the stock and options that produce it, named.
struct PipelineStage {
    let id: String
    let label: String
    let stock: FilmStock
    let options: FotufilmEngine.Options
}

/// The walkthrough itself — every stage at its off position, then one stage turned back on per
/// step, in the order the light meets them.
///
/// This is the single definition of what "stage N off" means. The renderer developing an image
/// and the exporter sealing packs for the browser both read it, so the two cannot drift: a browser
/// frame and a native frame for the same step are the same stock and the same options.
func stageSequence(stock: FilmStock, options: FotufilmEngine.Options) -> [PipelineStage] {
    var bare = stock
    bare.spectralProfile = idealizedCapture(stock.spectralProfile)
    bare.curves = stock.curves.map(straightLine)
    bare.flare = 0
    bare.emulsionDiffusionMM = stock.emulsionDiffusionMM.map { _ in 0 }
    bare.emulsionDiffusionSecondaryMM = stock.emulsionDiffusionSecondaryMM.map { _ in 0 }
    bare.emulsionDiffusionPrimaryShare = stock.emulsionDiffusionPrimaryShare.map { _ in 1 }
    bare.lumaDiffusionMM = 0
    bare.mtfLumaShare = 0
    bare.adjacencyStrength = 0

    var quiet = options
    // Stage 2 is off by default now, so the walkthrough has to ask for it back —
    // otherwise the step labelled "lens flare" would render without any.
    quiet.flareScale = 0
    quiet.halationScale = 0
    quiet.couplerScale = 0
    quiet.grainScale = 0
    // Stage 8 off: the developed negative read straight, base divided out, with
    // no paper anywhere in the path.
    if !stock.isReversal { quiet.negativeViewing = .scanner }

    var steps: [PipelineStage] = []
    // Turned back on in the order the light meets them, so the sequence walks
    // the pipeline rather than the engine's switchability. Everything before
    // stage 8 is therefore a negative: the print is the last thing to happen.
    steps.append(PipelineStage(id: "01-bypassed", label: "Every stage at its off position",
                                stock: bare, options: quiet))

    bare.spectralProfile = stock.spectralProfile
    steps.append(PipelineStage(id: "02-exposure", label: "Stage 1 — spectral exposure",
                                stock: bare, options: quiet))

    bare.flare = stock.flare
    quiet.flareScale = options.flareScale > 0 ? options.flareScale : 1
    steps.append(PipelineStage(id: "03-flare", label: "Stage 2 — lens flare",
                                stock: bare, options: quiet))

    bare.emulsionDiffusionMM = stock.emulsionDiffusionMM
    bare.emulsionDiffusionSecondaryMM = stock.emulsionDiffusionSecondaryMM
    bare.emulsionDiffusionPrimaryShare = stock.emulsionDiffusionPrimaryShare
    bare.lumaDiffusionMM = stock.lumaDiffusionMM
    bare.mtfLumaShare = stock.mtfLumaShare
    steps.append(PipelineStage(id: "04-diffusion", label: "Stage 3 — emulsion diffusion",
                                stock: bare, options: quiet))

    quiet.halationScale = options.halationScale
    steps.append(PipelineStage(id: "05-halation", label: "Stage 4 — halation",
                                stock: bare, options: quiet))

    quiet.couplerScale = options.couplerScale
    bare.adjacencyStrength = stock.adjacencyStrength
    steps.append(PipelineStage(id: "06-couplers", label: "Stage 5 — DIR couplers and adjacency",
                                stock: bare, options: quiet))

    bare.curves = stock.curves
    steps.append(PipelineStage(id: "07-development", label: "Stage 6 — H&D development",
                                stock: bare, options: quiet))

    quiet.grainScale = options.grainScale
    steps.append(PipelineStage(id: "08-grain", label: "Stage 7 — grain",
                                stock: bare, options: quiet))

    // The developed negative as the print stage actually sees it, base and all,
    // before stage 8 turns it into a positive.
    if !stock.isReversal {
        var onLightBox = quiet
        onLightBox.negativeViewing = .lightBox
        steps.append(PipelineStage(id: "09-negative", label: "Stage 8 input — the developed negative",
                                stock: bare, options: onLightBox))
    }

    quiet.negativeViewing = options.negativeViewing
    steps.append(PipelineStage(id: "10-print", label: "Stage 8 — output medium",
                                stock: bare, options: quiet))

    return steps
}

/// Develops one image through every stage of the walkthrough, writing a frame per step and an
/// amplified difference against the step before it.
func writeStageSequence(linear: ImageBuffer, alpha: [Float], stock: FilmStock,
                        options: FotufilmEngine.Options, directory: String, depth: Int) {
    do {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory, isDirectory: true),
            withIntermediateDirectories: true)
    } catch {
        fail("Could not create \(directory): \(error)")
    }
    let width = linear.width, height = linear.height
    let count = width * height
    let steps = stageSequence(stock: stock, options: options)

    // A manifest beside the frames, so anything reading the directory back — the browser demo's
    // static fallback among them — gets the labels and the order from the run that wrote them
    // rather than by parsing filenames or this program's console output.
    var manifest: [String] = []

    var previous: [Float]?
    for step in steps {
        let out = FotufilmEngine(stock: step.stock, options: step.options)
            .process(linearRGB: linear)
        var reflectance = [Float](repeating: 1, count: count * 4)
        for i in 0..<count {
            reflectance[i * 4] = out.planes[0][i]
            reflectance[i * 4 + 1] = out.planes[1][i]
            reflectance[i * 4 + 2] = out.planes[2][i]
            reflectance[i * 4 + 3] = alpha[i * 4 + 3]
        }
        saveReflectance(reflectance, width: width, height: height,
                        path: "\(directory)/\(step.id).png", depth: depth,
                        seed: step.options.seed)

        // The lightbox negative is an aside, not a step: it neither takes a
        // difference nor becomes the baseline for the print that follows it.
        let isAside = step.id.hasSuffix("-negative")
        let hasDelta = previous != nil && !isAside
        manifest.append("""
        {"id":"\(step.id)","label":"\(step.label)","file":"\(step.id).png"\
        \(hasDelta ? ",\"delta\":\"\(step.id)-delta.png\"" : "")}
        """)
        if let previous, !isAside {
            var difference = [Float](repeating: 1, count: count * 4)
            var peak: Float = 0
            for i in 0..<count {
                for c in 0..<3 {
                    let d = abs(reflectance[i * 4 + c] - previous[i * 4 + c])
                    difference[i * 4 + c] = d
                    peak = max(peak, d)
                }
            }
            // Amplify so the largest change this stage made appears as display
            // white; without it the subtler stages are a code value or two.
            let gain = peak > 1e-6 ? 0.9 / peak : 1
            for i in 0..<(count * 4) where i % 4 != 3 { difference[i] *= gain }
            saveReflectance(difference, width: width, height: height,
                            path: "\(directory)/\(step.id)-delta.png", depth: depth,
                            seed: step.options.seed)
            print(String(format: "%@\tpeak %.4f\tgain %.0fx", step.label, peak, gain))
        } else {
            print(step.label)
        }
        if !isAside { previous = reflectance }
    }
    let entries: String = manifest.joined(separator: ",")
    let index: String = """
    {"stock":"\(stockID)","name":"\(stock.name)","stages":[\(entries)]}
    """
    do {
        try index.write(toFile: "\(directory)/index.json", atomically: true, encoding: .utf8)
    } catch {
        fail("Could not write \(directory)/index.json: \(error.localizedDescription)")
    }
    print("Wrote \(steps.count) stage frames to \(directory)")
}

guard positional.count == 2 || flags["--dump-wasm-pack"] != nil
    || flags["--dump-wasm-stages"] != nil else { fail(usage) }

if FilmStock.allPresetIDs.isEmpty {
    if let error = FilmStockPack.loadError {
        fail("No film stocks could be loaded: \(error)")
    }
    fail("""
    No film stocks installed. Fotufilm ships the model, not the calibration; \
    point FOTUFILM_STOCKS at a stock pack directory, or use the example stocks \
    bundled with the package. See tools/calibration/STOCK_PACKS.md.
    """)
}

let stock: FilmStock
let stockID: String
if let requested = flags["--stock"] {
    guard let match = FilmStock.named(requested) else {
        fail("Unknown stock '\(requested)'. Use --list-stocks to see options.")
    }
    stock = match
    stockID = requested
} else {
    stockID = FilmStock.presetIDs.first ?? FilmStock.allPresetIDs.first!
    stock = FilmStock.named(stockID)!
}

var options = FotufilmEngine.Options()
options.format = FilmFormat.native(forStockID: stockID)
if let formatID = flags["--format"] {
    // `sensor` is the frame the input file says it was exposed on, cut from the film the stock
    // names — the app's own automatic gauge, asked for by hand here because the CLI is a
    // reproducible path and a default that changed with the input's metadata would not be one.
    if formatID == "sensor" {
        guard let input = positional.first else {
            fail("--format sensor needs an input file to read the frame from.")
        }
        guard let frame = SensorFrame.read(url: URL(fileURLWithPath: input)) else {
            fail("""
            \(input) does not say what frame it was exposed on. \
            Name a gauge instead; --list-formats has them.
            """)
        }
        options.format = frame.gauge.format
        print("""
        Sensor frame: \(frame.frameSize) \
        (\(String(format: "%.2f", frame.cropFactor))x crop) \
        -> \(options.format.name), the nearest gauge \
        (\(String(format: "%.2f", frame.gaugeStretch))x)
        """)
    } else {
        guard let format = FilmFormat.preset(id: formatID) else {
            fail("Unknown format '\(formatID)'. Use --list-formats to see options.")
        }
        options.format = format
    }
}
if let ev = flags["--ev"] { options.exposureEV = Float(ev) ?? 0 }
if let g = flags["--grain"] { options.grainScale = Float(g) ?? 1 }
if let model = flags["--grain-model"] {
    switch model {
    case "clump": options.grainModel = .clumpField
    case "discs": options.grainModel = .discs
    default:
        FileHandle.standardError.write(Data(
            "unknown grain model '\(model)'; expected clump or discs\n".utf8))
        exit(2)
    }
}
if let h = flags["--halation"] { options.halationScale = Float(h) ?? 1 }
if let c = flags["--halation-colour"] {
    options.halationSourceColour = Float(c) ?? 0
}
if let z = flags["--halation-haze"] { options.halationHazeMM = Float(z) }
options.useEstimatedHalationProfile = flags["--estimated-halation"] != nil
// Capture veiling glare, off unless asked for: see Options.flareScale.
if let f = flags["--flare"] { options.flareScale = Float(f) ?? 1 }
if let c = flags["--couplers"] { options.couplerScale = Float(c) ?? 1 }
if let b = flags["--bleach-bypass"] { options.bleachBypass = Float(b) ?? 0 }
if let m = flags["--mottle"] { options.grainMottleShare = Float(m) }
if let s = flags["--shutter"] { options.shutterSeconds = Float(s) }
if let p = flags["--push"] {
    guard let stops = Float(p), stops.isFinite else {
        fail("Invalid --push value '\(p)'; expected a measured stop value for this stock.")
    }
    do {
        _ = try stock.pushed(stops: stops)
    } catch {
        fail("\(error)")
    }
    options.developmentEV = stops
}
if let y = flags["--expired"] { options.expiredYears = Float(y) ?? 0 }
if let k = flags["--print-light"] { options.printViewingKelvin = Float(k) }
if let s = flags["--seed"] { options.seed = UInt64(s) ?? options.seed }
if let f = flags["--focal"] { options.focalLengthMM = Float(f) }
if let coating = flags["--filter-coating"], FilterCoating(rawValue: coating) == nil {
    fail("Unknown coating '\(coating)'. Choices: "
         + FilterCoating.allCases.map(\.rawValue).joined(separator: ", "))
}
let filterCoating = flags["--filter-coating"]
    .flatMap { FilterCoating(rawValue: $0) } ?? .multiCoated
if let list = flags["--filter"] {
    var fitted: [LensFilter] = []
    for id in list.split(separator: ",").map(String.init) {
        guard var found = LensFilter.catalogued(id) else {
            fail("Unknown filter '\(id)'. Choices: "
                 + LensFilter.catalogue.map(\.id).joined(separator: ", "))
        }
        found.coating = filterCoating
        fitted.append(found)
    }
    let metering = flags["--metering"] ?? "ttl"
    let compensation: LensFilterCompensation
    switch metering {
    case "none": compensation = .none
    case "ttl": compensation = .throughTheLens
    case "factor": compensation = .filmSpeed
    default: fail("Unknown metering '\(metering)'. Choices: none, ttl, factor")
    }
    options.lensFilters = LensFilterStack(fitted, compensation: compensation)
}
if let family = flags["--diffusion"] {
    guard let chosen = DiffusionFilter.Family(rawValue: family) else {
        fail("Unknown diffusion filter '\(family)'. Choices: "
             + DiffusionFilter.Family.allCases.map(\.rawValue).joined(separator: ", "))
    }
    let name = flags["--diffusion-grade"] ?? "1/4"
    guard let grade = DiffusionFilter.Grade(rawValue: name) else {
        fail("Unknown grade '\(name)'. Choices: "
             + DiffusionFilter.Grade.allCases.map(\.rawValue).joined(separator: ", "))
    }
    options.diffusionFilter = DiffusionFilter.preset(chosen, grade: grade,
                                                     coating: filterCoating)
}
if let p = flags["--paper"] {
    guard let choice = PrintPaper.preset(id: p) else {
        fail("Unknown paper '\(p)'. Choices: "
             + PrintPaper.allCases.map(\.id).joined(separator: ", "))
    }
    options.paper = choice
}
// The regional tone base is measured from the image being developed, so it is the one control the
// exported pack cannot carry. Turning it off here is what makes a native render comparable to the
// browser's.
if let t = flags["--local-tone"] { options.localTone = t != "0" }
if let n = flags["--negative"] {
    switch n {
    case "lightbox": options.negativeViewing = .lightBox
    case "scanner": options.negativeViewing = .scanner
    default: fail("--negative takes 'lightbox' or 'scanner'")
    }
}
// The browser engine runs the same Halide kernels but cannot build their inputs: the spectral
// tables are a wavelength-domain solve, and the packed configuration folds in the coupler warp,
// the halation kernel and the print curves. All of it is exported here instead, so the WebAssembly
// side only has to hand the numbers to the kernel.
//
// The pack is tied to a frame size, because every spatial parameter in it is a diffusion length
// in millimetres scaled by the frame's pixels-per-mm. A frame of another size needs another pack.
/// The frame a pack is being sealed for. Every spatial parameter in a pack is a diffusion length
/// in millimetres multiplied by this frame's pixels-per-mm, so the size is part of the export,
/// not a detail of the caller.
func packFrameSize() -> (width: Int, height: Int) {
    let size = flags["--pack-size"] ?? "1600x900"
    let parts = size.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
        fail("--pack-size takes WIDTHxHEIGHT, e.g. 1024x683")
    }
    return (parts[0], parts[1])
}

/// Little-endian appenders shared by the two exports. Swift's `Data` has no numeric append and the
/// browser reads these buffers as typed arrays, so the byte order is written out rather than
/// inherited from the host.
extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) { appendUInt32(UInt32(bitPattern: value)) }

    mutating func appendFloats(_ values: [Float]) {
        values.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map {
                append(UnsafeBufferPointer(start: UnsafeRawPointer($0)
                    .assumingMemoryBound(to: UInt8.self),
                    count: buffer.count * MemoryLayout<Float>.size))
            }
        }
    }

    /// A length-prefixed UTF-8 string, tail-padded so whatever follows stays four-byte aligned.
    /// The floats after it are read through `Float32Array`, which refuses an odd offset.
    mutating func appendPaddedString(_ string: String) {
        let bytes = Array(string.utf8)
        appendInt32(Int32(bytes.count))
        append(contentsOf: bytes)
        append(contentsOf: [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4))
    }
}

if let packPath = flags["--dump-wasm-pack"] {
    let (packWidth, packHeight) = packFrameSize()

    // This export has no source image from which to measure a local tone base. Disable local tone
    // and retain the invocation's identity grid.
    options.localTone = false

    let invocation = FilmEngineInvocation(stock: stock, options: options,
                                          width: packWidth, height: packHeight)
    let tables = invocation.spectral
    let lutCount = tables.exposure.values.count

    var pack = Data()
    pack.append(contentsOf: Array("FSWP".utf8))
    pack.appendUInt32(1)
    pack.appendInt32(Int32(packWidth))
    pack.appendInt32(Int32(packHeight))
    pack.appendInt32(invocation.featureMask)
    pack.appendUInt32(invocation.seed)
    pack.appendInt32(Int32(invocation.configuration.count))
    pack.appendInt32(Int32(tables.exposure.dimension))
    pack.appendInt32(Int32(lutCount))
    pack.appendInt32(tables.paperOutput == nil ? 0 : 1)
    pack.appendFloats(invocation.configuration)
    pack.appendFloats(tables.exposure.values)
    pack.appendFloats(tables.filmOutput.values)
    // A reversal stock prints nothing, and the kernel never samples the cube. It still has to be
    // bound, so it goes across as zeros rather than as a missing buffer.
    pack.appendFloats(tables.paperOutput?.values ?? [Float](repeating: 0, count: lutCount))

    do {
        try pack.write(to: URL(fileURLWithPath: packPath))
    } catch {
        fail("Could not write \(packPath): \(error.localizedDescription)")
    }
    print("""
    \(stockID) on \(options.paper(for: stock).id) at \(packWidth)x\(packHeight): \
    \(pack.count / 1024) KiB, features 0x\(String(invocation.featureMask, radix: 16)) \
    -> \(packPath)
    """)
    exit(0)
}

// The stage sidecar: the same export, once for each state in `stageSequence`, so a browser can
// show what each part of the pipeline contributed.
//
// Sealing a whole pack per stage would cost a stage's worth of three colour cubes each — some
// 20 MiB for one stock, nearly all of it repeated. Two things keep it small. A stage stores its
// configuration as the slots that differ from the base pack, because switching off flare, halation,
// couplers or grain moves a handful of the 8681 and leaves the rest alone. And the cubes are pooled:
// the six stages developed before the H&D curve comes back all read the same straight-line film
// cube, so it is written once and referenced. The reader rebuilds a stage from the base pack, the
// slot differences, and whichever pooled cubes the stage names.
if let stagesPath = flags["--dump-wasm-stages"] {
    let (packWidth, packHeight) = packFrameSize()
    // As in the single-pack export: no image here means no regional exposure to measure.
    options.localTone = false

    let stages = stageSequence(stock: stock, options: options)
    // The last stage is the film as it actually is, so its tables are the base every other stage is
    // written as a difference from — and it is the pack the browser starts a fresh image with.
    guard let base = stages.last.map({
        FilmEngineInvocation(stock: $0.stock, options: $0.options,
                             width: packWidth, height: packHeight)
    }) else {
        fail("The pipeline has no stages to export.")
    }
    let baseTables = base.spectral
    let lutCount = baseTables.exposure.values.count
    let emptyCube = [Float](repeating: 0, count: lutCount)
    let basePaper = baseTables.paperOutput?.values ?? emptyCube

    // The pool. A cube already in the base pack is index -1 and costs nothing; anything else is
    // matched against what has been pooled so far, so an unchanged table is stored once however
    // many stages read it.
    var pool: [[Float]] = []
    func poolIndex(_ cube: [Float], sameAsBase: [Float]) -> Int32 {
        if cube == sameAsBase { return -1 }
        if let existing = pool.firstIndex(of: cube) { return Int32(existing) }
        pool.append(cube)
        return Int32(pool.count - 1)
    }

    var records = Data()
    for stage in stages {
        let invocation = FilmEngineInvocation(stock: stage.stock, options: stage.options,
                                              width: packWidth, height: packHeight)
        let tables = invocation.spectral
        let exposureCube = poolIndex(tables.exposure.values, sameAsBase: baseTables.exposure.values)
        let filmCube = poolIndex(tables.filmOutput.values, sameAsBase: baseTables.filmOutput.values)
        let paperCube = poolIndex(tables.paperOutput?.values ?? emptyCube, sameAsBase: basePaper)

        // Compared by bit pattern rather than by value, so a slot the engine writes as a signed
        // zero or a NaN still appears as unchanged when it is unchanged.
        var changed: [(Int32, Float)] = []
        for (index, value) in invocation.configuration.enumerated()
        where value.bitPattern != base.configuration[index].bitPattern {
            changed.append((Int32(index), value))
        }

        records.appendPaddedString(stage.id)
        records.appendPaddedString(stage.label)
        records.appendInt32(invocation.featureMask)
        records.appendUInt32(invocation.seed)
        records.appendInt32(exposureCube)
        records.appendInt32(filmCube)
        records.appendInt32(paperCube)
        records.appendInt32(Int32(changed.count))
        for (index, value) in changed {
            records.appendInt32(index)
            records.appendFloats([value])
        }

        let carried = [("exposure", exposureCube), ("film", filmCube), ("paper", paperCube)]
            .filter { $0.1 >= 0 }.map { "\($0.0) #\($0.1)" }
        print("  \(stage.id.padding(toLength: 14, withPad: " ", startingAt: 0))"
            + "\(changed.count) slots  \(carried.isEmpty ? "-" : carried.joined(separator: ", "))")
    }

    var sidecar = Data()
    sidecar.append(contentsOf: Array("FSSQ".utf8))
    sidecar.appendUInt32(1)
    sidecar.appendInt32(Int32(packWidth))
    sidecar.appendInt32(Int32(packHeight))
    sidecar.appendInt32(Int32(base.configuration.count))
    sidecar.appendInt32(Int32(lutCount))
    sidecar.appendInt32(Int32(stages.count))
    sidecar.appendInt32(Int32(pool.count))
    // Store the fixed-size cube pool after variable-length stage records so offsets are known after
    // one record scan.
    sidecar.append(records)
    for cube in pool { sidecar.appendFloats(cube) }

    do {
        try sidecar.write(to: URL(fileURLWithPath: stagesPath))
    } catch {
        fail("Could not write \(stagesPath): \(error.localizedDescription)")
    }
    print("""
    \(stockID) on \(options.paper(for: stock).id) at \(packWidth)x\(packHeight): \
    \(stages.count) stages, \(pool.count) pooled cubes, \(sidecar.count / 1024) KiB \
    -> \(stagesPath)
    """)
    exit(0)
}

let hlgOutput = flags["--hlg"] != nil
// Eight bits of an HLG signal is banding, not a delivery: the curve spends its lower half on
// the range sRGB gives its whole range to.
let depth = hlgOutput ? 16 : (flags["--depth"].flatMap { Int($0) } ?? 8)
guard depth == 8 || depth == 16 else { fail("--depth must be 8 or 16") }
let balance = WhiteBalance(
    kelvin: flags["--wb"].flatMap { Float($0) } ?? WhiteBalance.neutralKelvin,
    tint: flags["--tint"].flatMap { Float($0) } ?? 0)
let background = parseLinearBackground(flags["--background"])

var (rgba, width, height, remaining, sceneKelvin, contentHeadroom) =
    loadLinear(path: positional[0], balance: balance)
PremultipliedAlpha.flatten(&rgba, over: background)
options.whiteBalance = remaining
// The film-side scene light, from the raw file's as-shot record — the same wiring as the
// app's still path. The gate inside the engine decides whether it does anything.
options.sceneIlluminantKelvin = sceneKelvin
// And the declared range, the other clip-side fact the app attaches: recorded light above
// diffuse white is metered into the film's latitude instead of flattening to paper white.
options.sceneHeadroom = contentHeadroom
if flags["--autoexpose"] != nil {
    let ev = autoExposureEV(rgba: rgba, width: width, height: height)
    options.exposureEV += ev
    print(String(format: "Auto exposure: %+.2f stops", ev))
}

guard FotufilmEngine.isHalideBackendAvailable else {
    fail("""
    The Halide engine is not linked into this build. Install Halide \
    (brew install halide, or set HALIDE_ROOT) and rebuild.
    """)
}

let start = Date()
// Unclamped: a component the ingest matrix leaves negative is real colour beyond Rec.2020 —
// a laser, an LED, a gas discharge — on its way to the spectral recovery, which is the one
// place on the scene path that decides what light is. Zeroing it here developed every such
// source as its per-channel clip. Only a non-finite sample, which a decoder can emit on a
// failed frame, is replaced, and by darkness rather than by a channel.
var linear = ImageBuffer(width: width, height: height)
for i in 0..<(width * height) {
    for channel in 0..<3 {
        let value = rgba[i * 4 + channel]
        linear.planes[channel][i] = value.isFinite ? value : 0
    }
}

if flags["--stages"] != nil {
    // The stage sequence is a diagnostic written as SDR PNGs; there is no HLG stage to write,
    // and silently ignoring the flag would be worse than saying so.
    if hlgOutput { fail("--hlg and --stages cannot be combined") }
    writeStageSequence(linear: linear, alpha: rgba, stock: stock, options: options,
                       directory: positional[1], depth: depth)
    exit(0)
}
let out = FotufilmEngine(stock: stock, options: options).process(linearRGB: linear)
var reflectance = [Float](repeating: 1, count: width * height * 4)
for i in 0..<(width * height) {
    reflectance[i * 4] = out.planes[0][i]
    reflectance[i * 4 + 1] = out.planes[1][i]
    reflectance[i * 4 + 2] = out.planes[2][i]
    reflectance[i * 4 + 3] = rgba[i * 4 + 3]
}
let elapsed = Date().timeIntervalSince(start)
if hlgOutput {
    saveHLG(reflectance, width: width, height: height, path: positional[1])
} else {
    saveReflectance(reflectance, width: width, height: height, path: positional[1],
                    depth: depth, seed: options.seed)
}
print("Processed \(width)x\(height) with \(stock.name) (halide) in \(String(format: "%.2f", elapsed))s -> \(positional[1])")
#else
fail("Image I/O requires macOS (ImageIO). The FotufilmCore library itself is portable.")
#endif
