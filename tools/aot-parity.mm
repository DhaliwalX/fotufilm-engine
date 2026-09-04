// Compares every selectable shipped AOT variant with the equivalent JIT pipeline. Swift tests use
// only JIT kernels and therefore cannot detect AOT compile failures or stage-mask divergence.
// `tools/verify-aot-parity.sh` builds this source twice:
//
//   parity-aot  -DFOTUFILM_HALIDE_IOS_AOT=1, with FotufilmHalideIOS.o and generated archives
//   parity-jit  -DFOTUFILM_HALIDE_ENABLED=1, with FotufilmHalideMetal.cpp and libHalide
//
// Each executable writes a dump because both implementations export the same symbols. A third
// invocation compares them. Objective-C++ is required to allocate MTLBuffers for head/tail spans.
// The fixture starts from a real stock but sets otherwise-unused slots to in-range values to enable
// gated stages; this verifies parity, not physical accuracy. Variants with identical selector bits
// resolve to the first compatible entry, so unreachable duplicate entries are not executed.

#import <Metal/Metal.h>

#include "FotufilmHalide.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr int kLutDimension = 33;

struct Variant {
    const char *name;
    int32_t mask;
};

const Variant kVariants[] = {
#define FOTUFILM_PARITY_ENTRY(variant_name, variant_mask) {#variant_name, (variant_mask)},
    FOTUFILM_AOT_VARIANTS(FOTUFILM_PARITY_ENTRY)
#undef FOTUFILM_PARITY_ENTRY
};
constexpr int kVariantCount = int(sizeof(kVariants) / sizeof(kVariants[0]));

/// The stock's kernel inputs, as `fotufilm --dump-wasm-pack` writes them.
struct Pack {
    int32_t width = 0, height = 0;
    int32_t feature_mask = 0;
    uint32_t seed = 0;
    std::vector<float> configuration, exposure, film, paper;
};

int32_t read_i32(const uint8_t *&cursor) {
    int32_t value;
    std::memcpy(&value, cursor, sizeof(value));
    cursor += sizeof(value);
    return value;
}

bool read_pack(const char *path, Pack &pack) {
    FILE *file = std::fopen(path, "rb");
    if (!file) return false;
    std::fseek(file, 0, SEEK_END);
    const long size = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    std::vector<uint8_t> bytes(size_t(size < 0 ? 0 : size));
    const bool read = !bytes.empty()
        && std::fread(bytes.data(), 1, bytes.size(), file) == bytes.size();
    std::fclose(file);
    if (!read || bytes.size() < 40 || std::memcmp(bytes.data(), "FSWP", 4) != 0) return false;

    const uint8_t *cursor = bytes.data() + 4;
    if (read_i32(cursor) != 1) return false;
    pack.width = read_i32(cursor);
    pack.height = read_i32(cursor);
    pack.feature_mask = read_i32(cursor);
    pack.seed = uint32_t(read_i32(cursor));
    const int32_t configuration_count = read_i32(cursor);
    const int32_t lut_dimension = read_i32(cursor);
    const int32_t lut_count = read_i32(cursor);
    read_i32(cursor);  // Whether the stock prints; the cube is written either way.
    if (configuration_count != FOTUFILM_FRAME_CONFIGURATION_COUNT
        || lut_dimension != kLutDimension) {
        std::fprintf(stderr,
                     "pack disagrees with this build: %d configuration floats (expected %d), "
                     "LUT dimension %d (expected %d)\n",
                     configuration_count, FOTUFILM_FRAME_CONFIGURATION_COUNT,
                     lut_dimension, kLutDimension);
        return false;
    }

    auto take = [&](std::vector<float> &into, int32_t count) {
        into.resize(size_t(count));
        std::memcpy(into.data(), cursor, size_t(count) * sizeof(float));
        cursor += size_t(count) * sizeof(float);
    };
    take(pack.configuration, configuration_count);
    take(pack.exposure, lut_count);
    take(pack.film, lut_count);
    take(pack.paper, lut_count);
    return cursor == bytes.data() + bytes.size();
}

