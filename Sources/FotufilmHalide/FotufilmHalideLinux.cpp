// The Linux desktop's ahead-of-time kernels (tools/generate-halide-aot-linux.sh): the desktop
// graph compiled twice, for CUDA and for Vulkan, behind the CUDA entry points the JIT build offers.
// The device is chosen once, when the app first asks: CUDA where an NVIDIA driver answers, Vulkan
// on any other GPU (a discrete one first), a software Vulkan device when there is no GPU, and
// none otherwise.
// FOTUFILM_GPU_DEVICE=cuda, vulkan or cpu chooses instead.
#if defined(FOTUFILM_HALIDE_LINUX_AOT)

#include "FotufilmAotFrame.h"
#include "fotufilm_aot_negative_cpu.h"
#include "fotufilm_aot_transport_cpu.h"
#include "fotufilm_aot_transport_scene_cpu.h"
#include "fotufilm_aot_transport_domain_cpu.h"
#include "TransportFrameAot.h"
#include "FotufilmTransport.h"
#include <HalideBuffer.h>
#include <HalideRuntimeCuda.h>
#include <HalideRuntimeVulkan.h>

#include "FotufilmHalide.h"
#include "FotufilmResolvedFrameParams.h"
#include "Pipeline/FilmTileStore.h"

#include <dlfcn.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <mutex>
#include <string>

using Halide::Runtime::Buffer;
using fotufilm::aot::AotVariant;
using fotufilm::aot::FrameFunction;

#define FOTUFILM_AOT_DECLARE(variant_name, variant_mask)                                   \
    extern "C" int fotufilm_aot_cuda_##variant_name(FOTUFILM_AOT_FRAME_SIGNATURE);        \
    extern "C" int fotufilm_aot_vulkan_##variant_name(FOTUFILM_AOT_FRAME_SIGNATURE);
FOTUFILM_AOT_VARIANTS(FOTUFILM_AOT_DECLARE)
#undef FOTUFILM_AOT_DECLARE

