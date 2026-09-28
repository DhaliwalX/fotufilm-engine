#if os(Linux)
import Foundation
#if canImport(CFotufilmVideo)
import CFotufilmVideo
#endif

extension HostPlatform {
    /// Linux: the Halide GPU developer on CUDA or Vulkan where a device answers, photographs,
    /// scans and stills through the portable codecs, and movies through the system's FFmpeg where
    /// it is installed, developed on the same device three frames at a time. The clipboard and the
    /// other services are still to come; until then their features stay off.
    static var linux: HostPlatform {
        var platform = HostPlatform()
        platform.developer = HalideGPUDeveloper()
        #if canImport(CFotufilmCodecs)
        platform.decoder = PortableImageDecoder()
        platform.scans = PortableScanDecoder()
        platform.encoder = PortableStillEncoder()
        #endif
        #if canImport(CFotufilmVideo)
        if ffv_available() != 0 {
            platform.videoSource = FFmpegVideoSources()
            platform.videoWriter = FFmpegVideoWriters()
        }
        #endif
        platform.videoDeveloper = HalideGPUVideoDeveloper()
        return platform
    }
}
#endif
