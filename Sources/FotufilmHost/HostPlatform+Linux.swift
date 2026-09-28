#if os(Linux)
import Foundation

extension HostPlatform {
    /// Linux: the Halide GPU developer on CUDA or Vulkan where a device answers, and photographs,
    /// scans and stills through the portable codecs. Movies, the clipboard and the other services
    /// are still to come; until then their features stay off.
    static var linux: HostPlatform {
        var platform = HostPlatform()
        platform.developer = HalideGPUDeveloper()
        #if canImport(CFotufilmCodecs)
        platform.decoder = PortableImageDecoder()
        platform.scans = PortableScanDecoder()
        platform.encoder = PortableStillEncoder()
        #endif
        return platform
    }
}
#endif
