#if defined(FOTUFILM_HALIDE_ANDROID_GPU_AOT)

#include "fotufilm_halide_android_gpu_color.h"
#include "fotufilm_halide_android_gpu_monochrome.h"
#include <HalideBuffer.h>
#include <HalideRuntimeVulkan.h>

// Provided by the batched Vulkan runtime (android/tools/halide-vk-batch.patch).
extern "C" int32_t halide_vulkan_batch_set(void *user_context, int32_t enabled);

#include "FotufilmHalide.h"
#include "FotufilmResolvedFrameParams.h"

#include <algorithm>
#include <cstring>
#include <cstdlib>
#include <mutex>

#include <android/log.h>
#include <dlfcn.h>

using Halide::Runtime::Buffer;

namespace {

constexpr int kLutDimension = 33;
constexpr int kLutValueCount = kLutDimension * kLutDimension * kLutDimension * 4;
/// Mirrors kLutVulkanPaddedCount in the schedule.
constexpr int kLutPaddedCount = 147456;

/// Set once Vulkan has failed here; the device falls back and stays fallen back.
/// Without it a failed driver would pay a failed init on every frame.
bool vulkan_unusable = false;

/// Halide's default error handler aborts the process. Every error the runtime
/// can raise here is one the caller handles by returning false — the bridge
/// then develops the frame on the CPU — so the handler logs and lets the
/// kernel unwind with its error code instead.
void *default_user_context = nullptr;
void halide_log_and_return(void *user_context, const char *message) {
    (void)user_context;
    (void)default_user_context;
    __android_log_print(ANDROID_LOG_WARN, "fotufilm-vulkan", "%s", message);
}

void install_error_handler() {
    static const bool installed = [] {
        halide_set_error_handler(halide_log_and_return);
        return true;
    }();
    (void)installed;
}

/// Halide's weak default only tries `libvulkan.so.1` and the dylib spelling,
/// neither of which exists on Android, where the loader ships as
/// `libvulkan.so`. Supplying the platform's own name lets the runtime resolve
/// the Vulkan API in an app's linker namespace, where nothing is global.
extern "C" void *halide_vulkan_get_symbol(void *user_context, const char *name) {
    (void)user_context;
    static void *loader = [] {
        return dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    }();
    return loader ? dlsym(loader, name) : nullptr;
}

/// Caches spectral tables on the device until the stock changes.
struct SpectralCache {
    Buffer<float> exposure, film, paper;
    uint64_t identifier = 0;
    bool valid = false;

    void ensure(const float *exposure_values, const float *film_values,
                const float *paper_values, uint64_t cache_id) {
        if (valid && identifier == cache_id) return;
        exposure = Buffer<float>(kLutPaddedCount);
        film = Buffer<float>(kLutPaddedCount);
        paper = Buffer<float>(kLutPaddedCount);
        for (Buffer<float> *buffer : {&exposure, &film, &paper}) {
            std::memset(buffer->data(), 0, kLutPaddedCount * sizeof(float));
        }
        std::memcpy(exposure.data(), exposure_values, kLutValueCount * sizeof(float));
        std::memcpy(film.data(), film_values, kLutValueCount * sizeof(float));
        std::memcpy(paper.data(), paper_values, kLutValueCount * sizeof(float));
        exposure.set_host_dirty();
        film.set_host_dirty();
        paper.set_host_dirty();
        identifier = cache_id;
        valid = true;
    }
};

/// Sends a buffer's bytes to the device, and says whether they arrived.
///
/// Marking a buffer host-dirty is not enough here. Halide's generated code copies an input up only
/// where it can see that it must, and with these kernels it does not: the frame came back a flat
/// colour — one that is not the print of any input — because every buffer the pipeline read was
/// still whatever the device allocator last left there. Asking for the copy by name is the whole
/// fix, and it costs nothing on a buffer that is already clean.
int upload(Buffer<float> &buffer) {
    return buffer.copy_to_device(halide_vulkan_device_interface());
}
int upload(Buffer<uint8_t> &buffer) {
    return buffer.copy_to_device(halide_vulkan_device_interface());
}

/// Deliberately never destroyed.
SpectralCache &spectral_cache() {
    static SpectralCache *cache = new SpectralCache();
    return *cache;
}

/// The frame's own buffers, kept between frames at one size.
///
/// A `Buffer` wrapped around the caller's bytes has to be given device memory before the pipeline
/// can read it, and returned after — and the Vulkan allocator does not survive that being done
/// per frame: it runs the device out somewhere around the tenth. Holding the pair here means the
/// device allocation happens once per size instead of once per frame, which is what a video loop
/// needs anyway. The copies in and out are the price, and they are a memcpy against a develop.
struct FrameCache {
    Buffer<uint8_t> input, output;
    Buffer<float> configuration;
    int width = 0, height = 0;

    void ensure(int frame_width, int frame_height) {
        if (width == frame_width && height == frame_height) return;
        input = Buffer<uint8_t>::make_interleaved(frame_width, frame_height, 4);
        output = Buffer<uint8_t>::make_interleaved(frame_width, frame_height, 4);
        if (!configuration.data()) {
            configuration = Buffer<float>(FOTUFILM_FRAME_CONFIGURATION_COUNT);
        }
        width = frame_width;
        height = frame_height;
    }
};

FrameCache &frame_cache() {
    static FrameCache *cache = new FrameCache();
    return *cache;
}

std::mutex &pipeline_mutex() {
    static std::mutex *mutex = new std::mutex();
    return *mutex;
}

bool reuse_configured = false;

}

