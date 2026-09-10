#if canImport(Metal)
import Foundation
import FotufilmHalide
import Metal

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Loads the release-built hand-written Metal library while preserving runtime specialization.
///
/// Device/simulator app builds compile the maintainable MSL files into one bundled metallib. Metal
/// function constants remain runtime-specialized; only source parsing and compilation move out of
/// the first camera frame. SwiftPM clients compile the sources in their module resource bundle
/// when the platform-specific metallib is not present.
enum HandwrittenMetalShaderLibrary {
    enum Shader: String {
        case pointwise = "HandwrittenPointwise"
        case composedPointwise = "HandwrittenComposedPointwise"
        case frameEndpoints = "HandwrittenFrameEndpoints"
        case globalMeasurements = "HandwrittenGlobalMeasurements"
        case spectralHead = "HandwrittenSpectralHead"
        case cameraPassThrough = "HandwrittenCameraPassThrough"
        case spatial = "HandwrittenSpatial"
        case digitalDelivery = "HandwrittenDigitalDelivery"
        case stillDelivery = "HandwrittenStillDelivery"
        case compositeTail = "HandwrittenCompositeTail"

        var insertsCameraSceneTransfer: Bool {
            self == .globalMeasurements || self == .spectralHead
                || self == .cameraPassThrough
        }

        var insertsCameraYCbCr: Bool {
            self == .globalMeasurements || self == .spectralHead
                || self == .cameraPassThrough
        }

        var insertsDigitalDeliveryTransfer: Bool {
            self == .digitalDelivery || self == .stillDelivery
        }
    }

    enum LoadError: Swift.Error, CustomStringConvertible {
        case missingResource(String, searched: [String])
        case unreadable(URL, underlying: Swift.Error)
        case malformedSource(String)

        var description: String {
            switch self {
            case let .missingResource(name, searched):
                return "missing Metal shader resource \(name); searched \(searched.joined(separator: ", "))"
            case let .unreadable(url, error):
                return "could not read Metal shader resource \(url.path): \(error)"
            case let .malformedSource(reason):
                return "invalid Metal shader source: \(reason)"
            }
        }
    }

    static func makeLibrary(
        device: MTLDevice, shader: Shader, options: MTLCompileOptions,
        preprocessorMacros: [String: NSNumber] = [:]
    ) throws -> MTLLibrary {
        if let library = precompiledLibrary(device: device) {
            return library
        }
        var macros = options.preprocessorMacros ?? [:]
        for (name, value) in sharedConfigurationMacros {
            macros[name] = value
        }
        for (name, value) in preprocessorMacros {
            macros[name] = value
        }
        options.preprocessorMacros = macros
        return try device.makeLibrary(source: assembledSource(for: shader), options: options)
    }

    private static let precompiledLock = NSLock()
    private static var precompiledByDevice: [ObjectIdentifier: MTLLibrary] = [:]

    private static func precompiledLibrary(device: MTLDevice) -> MTLLibrary? {
        precompiledLock.lock()
        defer { precompiledLock.unlock() }
        let deviceID = ObjectIdentifier(device)
        if let cached = precompiledByDevice[deviceID] { return cached }
        for url in precompiledLibraryCandidates() {
            guard FileManager.default.fileExists(atPath: url.path),
                  let library = try? device.makeLibrary(URL: url)
            else { continue }
            precompiledByDevice[deviceID] = library
            return library
        }
        return nil
    }

    private static let cameraSceneTransferMarker =
        "#include \"HandwrittenCameraSceneTransfer.metalinc\""
    private static let cameraYCbCrMarker =
        "#include \"HandwrittenCameraYCbCr.metalinc\""
    private static let digitalDeliveryTransferMarker =
        "#include \"HandwrittenDigitalDeliveryTransfer.metalinc\""
    private static let exactCameraTailMarker =
        "#include \"HandwrittenExactCameraTail.metal\""

