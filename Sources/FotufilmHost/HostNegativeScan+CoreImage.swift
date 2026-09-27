#if canImport(CoreImage) && canImport(ImageIO)
import CoreImage
import Foundation
import UniformTypeIdentifiers
#if canImport(FotufilmImaging)
import FotufilmImaging
#endif

/// Scans read through `NegativeScanImport`, the apps' own importer: a camera RAW with every
/// rendering choice off, anything else through its colour profile or as linear samples.
struct CoreImageScanDecoder: HostScanDecoder {
    func decodeScan(_ url: URL, linearSamples: Bool) throws -> HostScanFile {
        let data = try Data(contentsOf: url)
        let hint = UTType(filenameExtension: url.pathExtension)?.identifier
        let image = try NegativeScanImport.decode(data: data, identifierHint: hint,
                                                  linearSamples: linearSamples)
        let width = Int(image.extent.width), height = Int(image.extent.height)
        guard width > 0, height > 0, width <= 40000, height <= 40000,
              width * height <= 150_000_000 else { throw NegativeScanImport.Failure.unreadable }
        // A film reading wants every dense dye positive: the scan is held in the wide film space.
        var rgba = [Float](repeating: 1, count: width * height * 4)
        CIContext(options: [.workingColorSpace: NegativeScanImport.linearSpace,
                            .cacheIntermediates: false])
            .render(image, toBitmap: &rgba, rowBytes: width * 16,
                    bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                    colorSpace: NegativeScanImport.filmSpace)
        let scan = HostImage(rgba: rgba, width: width, height: height, contentHeadroom: 1)
        return HostScanFile(image: scan, isRAW: RawDecode.isRaw(data: data, identifierHint: hint))
    }

    func measureLight(_ url: URL) throws -> NegativeLightFrame {
        let data = try Data(contentsOf: url)
        let hint = UTType(filenameExtension: url.pathExtension)?.identifier
        return try NegativeLightFrame(photo: NegativeScanImport.decode(data: data,
                                                                       identifierHint: hint))
    }
}
#endif
