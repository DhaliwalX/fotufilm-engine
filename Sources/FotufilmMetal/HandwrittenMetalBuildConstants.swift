#if canImport(Metal)
import Foundation

/// Build-tool access to the same definitions used by runtime Metal compilation.
@_spi(BuildTools) public enum HandwrittenMetalBuildConstants {
    public static func compilerDefinitions() -> [String: String] {
        var values = HandwrittenMetalShaderLibrary.sharedConfigurationMacros
        values.merge(HandwrittenMetalShaderLibrary.digitalDeliveryMacros) { _, value in value }
        let tableSizes: [String: Int] = [
            "FOTUFILM_POINTWISE_CURVE_SAMPLES": HandwrittenMetalFilmRenderer.curveSamples,
            "FOTUFILM_MEASUREMENT_DECODE_SAMPLES": HandwrittenMetalGlobalMeasurements.decodeSamples,
            "FOTUFILM_POINTWISE_TRANSFER_SAMPLES": HandwrittenMetalFilmRenderer.transferSamples,
            "FOTUFILM_POINTWISE_DECODE_SAMPLES": HandwrittenMetalFilmRenderer.decodeSamples,
            "FOTUFILM_ENDPOINT_CURVE_SAMPLES": HandwrittenMetalFrameEndpoints.curveSamples,
            "FOTUFILM_ENDPOINT_TRANSFER_SAMPLES": HandwrittenMetalFrameEndpoints.transferSamples,
            "FOTUFILM_MEASUREMENT_REDUCTION_THREADS": HandwrittenMetalGlobalMeasurements.reductionThreads,
            "FOTUFILM_MEASUREMENT_FLARE_ITEMS": HandwrittenMetalGlobalMeasurements.flareItemsPerThread,
            "FOTUFILM_HEAD_DECODE_SAMPLES": HandwrittenMetalSpectralHead.decodeSamples,
            "FOTUFILM_CAMERA_DECODE_SAMPLES": HandwrittenMetalCameraPassThrough.decodeSamples,
        ]
        for (name, value) in tableSizes { values[name] = NSNumber(value: value) }
        return values.mapValues { value in
            switch String(cString: value.objCType) {
            case "f", "d": return "\(value.floatValue)f"
            default: return value.stringValue
            }
        }
    }
}
#endif