    static func assembledSource(for shader: Shader) throws -> String {
        var shaderSource = try source(named: shader.rawValue, extension: "metal")
        if shader == .spatial {
            guard shaderSource.components(
                separatedBy: exactCameraTailMarker).count == 2 else {
                throw LoadError.malformedSource(
                    "HandwrittenSpatial.metal must contain exactly one camera-tail include")
            }
            // Keep the camera-only fused endpoint in its own source file while compiling it in
            // the same translation unit as the shared development helpers above it. Runtime source
            // compilation expands the include; the offline Metal compiler resolves it directly.
            let tail = try source(
                named: "HandwrittenExactCameraTail", extension: "metal")
            shaderSource = shaderSource.replacingOccurrences(
                of: exactCameraTailMarker, with: tail)
        }
        if shader.insertsCameraSceneTransfer {
            guard shaderSource.components(
                separatedBy: cameraSceneTransferMarker).count == 2 else {
                throw LoadError.malformedSource(
                    "\(shader.rawValue).metal must contain exactly one camera-transfer marker")
            }
            let transfer = try source(
                named: "HandwrittenCameraSceneTransfer", extension: "metalinc")
            shaderSource = shaderSource.replacingOccurrences(
                of: cameraSceneTransferMarker, with: transfer)
        }
        if shader.insertsCameraYCbCr {
            guard shaderSource.components(
                separatedBy: cameraYCbCrMarker).count == 2 else {
                throw LoadError.malformedSource(
                    "\(shader.rawValue).metal must contain exactly one camera-YCbCr marker")
            }
            let yCbCr = try source(
                named: "HandwrittenCameraYCbCr", extension: "metalinc")
            shaderSource = shaderSource.replacingOccurrences(
                of: cameraYCbCrMarker, with: yCbCr)
        }
        if shader.insertsDigitalDeliveryTransfer {
            guard shaderSource.components(
                separatedBy: digitalDeliveryTransferMarker).count == 2 else {
                throw LoadError.malformedSource(
                    "\(shader.rawValue).metal must contain exactly one delivery-transfer marker")
            }
            let transfer = try source(
                named: "HandwrittenDigitalDeliveryTransfer", extension: "metalinc")
            shaderSource = shaderSource.replacingOccurrences(
                of: digitalDeliveryTransferMarker, with: transfer)
        }
        return shaderSource
    }