namespace {

constexpr int kLutDimension = 33;
constexpr int kLutValueCount = kLutDimension * kLutDimension * kLutDimension * 4;
/// The Vulkan graph reads its tables padded to this many entries (kLutVulkanPaddedCount).
constexpr int kLutVulkanPaddedCount = 147456;

enum Device : int32_t { kNone = 0, kCuda = 1, kVulkan = 2 };

const AotVariant kCudaVariants[] = {
#define FOTUFILM_AOT_ENTRY(variant_name, variant_mask) \
    {(variant_mask), fotufilm_aot_cuda_##variant_name, #variant_name},
    FOTUFILM_AOT_VARIANTS(FOTUFILM_AOT_ENTRY)
#undef FOTUFILM_AOT_ENTRY
};
const AotVariant kVulkanVariants[] = {
#define FOTUFILM_AOT_ENTRY(variant_name, variant_mask) \
    {(variant_mask), fotufilm_aot_vulkan_##variant_name, #variant_name},
    FOTUFILM_AOT_VARIANTS(FOTUFILM_AOT_ENTRY)
#undef FOTUFILM_AOT_ENTRY
};

// Kernels report a failure and return its code; Halide's default handler would abort the app
// before the engine could fall back to the CPU.
void configure_error_handler() {
    static const auto previous = halide_set_error_handler([](void *, const char *message) {
        std::fprintf(stderr, "Fotufilm Halide Linux runtime error: %s\n", message);
    });
    (void)previous;
}

const halide_device_interface_t *interface_for(Device device) {
    return device == kCuda ? halide_cuda_device_interface() : halide_vulkan_device_interface();
}

/// Whether the device takes a buffer: its driver loads, a device answers, and memory moves.
bool answers(Device device) {
    Buffer<float> probe(16);
    probe.fill(0.0f);
    probe.set_host_dirty();
    if (probe.copy_to_device(interface_for(device)) != 0) return false;
    probe.device_free();
    return true;
}

/// Which kind of Vulkan device to develop on, for Halide's runtime (HL_VK_DEVICE_TYPE): a discrete
/// GPU over an integrated one, as a laptop with both wants, and a software device (Mesa's
/// lavapipe) only when there is no GPU at all. Halide alone takes the first GPU it enumerates and
/// never a software one. Read through the loader directly, with only the fields it needs.
const char *preferred_vulkan_device_type() {
    void *loader = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!loader) return nullptr;
    struct ApplicationInfo {
        int32_t type; const void *next; const char *name; uint32_t version;
        const char *engine; uint32_t engine_version; uint32_t api;
    };
    struct InstanceInfo {
        int32_t type; const void *next; uint32_t flags; const ApplicationInfo *application;
        uint32_t layers; const char *const *layer_names; uint32_t extensions;
        const char *const *extension_names;
    };
    using Create = int32_t (*)(const InstanceInfo *, const void *, void **);
    using Enumerate = int32_t (*)(void *, uint32_t *, void **);
    using Properties = void (*)(void *, void *);
    using Destroy = void (*)(void *, const void *);
    auto create = reinterpret_cast<Create>(dlsym(loader, "vkCreateInstance"));
    auto enumerate = reinterpret_cast<Enumerate>(dlsym(loader, "vkEnumeratePhysicalDevices"));
    auto properties = reinterpret_cast<Properties>(dlsym(loader, "vkGetPhysicalDeviceProperties"));
    auto destroy = reinterpret_cast<Destroy>(dlsym(loader, "vkDestroyInstance"));
    const char *type = nullptr;
    void *instance = nullptr;
    const ApplicationInfo application{0, nullptr, "Fotufilm", 1, "Fotufilm", 1, (1u << 22) | (2u << 12)};
    const InstanceInfo info{1, nullptr, 0, &application, 0, nullptr, 0, nullptr};
    if (create && enumerate && properties && destroy && create(&info, nullptr, &instance) == 0) {
        void *devices[16];
        uint32_t count = 16;
        if (enumerate(instance, &count, devices) >= 0) {
            bool discrete = false, integrated = false, software = false;
            for (uint32_t index = 0; index < count; ++index) {
                // VkPhysicalDeviceProperties: four uint32_t, then deviceType.
                alignas(8) unsigned char device[4096];
                properties(devices[index], device);
                int32_t kind;
                std::memcpy(&kind, device + 16, sizeof(kind));
                discrete |= kind == 2;
                integrated |= kind == 1;
                software |= kind == 4;
            }
            type = discrete ? "discrete-gpu" : integrated ? "integrated-gpu" : software ? "cpu" : nullptr;
        }
        destroy(instance, nullptr);
    }
    dlclose(loader);
    return type;
}

void release_device();

Device pick_device() {
    configure_error_handler();
    const char *setting = std::getenv("FOTUFILM_GPU_DEVICE");
    const std::string wanted = setting ? setting : "";
    if (wanted == "cpu") return kNone;
    if (wanted == "cuda") return answers(kCuda) ? kCuda : kNone;
    if (wanted != "vulkan" && answers(kCuda)) return kCuda;
    if (!std::getenv("HL_VK_DEVICE_TYPE"))
        if (const char *type = preferred_vulkan_device_type())
            setenv("HL_VK_DEVICE_TYPE", type, 0);
    return answers(kVulkan) ? kVulkan : kNone;
}

Device chosen_device() {
    static const Device device = [] {
        const Device picked = pick_device();
        // Halide's runtime releases its Vulkan device from a library destructor, after the
        // driver may have finalised (NVIDIA's crashes there); exit handlers run before that.
        if (picked == kVulkan) std::atexit(release_device);
        // A frame's intermediates keep their device memory for the next frame of the same size,
        // rather than allocate and free it (a synchronising free on CUDA) every frame.
        if (picked != kNone) halide_reuse_device_allocations(nullptr, true);
        return picked;
    }();
    return device;
}

/// The spectral tables, kept on the device between frames of one film.
struct State {
    std::mutex mutex;
    Buffer<float> exposure, film, paper;
    uint64_t identifier = 0;
    Buffer<float> configuration{FOTUFILM_FRAME_CONFIGURATION_COUNT};

    int ensure(Device device, const float *exposure_values, const float *film_values,
               const float *paper_values, int32_t dimension, uint64_t cache_id) {
        if (dimension != kLutDimension || !exposure_values || !film_values || !paper_values)
            return -1;
        if (identifier == cache_id && exposure.data() != nullptr) return 0;
        const int bound = device == kVulkan ? kLutVulkanPaddedCount : kLutValueCount;
        const halide_device_interface_t *interface = interface_for(device);
        int error = 0;
        for (auto [buffer, values] : {std::pair{&exposure, exposure_values},
                                      std::pair{&film, film_values},
                                      std::pair{&paper, paper_values}}) {
            *buffer = Buffer<float>(bound);
            std::memcpy(buffer->data(), values, kLutValueCount * sizeof(float));
            std::fill(buffer->data() + kLutValueCount, buffer->data() + bound, 0.0f);
            buffer->set_host_dirty();
            if (!error) error = buffer->copy_to_device(interface);
        }
        identifier = error ? 0 : cache_id;
        return error;
    }
};

State &state() {
    static State shared;
    return shared;
}

using FilmTileStore = fotufilm::BasicFilmTileStore<Buffer<float>>;

FilmTileStore &film_tile_store() {
    static FilmTileStore &store = []() -> FilmTileStore & {
        FilmTileStore &shared = FilmTileStore::shared();
        shared.upload_with([](Buffer<float> &tiles) {
            tiles.set_host_dirty();
            return tiles.copy_to_device(interface_for(chosen_device()));
        });
        return shared;
    }();
    return store;
}

void release_device() {
    {
        State &cache = state();
        std::lock_guard<std::mutex> lock(cache.mutex);
        for (Buffer<float> *buffer : {&cache.exposure, &cache.film, &cache.paper, &cache.configuration})
            buffer->device_free();
        cache.identifier = 0;
    }
    film_tile_store().device_free();
    halide_device_release(nullptr, interface_for(chosen_device()));
}

bool valid_flare_mean(const float *configuration, int32_t feature_mask) {
    if ((feature_mask & FOTUFILM_FRAME_FLARE) == 0) return true;
    if ((feature_mask & FOTUFILM_FRAME_FLARE_MEASURE) != 0) return true;
    for (int channel = 0; channel < 3; ++channel) {
        const float value = configuration[FOTUFILM_CONFIG_FLARE_MEAN + channel];
        if (!std::isfinite(value) || value < 0.0f) return false;
    }
    return true;
}

template <typename Element>
int32_t develop(const Element *input, Element *output, int32_t width, int32_t height,
                int32_t origin_x, int32_t origin_y, const float *configuration,
                const float *exposure_lut, const float *film_output_lut,
                const float *paper_output_lut, int32_t lut_dimension,
                uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    const Device device = chosen_device();
    if (device == kNone || !input || !output || !configuration || width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask))
        return -1;
    const FrameFunction pipeline = device == kCuda
        ? fotufilm::aot::select_variant(kCudaVariants, std::size(kCudaVariants), feature_mask)
        : fotufilm::aot::select_variant(kVulkanVariants, std::size(kVulkanVariants), feature_mask);
    if (!pipeline) return -3;
    State &cache = state();
    std::lock_guard<std::mutex> lock(cache.mutex);
    int error = cache.ensure(device, exposure_lut, film_output_lut, paper_output_lut,
                             lut_dimension, spectral_cache_id);
    if (error) return error;
    std::memcpy(cache.configuration.data(), configuration,
                FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float));
    cache.configuration.set_host_dirty();
    const fotufilm::ResolvedFrameParams frame(configuration, width, height, seed,
        (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0, origin_x, origin_y);
    bool film_on = false;
    Buffer<float> film_tiles = film_tile_store().tiles_for(configuration, film_on);
    auto in = Buffer<Element>::make_interleaved(const_cast<Element *>(input), width, height, 4);
    auto out = Buffer<Element>::make_interleaved(output, width, height, 4);
    in.set_host_dirty();
    auto *cfg = cache.configuration.raw_buffer();
    auto *exposure = cache.exposure.raw_buffer();
    auto *film = cache.film.raw_buffer();
    auto *paper = cache.paper.raw_buffer();
    error = pipeline(FOTUFILM_AOT_FRAME_ARGUMENTS(in.raw_buffer(), cfg, exposure, film, paper,
                                                  width, height, frame, seed, origin_x, origin_y,
                                                  feature_mask, configuration,
                                                  film_tiles.raw_buffer(), film_on ? 1 : 0),
                     out.raw_buffer());
    if (!error) error = out.copy_to_host();
    return error;
}

}  // namespace