extern "C" int32_t fotufilm_halide_android_gpu_available(void) {
    return vulkan_unusable ? 0 : 1;
}

extern "C" int32_t fotufilm_halide_android_gpu_prepare(
    const float *exposure_lut, const float *film_lut, const float *paper_lut,
    int32_t lut_dimension, uint64_t cache_id) {
    if (vulkan_unusable) return -4;
    if (!exposure_lut || !film_lut || !paper_lut ||
        lut_dimension != kLutDimension) return -1;
    std::lock_guard<std::mutex> lock(pipeline_mutex());
    install_error_handler();
    spectral_cache().ensure(exposure_lut, film_lut, paper_lut, cache_id);
    return 0;
}

/// Develops one interleaved RGBA8 frame in place of another.
extern "C" int32_t fotufilm_halide_android_gpu_process_rgba8(
    const uint8_t *input, uint8_t *output, int32_t width, int32_t height,
    const float *configuration, int32_t feature_mask, uint32_t seed,
    int32_t origin_x, int32_t origin_y) {
    if (vulkan_unusable) return -4;
    if (!input || !output || !configuration || width <= 0 || height <= 0) return -1;
    std::lock_guard<std::mutex> lock(pipeline_mutex());
    install_error_handler();
    if (!spectral_cache().valid) return -2;
    if (!reuse_configured) {
        // On affected Mali devices, Halide sizes scalar uniform buffers to 64-byte alignment and
        // truncates a 108-byte request. Setting a 256-byte allocation multiple preserves the full
        // request. The allocator reads this colon-delimited setting at first dispatch; overwrite=0
        // preserves an operator-provided value.
        setenv("HL_VK_ALLOC_CONFIG", "0:1:0:0:256", 0);
        const char *reuse = getenv("FOTUFILM_VK_REUSE");
        halide_reuse_device_allocations(nullptr, !reuse || reuse[0] != '0');
        reuse_configured = true;
    }

    FrameCache &frame = frame_cache();
    frame.ensure(width, height);
    Buffer<uint8_t> &in = frame.input;
    Buffer<uint8_t> &out = frame.output;
    Buffer<float> &config = frame.configuration;
    std::memcpy(in.data(), input, static_cast<size_t>(width) * height * 4);
    in.set_host_dirty();
    std::memcpy(config.data(), configuration,
                FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float));
    config.set_host_dirty();
    SpectralCache &spectral = spectral_cache();
    if (int failed = upload(in)) return failed;
    if (int failed = upload(config)) return failed;
    if (int failed = upload(spectral.exposure)) return failed;
    if (int failed = upload(spectral.film)) return failed;
    if (int failed = upload(spectral.paper)) return failed;

    const fotufilm::ResolvedFrameParams resolved(configuration, width, height, seed,
        (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0, origin_x, origin_y);

#define FOTUFILM_GPU_ARGUMENTS \
    in, config, spectral_cache().exposure, spectral_cache().film, spectral_cache().paper, width, \
    height, resolved.mtf_sigma_0, resolved.mtf_sigma_1, resolved.mtf_sigma_2, \
    resolved.mtf_luma_sigma, resolved.mtf_radius_0, resolved.mtf_radius_1, resolved.mtf_radius_2, \
    resolved.mtf_luma_radius, resolved.halation_radius_0, resolved.halation_radius_1, \
    resolved.halation_radius_2, resolved.coupler_sigma, resolved.coupler_radius, \
    resolved.adjacency_sigma, resolved.adjacency_radius, resolved.adjacency_secondary_sigma, \
    resolved.adjacency_secondary_radius, resolved.fringe_sigma, resolved.fringe_radius, \
    resolved.grain_sigma, resolved.grain_radius, resolved.grain_lambda, resolved.mottle_lambda, \
    resolved.mottle_radius, resolved.print_mtf_radius, seed, resolved.reversal, origin_x, origin_y, \
    resolved.halation_stride_0, resolved.halation_stride_1, resolved.halation_stride_2, \
    resolved.halation_strided_radius_0, resolved.halation_strided_radius_1, \
    resolved.halation_strided_radius_2, resolved.diffusion_stride_0, resolved.diffusion_stride_1, \
    resolved.diffusion_stride_2, resolved.diffusion_strided_radius_0, \
    resolved.diffusion_strided_radius_1, resolved.diffusion_strided_radius_2, feature_mask, \
    fotufilm_byte_basis(configuration), out

    // Every pass the kernel launches shares one command buffer and one sync.
    halide_vulkan_batch_set(nullptr, 1);
    const int error = (feature_mask & FOTUFILM_FRAME_MONOCHROME)
        ? fotufilm_halide_android_gpu_monochrome(FOTUFILM_GPU_ARGUMENTS)
        : fotufilm_halide_android_gpu_color(FOTUFILM_GPU_ARGUMENTS);
#undef FOTUFILM_GPU_ARGUMENTS
    halide_vulkan_batch_set(nullptr, 0);
    if (error) {
        // An error here is the runtime giving up on the device — the failed
        // instance creation, an exhausted allocator. Fall back permanently; the
        // CPU engine develops the rest of the session.
        vulkan_unusable = true;
        return error;
    }
    out.copy_to_host();
    std::memcpy(output, out.data(), static_cast<size_t>(width) * height * 4);
    return 0;
}

#endif