/// Fills the slots the browser export leaves alone, so that the stages selected by the variants
/// below are asked to do something rather than collapsing to a copy. Arbitrary but in range, and
/// identical on both paths, which is all a parity fixture owes.
void arm_configuration(std::vector<float> &configuration) {
    float *c = configuration.data();

    // A measured veiling-glare mean, which the non-measuring FLARE variants are promised and
    // refuse to run without (`valid_flare_mean`).
    for (int channel = 0; channel < 3; ++channel) c[FOTUFILM_CONFIG_FLARE_MEAN + channel] = 0.18f;

    // The host output transform the ENCODE_OUT variants read: identity primaries and a linear
    // transfer, so the encode arm runs and returns what it was given.
    for (int i = 0; i < 9; ++i) c[FOTUFILM_CONFIG_OUTPUT_MATRIX + i] = (i % 4 == 0) ? 1.0f : 0.0f;
    c[FOTUFILM_CONFIG_OUTPUT_TRANSFER] = 0.0f;
    for (int i = 0; i < 6; ++i) c[FOTUFILM_CONFIG_OUTPUT_COEFFICIENTS + i] = 0.0f;
    c[FOTUFILM_CONFIG_OUTPUT_PREMULTIPLIED] = 0.0f;

    // The donor capture layer. A stock that coats none arrives with its release row at zero and
    // the stage sums to nothing, which would leave every `_donor` twin developing exactly what
    // its plain counterpart does — a variant that runs but is never asked a question. Its own
    // curve borrows the green record's, which is the shape a fourth layer's is.
    for (int i = 0; i < 6; ++i) {
        c[FOTUFILM_CONFIG_DONOR_CURVE + i] = c[FOTUFILM_CONFIG_CURVES + 6 + i];
    }
    const float donor_release[3] = {0.62f, 0.0f, 0.0f};
    for (int i = 0; i < 3; ++i) c[FOTUFILM_CONFIG_DONOR_RELEASE + i] = donor_release[i];

    // Current physical halation uses centered continuous Gaussian mixtures. The three legacy
    // annular-radius slots remain zero to preserve the packed-configuration ABI.
}

/// A deterministic scene, in the units the scene-referred path expects.
///
/// Peak radiance stays above 1: the exposure walk samples the spectral cube near its origin below
/// unit radiance, where the two paths' agreement would be measuring the cube's corner rather than
/// the pipeline. It carries an edge, a gradient and a saturated patch, so the spatial stages have
/// something to move and the print has something to clip.
void fill_scene(std::vector<float> &scene, int32_t width, int32_t height) {
    scene.resize(size_t(width) * size_t(height) * 4);
    for (int32_t y = 0; y < height; ++y) {
        for (int32_t x = 0; x < width; ++x) {
            const float u = float(x) / float(width - 1);
            const float v = float(y) / float(height - 1);
            const bool bright = (x > width / 2) && (y > height / 3) && (y < 2 * height / 3);
            float rgb[3] = {0.05f + 3.0f * u * u, 0.05f + 2.0f * v, 0.05f + 1.5f * (1.0f - u) * v};
            if (bright) { rgb[0] = 8.0f; rgb[1] = 7.2f; rgb[2] = 6.4f; }
            float *pixel = &scene[(size_t(y) * size_t(width) + size_t(x)) * 4];
            pixel[0] = rgb[0];
            pixel[1] = rgb[1];
            pixel[2] = rgb[2];
            pixel[3] = 1.0f;
        }
    }
}

/// The same scene quantised, for the variants whose input is RGBA8.
void fill_scene_u8(std::vector<uint8_t> &scene, const std::vector<float> &linear) {
    scene.resize(linear.size());
    for (size_t i = 0; i < linear.size(); ++i) {
        const float value = linear[i] / 8.0f;
        const float encoded = value <= 0.0031308f
            ? value * 12.92f
            : 1.055f * std::pow(value, 1.0f / 2.4f) - 0.055f;
        const float clamped = encoded < 0.0f ? 0.0f : (encoded > 1.0f ? 1.0f : encoded);
        scene[i] = uint8_t(clamped * 255.0f + 0.5f);
    }
}