extern "C" int32_t fotufilm_halide_gpu_device(void) { return chosen_device(); }

extern "C" int32_t fotufilm_halide_cuda_available(void) { return chosen_device() != kNone; }

extern "C" int32_t fotufilm_halide_cuda_prepare(
    int32_t, const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension, uint64_t spectral_cache_id) {
    const Device device = chosen_device();
    if (device == kNone) return -1;
    State &cache = state();
    std::lock_guard<std::mutex> lock(cache.mutex);
    return cache.ensure(device, exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
                        spectral_cache_id);
}

extern "C" int32_t fotufilm_halide_cuda_process_srgb8(
    const uint8_t *input, uint8_t *output, int32_t width, int32_t height,
    const float *configuration, const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension, uint64_t spectral_cache_id,
    int32_t feature_mask, uint32_t seed) {
    return develop(input, output, width, height, 0, 0, configuration, exposure_lut,
                   film_output_lut, paper_output_lut, lut_dimension, spectral_cache_id,
                   feature_mask & ~FOTUFILM_FRAME_FLOAT_IO, seed);
}

extern "C" int32_t fotufilm_halide_cuda_process_linear_float(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    return develop(input, output, width, height, origin_x, origin_y, configuration,
                   exposure_lut, film_output_lut, paper_output_lut, lut_dimension,
                   spectral_cache_id, feature_mask | FOTUFILM_FRAME_FLOAT_IO, seed);
}