    private static func source(named name: String, extension pathExtension: String) throws -> String {
        let candidates = resourceCandidates(name: name, extension: pathExtension)
        guard let url = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw LoadError.missingResource(
                "\(name).\(pathExtension)", searched: candidates.map(\.path))
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LoadError.unreadable(url, underlying: error)
        }
    }

    private static func resourceCandidates(
        name: String, extension pathExtension: String
    ) -> [URL] {
        var urls: [URL] = []
        func appendBundleCandidates(_ bundle: Bundle) {
            if let nested = bundle.url(
                forResource: name, withExtension: pathExtension, subdirectory: "Shaders") {
                urls.append(nested)
            }
            if let flat = bundle.url(forResource: name, withExtension: pathExtension) {
                urls.append(flat)
            }
        }

        if let configured = ProcessInfo.processInfo.environment["FOTUFILM_METAL_SHADER_ROOT"] {
            let root = URL(fileURLWithPath: configured, isDirectory: true)
            urls.append(root.appendingPathComponent("\(name).\(pathExtension)"))
            urls.append(root.appendingPathComponent("Shaders", isDirectory: true)
                .appendingPathComponent("\(name).\(pathExtension)"))
        }
        #if SWIFT_PACKAGE
        appendBundleCandidates(Bundle.module)
        #endif
        appendBundleCandidates(Bundle.main)

        // Flat developer builds may still use the checkout. Package clients use Bundle.module;
        // do not bake a checkout location into shipping code with #filePath.
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                        isDirectory: true)
            .appendingPathComponent("Sources/FotufilmMetal/Shaders", isDirectory: true)
            .appendingPathComponent("\(name).\(pathExtension)"))
        return urls
    }

    private static func precompiledLibraryCandidates() -> [URL] {
        var urls: [URL] = []
        func appendBundleCandidates(_ bundle: Bundle) {
            if let nested = bundle.url(
                forResource: "HandwrittenFotufilm", withExtension: "metallib",
                subdirectory: "Shaders"
            ) {
                urls.append(nested)
            }
            if let flat = bundle.url(
                forResource: "HandwrittenFotufilm", withExtension: "metallib")
            {
                urls.append(flat)
            }
        }

        if let configured = ProcessInfo.processInfo.environment[
            "FOTUFILM_METAL_LIBRARY_PATH"]
        {
            urls.append(URL(fileURLWithPath: configured))
        }
        appendBundleCandidates(Bundle.main)
        return urls
    }

    /// One spelling of the matrices and HLG constants used by both RGB still and x420 video
    /// delivery. Their MSL transfer functions are injected from the same metalinc as well.
    static var digitalDeliveryMacros: [String: NSNumber] {
        let systemGamma: Float = 1.2
        let headroom = HLGSceneTransfer.headroom
        let displayCeiling = pow(headroom, systemGamma)
        let p3To2020 = rowMajor(ColorScience.linearDisplayP3ToRec2020)
        let p3To709 = rowMajor(ColorScience.linearDisplayP3ToSRGB)
        var macros: [String: NSNumber] = [
            "FOTUFILM_DELIVERY_HLG_HEADROOM": NSNumber(value: headroom),
            "FOTUFILM_DELIVERY_HLG_DISPLAY_CEILING": NSNumber(
                value: displayCeiling),
            "FOTUFILM_DELIVERY_HLG_GAMMA": NSNumber(value: systemGamma),
        ]
        for (index, value) in p3To2020.enumerated() {
            macros["FOTUFILM_DELIVERY_P3_TO_2020_\(index)"] = NSNumber(value: value)
        }
        for (index, value) in p3To709.enumerated() {
            macros["FOTUFILM_DELIVERY_P3_TO_709_\(index)"] = NSNumber(value: value)
        }
        return macros
    }

    private static func rowMajor(
        _ transform: (SIMD3<Float>) -> SIMD3<Float>
    ) -> [Float] {
        let red = transform(SIMD3(1, 0, 0))
        let green = transform(SIMD3(0, 1, 0))
        let blue = transform(SIMD3(0, 0, 1))
        return [
            red.x, green.x, blue.x,
            red.y, green.y, blue.y,
            red.z, green.z, blue.z,
        ]
    }

    /// FilmEngineInvocation is an append-only Swift ABI. Supplying every shared offset here keeps
    /// the source files readable and makes a renamed or removed ABI field fail at Swift compile
    /// time instead of silently changing a shader literal.
    static let sharedConfigurationMacros: [String: NSNumber] = [
        "FOTUFILM_CFG_CURVES": NSNumber(value: Int(FOTUFILM_CONFIG_CURVES)),
        "FOTUFILM_CFG_COUPLER": NSNumber(value: Int(FOTUFILM_CONFIG_COUPLER)),
        "FOTUFILM_CFG_GRAIN": NSNumber(value: FilmEngineInvocation.grainOffset),
        "FOTUFILM_CFG_COUPLER_SCALE": NSNumber(value: Int(FOTUFILM_CONFIG_COUPLER_SCALE)),
        "FOTUFILM_CFG_ADJACENCY_STRENGTH": NSNumber(value: Int(FOTUFILM_CONFIG_ADJACENCY_STRENGTH)),
        "FOTUFILM_CFG_ADJACENCY_MODEL": NSNumber(value: FilmEngineInvocation.adjacencyModelOffset),
        "FOTUFILM_CFG_CHROMATIC_FRINGE_AMOUNT": NSNumber(value: FilmEngineInvocation.chromaticFringeAmountOffset),
        "FOTUFILM_CFG_COUPLER_WARP": NSNumber(value: FilmEngineInvocation.couplerWarpOffset),
        "FOTUFILM_CFG_HALATION_KERNEL": NSNumber(value: FilmEngineInvocation.halationKernelOffset),
        "FOTUFILM_CFG_MOTTLE": NSNumber(value: FilmEngineInvocation.mottleOffset),
        "FOTUFILM_CFG_GRAIN_LAW": NSNumber(value: FilmEngineInvocation.grainLawOffset),
        "FOTUFILM_CFG_GRAIN_ANCHOR": NSNumber(value: FilmEngineInvocation.grainAnchorOffset),
        "FOTUFILM_CFG_GRAIN_FOG": NSNumber(value: FilmEngineInvocation.grainFogOffset),
        "FOTUFILM_CFG_HALATION_MATRIX": NSNumber(value: FilmEngineInvocation.halationMatrixOffset),
        "FOTUFILM_CFG_DIFFUSION_DIRECT": NSNumber(value: FilmEngineInvocation.diffusionDirectOffset),
        "FOTUFILM_CFG_DIFFUSION_KERNEL": NSNumber(value: FilmEngineInvocation.diffusionKernelOffset),
        "FOTUFILM_CFG_DONOR_DIFFUSION_KERNEL": NSNumber(value: FilmEngineInvocation.donorDiffusionKernelOffset),
        "FOTUFILM_CFG_GRAIN_DENSITY_PROFILE": NSNumber(value: FilmEngineInvocation.grainDensityProfileOffset),
        "FOTUFILM_CFG_PAPER": NSNumber(value: Int(FOTUFILM_CONFIG_PAPER)),
        "FOTUFILM_CFG_MASKING": NSNumber(value: Int(FOTUFILM_CONFIG_MASKING)),
        "FOTUFILM_CFG_PAPER_MIDPOINT": NSNumber(value: Int(FOTUFILM_CONFIG_PAPER_MIDPOINT)),
        "FOTUFILM_COUPLER_WARP_SAMPLES": NSNumber(value: FilmEngineInvocation.couplerWarpSamples),
        "FOTUFILM_FEATURE_COUPLERS": NSNumber(value: FilmEngineFeature.couplers),
        "FOTUFILM_FEATURE_DONOR": NSNumber(value: FilmEngineFeature.donorLayer),
        "FOTUFILM_CFG_SAMPLED_CURVES": NSNumber(value: FilmEngineInvocation.sampledCurvesOffset),
        "FOTUFILM_SAMPLED_CURVE_STRIDE": NSNumber(value: FilmEngineInvocation.sampledCurveStride),
        "FOTUFILM_CFG_DEVELOP_COMPLEMENT": NSNumber(value: FilmEngineInvocation.developComplementOffset),
        "FOTUFILM_CFG_GRAIN_REVERSAL_PROFILE": NSNumber(value: FilmEngineInvocation.grainReversalProfileOffset),
        "FOTUFILM_CFG_CURVE_SECONDARY": NSNumber(
            value: FilmEngineInvocation.curveSecondaryOffset),
        "FOTUFILM_CFG_COUPLER_RELEASE_GAMMA": NSNumber(
            value: FilmEngineInvocation.couplerReleaseGammaOffset),
        "FOTUFILM_CFG_DONOR_RELEASE_GAMMA": NSNumber(
            value: FilmEngineInvocation.donorReleaseGammaOffset),
        "FOTUFILM_CFG_DONOR_CURVE": NSNumber(value: FilmEngineInvocation.donorCurveOffset),
        "FOTUFILM_CFG_DONOR_RELEASE": NSNumber(value: FilmEngineInvocation.donorReleaseOffset),
        "FOTUFILM_CFG_EXPOSURE_GAIN": NSNumber(value: FilmEngineInvocation.exposureGainOffset),
        "FOTUFILM_CFG_WHITE_BALANCE": NSNumber(value: FilmEngineInvocation.whiteBalanceOffset),
        "FOTUFILM_CFG_SCENE_ADJUST": NSNumber(value: FilmEngineInvocation.sceneAdjustOffset),
        "FOTUFILM_CFG_GRADE": NSNumber(value: FilmEngineInvocation.gradeOffset),
        "FOTUFILM_CFG_FRAME_SIZE": NSNumber(value: FilmEngineInvocation.frameSizeOffset),
        "FOTUFILM_CFG_TONE_GRID_SIZE": NSNumber(value: FilmEngineInvocation.toneGridSizeOffset),
        "FOTUFILM_CFG_TONE_GRID_A": NSNumber(value: FilmEngineInvocation.toneGridAOffset),
        "FOTUFILM_CFG_TONE_GRID_B": NSNumber(value: FilmEngineInvocation.toneGridBOffset),
        "FOTUFILM_CFG_PAPER_RED": NSNumber(value: FilmEngineInvocation.paperRedOffset),
        "FOTUFILM_CFG_PAPER_BLUE": NSNumber(value: FilmEngineInvocation.paperBlueOffset),
        "FOTUFILM_CFG_PAPER_MIDPOINT_RED": NSNumber(
            value: FilmEngineInvocation.paperMidpointRedOffset),
        "FOTUFILM_CFG_PAPER_MIDPOINT_BLUE": NSNumber(
            value: FilmEngineInvocation.paperMidpointBlueOffset),
        "FOTUFILM_HLG_A": NSNumber(value: HLGSceneTransfer.a),
        "FOTUFILM_HLG_B": NSNumber(value: HLGSceneTransfer.b),
        "FOTUFILM_HLG_C": NSNumber(value: HLGSceneTransfer.c),
        "FOTUFILM_APPLE_LOG_R0": NSNumber(value: AppleLogCurve.r0),
        "FOTUFILM_APPLE_LOG_C": NSNumber(value: AppleLogCurve.c),
        "FOTUFILM_APPLE_LOG_BETA": NSNumber(value: AppleLogCurve.beta),
        "FOTUFILM_APPLE_LOG_GAMMA": NSNumber(value: AppleLogCurve.gamma),
        "FOTUFILM_APPLE_LOG_DELTA": NSNumber(value: AppleLogCurve.delta),
        "FOTUFILM_APPLE_LOG_TOE_SIGNAL": NSNumber(value: AppleLogCurve.toeSignal),
    ].merging(appleWideGamutMacros) { current, _ in current }

    /// Apple Log 2's recorded gamut carried to the Rec.2020 working space, row-major, so the x420
    /// decode uses the same matrix `CameraLogEncoding.appleLog2` hands the file path.
    private static var appleWideGamutMacros: [String: NSNumber] {
        var macros: [String: NSNumber] = [:]
        for (index, value) in CameraGamut.appleWideGamut.toRec2020.enumerated() {
            macros["FOTUFILM_APPLE_WG_TO_2020_\(index)"] = NSNumber(value: Float(value))
        }
        return macros
    }
}
#endif