float from_half(uint16_t bits) {
    _Float16 value;
    std::memcpy(&value, &bits, sizeof(value));
    return float(value);
}

}  // namespace

namespace {

/// One variant's result, as it is written to disk and read back for comparison.
struct Record {
    std::string name;
    int32_t mask = 0;
    int32_t status = 0;
    std::vector<float> output;
};

bool write_record(const char *path, const Record &record) {
    FILE *file = std::fopen(path, "wb");
    if (!file) return false;
    const int32_t name_length = int32_t(record.name.size());
    const int32_t count = int32_t(record.output.size());
    bool ok = std::fwrite("FSPY", 1, 4, file) == 4
        && std::fwrite(&name_length, sizeof(name_length), 1, file) == 1
        && std::fwrite(record.name.data(), 1, record.name.size(), file) == record.name.size()
        && std::fwrite(&record.mask, sizeof(record.mask), 1, file) == 1
        && std::fwrite(&record.status, sizeof(record.status), 1, file) == 1
        && std::fwrite(&count, sizeof(count), 1, file) == 1;
    if (ok && count > 0) {
        ok = std::fwrite(record.output.data(), sizeof(float), size_t(count), file)
            == size_t(count);
    }
    std::fclose(file);
    return ok;
}

bool read_record(const char *path, Record &record) {
    FILE *file = std::fopen(path, "rb");
    if (!file) return false;
    char magic[4];
    int32_t name_length = 0, count = 0;
    bool ok = std::fread(magic, 1, 4, file) == 4 && std::memcmp(magic, "FSPY", 4) == 0
        && std::fread(&name_length, sizeof(name_length), 1, file) == 1
        && name_length >= 0 && name_length < 256;
    if (ok) {
        record.name.resize(size_t(name_length));
        ok = std::fread(&record.name[0], 1, size_t(name_length), file) == size_t(name_length)
            && std::fread(&record.mask, sizeof(record.mask), 1, file) == 1
            && std::fread(&record.status, sizeof(record.status), 1, file) == 1
            && std::fread(&count, sizeof(count), 1, file) == 1
            && count >= 0;
    }
    if (ok && count > 0) {
        record.output.resize(size_t(count));
        ok = std::fread(record.output.data(), sizeof(float), size_t(count), file)
            == size_t(count);
    }
    std::fclose(file);
    return ok;
}

/// A Metal buffer that outlives the call it is handed to, with its contents readable on return.
struct DeviceBuffer {
    id<MTLBuffer> buffer = nil;
    explicit DeviceBuffer(id<MTLDevice> device, size_t bytes) {
        buffer = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    }
    uint64_t handle() const { return uint64_t(uintptr_t((__bridge void *)buffer)); }
    void *contents() const { return buffer.contents; }
    explicit operator bool() const { return buffer != nil; }
};

/// A deterministic developed negative, for the spans that read density rather than scene light.
void fill_density(std::vector<uint16_t> &density, int32_t width, int32_t height) {
    density.resize(size_t(width) * size_t(height) * 4);
    for (int32_t y = 0; y < height; ++y) {
        for (int32_t x = 0; x < width; ++x) {
            const float u = float(x) / float(width - 1);
            const float v = float(y) / float(height - 1);
            const float value[4] = {0.15f + 2.3f * u, 0.15f + 2.1f * v,
                                    0.15f + 1.9f * u * v, 1.0f};
            uint16_t *pixel = &density[(size_t(y) * size_t(width) + size_t(x)) * 4];
            for (int c = 0; c < 4; ++c) {
                const _Float16 half = _Float16(value[c]);
                std::memcpy(&pixel[c], &half, sizeof(uint16_t));
            }
        }
    }
}

int32_t run_variant(const Variant &variant, const Pack &pack,
                    const std::vector<float> &scene, const std::vector<uint8_t> &scene_u8,
                    std::vector<float> &out) {
    const int32_t width = pack.width, height = pack.height;
    const size_t pixels = size_t(width) * size_t(height);
    const float *configuration = pack.configuration.data();
    const float *exposure = pack.exposure.data();
    const float *film = pack.film.data();
    const float *paper = pack.paper.data();
    // One id per LUT set. It never changes here, so both paths upload the cubes once.
    const uint64_t cache_id = 0x9E3779B97F4A7C15ull;
    const int32_t mask = variant.mask;
    const uint32_t seed = pack.seed;

    int32_t status = fotufilm_halide_metal_prepare(mask, exposure, film, paper,
                                                  kLutDimension, cache_id);
    if (status != 0) return status;

    if ((mask & FOTUFILM_FRAME_LIGHT_OUT) != 0) {
        std::vector<float> light(pixels * 4);
        status = fotufilm_halide_metal_process_light_rows(
            scene.data(), light.data(), width, height, 0, height, 0, 0,
            configuration, exposure, film, paper, kLutDimension, cache_id, mask, seed);
        out = light;
        return status;
    }

    if ((mask & FOTUFILM_FRAME_FIELDS_IN) != 0) {
        // The fields path is two shipped kernels and a blob layout, so it is run rather than
        // faked: the light pass, the pyramid builder, then the strip that samples it. A
        // disagreement anywhere in the chain lands here.
        const int32_t light_mask = FOTUFILM_FRAME_FLARE | FOTUFILM_FRAME_MTF
            | FOTUFILM_FRAME_MTF_LUMA | FOTUFILM_FRAME_FLOAT_IO | FOTUFILM_FRAME_LIGHT_OUT
            | (mask & FOTUFILM_FRAME_MONOCHROME);
        std::vector<float> light(pixels * 4);
        status = fotufilm_halide_metal_prepare(light_mask, exposure, film, paper,
                                              kLutDimension, cache_id);
        if (status != 0) return status;
        status = fotufilm_halide_metal_process_light_rows(
            scene.data(), light.data(), width, height, 0, height, 0, 0,
            configuration, exposure, film, paper, kLutDimension, cache_id, light_mask, seed);
        if (status != 0) return status;

        int32_t radii[3];
        for (int scale = 0; scale < 3; ++scale) {
            radii[scale] = int32_t(configuration[FOTUFILM_CONFIG_HALATION_RADIUS + scale]);
        }
        const int32_t fields_floats =
            fotufilm_halide_metal_halation_fields_floats(width, height, radii);
        if (fields_floats < 0) return fields_floats;
        std::vector<float> fields(static_cast<size_t>(fields_floats), 0.0f);
        status = fotufilm_halide_metal_halation_fields(light.data(), width, height, radii,
                                                      fields.data(), fields_floats);
        if (status != 0) return status;

        status = fotufilm_halide_metal_prepare(mask, exposure, film, paper,
                                              kLutDimension, cache_id);
        if (status != 0) return status;
        out.assign(pixels * 4, 0.0f);
        status = fotufilm_halide_metal_process_linear_float_fields_rows(
            scene.data(), out.data(), width, height, 0, height, 0, 0,
            configuration, fields.data(), fields_floats, cache_id + 1,
            exposure, film, paper, kLutDimension, cache_id, mask, seed);
        // The pyramid is half of what this variant develops, so it travels with the frame.
        out.insert(out.end(), fields.begin(), fields.end());
        return status;
    }

    const bool density_in = (mask & FOTUFILM_FRAME_DENSITY_IN) != 0;
    const bool density_out = (mask & FOTUFILM_FRAME_DENSITY_OUT) != 0;
    const bool float_io = (mask & FOTUFILM_FRAME_FLOAT_IO) != 0;

    if (!float_io && (density_in || density_out)) {
        // The hybrid still path's two halves. Neither has a host-pointer entry point — they are
        // zero-copy over caller-owned MTLBuffers — so the buffers are made here.
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            std::fprintf(stderr, "no Metal device\n");
            return -100;
        }
        if (density_out) {
            DeviceBuffer input(device, pixels * 4);
            DeviceBuffer density(device, pixels * 4 * sizeof(uint16_t));
            if (!input || !density) return -101;
            std::memcpy(input.contents(), scene_u8.data(), pixels * 4);
            status = fotufilm_halide_metal_process_buffers_head(
                input.handle(), density.handle(), width, height, 0, 0,
                configuration, exposure, film, paper, kLutDimension, cache_id, mask, seed);
            const uint16_t *values = static_cast<const uint16_t *>(density.contents());
            out.resize(pixels * 4);
            for (size_t i = 0; i < out.size(); ++i) out[i] = from_half(values[i]);
            return status;
        }
        std::vector<uint16_t> density_rows;
        fill_density(density_rows, width, height);
        DeviceBuffer density(device, density_rows.size() * sizeof(uint16_t));
        DeviceBuffer output(device, pixels * 4);
        if (!density || !output) return -101;
        std::memcpy(density.contents(), density_rows.data(),
                    density_rows.size() * sizeof(uint16_t));
        status = fotufilm_halide_metal_process_buffers_tail(
            density.handle(), output.handle(), width, height, width, height, 0, 0,
            configuration, exposure, film, paper, kLutDimension, cache_id, mask, seed);
        const uint8_t *values = static_cast<const uint8_t *>(output.contents());
        out.resize(pixels * 4);
        for (size_t i = 0; i < out.size(); ++i) out[i] = float(values[i]);
        return status;
    }