// Device pointers stay a JIT feature: the desktop hands frames over in host memory.
extern "C" int32_t fotufilm_halide_cuda_process_device_srgb8(
    uint64_t, uint64_t, int32_t, int32_t, const float *, const float *, const float *,
    const float *, int32_t, uint64_t, int32_t, uint32_t) { return -1; }
extern "C" int32_t fotufilm_halide_cuda_process_device_linear_float(
    uint64_t, uint64_t, int32_t, int32_t, int32_t, int32_t, const float *, const float *,
    const float *, const float *, int32_t, uint64_t, int32_t, uint32_t) { return -1; }

extern "C" int32_t fotufilm_halide_metal_available(void) { return 0; }

// Scan inversion on the CPU; the caller falls back to it when the device path (1) refuses.
extern "C" int32_t fotufilm_negative_scan(const float *in, float *out, int32_t w, int32_t h,
                                          const float *p, int32_t backend) {
    if (!in || !out || !p || w < 1 || h < 1 || w > 40000 || h > 40000
        || int64_t(w) * h > 150000000 || backend != 0) return -1;
    for (int c = 0; c < 3; ++c)
        if (!std::isfinite(p[c]) || !std::isfinite(p[c + 3]) || p[c] < 0 || p[c + 3] < p[c])
            return -1;
    if (!std::isfinite(p[6]) || p[6] < 0.1f || p[6] > 2.0f || !std::isfinite(p[7])) return -1;
    Buffer<float> input(const_cast<float *>(in), w, h, 3), output(out, w, h, 3);
    Buffer<float> params(const_cast<float *>(p), 8);
    return fotufilm_aot_negative_cpu(input, params, output);
}

// Layered Transport's spreading on the CPU; the desktop has no Metal (1).
extern "C" int32_t fotufilm_transport_available(int32_t backend) { return backend == 0; }

