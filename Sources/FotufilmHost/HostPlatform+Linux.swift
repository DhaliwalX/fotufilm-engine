#if os(Linux)
import Foundation

extension HostPlatform {
    /// Linux: the Halide GPU developer on CUDA or Vulkan where a device answers. Files, movies,
    /// the clipboard and the other services are still to come; until then their features stay off.
    static var linux: HostPlatform {
        var platform = HostPlatform()
        platform.developer = HalideGPUDeveloper()
        return platform
    }
}
#endif
