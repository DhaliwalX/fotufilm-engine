#if canImport(CFotufilmCodecs) && !canImport(ImageIO)
import CFotufilmCodecs
import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Photographs through the portable codecs (`Sources/CFotufilmCodecs`: libjpeg-turbo, libpng,
/// libtiff, LibRaw, OpenEXR, libheif and lcms2), for hosts without Core Image and ImageIO. They
/// decode as `SceneImage` does on the Mac: associated linear Rec. 2020, upright, RAW at its
/// as-shot white with the camera profile correction. HDR gain maps and PQ/HLG files read as SDR.
enum PortableCodecs {
    struct Decoded {
        var rgba: [Float]
        var width: Int
        var height: Int
        var isRAW: Bool
        var contentHeadroom: Float
        var sceneKelvin: Float?
        var camera: CameraIdentity?
        var lensShot: LensShot?
        var sensorFrame: SensorFrame?
        /// The Exif record an export carries (`ffc_encode`).
        var exif: Data?
    }

    static func decode(_ url: URL, options: UInt32, rawLongEdge: Int = 0) throws -> Decoded {
        var image = ffc_image()
        var message = [CChar](repeating: 0, count: 512)
        guard ffc_decode(url.path, options, UInt32(clamping: rawLongEdge), &image, &message,
                         message.count) == 0 else {
            throw HostEngine.Failure(description: String(cString: message))
        }
        defer { ffc_image_free(&image) }
        let count = Int(image.width) * Int(image.height) * 4
        let capture = image.capture
        let make = text(capture.make), model = text(capture.model)
        let lensModel = text(capture.lens_model)
        var decoded = Decoded(
            rgba: Array(UnsafeBufferPointer(start: image.rgba, count: count)),
            width: Int(image.width), height: Int(image.height), isRAW: image.is_raw != 0,
            contentHeadroom: max(1, image.content_headroom),
            sceneKelvin: image.as_shot_kelvin > 0 ? image.as_shot_kelvin : nil,
            camera: make.isEmpty || model.isEmpty ? nil : CameraIdentity(make: make, model: model))
        if !lensModel.isEmpty {
            decoded.lensShot = LensShot(
                lensModel: lensModel, lensMaker: text(capture.lens_make).nilIfEmpty,
                cameraModel: model.nilIfEmpty,
                focalLength: capture.focal_length > 0 ? capture.focal_length : nil,
                aperture: capture.f_number > 0 ? capture.f_number : nil)
        }
        decoded.sensorFrame = sensorFrame(capture)
        if let exif = capture.exif, capture.exif_length > 0 {
            decoded.exif = Data(bytes: exif, count: capture.exif_length)
        }
        return decoded
    }

    /// The frame the camera exposed, from the same records `SensorFrame.read` asks ImageIO for.
    private static func sensorFrame(_ capture: ffc_capture) -> SensorFrame? {
        let width = Int(capture.stored_width), height = Int(capture.stored_height)
        guard width > 0, height > 0 else { return nil }
        var focalPlane: SensorFrame?
        if capture.focal_plane_x_resolution > 0, capture.focal_plane_y_resolution > 0,
           capture.focal_plane_unit > 0 {
            focalPlane = SensorFrame.focalPlane(
                xResolution: capture.focal_plane_x_resolution,
                yResolution: capture.focal_plane_y_resolution,
                unit: Int(capture.focal_plane_unit), pixelWidth: width, pixelHeight: height)
        }
        var equivalentFocal: SensorFrame?
        if capture.focal_length > 0, capture.focal_length_35mm > 0 {
            equivalentFocal = SensorFrame.equivalentFocal(
                focalLengthMM: Double(capture.focal_length),
                equivalent35mmMM: Double(capture.focal_length_35mm),
                pixelWidth: width, pixelHeight: height)
        }
        return SensorFrame.measured(focalPlane: focalPlane, equivalentFocal: equivalentFocal)
    }

    private static func text<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The editor's photographs: RAW with its camera profile, as `CoreImageDecoder` opens them.
struct PortableImageDecoder: HostImageDecoder {
    func decode(_ url: URL) throws -> HostImage {
        let scene = try Self.scene(url, rawLongEdge: 0)
        let image = HostImage(rgba: scene.rgba, width: scene.width, height: scene.height,
                              contentHeadroom: scene.contentHeadroom)
        image.lensShot = scene.lensShot
        image.captureMetadata = scene.exif.map { ["exif": $0] }
        image.sensorFrame = scene.sensorFrame
        image.isRAW = scene.isRAW
        if scene.isRAW {
            image.decodeReduced = { longEdge in
                let reduced = try Self.scene(url, rawLongEdge: longEdge)
                return (reduced.rgba, reduced.width, reduced.height)
            }
        }
        return image
    }

    private static func scene(_ url: URL, rawLongEdge: Int) throws -> PortableCodecs.Decoded {
        var scene = try PortableCodecs.decode(url, options: UInt32(FFC_DECODE_SCENE),
                                              rawLongEdge: rawLongEdge)
        if scene.isRAW, let corrected = CameraProfileCorrection.resolve(
            camera: scene.camera, sceneKelvin: scene.sceneKelvin) {
            CameraProfileCorrection.apply(corrected.matrix, toRGBA: &scene.rgba)
        }
        return scene
    }
}

/// Scanned negatives as `CoreImageScanDecoder` reads them: a camera RAW with no exposure or
/// profile of its own, anything else through its colour profile or as linear samples.
struct PortableScanDecoder: HostScanDecoder {
    func decodeScan(_ url: URL) throws -> HostImage {
        // An untagged scan is the scanner's raw output: its samples are linear light.
        let scan = try PortableCodecs.decode(
            url, options: UInt32(FFC_DECODE_SCAN) | UInt32(FFC_DECODE_LINEAR_SAMPLES))
        guard scan.width <= 40000, scan.height <= 40000,
              scan.width * scan.height <= 150_000_000 else {
            throw HostEngine.Failure(description: "This negative could not be decoded. Try an "
                                     + "unadjusted TIFF or a supported camera RAW file.")
        }
        return HostImage(rgba: scan.rgba, width: scan.width, height: scan.height,
                         contentHeadroom: 1)
    }

    func decodeExposure(_ url: URL) throws -> (rgba: [Float], width: Int, height: Int) {
        let exposure = try PortableCodecs.decode(
            url, options: UInt32(FFC_DECODE_SCAN) | UInt32(FFC_DECODE_EXPOSURE)
                | UInt32(FFC_DECODE_LINEAR_SAMPLES))
        return (exposure.rgba, exposure.width, exposure.height)
    }

    func measureLight(_ url: URL) throws -> NegativeLightFrame {
        let photo = try PortableCodecs.decode(url, options: UInt32(FFC_DECODE_SCAN))
        var srgb = photo.rgba
        for i in 0..<(photo.width * photo.height) {
            let rgb = AutomaticNegativeScan.rec2020ToSRGB(
                SIMD3(srgb[i * 4], srgb[i * 4 + 1], srgb[i * 4 + 2]))
            for c in 0..<3 { srgb[i * 4 + c] = rgb[c] }
        }
        return try NegativeLightFrame(linearSRGB: srgb, width: photo.width, height: photo.height)
    }
}

/// Stills as `ImageIOStillEncoder` writes them, SDR only: Display P3 with its profile and the
/// source's Exif record by the chosen policy (a TIFF keeps only its text fields).
struct PortableStillEncoder: HostStillEncoder {
    var types: [String] {
        ["image/png", "image/jpeg", "image/tiff", "image/heic"].filter { ffc_can_encode($0) != 0 }
    }
    var writesHDR: Bool { false }

    func write(_ still: HostStill, type: String, quality: Double, to url: URL) throws
        -> (width: Int, height: Int) {
        guard ffc_can_encode(type) != 0 else {
            throw HostEngine.Failure(description: "This host cannot write \(type).")
        }
        guard still.frame == nil else {
            throw HostEngine.Failure(description: "This host cannot draw print frames.")
        }
        let exif = still.metadata == .strip ? nil : still.capture?["exif"] as? Data
        let keepLocation: Int32 = still.metadata == .preserve ? 1 : 0
        var message = [CChar](repeating: 0, count: 512)
        let status: Int32 = (exif ?? Data()).withUnsafeBytes { record in
            let bytes = record.bindMemory(to: UInt8.self)
            func encode(_ pixels: UnsafeRawBufferPointer, bits: Int32) -> Int32 {
                ffc_encode(url.path, type, pixels.baseAddress, bits, UInt32(still.width),
                           UInt32(still.height), Float(quality), bytes.baseAddress, bytes.count,
                           keepLocation, &message, message.count)
            }
            switch still.pixels {
            case .display8(let pixels): return pixels.withUnsafeBytes { encode($0, bits: 8) }
            case .display16(let pixels): return pixels.withUnsafeBytes { encode($0, bits: 16) }
            }
        }
        guard status == 0 else {
            throw HostEngine.Failure(description: String(cString: message))
        }
        return (still.width, still.height)
    }
}
#endif