extern "C" int32_t fotufilm_transport_component(
    const float *exposure, float *accumulated, int32_t width, int32_t height, int32_t channels,
    const float *stencils, int32_t backend) {
    if (int32_t status = fotufilm_transport_validate(exposure, accumulated, width, height, channels,
                                                     stencils, backend)) return status;
    if (backend != 0) return -3;
    int32_t r[FOTUFILM_TRANSPORT_LEVELS];
    for (int l = 0; l < FOTUFILM_TRANSPORT_LEVELS; ++l) r[l] = int32_t(stencils[l]);
    Buffer<float> input(const_cast<float *>(exposure), width, height, channels);
    Buffer<float> sum(accumulated, width, height, channels);
    Buffer<float> table(const_cast<float *>(stencils), FOTUFILM_TRANSPORT_TABLE_FLOATS);
    Buffer<float> output(width, height, channels);
    int status = fotufilm_aot_transport_cpu(input, sum, table, r[0], r[1], r[2], r[3], r[4], r[5],
                                            r[6], r[7], r[8], r[9], r[10], r[11], r[12], output);
    if (!status) std::copy_n(output.data(), int64_t(width) * height * channels, accumulated);
    return status;
}

extern "C" fotufilm_transport_frame *fotufilm_transport_frame_begin(
    const float *scene, const float *configuration, float *sum, int32_t width, int32_t height,
    int32_t channels, int32_t backend) {
    if (backend != 0) return nullptr;
    return fotufilm::transport_frame::begin(fotufilm_aot_transport_domain_cpu,
                                            fotufilm_aot_transport_scene_cpu, nullptr, scene,
                                            configuration, sum, width, height, channels);
}

extern "C" int32_t fotufilm_transport_frame_add(fotufilm_transport_frame *frame,
                                                const float *configuration,
                                                const float *exposure_lut, const float *stencils) {
    return fotufilm::transport_frame::add(frame, configuration, exposure_lut, stencils);
}

extern "C" int32_t fotufilm_transport_frame_finish(fotufilm_transport_frame *frame, int32_t deliver) {
    return fotufilm::transport_frame::finish(frame, deliver);
}

extern "C" int32_t fotufilm_halide_available(void) { return 0; }
// The Film tile builder needs the Halide compiler; the engine builds tiles in Swift instead.
extern "C" int32_t fotufilm_film_tile_build(int32_t, int32_t, int32_t, const float *, int32_t,
    const float *, const float *, int32_t, uint32_t, int32_t, float *) {
    return -3;
}
extern "C" int32_t fotufilm_halide_set_film_tiles(int32_t id, const float *tiles,
                                                  int64_t count) {
    return film_tile_store().set(id, tiles, count) ? 0 : -1;
}
extern "C" int32_t fotufilm_halide_develop(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, int32_t, int32_t,
    uint32_t) { return -1; }
extern "C" int32_t fotufilm_halide_print(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, const float *, int32_t,
    int32_t) { return -1; }
extern "C" int32_t fotufilm_halide_process(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, const float *, const float *, const float *,
    const float *, int32_t, int32_t, uint32_t) { return -1; }
extern "C" int32_t fotufilm_halide_process_strip(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    const float *, const float *, const float *, const float *, int32_t,
    int32_t, uint32_t) { return -1; }
extern "C" int32_t fotufilm_halide_process_tile(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, const float *, const float *, const float *, const float *,
    int32_t, int32_t, uint32_t) { return -1; }
extern "C" int32_t fotufilm_halide_process_tile_with_exposure(
    const float *, const float *, const float *, float *, float *, float *,
    int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, int32_t, const float *, const float *, const float *, const float *,
    int32_t, int32_t, uint32_t, const float *) { return -1; }
extern "C" int32_t fotufilm_halide_gaussian(
    const float *, float *, int32_t, int32_t, float, int32_t) { return -1; }
extern "C" int32_t fotufilm_halide_approximate_gaussian(
    const float *, float *, int32_t, int32_t, int32_t) { return -1; }

#endif