    if (!float_io) {
        std::vector<uint8_t> encoded(pixels * 4);
        status = fotufilm_halide_metal_process_srgb8(
            scene_u8.data(), encoded.data(), width, height, configuration,
            exposure, film, paper, kLutDimension, cache_id, mask, seed);
        out.resize(encoded.size());
        for (size_t i = 0; i < encoded.size(); ++i) out[i] = float(encoded[i]);
        return status;
    }

    // Every remaining variant takes interleaved linear float RGBA. A span that reads densities
    // is handed the same deterministic negative the tail gets, so it is asked a question in its
    // own units rather than developing scene light as though it were density.
    std::vector<float> input;
    if (density_in) {
        std::vector<uint16_t> density_rows;
        fill_density(density_rows, width, height);
        input.resize(density_rows.size());
        for (size_t i = 0; i < input.size(); ++i) input[i] = from_half(density_rows[i]);
    } else {
        input = scene;
    }
    out.assign(pixels * 4, 0.0f);
    status = fotufilm_halide_metal_process_linear_float(
        input.data(), out.data(), width, height, 0, 0, configuration,
        exposure, film, paper, kLutDimension, cache_id, mask, seed);
    return status;
}

}  // namespace

namespace {

/// Compares two dumps of the same variant. NaN is compared by presence rather than by value, so
/// a stage that legitimately produces one on both paths appears as agreement and a stage that
/// produces one on only one path appears as the disagreement it is.
struct Difference {
    double max_absolute = 0.0;
    // The worst difference *excluding* categorical elements (see below) — the number a float-scale
    // tolerance should actually be checked against. A rounding boundary landing the other way on
    // an 8-bit output reads as up to 1.0 in max_absolute, which would swallow the tolerance meant
    // to catch a genuine 1e-6-scale regression on the 64 variants that write a 0..1 float picture.
    double worst_noncategorical = 0.0;
    size_t nan_mismatches = 0;
    size_t count_mismatch = 0;
    // Where the worst one is and what the two roads actually said there. A magnitude on its own
    // does not distinguish a last-bit disagreement from one road answering 0 where the other
    // answered 1, and those two want completely different explanations.
    size_t worst_index = 0;
    float worst_left = 0.0f;
    float worst_right = 0.0f;
    // Elements at least 0.5 apart in the buffer's own units. On a 0..1 float output that is half
    // scale; on an 8-bit output every value is already an integer, so 0.5 means any code at all
    // disagrees. The same threshold names the same kind of event — a real answer, not a rounding
    // artifact — in either unit, which is why compare_mode's message calls it "half scale" for
    // both rather than trying to say two different things.
    size_t categorical = 0;
};

Difference compare_records(const Record &a, const Record &b) {
    Difference difference;
    if (a.output.size() != b.output.size()) {
        difference.count_mismatch = 1;
        return difference;
    }
    for (size_t i = 0; i < a.output.size(); ++i) {
        const bool a_nan = std::isnan(a.output[i]), b_nan = std::isnan(b.output[i]);
        if (a_nan || b_nan) {
            if (a_nan != b_nan) ++difference.nan_mismatches;
            continue;
        }
        const double delta = std::fabs(double(a.output[i]) - double(b.output[i]));
        if (delta >= 0.5) {
            ++difference.categorical;
        } else if (delta > difference.worst_noncategorical) {
            difference.worst_noncategorical = delta;
        }
        if (delta > difference.max_absolute) {
            difference.max_absolute = delta;
            difference.worst_index = i;
            difference.worst_left = a.output[i];
            difference.worst_right = b.output[i];
        }
    }
    return difference;
}

/// Whether a dump carries no information — every value the same. Two paths agree trivially on a
/// frame like that, so a run where many variants are flat is a run that proved less than its
/// summary line suggests. Reported rather than failed: a few spans legitimately develop a
/// constant from this fixture.
bool is_flat(const std::vector<float> &output) {
    if (output.size() < 2) return true;
    for (size_t i = 1; i < output.size(); ++i) {
        if (output[i] != output[0] && !(std::isnan(output[i]) && std::isnan(output[0]))) {
            return false;
        }
    }
    return true;
}

int compare_mode(const char *left_dir, const char *right_dir, double tolerance,
                  size_t categorical_budget) {
    int failures = 0;
    int flat = 0;
    double worst = 0.0;
    const char *worst_name = "";
    for (int index = 0; index < kVariantCount; ++index) {
        char left_path[1024], right_path[1024];
        std::snprintf(left_path, sizeof(left_path), "%s/%03d.bin", left_dir, index);
        std::snprintf(right_path, sizeof(right_path), "%s/%03d.bin", right_dir, index);
        Record left, right;
        const bool have_left = read_record(left_path, left);
        const bool have_right = read_record(right_path, right);
        if (!have_left || !have_right) {
            std::printf("MISSING  %-56s %s\n", kVariants[index].name,
                        !have_left && !have_right ? "(neither road)"
                            : (!have_left ? "(no AOT result)" : "(no JIT result)"));
            ++failures;
            continue;
        }
        if (left.name != right.name || left.mask != right.mask) {
            std::printf("MISMATCH %-56s the two dumps describe different variants\n",
                        kVariants[index].name);
            ++failures;
            continue;
        }
        if (left.status != right.status) {
            std::printf("STATUS   %-56s AOT %d, JIT %d\n", left.name.c_str(),
                        left.status, right.status);
            ++failures;
            continue;
        }
        if (left.status != 0) {
            std::printf("REFUSED  %-56s both roads returned %d\n", left.name.c_str(),
                        left.status);
            ++failures;
            continue;
        }
        if (is_flat(left.output)) {
            std::printf("FLAT     %-56s develops a constant, so agreement proves nothing\n",
                        left.name.c_str());
            ++flat;
        }
        const Difference difference = compare_records(left, right);
        if (difference.count_mismatch) {
            std::printf("SHAPE    %-56s AOT %zu floats, JIT %zu\n", left.name.c_str(),
                        left.output.size(), right.output.size());
            ++failures;
            continue;
        }
        if (difference.nan_mismatches) {
            std::printf("NAN      %-56s %zu values NaN on one road only\n",
                        left.name.c_str(), difference.nan_mismatches);
            ++failures;
            continue;
        }
        // Two separate questions, because they fail for different reasons. worst_noncategorical
        // against tolerance is "did the two compilers' arithmetic actually disagree" — the thing a
        // real regression trips. difference.categorical against its budget is "how many pixels
        // landed on the far side of a rounding boundary" — expected in small numbers on an 8-bit
        // output (measured: at most 2 of 331,776, on 21 of 182 variants) and not a defect on its
        // own. A variant can fail either bar without failing the other.
        const bool categorical_over_budget = difference.categorical > categorical_budget;
        const bool noncategorical_over_tolerance = difference.worst_noncategorical > tolerance;
        if (categorical_over_budget || noncategorical_over_tolerance) {
            std::printf("DIFFER   %-56s max |AOT - JIT| = %.9g at [%zu] "
                        "AOT %.9g JIT %.9g, %zu of %zu at least half scale apart%s%s\n",
                        left.name.c_str(), difference.max_absolute, difference.worst_index,
                        double(difference.worst_left), double(difference.worst_right),
                        difference.categorical, left.output.size(),
                        categorical_over_budget ? " [over categorical budget]" : "",
                        noncategorical_over_tolerance ? " [over tolerance]" : "");
            ++failures;
        } else if (difference.worst_noncategorical > worst) {
            // Tracked over the variants that passed, so the summary reports how close the
            // agreeing ones came to the tolerance rather than how far the failing ones went.
            worst = difference.worst_noncategorical;
            worst_name = kVariants[index].name;
        }
    }
    std::printf("\n%d variants, %d failing, %d developing a constant; "
                "worst agreeing difference %.9g (%s), tolerance %g, categorical budget %zu\n",
                kVariantCount, failures, flat, worst,
                worst_name[0] ? worst_name : "none", tolerance, categorical_budget);
    return failures == 0 ? 0 : 1;
}

void usage() {
    std::fprintf(stderr,
                 "usage: aot-parity --count\n"
                 "       aot-parity --pack=PACK --variant=INDEX --out=FILE\n"
                 "       aot-parity --compare LEFT_DIR RIGHT_DIR [--tolerance=T]\n"
                 "                  [--categorical-budget=N]\n");
}

}  // namespace

int main(int argc, char **argv) {
    const char *pack_path = nullptr;
    const char *out_path = nullptr;
    int wanted = -1;
    double tolerance = 0.0;
    size_t categorical_budget = 0;
    std::vector<const char *> positional;
    bool compare = false;

    for (int i = 1; i < argc; ++i) {
        const std::string argument = argv[i];
        if (argument == "--count") {
            std::printf("%d\n", kVariantCount);
            return 0;
        } else if (argument == "--compare") {
            compare = true;
        } else if (argument.rfind("--pack=", 0) == 0) {
            pack_path = argv[i] + 7;
        } else if (argument.rfind("--out=", 0) == 0) {
            out_path = argv[i] + 6;
        } else if (argument.rfind("--variant=", 0) == 0) {
            wanted = std::atoi(argv[i] + 10);
        } else if (argument.rfind("--tolerance=", 0) == 0) {
            tolerance = std::atof(argv[i] + 12);
        } else if (argument.rfind("--categorical-budget=", 0) == 0) {
            categorical_budget = size_t(std::atoll(argv[i] + 21));
        } else if (argument.rfind("--", 0) == 0) {
            std::fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return 2;
        } else {
            positional.push_back(argv[i]);
        }
    }

    if (compare) {
        if (positional.size() != 2) { usage(); return 2; }
        return compare_mode(positional[0], positional[1], tolerance, categorical_budget);
    }
    if (!pack_path || !out_path || wanted < 0) { usage(); return 2; }
    if (wanted >= kVariantCount) {
        std::fprintf(stderr, "--variant=%d is out of range (0..%d)\n",
                     wanted, kVariantCount - 1);
        return 2;
    }

    Pack pack;
    if (!read_pack(pack_path, pack)) {
        std::fprintf(stderr, "could not read pack: %s\n", pack_path);
        return 2;
    }
    arm_configuration(pack.configuration);

    std::vector<float> scene;
    std::vector<uint8_t> scene_u8;
    fill_scene(scene, pack.width, pack.height);
    fill_scene_u8(scene_u8, scene);

    const Variant &variant = kVariants[wanted];
    Record record;
    record.name = variant.name;
    record.mask = variant.mask;
    // A variant the build does not carry is a fact about the build, not a failure to run: it is
    // recorded as such so the comparison can say which path is missing it.
    if (fotufilm_halide_metal_available() != 1) {
        // Includes generated/runtime ABI checks. A missing record would make an abort look like a
        // harness failure; a distinct status makes the comparison name the broken AOT road.
        record.status = -201;
    } else if (fotufilm_halide_metal_variant_exists(variant.mask) != 1) {
        record.status = -200;
    } else {
        record.status = run_variant(variant, pack, scene, scene_u8, record.output);
    }
    if (!write_record(out_path, record)) {
        std::fprintf(stderr, "could not write %s\n", out_path);
        return 2;
    }
    return 0;
}
