#include "FotufilmHalide.h"

// The schedules below are written against a DeviceAPI rather than against Metal, so the same
// pipeline serves every GPU the engine reaches: Metal on Apple, Vulkan on Android, WebGPU in the
// browser, and CUDA on a Linux box. Only the host-side buffer handling below is per-API.
#if defined(FOTUFILM_HALIDE_ENABLED) \
    && (defined(__APPLE__) || defined(FOTUFILM_HALIDE_CUDA))

#include "FotufilmHalideShared.h"
#include "FotufilmHalideFrameParams.h"
#include "Schedule/Gpu.h"
#include "FotufilmCompiledCache.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include <cstdlib>

using Halide::BoundaryConditions::constant_exterior;
using Halide::Buffer;
using Halide::DeviceAPI;
using Halide::Expr;
using Halide::Float;
using Halide::Func;
using Halide::ImageParam;
using Halide::Param;
using Halide::Pipeline;
using Halide::RDom;
using Halide::Target;
using Halide::UInt;
using Halide::Var;

using namespace fotufilm;
using namespace fotufilm::gpu;

namespace {


/// Per-row tone and veiling-glare measurements for linear Rec.2020 float frames.
/// Row reductions make staged and striped totals independent of banding. Tone is measured and
/// solved before glare because glare uses the regional tone grid.
class MetalMeasurePipeline {
public:
    enum class Quantity { Tone, Flare };

    MetalMeasurePipeline(Quantity quantity, bool approximate,
                         const std::string &suffix)
        : quantity_(quantity), approximate_(approximate),
          input_(Float(32), 3, "measure_input" + suffix),
          configuration_(Float(32), 1, "measure_configuration" + suffix),
          exposure_lut_(Float(32), 1, "measure_exposure_lut" + suffix),
          width_("measure_width" + suffix),
          grid_width_("measure_grid_width" + suffix),
          origin_y_("measure_origin_y" + suffix) {
        Var x("measure_x" + suffix), y("measure_y" + suffix);
        Var lane("measure_lane" + suffix);
        input_.dim(0).set_stride(4).dim(2).set_stride(1).set_bounds(0, 4);
        configuration_.dim(0).set_bounds(0, FOTUFILM_FRAME_CONFIGURATION_COUNT);
        exposure_lut_.dim(0).set_bounds(0, kLutValueCount);

        Func rows("measure_rows" + suffix);
        if (quantity_ == Quantity::Flare) {
            // The same first stage the develop kernel runs, from the same definition. `origin_y_`
            // makes the row absolute: the tone grid this reads is indexed by where the pixel sits
            // in the frame, not by where it sits in the band that happens to hold it.
            Func exposure("measure_exposure" + suffix);
            exposure(x, y, lane) = scene_exposure(
                configuration_, exposure_lut_,
                input_(x, y, 0), input_(x, y, 1), input_(x, y, 2), lane,
                x, y + origin_y_, approximate_);
            RDom across(0, width_, "measure_across" + suffix);
            rows(lane, y) = Halide::sum(exposure(across, y, lane),
                                        "measure_row_sum" + suffix);
            rows.bound(lane, 0, 3);
        } else {
            // Metering weights spelled as ToneBaseMeasurement spells them — luminance weight times
            // white-balance gain, then the exposure gain over mid-grey — because that is the
            // measurement being replaced and the two have to be the same quantity. Note this is
            // not how `creative_exposure` spells its own metering; that one folds the reciprocal
            // of 0.18 in instead, and is a different number by a few ulps.
            Expr gain = configuration_(FOTUFILM_CONFIG_EXPOSURE_GAIN) / 0.18f;
            Expr weight_r =
                kLumaR * configuration_(FOTUFILM_CONFIG_WHITE_BALANCE) * gain;
            Expr weight_g =
                kLumaG * configuration_(FOTUFILM_CONFIG_WHITE_BALANCE + 1) * gain;
            Expr weight_b =
                kLumaB * configuration_(FOTUFILM_CONFIG_WHITE_BALANCE + 2) * gain;
            // Cell columns are the host's ceil-division split, and they differ in width by at most
            // one pixel. The domain is the widest of them and the guard drops the tail, which adds
            // a zero rather than a pixel: the cell still sums its own pixels, left to right.
            Expr low = (lane * width_ + grid_width_ - 1) / grid_width_;
            Expr high = ((lane + 1) * width_ + grid_width_ - 1) / grid_width_;
            RDom span(0, (width_ + grid_width_ - 1) / grid_width_ + 1,
                      "measure_span" + suffix);
            Expr px = Halide::clamp(low + span, 0, width_ - 1);
            Expr metered = weight_r * Halide::max(input_(px, y, 0), 0.0f)
                + weight_g * Halide::max(input_(px, y, 1), 0.0f)
                + weight_b * Halide::max(input_(px, y, 2), 0.0f);
            Expr stops = fs_log(Halide::max(metered, 1.0e-6f), approximate_)
                * (1.0f / 0.6931472f);
            rows(lane, y) = Halide::sum(
                Halide::select(low + span < high, stops, 0.0f),
                "measure_cell_sum" + suffix);
        }
        // One thread per row, as the fused measurement schedules its own row pass. A reduction
        // straight to the totals would run in a single thread; the totalling is the host's, and it
        // is three numbers or a few thousand.
        Var block("measure_block" + suffix), thread("measure_thread" + suffix);
        rows.compute_root()
            .reorder(lane, y)
            .gpu_tile(y, block, thread, 32, Halide::TailStrategy::GuardWithIf,
                      gpu_device_api());
        rows_ = rows;
        pipeline_ = Pipeline(rows_);
#if !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
        pipeline_.compile_jit(gpu_target());
#endif
    }

#if defined(__APPLE__)
    /// `lanes` results per row into `out`: three exposure channels for the glare, or one per
    /// tone-grid cell column. `origin_y` is the band's first row in the frame.
    ///
    /// The band arrives either as a caller-owned MTLBuffer, which a staged render already has on
    /// the device, or as host rows, which is what a striped render's strip buffer is. Same
    /// pipeline either way, and deliberately so: the two paths have to reach the same number, and
    /// the surest way to arrange that is for there to be one kernel and one schedule between them.
    void run_metal(uint64_t input_handle, const float *input_host, float *out,
                   int32_t lanes, int32_t width, int32_t rows, int32_t origin_y,
                   int32_t grid_width, const float *configuration,
                   const float *exposure, int32_t dimension,
                   uint64_t cache_id) {
        std::lock_guard<std::mutex> lock(mutex_);
        ensure_lut(exposure, dimension, cache_id);
        const bool wrapped = input_handle != 0;
        Buffer<float> input_buffer = Buffer<float>::make_interleaved(
            wrapped ? static_cast<float *>(nullptr)
                    : const_cast<float *>(input_host),
            width, rows, 4);
        const Target target = gpu_target();
        if (wrapped) {
            if (input_buffer.device_wrap_native(DeviceAPI::Metal, input_handle,
                                                target) != 0) {
                throw Halide::RuntimeError("Unable to wrap caller MTLBuffer");
            }
            input_buffer.set_device_dirty();
        } else {
            input_buffer.set_host_dirty();
        }
        try {
            Buffer<float> configuration_buffer(
                const_cast<float *>(configuration),
                FOTUFILM_FRAME_CONFIGURATION_COUNT);
            configuration_buffer.set_host_dirty();
            input_.set(input_buffer);
            configuration_.set(configuration_buffer);
            exposure_lut_.set(exposure_buffer_);
            width_.set(width);
            grid_width_.set(std::max(grid_width, 1));
            origin_y_.set(origin_y);
            Buffer<float> out_buffer(out, lanes, rows);
            pipeline_.realize(out_buffer, target);
            out_buffer.copy_to_host();
        } catch (...) {
            if (wrapped) input_buffer.device_detach_native();
            throw;
        }
        if (wrapped) input_buffer.device_detach_native();
    }
#endif

#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    /// Generates measurement passes alongside develop variants for the OFX plugin's linked AOT
    /// kernels. Measurement and development must use the same pipeline implementation.
    void compile_aot(const std::string &prefix, const std::string &function_name,
                     Target target) {
        target.set_feature(Target::NoRuntime);
        std::vector<Halide::Argument> arguments{
            input_, configuration_, exposure_lut_,
            width_, grid_width_, origin_y_};
        pipeline_.compile_to_static_library(prefix, arguments, function_name,
                                            target);
    }
#endif

private:
    void ensure_lut(const float *exposure, int32_t dimension, uint64_t cache_id) {
        if (dimension != kLutDimension) {
            throw Halide::RuntimeError("Fotufilm spectral LUT dimension must be 33");
        }
        if (lut_cache_id_ == cache_id && exposure_buffer_.defined()) return;
        exposure_buffer_ = Buffer<float>(kLutValueCount);
        std::memcpy(exposure_buffer_.data(), exposure,
                    kLutValueCount * sizeof(float));
        exposure_buffer_.set_host_dirty();
        const Target target = gpu_target();
        exposure_buffer_.copy_to_device(gpu_device_api(), target);
        lut_cache_id_ = cache_id;
    }

    const Quantity quantity_;
    const bool approximate_;
    ImageParam input_;
    ImageParam configuration_;
    ImageParam exposure_lut_;
    Param<int32_t> width_;
    Param<int32_t> grid_width_;
    Param<int32_t> origin_y_;
    Func rows_;
    Pipeline pipeline_;
    Buffer<float> exposure_buffer_;
    uint64_t lut_cache_id_ = 0;
    std::mutex mutex_;
};

/// Device host-to-engine decode: non-finite repair, un-premultiplication, transfer, and scene-space
/// matrix. Per-row reports store the pre-repair RGB peak in lane 0 and a repair flag in lane 1.
/// Keeping decode separate avoids doubling the AOT develop variants.
class MetalDecodePipeline {
public:
    MetalDecodePipeline(bool approximate, const std::string &suffix)
        : approximate_(approximate),
          input_(Float(32), 3, "decode_input" + suffix),
          parameters_(Float(32), 1, "decode_parameters" + suffix),
          width_("decode_width" + suffix) {
        Var x("decode_x" + suffix), y("decode_y" + suffix);
        Var channel("decode_channel" + suffix), lane("decode_lane" + suffix);
        input_.dim(0).set_stride(4).dim(2).set_stride(1).set_bounds(0, 4);
        parameters_.dim(0).set_bounds(0, FOTUFILM_DECODE_PARAMETER_COUNT);

        // One pixel, start to finish, exactly as `decodePixel` holds it in registers. `repaired`
        // accumulates the same way the host's `clean` does: every place the host would have
        // written a replacement value is a place this notices.
        struct Pixel {
            Halide::Expr r, g, b, a, peak, repaired;
        };
        // Read off the host's own numbers, before any repair: three components combined by max
        // from zero, so a negative never displaces it and a non-finite never enters. It is worth
        // having on its own because it reads the input and stops — no transfer curve, no matrix.
        auto peak_of = [&](Halide::Expr px, Halide::Expr py) {
            Halide::Expr r = input_(px, py, 0), g = input_(px, py, 1), b = input_(px, py, 2);
            return Halide::max(
                Halide::select(Halide::is_finite(r), r, 0.0f),
                Halide::max(Halide::select(Halide::is_finite(g), g, 0.0f),
                            Halide::select(Halide::is_finite(b), b, 0.0f)));
        };
        auto decode = [&](Halide::Expr px, Halide::Expr py) {
            Halide::Expr r = input_(px, py, 0), g = input_(px, py, 1);
            Halide::Expr b = input_(px, py, 2), a = input_(px, py, 3);
            Halide::Expr finite_r = Halide::is_finite(r), finite_g = Halide::is_finite(g);
            Halide::Expr finite_b = Halide::is_finite(b), finite_a = Halide::is_finite(a);
            Halide::Expr peak = peak_of(px, py);
            Halide::Expr repaired = !finite_r || !finite_g || !finite_b || !finite_a;
            r = Halide::select(finite_r, r, 0.0f);
            g = Halide::select(finite_g, g, 0.0f);
            b = Halide::select(finite_b, b, 0.0f);
            a = Halide::select(finite_a, a, 1.0f);

            // The engine wants straight alpha. Only the division can reintroduce infinity, and
            // alpha cannot have changed, so its half of the re-check is provably a no-op and is
            // not repeated — which is the host's reasoning too.
            Halide::Expr divide = parameters_(FOTUFILM_DECODE_PREMULTIPLIED) != 0.0f
                && a > 0.0f && a != 1.0f;
            Halide::Expr scale = 1.0f / a;
            r = Halide::select(divide, r * scale, r);
            g = Halide::select(divide, g * scale, g);
            b = Halide::select(divide, b * scale, b);
            repaired = repaired || (divide && (!Halide::is_finite(r) || !Halide::is_finite(g)
                                               || !Halide::is_finite(b)));
            r = Halide::select(Halide::is_finite(r), r, 0.0f);
            g = Halide::select(Halide::is_finite(g), g, 0.0f);
            b = Halide::select(Halide::is_finite(b), b, 0.0f);

            r = host_transfer_decode(parameters_, r, approximate_);
            g = host_transfer_decode(parameters_, g, approximate_);
            b = host_transfer_decode(parameters_, b, approximate_);
            repaired = repaired || !Halide::is_finite(r) || !Halide::is_finite(g)
                || !Halide::is_finite(b);
            r = Halide::select(Halide::is_finite(r), r, 0.0f);
            g = Halide::select(Halide::is_finite(g), g, 0.0f);
            b = Halide::select(Halide::is_finite(b), b, 0.0f);

            auto m = [&](int index) { return parameters_(FOTUFILM_DECODE_MATRIX + index); };
            Halide::Expr sx = m(0) * r + m(1) * g + m(2) * b;
            Halide::Expr sy = m(3) * r + m(4) * g + m(5) * b;
            Halide::Expr sz = m(6) * r + m(7) * g + m(8) * b;
            repaired = repaired || !Halide::is_finite(sx) || !Halide::is_finite(sy)
                || !Halide::is_finite(sz);
            return Pixel{Halide::select(Halide::is_finite(sx), sx, 0.0f),
                         Halide::select(Halide::is_finite(sy), sy, 0.0f),
                         Halide::select(Halide::is_finite(sz), sz, 0.0f),
                         a, peak, repaired};
        };

        Func scene("decode_scene" + suffix);
        Pixel pixel = decode(x, y);
        scene(x, y, channel) = Halide::mux(channel, {pixel.r, pixel.g, pixel.b, pixel.a});
        scene.bound(channel, 0, 4).reorder(channel, x, y).unroll(channel);
        scene.output_buffer().dim(0).set_stride(4).dim(2).set_stride(1).set_bounds(0, 4);

        // Both lanes are a max from zero, and max is associative, commutative and idempotent, so
        // the row's scan can be cut into fixed chunks and folded afterwards for exactly the number
        // the whole row would have reached. That matters because the alternative — one thread per
        // row — leaves a single lane walking the row, and the repair lane pays the transfer curve
        // at every pixel of it. The last chunk reads its final pixel repeatedly rather than
        // reading past the row; a max cannot notice a value it has already seen.
        const int chunk = 64;
        Var span("decode_span" + suffix);
        RDom inside(0, chunk, "decode_inside" + suffix);
        Halide::Expr scan_x = Halide::min(span * chunk + inside, width_ - 1);

        Func chunk_peak("decode_chunk_peak" + suffix);
        chunk_peak(span, y) = Halide::maximum(peak_of(scan_x, y), "decode_peak" + suffix);

        Func chunk_repaired("decode_chunk_repaired" + suffix);
        chunk_repaired(span, y) = Halide::maximum(
            Halide::select(decode(scan_x, y).repaired, 1.0f, 0.0f), "decode_repaired" + suffix);

        Func report("decode_report" + suffix);
        RDom spans(0, (width_ + chunk - 1) / chunk, "decode_spans" + suffix);
        report(lane, y) = Halide::maximum(
            Halide::select(lane == 0, chunk_peak(spans, y), chunk_repaired(spans, y)),
            "decode_fold" + suffix);
        report.bound(lane, 0, 2);

        Var block("decode_block" + suffix), thread("decode_thread" + suffix);
        Var xo("decode_xo" + suffix), xi("decode_xi" + suffix);
        Var yo("decode_yo" + suffix), yi("decode_yi" + suffix);
        scene.compute_root().gpu_tile(x, y, xo, yo, xi, yi, 16, 16,
                                      Halide::TailStrategy::GuardWithIf, gpu_device_api());
        // A thread per chunk of a row, so the transfer curve is spread across the whole device
        // rather than down one lane per row.
        for (Func stage : {chunk_peak, chunk_repaired}) {
            stage.compute_root().gpu_tile(span, y, xo, yo, xi, yi, 16, 16,
                                          Halide::TailStrategy::GuardWithIf, gpu_device_api());
        }
        // One thread per row for the fold, as the measurements schedule theirs: the reduction is
        // along the row and the host combines the rows.
        report.compute_root()
            .reorder(lane, y)
            .gpu_tile(y, block, thread, 32, Halide::TailStrategy::GuardWithIf,
                      gpu_device_api());
        scene_ = scene;
        report_ = report;
        pipeline_ = Pipeline({scene_, report_});
#if !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
        pipeline_.compile_jit(gpu_target());
#endif
    }

#if defined(__APPLE__)
    /// Decodes `rows` rows of `width` host pixels into `output`, and writes two numbers per row
    /// into `report`. Either side may be a caller-owned MTLBuffer — a staged render has both
    /// already on the device — or host memory, which is what a striped render holds.
    void run_metal(uint64_t input_handle, const float *input_host,
                   uint64_t output_handle, float *output_host, float *report,
                   int32_t width, int32_t rows, const float *parameters) {
        std::lock_guard<std::mutex> lock(mutex_);
        const bool wrapped_in = input_handle != 0;
        const bool wrapped_out = output_handle != 0;
        const Target target = gpu_target();
        Buffer<float> input_buffer = Buffer<float>::make_interleaved(
            wrapped_in ? static_cast<float *>(nullptr) : const_cast<float *>(input_host),
            width, rows, 4);
        Buffer<float> output_buffer = Buffer<float>::make_interleaved(
            wrapped_out ? static_cast<float *>(nullptr) : output_host, width, rows, 4);
        if (wrapped_in) {
            if (input_buffer.device_wrap_native(DeviceAPI::Metal, input_handle, target) != 0) {
                throw Halide::RuntimeError("Unable to wrap caller MTLBuffer");
            }
            input_buffer.set_device_dirty();
        } else {
            input_buffer.set_host_dirty();
        }
        if (wrapped_out) {
            if (output_buffer.device_wrap_native(DeviceAPI::Metal, output_handle, target) != 0) {
                input_buffer.device_detach_native();
                throw Halide::RuntimeError("Unable to wrap caller MTLBuffer");
            }
        }
        try {
            Buffer<float> parameter_buffer(const_cast<float *>(parameters),
                                           FOTUFILM_DECODE_PARAMETER_COUNT);
            parameter_buffer.set_host_dirty();
            input_.set(input_buffer);
            parameters_.set(parameter_buffer);
            width_.set(width);
            Buffer<float> report_buffer(report, 2, rows);
            pipeline_.realize(Halide::Realization({output_buffer, report_buffer}), target);
            report_buffer.copy_to_host();
            if (!wrapped_out) output_buffer.copy_to_host();
        } catch (...) {
            if (wrapped_in) input_buffer.device_detach_native();
            if (wrapped_out) output_buffer.device_detach_native();
            throw;
        }
        if (wrapped_in) input_buffer.device_detach_native();
        if (wrapped_out) output_buffer.device_detach_native();
    }
#endif

#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    void compile_aot(const std::string &prefix, const std::string &function_name,
                     Target target) {
        target.set_feature(Target::NoRuntime);
        std::vector<Halide::Argument> arguments{input_, parameters_, width_};
        pipeline_.compile_to_static_library(prefix, arguments, function_name, target);
    }
#endif

private:
    const bool approximate_;
    ImageParam input_;
    ImageParam parameters_;
    Param<int32_t> width_;
    Func scene_;
    Func report_;
    Pipeline pipeline_;
    std::mutex mutex_;
};

class MetalFramePipeline : FrameParams {
public:
    MetalFramePipeline(int32_t feature_mask, const std::string &suffix,
                       bool windowed = false)
        : FrameParams("frame_", suffix),
          float_io_((feature_mask & FOTUFILM_FRAME_FLOAT_IO) != 0),
          realtime_(!float_io_
                    || (feature_mask & FOTUFILM_FRAME_REALTIME) != 0),
          approximate_((feature_mask & FOTUFILM_FRAME_EXACT_MATH) == 0),
          density_out_((feature_mask & FOTUFILM_FRAME_DENSITY_OUT) != 0),
          density_in_((feature_mask & FOTUFILM_FRAME_DENSITY_IN) != 0),
          measure_flare_((feature_mask & FOTUFILM_FRAME_FLARE_MEASURE) != 0),
          encode_out_((feature_mask & FOTUFILM_FRAME_ENCODE_OUT) != 0),
          no_film_((feature_mask & FOTUFILM_FRAME_NO_FILM) != 0),
          output_transfer_shape_(
              (feature_mask & FOTUFILM_FRAME_OUTPUT_LINEAR) ? 0
              : (feature_mask & FOTUFILM_FRAME_OUTPUT_POWER) ? 1
              : (feature_mask & FOTUFILM_FRAME_OUTPUT_LOG) ? 2 : -1),
          light_out_((feature_mask & FOTUFILM_FRAME_LIGHT_OUT) != 0),
          fields_in_((feature_mask & FOTUFILM_FRAME_FIELDS_IN) != 0),
          still_boost_(float_io_ && !realtime_ && approximate_),
          // Only the scene-referred schedules can carry it: the mode returns the caller's own
          // frame scaled, and an 8-bit display-encoded frame is not light to scale.
          texture_((feature_mask & FOTUFILM_FRAME_TEXTURE) != 0
                   && (feature_mask & FOTUFILM_FRAME_FLOAT_IO) != 0),
          // Byte-input density seams may use half storage. Float-input still, video, and OFX
          // boundaries stay full precision; NegativeInterchange density reaches 8, where
          // half-float spacing is already 2/8192.
          input_((feature_mask & FOTUFILM_FRAME_DENSITY_IN)
                     ? ((feature_mask & FOTUFILM_FRAME_FLOAT_IO) ? Float(32)
                                                                : Float(16))
                     : float_io_ ? Float(32) : UInt(8),
                 3, "frame_input" + suffix),
          configuration_(Float(32), 1, "frame_configuration" + suffix),
          exposure_lut_(fast(kStillFastHalfLut) && f16_lut_compute()
                            ? Float(16) : Float(32),
                        1, "frame_exposure_lut" + suffix),
          film_lut_(Float(32), 1, "frame_film_lut" + suffix),
          paper_lut_(Float(32), 1, "frame_paper_lut" + suffix),
          halation_radius_0_("frame_halation_radius_0" + suffix),
          halation_radius_1_("frame_halation_radius_1" + suffix),
          halation_radius_2_("frame_halation_radius_2" + suffix),
          runtime_features_("frame_features" + suffix) {
        WindowedFrameSchedule window_schedule(windowed);
        feature_mask &= ~ablated_features();
        const bool use_flare = feature_mask & FOTUFILM_FRAME_FLARE;
        const bool use_mtf = feature_mask & FOTUFILM_FRAME_MTF;
        const bool use_mtf_luma = feature_mask & FOTUFILM_FRAME_MTF_LUMA;
        const bool use_diffusion = feature_mask & FOTUFILM_FRAME_DIFFUSION;
        const bool use_halation = feature_mask & FOTUFILM_FRAME_HALATION;
        const bool use_annular = use_halation
            && (feature_mask & FOTUFILM_FRAME_HALATION_ANNULAR);
        const bool use_couplers = feature_mask & FOTUFILM_FRAME_COUPLERS;
        const bool use_donor = feature_mask & FOTUFILM_FRAME_DONOR_LAYER;
        const bool use_coupler_diffusion =
            feature_mask & FOTUFILM_FRAME_COUPLER_DIFFUSION;
        const bool use_adjacency = feature_mask & FOTUFILM_FRAME_ADJACENCY;
        const bool use_grain = feature_mask & FOTUFILM_FRAME_GRAIN;
        const bool use_discs = use_grain && !realtime_
            && (feature_mask & FOTUFILM_FRAME_DISC_GRAIN);
        const bool monochrome = feature_mask & FOTUFILM_FRAME_MONOCHROME;

        Var x("x"), y("y"), channel("channel");
        input_.dim(0).set_stride(4);
        input_.dim(2).set_stride(1);
        input_.dim(2).set_bounds(0, 4);
        const int lut_extent = lut_bound();
        exposure_lut_.dim(0).set_bounds(0, lut_extent);
        // Where the film and paper cubes live when they share the configuration's buffer. Both
        // offsets are unread unless `packed_luts_`, but naming them here keeps the layout in one
        // place — the browser shim builds the same buffer and has to agree.
        const int film_lut_base = FOTUFILM_FRAME_CONFIGURATION_COUNT;
        const int paper_lut_base = film_lut_base + lut_extent;
        if (packed_luts_) {
            // WebGPU allows a compute stage only a handful of storage buffers — eight by the
            // specification, ten on this Metal-backed adapter — and the combine kernel binds
            // eleven. The film and paper cubes are the two cheapest to fold away: unlike the
            // configuration they are constant for the length of a frame, so on WebGPU they ride
            // behind it in a single buffer and the kernel binds nine.
            //
            // Metal keeps them apart on purpose. There the configuration is rewritten on every
            // slider tick while the cubes are uploaded once and cached by `ensure_luts`; fusing
            // them would re-send 1.1 MB of tables per frame to save a binding Metal has to spare.
            configuration_.dim(0).set_bounds(0, paper_lut_base + lut_extent);
        } else {
            film_lut_.dim(0).set_bounds(0, lut_extent);
            paper_lut_.dim(0).set_bounds(0, lut_extent);
        }

        Func decoded("frame_decoded" + suffix);
        if (float_io_) {
            // The float contract is the working space itself, linear Rec.2020.
            decoded(x, y, channel) = input_(x, y, channel);
        } else {
            // Encoded bytes are transfer-encoded Display P3; decoding the transfer leaves
            // linear P3, and the matrix steps it into the Rec.2020 working space. The matrix
            // needs all three channels, so the per-channel transfer decode is spelled as a
            // lambda over the channel index.
            Expr alpha = Halide::cast<float>(input_(x, y, 3));
            Expr denominator = Halide::select(alpha > 0.0f && alpha < 255.0f, alpha, 255.0f);
            auto linear_p3 = [&](int channel_index) {
                Expr encoded = Halide::clamp(
                    Halide::cast<float>(input_(x, y, channel_index))
                    / denominator, 0.0f, 1.0f);
                return sample_transfer(srgb_decode_, encoded);
            };
            Expr p3_r = linear_p3(0), p3_g = linear_p3(1), p3_b = linear_p3(2);
            decoded(x, y, channel) = Halide::mux(channel, {
                kP3ToRec2020[0] * p3_r + kP3ToRec2020[1] * p3_g + kP3ToRec2020[2] * p3_b,
                kP3ToRec2020[3] * p3_r + kP3ToRec2020[4] * p3_g + kP3ToRec2020[5] * p3_b,
                kP3ToRec2020[6] * p3_r + kP3ToRec2020[7] * p3_g + kP3ToRec2020[8] * p3_b,
            });
        }

        const bool half_store = fast(kStillFastHalfStore);

        Func film_curves;
        // The reference CPU samples this same 2048-entry table. Evaluating the
        // analytic curve per pixel instead changes the model between backends.
        const bool tabulated_curves = gpu_device_api() == DeviceAPI::WebGPU
            || fast(kStillFastCurves);
        if (tabulated_curves) {
            film_curves = film_curve_table(
                configuration_, "frame_film_curves" + suffix, gpu_device_api(), approximate_);
        }
        auto film_curve = [&](Expr channel_index, Expr log_exposure) {
            return tabulated_curves
                ? sample_film_curve(configuration_, film_curves, log_exposure, channel_index)
                : film_density(configuration_, channel_index, log_exposure,
                               approximate_);
        };

        Func exposure("frame_spectral_exposure" + suffix);
        exposure(x, y, channel) = scene_exposure(
            configuration_, exposure_lut_,
            decoded(x, y, 0), decoded(x, y, 1), decoded(x, y, 2), channel,
            x + origin_x_, y + origin_y_, approximate_,
            fast(kStillFastHalfTetra) && f16_tetra_compute());

        // Spectral integration and linear spatial scattering commute. The kernels are fitted per
        // film record, so they operate on record exposure rather than on Rec.2020 primaries.
        const int exposure_channels = use_donor ? 4 : 3;
        Func light = exposure;
        if (use_diffusion) {
            Func base = store_frame(exposure, half_store, exposure_channels);
            Param<int32_t> *diffusion_strides[3] = {
                &diffusion_stride_0_, &diffusion_stride_1_, &diffusion_stride_2_};
            Param<int32_t> *diffusion_strided_radii[3] = {
                &diffusion_strided_radius_0_, &diffusion_strided_radius_1_,
                &diffusion_strided_radius_2_};
            Func previous = base;
            Expr previous_stride = 1;
            Expr previous_phase_x = 0, previous_phase_y = 0;
            Expr previous_width = width_, previous_height = height_;
            Expr scattered_at[3];
            for (int scale_index = 0; scale_index < 3; ++scale_index) {
                const std::string name = "frame_diffusion_"
                    + std::to_string(scale_index) + suffix;
                Expr stride = *diffusion_strides[scale_index];
                Expr phase_x = origin_x_ % stride;
                Expr phase_y = origin_y_ % stride;
                Expr down_width = (width_ + phase_x + stride - 1) / stride;
                Expr down_height = (height_ + phase_y + stride - 1) / stride;
                Expr factor = stride / previous_stride;
                Expr offset_x = (phase_x - previous_phase_x) / previous_stride;
                Expr offset_y = (phase_y - previous_phase_y) / previous_stride;
                Func bounded_source = constant_exterior(
                    previous, typed_zero(previous),
                    {{0, previous_width}, {0, previous_height}, {0, exposure_channels}});
                RDom cell(0, factor, 0, factor, name + "_cell");
                Func down(name + "_down");
                Expr source_x = x * factor - offset_x + cell.x;
                Expr source_y = y * factor - offset_y + cell.y;
                Expr valid = Halide::select(source_x >= 0 && source_x < previous_width
                                                && source_y >= 0
                                                && source_y < previous_height,
                                            1.0f, 0.0f);
                Expr cell_count = Halide::sum(valid, name + "_down_weight");
                down(x, y, channel) = Halide::sum(
                    bounded_source(x * factor - offset_x + cell.x,
                                   y * factor - offset_y + cell.y,
                                   channel), name + "_down_sum")
                    / Halide::max(cell_count, 1.0f);
                Func down_view = store_frame(down, half_store, exposure_channels);
                // The CPU averages each scale directly from the source. Reusing an
                // averaged grid changes rounding, even when the strides divide exactly.
                if (gpu_device_api() != DeviceAPI::WebGPU) {
                    previous = down_view;
                    previous_stride = stride;
                    previous_phase_x = phase_x;
                    previous_phase_y = phase_y;
                    previous_width = down_width;
                    previous_height = down_height;
                }
                Func blurred = gpu_triple_box_blur(
                    down_view, *diffusion_strided_radii[scale_index],
                    down_width, down_height, half_store, name + "_spread",
                    exposure_channels);
                Func bounded_blur = constant_exterior(
                    blurred, typed_zero(blurred),
                    {{0, down_width}, {0, down_height}, {0, exposure_channels}});
                Expr sample_x = (Halide::cast<float>(x + phase_x) + 0.5f)
                    / Halide::cast<float>(stride) - 0.5f;
                Expr sample_y = (Halide::cast<float>(y + phase_y) + 0.5f)
                    / Halide::cast<float>(stride) - 0.5f;
                Expr x0 = Halide::cast<int32_t>(Halide::floor(sample_x));
                Expr y0 = Halide::cast<int32_t>(Halide::floor(sample_y));
                Expr fx = sample_x - Halide::floor(sample_x);
                Expr fy = sample_y - Halide::floor(sample_y);
                Expr w00 = (1.0f - fx) * (1.0f - fy), w01 = (1.0f - fx) * fy;
                Expr w10 = fx * (1.0f - fy), w11 = fx * fy;
                auto valid_sample = [&](Expr sx, Expr sy) {
                    return Halide::select(sx >= 0 && sx < down_width
                                              && sy >= 0 && sy < down_height, 1.0f, 0.0f);
                };
                Expr sample_weight = w00 * valid_sample(x0, y0)
                    + w01 * valid_sample(x0, y0 + 1)
                    + w10 * valid_sample(x0 + 1, y0)
                    + w11 * valid_sample(x0 + 1, y0 + 1);
                scattered_at[scale_index] =
                    (w00 * bounded_blur(x0, y0, channel)
                     + w01 * bounded_blur(x0, y0 + 1, channel)
                     + w10 * bounded_blur(x0 + 1, y0, channel)
                     + w11 * bounded_blur(x0 + 1, y0 + 1, channel))
                    / Halide::max(sample_weight, 1.0e-12f);
            }
            Func diffused("frame_diffused" + suffix);
            diffused(x, y, channel) = diffusion_mix(
                configuration_, channel, base(x, y, channel),
                scattered_at[0], scattered_at[1], scattered_at[2]);
            light = store_frame(diffused, half_store, exposure_channels);
        }

        // The donor capture layer reads the spare fourth channel. Lens diffusion uses its own
        // sensitivity-centroid weights; later image-plane stages pass it by because it forms no
        // dye, while its developed activation joins the coupler release sum.
        Func donor_exposure("frame_donor_exposure" + suffix);
        if (use_donor) {
            if (use_diffusion) {
                donor_exposure(x, y, channel) = light(x, y, 3);
            } else {
                donor_exposure(x, y, channel) = scene_exposure(
                    configuration_, exposure_lut_,
                    decoded(x, y, 0), decoded(x, y, 1), decoded(x, y, 2), 3,
                    x + origin_x_, y + origin_y_, approximate_,
                    fast(kStillFastHalfTetra) && f16_tetra_compute());
            }
        }

        bool light_stored = false;
        const bool merged_luma = use_mtf && use_mtf_luma;
        const int light_channels = merged_luma ? 4 : 3;
        // The hand-written tile kernels stay realtime-only: their threadgroup design caps the
        // radius (kMaxRadius/kMaxMtfRadius in FotufilmMetalGrain.mm) at what a video frame's
        // px-per-mm can ask for, and a 48-100 MP still's enlargement factor sails past it. The
        // still path takes the radius-unbounded Halide blurs instead.
        //
        // FOTUFILM_FRAME_TEXTURE is held out for a different reason: the extern folds the veiling
        // glare into the MTF and takes both in half precision, where the flat development the
        // mode differences against applies the glare in Halide. The two would then disagree by
        // half's own rounding on every pixel — several parts in ten thousand of a mode whose
        // whole claim is that everything but the spatial stages cancels.
        const bool extern_mtf = realtime_ && !float_io_ && merged_luma && !texture_
            && metal_mtf_compute() && f16_blur_compute()
            && gpu_device_api() == Halide::DeviceAPI::Metal;
        Func light_packed;
        Func flare_mean;
        auto widen_with_luminance = [&](Func planes, const std::string &name) {
            Func wide(name);
            wide(x, y, channel) = Halide::select(
                channel == 3, record_neutral(planes, x, y),
                planes(x, y, Halide::min(channel, 2)));
            return wide;
        };
        if (use_flare) {
            Func exposure_view;
            if (extern_mtf) {
                StoredFrame stored = store_frame_packed(
                    widen_with_luminance(light,
                                         "frame_exposure_luma" + suffix),
                    light_channels);
                exposure_view = stored.view;
                light_packed = stored.packed;
            } else {
                exposure_view = store_frame(
                    merged_luma
                        ? widen_with_luminance(light,
                                               "frame_exposure_luma" + suffix)
                        : light,
                    half_store, light_channels);
            }
            light = exposure_view;
            light_stored = true;
            Func mean("frame_flare_mean" + suffix);
            Expr provided = merged_luma
                ? Halide::select(
                      channel == 3,
                      (configuration_(FOTUFILM_CONFIG_FLARE_MEAN)
                           + configuration_(FOTUFILM_CONFIG_FLARE_MEAN + 1)
                           + configuration_(FOTUFILM_CONFIG_FLARE_MEAN + 2)) / 3.0f,
                      configuration_(FOTUFILM_CONFIG_FLARE_MEAN + Halide::min(channel, 2)))
                : configuration_(FOTUFILM_CONFIG_FLARE_MEAN + channel);
            if (measure_flare_) {
                // The exposure this averages is the one the frame is about to be developed from,
                // already resident and already computed. The host's alternative is to run the
                // whole first stage a second time, on the CPU, over every pixel — which is the
                // single most expensive thing in a staged frame.
                //
                // Two levels, because a reduction straight to three numbers would run in one
                // thread: a row per thread first, then the rows totalled. Both halves sum float32
                // left to right, so this does not reproduce the host's per-row doubles.
                Var row_block("frame_flare_row_block" + suffix);
                Var row_thread("frame_flare_row_thread" + suffix);
                RDom across(0, width_, "frame_flare_across" + suffix);
                Func rows("frame_flare_rows" + suffix);
                rows(channel, y) = Halide::sum(
                    exposure_view(across, y, channel),
                    "frame_flare_row_sum" + suffix);
                rows.compute_root()
                    .bound(channel, 0, light_channels)
                    .reorder(channel, y)
                    .unroll(channel)
                    .gpu_tile(y, row_block, row_thread, 32,
                              Halide::TailStrategy::GuardWithIf, gpu_device_api());
                RDom down(0, height_, "frame_flare_down" + suffix);
                mean(channel) = Halide::sum(rows(channel, down),
                                            "frame_flare_total" + suffix)
                    / (Halide::cast<float>(width_) * Halide::cast<float>(height_));
            } else {
                // Veiling glare is global, so the host measures the complete frame before any crop
                // or strip is submitted. A crop-local estimate makes the same pixel develop
                // differently depending on how the caller tiles the frame.
                mean(channel) = provided;
            }
            mean.compute_root().bound(channel, 0, light_channels).unroll(channel)
                .gpu_single_thread(gpu_device_api());
            flare_mean = mean;
            Func flared("frame_flared" + suffix);
            flared(x, y, channel) = veiling_glare(
                configuration_, exposure_view(x, y, channel), mean(channel));
            light = flared;
        }

        // FOTUFILM_FRAME_TEXTURE branches after veiling glare and before spatial stages. Both the
        // spatial and flat developments read the same selected store; otherwise a storage
        // conversion can introduce a pointwise difference when no texture stages are selected.
        if (texture_ && !light_stored) {
            light = store_frame(
                merged_luma
                    ? widen_with_luminance(light,
                                           "frame_texture_light_luma" + suffix)
                    : light,
                half_store, light_channels);
            light_stored = true;
        }
        Func flat_light = light;

        if (use_mtf && extern_mtf) {
            if (!light_packed.defined()) {
                StoredFrame stored = store_frame_packed(
                    widen_with_luminance(light, "frame_light_luma" + suffix),
                    light_channels);
                light_packed = stored.packed;
            }
            if (!flare_mean.defined()) {
                Func zero_mean("frame_mtf_zero_mean" + suffix);
                zero_mean(channel) = 0.0f;
                zero_mean.compute_root().bound(channel, 0, 4).unroll(channel)
                    .gpu_single_thread(gpu_device_api());
                flare_mean = zero_mean;
            }
            Expr mtf_radius = Halide::max(
                mtf_radius_0_, Halide::max(mtf_radius_1_, mtf_radius_2_));
            Expr secondary_radius = mtf_luma_radius_;
            Expr extent = Halide::max(mtf_radius, mtf_luma_radius_);
            Var k("frame_mtf_ext_k" + suffix);
            Expr sigma = Halide::select(
                channel == 0, mtf_sigma_0_,
                channel == 1, mtf_sigma_1_,
                channel == 2, mtf_sigma_2_,
                channel == 3, mtf_luma_sigma_,
                channel == 4,
                    Halide::max(configuration_(FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA),
                                0.151f),
                channel == 5,
                    Halide::max(configuration_(FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA + 1),
                                0.151f),
                Halide::max(configuration_(FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA + 2),
                            0.151f));
            Expr denominator = 2.0f * sigma * sigma;
            RDom normalization_taps(-extent, extent * 2 + 1,
                                    "frame_mtf_ext_norm_taps" + suffix);
            Expr window = Halide::select(channel < 3, mtf_radius,
                                         channel == 3, mtf_luma_radius_,
                                         secondary_radius);
            Expr total = Halide::sum(
                Halide::select(
                    Halide::abs(normalization_taps.x) <= window,
                    Halide::exp(-Halide::cast<float>(normalization_taps.x
                                                     * normalization_taps.x)
                                / denominator),
                    0.0f),
                "frame_mtf_ext_norm_sum" + suffix);
            Func weights("frame_mtf_ext_weights" + suffix);
            weights(k, channel) = Halide::cast(
                Float(16),
                Halide::select(
                    Halide::abs(k) <= window,
                    Halide::exp(-Halide::cast<float>(k * k) / denominator)
                        / total,
                    0.0f));
            gpu_table(weights, k, channel, 7,
                      "frame_mtf_ext_weights" + suffix);
            Expr flare_amount = use_flare
                ? Expr(configuration_(FOTUFILM_CONFIG_FLARE))
                : Expr(0.0f);
            Func field("frame_mtf_field_ext" + suffix);
            std::vector<Halide::ExternFuncArgument> extern_args = {
                light_packed, flare_mean, weights,
                Expr(width_), Expr(height_), flare_amount,
                Expr(configuration_(FOTUFILM_CONFIG_MTF_LUMA_SHARE)),
                Expr(configuration_(FOTUFILM_CONFIG_MTF_PRIMARY_SHARE)),
                Expr(configuration_(FOTUFILM_CONFIG_MTF_PRIMARY_SHARE + 1)),
                Expr(configuration_(FOTUFILM_CONFIG_MTF_PRIMARY_SHARE + 2)),
                extent};
            field.define_extern("fotufilm_metal_mtf_field", extern_args,
                                Float(16), 3, Halide::NameMangling::C,
                                gpu_device_api());
            field.compute_root();
            Func widened("frame_mtf_separated" + suffix + "_widened");
            widened(x, y, channel) = Halide::cast<float>(field(x, y, channel));
            light = widened;
            light_stored = true;
        } else if (use_mtf) {
            if (!light_stored) {
                light = store_frame(
                    merged_luma
                        ? widen_with_luminance(light,
                                               "frame_light_luma" + suffix)
                        : light,
                    half_store, light_channels);
                light_stored = true;
            }
            Func pre_mtf = light;
            Expr mtf_radius = Halide::max(
                mtf_radius_0_, Halide::max(mtf_radius_1_, mtf_radius_2_));
            Func per_layer = gpu_gaussian(
                light, mtf_sigma_0_, mtf_sigma_1_, mtf_sigma_2_, mtf_radius,
                width_, height_, half_store, "frame_mtf" + suffix,
                light_channels, true,
                merged_luma ? Expr(mtf_luma_sigma_) : Expr(),
                merged_luma ? Expr(mtf_luma_radius_) : Expr());
            light = per_layer;
            light_stored = true;

            if (use_mtf_luma) {
                Func secondary = gpu_gaussian(
                    pre_mtf,
                    Halide::max(configuration_(FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA),
                                0.151f),
                    Halide::max(configuration_(FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA + 1),
                                0.151f),
                    Halide::max(configuration_(FOTUFILM_CONFIG_MTF_SECONDARY_SIGMA + 2),
                                0.151f),
                    mtf_luma_radius_, width_, height_, half_store,
                    "frame_mtf_secondary" + suffix, 3);
                Func mixed("frame_mtf_mixed" + suffix);
                Expr primary_share =
                    configuration_(FOTUFILM_CONFIG_MTF_PRIMARY_SHARE + channel);
                mixed(x, y, channel) = primary_share * per_layer(x, y, channel)
                    + (1.0f - primary_share) * secondary(x, y, channel);
                Func mixed_view = store_frame(mixed, half_store);
                Func separated("frame_mtf_separated" + suffix);
                Expr extended = mtf_luma_mix(
                    configuration_, mixed_view(x, y, channel),
                    record_neutral(mixed_view, x, y), per_layer(x, y, 3));
                separated(x, y, channel) = gpu_device_api() == DeviceAPI::WebGPU
                    ? Halide::select((runtime_features_ & FOTUFILM_FRAME_MTF_LUMA) != 0,
                                     extended, per_layer(x, y, channel))
                    : extended;
                light = store_frame(separated, half_store);
            }
            if (gpu_device_api() == DeviceAPI::WebGPU) {
                Func selected("frame_selected_mtf" + suffix);
                selected(x, y, channel) = Halide::select(
                    (runtime_features_ & FOTUFILM_FRAME_MTF) != 0,
                    light(x, y, channel), pre_mtf(x, y, channel));
                light = store_frame(selected, false);
            }
        }

        if (use_halation && fields_in_) {
            if (!light_stored) {
                light = store_frame(light, half_store);
                light_stored = true;
            }
            // The pyramid was built whole-frame by the fields pipeline from the light a
            // LIGHT_OUT pass wrote; its blurred grids ride behind the configuration. The
            // sampling below is the staged path's own bilinear over the same values at the same
            // absolute coordinates (a whole frame has origin zero and so phase zero), so the
            // delivered pixels match a staged develop's exactly — without the strip carrying
            // halation's reach in its apron.
            Param<int32_t> *strides[3] = {
                &halation_stride_0_, &halation_stride_1_, &halation_stride_2_};
            const int header_base = FOTUFILM_FRAME_CONFIGURATION_COUNT;
            const int data_base = header_base + 11;
            Expr config_last = configuration_.dim(0).extent() - 1;
            Expr grid_channel = Halide::min(channel, 2);
            Expr scattered_at[3];
            for (int scale_index = 0; scale_index < 3; ++scale_index) {
                Expr stride = *strides[scale_index];
                Expr grid_width = Halide::cast<int32_t>(
                    configuration_(header_base + 2 + scale_index * 3));
                Expr grid_height = Halide::cast<int32_t>(
                    configuration_(header_base + 3 + scale_index * 3));
                Expr grid_offset = Halide::cast<int32_t>(
                    configuration_(header_base + 4 + scale_index * 3));
                auto at = [&](Expr cx, Expr cy) {
                    Expr clamped_x = Halide::clamp(cx, 0, grid_width - 1);
                    Expr clamped_y = Halide::clamp(cy, 0, grid_height - 1);
                    Expr index = data_base + grid_offset
                        + (clamped_y * grid_width + clamped_x) * 3 + grid_channel;
                    return configuration_(Halide::clamp(index, 0, config_last));
                };
                Expr sample_x = (Halide::cast<float>(x + origin_x_) + 0.5f)
                    / Halide::cast<float>(stride) - 0.5f;
                Expr sample_y = (Halide::cast<float>(y + origin_y_) + 0.5f)
                    / Halide::cast<float>(stride) - 0.5f;
                Expr x0 = Halide::cast<int32_t>(Halide::floor(sample_x));
                Expr y0 = Halide::cast<int32_t>(Halide::floor(sample_y));
                Expr fx = sample_x - Halide::floor(sample_x);
                Expr fy = sample_y - Halide::floor(sample_y);
                Expr center =
                    (1.0f - fx) * ((1.0f - fy) * at(x0, y0)
                                   + fy * at(x0, y0 + 1))
                    + fx * ((1.0f - fy) * at(x0 + 1, y0)
                            + fy * at(x0 + 1, y0 + 1));
                scattered_at[scale_index] = use_annular
                    ? annular_sample(
                        at, sample_x, sample_y,
                        configuration_(FOTUFILM_CONFIG_HALATION_RING_RADIUS
                                       + scale_index)
                            / Halide::cast<float>(stride))
                    : center;
            }
            Func returned("frame_halation_returned" + suffix);
            returned(x, y, channel) = halation_returned(
                configuration_, channel, light(x, y, channel), scattered_at[0],
                scattered_at[1], scattered_at[2]);
            Func returned_view = store_frame(returned, half_store);
            Func halated("frame_halated" + suffix);
            halated(x, y, channel) = halation_mix(
                configuration_, channel, light(x, y, channel),
                [&](int source) { return returned_view(x, y, source); });
            light = halated;
            light_stored = false;
        } else if (use_halation) {
            if (!light_stored) {
                light = store_frame(light, half_store);
                light_stored = true;
            }
            Param<int32_t> *strides[3] = {
                &halation_stride_0_, &halation_stride_1_, &halation_stride_2_};
            Param<int32_t> *strided_radii[3] = {
                &halation_strided_radius_0_, &halation_strided_radius_1_,
                &halation_strided_radius_2_};
            Func previous = light;
            Expr previous_stride = 1;
            Expr previous_phase_x = 0, previous_phase_y = 0;
            Expr previous_width = width_, previous_height = height_;
            Expr scattered_at[3];
            for (int scale_index = 0; scale_index < 3; ++scale_index) {
                const std::string name = "frame_halation_"
                    + std::to_string(scale_index) + suffix;
                Expr stride = *strides[scale_index];
                Expr phase_x = origin_x_ % stride;
                Expr phase_y = origin_y_ % stride;
                Expr down_width = (width_ + phase_x + stride - 1) / stride;
                Expr down_height = (height_ + phase_y + stride - 1) / stride;
                Expr factor = stride / previous_stride;
                Expr offset_x = (phase_x - previous_phase_x) / previous_stride;
                Expr offset_y = (phase_y - previous_phase_y) / previous_stride;
                Func bounded_source = constant_exterior(
                    previous, typed_zero(previous),
                    {{0, previous_width}, {0, previous_height}, {0, 3}});
                RDom cell(0, factor, 0, factor, name + "_cell");
                Func down(name + "_down");
                Expr source_x = x * factor - offset_x + cell.x;
                Expr source_y = y * factor - offset_y + cell.y;
                Expr valid = Halide::select(source_x >= 0 && source_x < previous_width
                                                && source_y >= 0
                                                && source_y < previous_height,
                                            1.0f, 0.0f);
                Expr cell_count = Halide::sum(valid, name + "_down_weight");
                down(x, y, channel) = Halide::sum(
                    bounded_source(x * factor - offset_x + cell.x,
                                   y * factor - offset_y + cell.y,
                                   channel), name + "_down_sum")
                    / Halide::max(cell_count, 1.0f);
                Func down_view = store_frame(down, half_store);
                // The CPU averages each scale directly from the source. Reusing an
                // averaged grid changes rounding, even when the strides divide exactly.
                if (gpu_device_api() != DeviceAPI::WebGPU) {
                    previous = down_view;
                    previous_stride = stride;
                    previous_phase_x = phase_x;
                    previous_phase_y = phase_y;
                    previous_width = down_width;
                    previous_height = down_height;
                }
                Func blurred = gpu_triple_box_blur(
                    down_view, *strided_radii[scale_index],
                    down_width, down_height, half_store, name + "_spread");
                Func bounded_blur = constant_exterior(
                    blurred, typed_zero(blurred),
                    {{0, down_width}, {0, down_height}, {0, 3}});
                Expr sample_x = (Halide::cast<float>(x + phase_x) + 0.5f)
                    / Halide::cast<float>(stride) - 0.5f;
                Expr sample_y = (Halide::cast<float>(y + phase_y) + 0.5f)
                    / Halide::cast<float>(stride) - 0.5f;
                Expr x0 = Halide::cast<int32_t>(Halide::floor(sample_x));
                Expr y0 = Halide::cast<int32_t>(Halide::floor(sample_y));
                Expr fx = sample_x - Halide::floor(sample_x);
                Expr fy = sample_y - Halide::floor(sample_y);
                auto valid_sample = [&](Expr sx, Expr sy) {
                    return Halide::select(sx >= 0 && sx < down_width
                                              && sy >= 0 && sy < down_height, 1.0f, 0.0f);
                };
                auto at = [&](Expr sx, Expr sy) {
                    return bounded_blur(sx, sy, channel);
                };
                const bool separate_weights = gpu_device_api() == DeviceAPI::WebGPU;
                Expr center = bilinear_sample(at, sample_x, sample_y, separate_weights)
                    / Halide::max(bilinear_sample(valid_sample, sample_x, sample_y,
                                                  separate_weights), 1.0e-12f);
                if (use_annular) {
                    Expr ring_radius = configuration_(
                        FOTUFILM_CONFIG_HALATION_RING_RADIUS + scale_index)
                        / Halide::cast<float>(stride);
                    scattered_at[scale_index] = annular_sample(
                        at, sample_x, sample_y, ring_radius)
                        / Halide::max(annular_sample(
                            valid_sample, sample_x, sample_y, ring_radius), 1.0e-12f);
                } else {
                    scattered_at[scale_index] = center;
                }
            }
            Func returned("frame_halation_returned" + suffix);
            returned(x, y, channel) = halation_returned(
                configuration_, channel, light(x, y, channel), scattered_at[0],
                scattered_at[1], scattered_at[2]);
            Func returned_view = store_frame(returned, half_store);
            Func halated("frame_halated" + suffix);
            halated(x, y, channel) = halation_mix(
                configuration_, channel, light(x, y, channel),
                [&](int source) { return returned_view(x, y, source); });
            light = halated;
            light_stored = false;
        }

        Func log_exposure("frame_log_exposure" + suffix);
        log_exposure(x, y, channel) = fs_log10(
            Halide::max(light(x, y, channel), 1.0e-6f), approximate_);
        Func effective_log = log_exposure;
        Func donor_activation("frame_donor_activation" + suffix);
        Expr adjacency_residual = 0.0f;
        Func donor_released("frame_donor_released" + suffix);
        Func donor_pointwise = donor_released;
        Func donor_diffused = donor_pointwise;
        if (use_couplers || use_adjacency || use_donor) {
            Func log_view = store_frame(log_exposure, half_store);
            Func activation("frame_activation" + suffix);
            activation(x, y, channel) = film_activation(
                configuration_, channel, film_curve(channel, log_view(x, y, channel)));
            // Recomputing the activation per consumer is only cheap when the film curve is a
            // table; the analytic curve is worth a stored frame.
            Func activation_view = tabulated_curves
                ? activation : store_frame(activation, half_store);
            Func released("frame_released" + suffix);
            released(x, y, channel) = coupler_release(
                configuration_, channel, activation_view(x, y, channel));
            Func released_view = store_frame(released, half_store);
            Func coupler_diffused = released_view;
            Func fringe_diffused = released_view;
            Func adjacency_diffused = activation_view;
            // Release is nonlinear and happens before inhibitor diffusion. Adjacency still acts on
            // developed activation, so the two spatial stages deliberately no longer share a grid.
            if (use_coupler_diffusion && use_couplers) {
                coupler_diffused = gpu_gaussian_decimated(
                    released_view, coupler_sigma_, coupler_radius_,
                    origin_x_, origin_y_, width_, height_, half_store,
                    "frame_coupler_diffused" + suffix);
                // Conditional auxiliary fields do not satisfy the folded-window schedule's
                // monotone-access contract. The host routes those models to the general graph.
                if (!windowed) {
                    fringe_diffused = gpu_gaussian_decimated(
                        released_view, fringe_sigma_, fringe_radius_,
                        origin_x_, origin_y_, width_, height_, half_store,
                        "frame_fringe_diffused" + suffix);
                }
            }
            if (use_adjacency) {
                adjacency_diffused = gpu_gaussian_decimated(
                    activation_view, adjacency_sigma_, adjacency_radius_,
                    origin_x_, origin_y_, width_, height_, half_store,
                    "frame_adjacency_diffused" + suffix);
                Func secondary = adjacency_diffused;
                if (!windowed) {
                    secondary = gpu_gaussian_decimated(
                        activation_view,
                        adjacency_secondary_sigma_, adjacency_secondary_radius_,
                        origin_x_, origin_y_, width_, height_, half_store,
                        "frame_adjacency_secondary" + suffix);
                }
                adjacency_residual = activation_view(x, y, channel) - adjacency_transport(
                    configuration_, adjacency_diffused(x, y, channel), secondary(x, y, channel));
            }
            // The donor's development: its own curve on its own exposure, diffused with the
            // other inhibitors — the released species travels the same gelatin.
            if (use_donor) {
                Func donor_curves;
                if (tabulated_curves) {
                    donor_curves = curve_table(
                        configuration_, FOTUFILM_CONFIG_DONOR_CURVE, 6, 1,
                        "frame_donor_curve" + suffix, gpu_device_api(), approximate_);
                }
                Func donor_log("frame_donor_log" + suffix);
                donor_log(x, y, channel) = fs_log10(
                    Halide::max(donor_exposure(x, y, channel), 1.0e-6f),
                    approximate_);
                Func donor_log_view = store_frame(donor_log, half_store);
                Expr donor_formed = tabulated_curves
                    ? sample_curve(donor_curves,
                                   donor_log_view(x, y, channel), 0)
                    : curve_density(configuration_, FOTUFILM_CONFIG_DONOR_CURVE,
                                    donor_log_view(x, y, channel), approximate_);
                // Guarded exactly as the CPU schedule guards it: a stock with no donor
                // zeroes the whole block, and 0/0 would poison a release row that is
                // already zero.
                donor_activation(x, y, channel) =
                    (donor_formed - configuration_(FOTUFILM_CONFIG_DONOR_CURVE))
                    / Halide::max(
                        curve_range(configuration_, FOTUFILM_CONFIG_DONOR_CURVE),
                        1.0e-6f);
                Func donor_view = tabulated_curves
                    ? donor_activation
                    : store_frame(donor_activation, half_store);
                donor_released(x, y, channel) = donor_release(
                    configuration_, donor_view(x, y, channel));
                Func donor_released_view = store_frame(donor_released, half_store);
                donor_pointwise = donor_released_view;
                donor_diffused = donor_released_view;
                if (use_coupler_diffusion) {
                    donor_diffused = gpu_gaussian_decimated(
                        donor_released_view, coupler_sigma_, coupler_radius_,
                        origin_x_, origin_y_, width_, height_, half_store,
                        "frame_donor_diffused" + suffix);
                }
            }
            Func shifted("frame_inhibited" + suffix);
            Expr inhibited = log_view(x, y, channel);
            if (use_couplers || use_donor) {
                Expr inhibition = 0.0f;
                if (use_couplers) {
                    inhibition = coupler_inhibition(
                        configuration_, channel, coupler_diffused(x, y, 0),
                        coupler_diffused(x, y, 1), coupler_diffused(x, y, 2));
                    if (use_coupler_diffusion && !windowed) {
                        inhibition = fringe_inhibition(
                            configuration_, channel, inhibition, fringe_radius_,
                            fringe_diffused(x, y, 0) - coupler_diffused(x, y, 0),
                            fringe_diffused(x, y, 1) - coupler_diffused(x, y, 1),
                            fringe_diffused(x, y, 2) - coupler_diffused(x, y, 2));
                    }
                }
                if (use_donor) {
                    inhibition = inhibition
                        + donor_inhibition(configuration_, channel, donor_diffused(x, y, 0));
                }
                inhibited = inhibited_log_exposure(
                    configuration_, channel, log_view(x, y, channel), inhibition);
            }
            Expr shift = 0.0f;
            if (use_adjacency) shift = adjacency_shift(configuration_, adjacency_residual);
            shifted(x, y, channel) = inhibited - shift;
            effective_log = shifted;
        }

        Func density("frame_density" + suffix);
        if (density_in_) {
            Expr in_w = input_.dim(0).extent();
            Expr in_h = input_.dim(1).extent();
            Expr fx = (Halide::cast<float>(x) + 0.5f)
                * (Halide::cast<float>(in_w) / Halide::cast<float>(width_))
                - 0.5f;
            Expr fy = (Halide::cast<float>(y) + 0.5f)
                * (Halide::cast<float>(in_h) / Halide::cast<float>(height_))
                - 0.5f;
            Expr x0 = Halide::clamp(
                Halide::cast<int32_t>(Halide::floor(fx)), 0, in_w - 2);
            Expr y0 = Halide::clamp(
                Halide::cast<int32_t>(Halide::floor(fy)), 0, in_h - 2);
            Expr tx = Halide::clamp(fx - Halide::cast<float>(x0), 0.0f, 1.0f);
            Expr ty = Halide::clamp(fy - Halide::cast<float>(y0), 0.0f, 1.0f);
            Expr plane = Halide::min(channel, 2);
            Expr d00 = Halide::cast<float>(input_(x0, y0, plane));
            Expr d10 = Halide::cast<float>(input_(x0 + 1, y0, plane));
            Expr d01 = Halide::cast<float>(input_(x0, y0 + 1, plane));
            Expr d11 = Halide::cast<float>(input_(x0 + 1, y0 + 1, plane));
            Expr top = (1.0f - tx) * d00 + tx * d10;
            Expr bottom = (1.0f - tx) * d01 + tx * d11;
            density(x, y, channel) = (1.0f - ty) * top + ty * bottom;
        } else {
            Expr formed = film_curve(channel, effective_log(x, y, channel));
            if (use_adjacency) {
                formed = adjacency_density(configuration_, channel, formed, adjacency_residual);
            }
            density(x, y, channel) = developed_density(configuration_, channel, formed);
        }

        // The other development FOTUFILM_FRAME_TEXTURE differences against: the same curve, the
        // same couplers' own inhibition, and none of the spatial stages. Pointwise throughout, so
        // it costs a curve evaluation rather than a pass over the frame, and everything it shares
        // with the development above cancels when the two are subtracted.
        Func flat_density("frame_flat_density" + suffix);
        if (texture_) {
            Func flat_log("frame_flat_log_exposure" + suffix);
            flat_log(x, y, channel) = fs_log10(
                Halide::max(flat_light(x, y, channel), 1.0e-6f), approximate_);
            Func flat_effective = flat_log;
            if (use_couplers || use_donor) {
                Func flat_log_view = store_frame(flat_log, half_store);
                Func flat_shifted("frame_flat_inhibited" + suffix);
                Expr inhibition = 0.0f;
                if (use_couplers) {
                    Func flat_activation("frame_flat_activation" + suffix);
                    flat_activation(x, y, channel) = film_activation(
                        configuration_, channel,
                        film_curve(channel, flat_log_view(x, y, channel)));
                    Func flat_activation_view = realtime_
                        ? flat_activation : store_frame(flat_activation, half_store);
                    Func flat_released("frame_flat_released" + suffix);
                    flat_released(x, y, channel) = coupler_release(
                        configuration_, channel,
                        flat_activation_view(x, y, channel));
                    Func flat_released_view = store_frame(flat_released, half_store);
                    inhibition = coupler_inhibition(
                        configuration_, channel, flat_released_view(x, y, 0),
                        flat_released_view(x, y, 1), flat_released_view(x, y, 2));
                }
                // The donor is pointwise and pre-spatial, so its undiffused activation is its
                // own flat development — with no diffusion selected the two developments carry
                // the identical term and the donor cancels out of the texture.
                if (use_donor) {
                    inhibition = inhibition
                        + donor_inhibition(configuration_, channel, donor_pointwise(x, y, 0));
                }
                flat_shifted(x, y, channel) = inhibited_log_exposure(
                    configuration_, channel, flat_log_view(x, y, channel), inhibition);
                flat_effective = flat_shifted;
            }
            flat_density(x, y, channel) = developed_density(
                configuration_, channel, film_curve(channel, flat_effective(x, y, channel)));
        }

        // Resolved discs reuse density throughout the unrolled coverage calculation.
        // Materialize it once per pixel to keep sampled-curve searches out of that large
        // expression. Float32 storage preserves the previously inline density precision.
        if (use_discs) density = store_frame(density, false);
        Func developed = density;
        if (use_grain) {
            Func noise("frame_poisson_noise" + suffix);
            const int noise_channels = monochrome ? 1 : 3;
            const bool use_mottle = feature_mask & FOTUFILM_FRAME_GRAIN_MOTTLE;
            // The extern kernel draws and blurs one field in a single Metal dispatch, which is
            // what makes the realtime path fast. It has no second population, so the mixture asks
            // for the Halide-scheduled blur instead: two fields at two correlation lengths, which
            // is slower and is only ever reached when a stock or the user asks for the mottle.
            // The reference CPU draws from these inverse-CDF tables. The browser GPU must
            // use the same seeded samples, rather than a different analytic approximation.
            const bool table_grain = gpu_device_api() == DeviceAPI::WebGPU
                || fast(kStillFastGrainTable);
            // Realtime-only for the same radius-cap reason as the extern MTF above; a still that
            // draws from the tables still blurs through the Halide schedule.
            const bool extern_grain = realtime_ && !float_io_ && metal_grain_compute()
                && f16_blur_compute() && gpu_device_api() == DeviceAPI::Metal
                && !use_mottle;
            Func extern_field;
            if (!table_grain) {
                Expr shared_draw = monochrome
                    ? normal_sample(x + origin_x_, y + origin_y_, seed_,
                                    kGrainSharedLayer, approximate_)
                    : poisson_sample(x + origin_x_, y + origin_y_, seed_,
                                     grain_lambda_, kGrainSharedLayer,
                                     approximate_);
                noise(x, y, channel) = monochrome
                    ? shared_draw
                    : grain_mix(
                          configuration_,
                          poisson_sample(x + origin_x_, y + origin_y_, seed_,
                                         grain_lambda_, channel, approximate_),
                          shared_draw);
            } else {
                Func poisson_table = poisson_inverse_cdf(
                    grain_lambda_, "frame_poisson_cdf" + suffix, gpu_device_api());
                Func normal_table = normal_inverse_cdf(
                    "frame_normal_cdf" + suffix, gpu_device_api());
                if (extern_grain) {
                    Var k("frame_grain_ext_k" + suffix);
                    // Each layer's crystals have their own size, so each gets its own kernel in
                    // the weights table the kernel already indexes per channel. The radius is
                    // shared and sized for the coarsest layer; a finer layer simply carries taps
                    // that fall to zero, and the normalisation below is taken per channel, so a
                    // wider-than-needed window costs arithmetic and changes nothing.
                    Expr sigma = Halide::select(
                        channel == 0,
                        configuration_(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER),
                        channel == 1,
                        configuration_(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 1),
                        configuration_(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 2));
                    Expr denominator = 2.0f * sigma * sigma;
                    RDom normalization_taps(-grain_radius_,
                                            grain_radius_ * 2 + 1,
                                            "frame_grain_ext_norm_taps" + suffix);
                    Func weights("frame_grain_ext_weights" + suffix);
                    Expr total = Halide::sum(
                        Halide::exp(-Halide::cast<float>(normalization_taps.x
                                                         * normalization_taps.x)
                                    / denominator),
                        "frame_grain_ext_norm_sum" + suffix);
                    weights(k, channel) = Halide::cast(
                        Float(16),
                        Halide::exp(-Halide::cast<float>(k * k) / denominator)
                            / total);
                    gpu_table(weights, k, channel, noise_channels,
                              "frame_grain_ext_weights" + suffix);
                    Func field("frame_grain_field_ext" + suffix);
                    std::vector<Halide::ExternFuncArgument> extern_args = {
                        poisson_table, normal_table, weights,
                        Expr(width_), Expr(height_), Expr(seed_),
                        Expr(grain_lambda_),
                        Halide::clamp(
                            configuration_(FOTUFILM_CONFIG_GRAIN_CORRELATION),
                            0.0f, 1.0f),
                        Expr(grain_radius_), Expr(origin_x_), Expr(origin_y_)};
                    field.define_extern("fotufilm_metal_grain_field",
                                        extern_args, Float(16), 3,
                                        Halide::NameMangling::C,
                                        gpu_device_api());
                    field.compute_root();
                    Func widened("frame_grain_field" + suffix + "_widened");
                    widened(x, y, channel) =
                        Halide::cast<float>(field(x, y, channel));
                    extern_field = widened;
                } else {
                    Expr shared_draw = monochrome
                        ? normal_sample_lut(
                              normal_table, x + origin_x_, y + origin_y_, seed_,
                              kGrainSharedLayer)
                        : poisson_sample_lut(
                              poisson_table, normal_table, x + origin_x_,
                              y + origin_y_, seed_, grain_lambda_,
                              kGrainSharedLayer);
                    noise(x, y, channel) = monochrome
                        ? shared_draw
                        : grain_mix(
                              configuration_,
                              poisson_sample_lut(poisson_table, normal_table,
                                                 x + origin_x_, y + origin_y_,
                                                 seed_, grain_lambda_, channel),
                              shared_draw);
                }
            }
            Func noise_view = extern_field.defined()
                ? extern_field : store_frame(noise, half_store, noise_channels);
            Func grain_field = extern_field.defined()
                ? extern_field
                : gpu_gaussian(
                      noise_view,
                      configuration_(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER),
                      configuration_(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 1),
                      configuration_(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 2),
                      grain_radius_, width_, height_, half_store,
                      "frame_grain_field" + suffix, noise_channels);
            // The mixture's coarse crystal population: an independent Poisson field on its own
            // hash streams, blurred at its own correlation length, carrying its share of the
            // published granularity under the same density modulation as the fine field.
            Func mottle_field;
            if (use_mottle) {
                Func mottle_noise("frame_mottle_noise" + suffix);
                if (!table_grain) {
                    Expr shared_draw = monochrome
                        ? normal_sample(
                              x + origin_x_, y + origin_y_, seed_,
                              kGrainMottleSharedLayer, approximate_)
                        : poisson_sample(
                              x + origin_x_, y + origin_y_, seed_,
                              mottle_lambda_, kGrainMottleSharedLayer,
                              approximate_);
                    mottle_noise(x, y, channel) = monochrome
                        ? shared_draw
                        : grain_mix(
                              configuration_,
                              poisson_sample(x + origin_x_, y + origin_y_,
                                             seed_, mottle_lambda_,
                                             channel + kGrainMottleLayerBase,
                                             approximate_),
                              shared_draw);
                } else {
                    Func mottle_table = poisson_inverse_cdf(
                        mottle_lambda_, "frame_mottle_cdf" + suffix,
                        gpu_device_api());
                    Func mottle_normal = normal_inverse_cdf(
                        "frame_mottle_normal_cdf" + suffix, gpu_device_api());
                    Expr shared_draw = monochrome
                        ? normal_sample_lut(
                              mottle_normal, x + origin_x_, y + origin_y_, seed_,
                              kGrainMottleSharedLayer)
                        : poisson_sample_lut(
                              mottle_table, mottle_normal, x + origin_x_,
                              y + origin_y_, seed_, mottle_lambda_,
                              kGrainMottleSharedLayer);
                    mottle_noise(x, y, channel) = monochrome
                        ? shared_draw
                        : grain_mix(
                              configuration_,
                              poisson_sample_lut(mottle_table, mottle_normal,
                                                 x + origin_x_, y + origin_y_,
                                                 seed_, mottle_lambda_,
                                                 channel + kGrainMottleLayerBase),
                              shared_draw);
                }
                mottle_field = gpu_gaussian(
                    store_frame(mottle_noise, half_store, noise_channels),
                    configuration_(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER),
                    configuration_(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER + 1),
                    configuration_(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER + 2),
                    mottle_radius_, width_, height_, half_store,
                    "frame_mottle_field" + suffix, noise_channels);
            }

            Func grained("frame_grained_density" + suffix);
            DensityPosition position = density_position(
                configuration_, channel, density(x, y, channel));
            Expr layer = monochrome ? Expr(0) : Expr(channel);
            Expr modulation = grain_density_modulation(configuration_, channel, position.net);
            Expr clump = clump_grain(
                configuration_, channel, modulation, grain_field(x, y, layer),
                use_mottle ? mottle_field(x, y, layer) : Expr());
            Expr disc, crystal;
            if (use_discs) {
                disc = disc_grain(configuration_, density, position.net,
                                  x, y, channel, origin_x_, origin_y_, seed_);
                // The crystal population, as in the CPU schedule: one stored count field per
                // size bin, blurred to its cloud within the radius sized for the coarsest.
                // Counts are stored in full precision — a pixel can hold hundreds.
                std::vector<Func> fields;
                for (int bin = 0; bin < FOTUFILM_CRYSTAL_GRAIN_BINS; ++bin) {
                    const std::string tag = std::to_string(bin) + suffix;
                    Func counts("frame_crystal_counts_" + tag);
                    counts(x, y, channel) = crystal_latent_count(
                        configuration_, x + origin_x_, y + origin_y_, seed_, channel, bin,
                        crystal_lambda(configuration_, channel, bin, position.amount), approximate_);
                    Func counts_view = store_frame(counts, half_store, 3);
                    fields.push_back(gpu_gaussian(
                        counts_view,
                        crystal_bin_field(configuration_, 0, bin, 0),
                        crystal_bin_field(configuration_, 1, bin, 0),
                        crystal_bin_field(configuration_, 2, bin, 0),
                        grain_radius_, width_, height_, half_store,
                        "frame_crystal_field_" + tag, 3));
                }
                crystal = crystal_grain(configuration_, channel, fields, x, y);
            }
            grained(x, y, channel) = selected_developed_density(
                Halide::cast<int32_t>(configuration_(FOTUFILM_CONFIG_GRAIN_MODE) + 0.5f),
                density(x, y, channel), clump, disc, crystal);
            developed = grained;
        }

        if (feature_mask & FOTUFILM_FRAME_PRINT_MTF) {
            if (gpu_device_api() == DeviceAPI::WebGPU) {
                // The runtime bypass also reads this field. Store it once so that selecting
                // the print stage does not pull the entire grain graph into the print pass.
                developed = store_frame(developed, false, 3);
            }
            // The enlarger lens and the paper's own scattering, in the transmittance the negative
            // actually passes rather than in its density. Placed after grain and before anything
            // reads the negative, which is where an enlarger sits.
            Func transmittance("frame_print_mtf_transmittance" + suffix);
            transmittance(x, y, channel) = transmittance_of(
                developed(x, y, channel), approximate_);
            Func spread = gpu_gaussian(
                store_frame(transmittance, half_store, 3),
                configuration_(FOTUFILM_CONFIG_PRINT_MTF_SIGMA),
                configuration_(FOTUFILM_CONFIG_PRINT_MTF_SIGMA),
                configuration_(FOTUFILM_CONFIG_PRINT_MTF_SIGMA),
                print_mtf_radius_, width_, height_, half_store,
                "frame_print_mtf" + suffix, 3);
            Func printed("frame_printed_density" + suffix);
            Expr printed_density = density_of(
                print_mtf_read(configuration_, transmittance(x, y, channel),
                               spread(x, y, channel)),
                approximate_);
            // The browser shares one graph across stocks. A zero-radius filter still makes
            // a rounded density/transmittance round trip, so honor the actual stage mask.
            printed(x, y, channel) = gpu_device_api() == DeviceAPI::WebGPU
                ? Halide::select((runtime_features_ & FOTUFILM_FRAME_PRINT_MTF) != 0,
                                 printed_density, developed(x, y, channel))
                : printed_density;
            developed = printed;
            if (texture_) {
                // The flat development takes the same path through transmittance and back, minus
                // the blur that is the spatial part of it. Two reasons, and the second is the one
                // that matters: the difference is then exactly the enlarger's spread, and where
                // the enlarger was not asked for at all — its radius zero, the stage present only
                // because the variant that covers this request carries it — the two sides take
                // the identical pointwise round trip and cancel to the bit.
                Func flat_transmittance("frame_flat_print_mtf_transmittance" + suffix);
                flat_transmittance(x, y, channel) = transmittance_of(
                    flat_density(x, y, channel), approximate_);
                // Through the same selected store the spatial side's transmittance uses, so a flat
                // development cannot differ merely because only one side crossed a storage seam.
                Func flat_stored = store_frame(flat_transmittance, half_store, 3);
                Func flat_printed("frame_flat_printed_density" + suffix);
                Expr flat_printed_density = density_of(
                    flat_stored(x, y, channel), approximate_);
                flat_printed(x, y, channel) = gpu_device_api() == DeviceAPI::WebGPU
                    ? Halide::select((runtime_features_ & FOTUFILM_FRAME_PRINT_MTF) != 0,
                                     flat_printed_density, flat_density(x, y, channel))
                    : flat_printed_density;
                flat_density = flat_printed;
            }
        }

        // Keep the film LUT, paper curve, and paper LUT separate. Folding the paper curve into the
        // 33-node cube caused 1.37 codes of contouring; separate stages measured 0.003 codes in
        // DenseRampTests. The 2048-sample curve table avoids per-pixel transcendental functions.
        Expr ar = film_activation(configuration_, 0, developed(x, y, 0));
        Expr ag = film_activation(configuration_, 1, developed(x, y, 1));
        Expr ab = film_activation(configuration_, 2, developed(x, y, 2));

        // Half tetrahedral arithmetic is confined to the byte-input realtime schedule. Float
        // paths keep the preservation contract even when they select other realtime techniques.
        const bool half_tetra =
            fast(kStillFastHalfTetra) && f16_tetra_compute();
        // Cache each channel's relative log paper exposure for the paper and reversal branches.
        auto relative = [&](Expr channel_index) {
            return packed_luts_
                ? lut_sample_at(configuration_, film_lut_base, ar, ag, ab,
                                channel_index, half_tetra)
                : lut_sample(film_lut_, ar, ag, ab, channel_index, half_tetra);
        };

        Func paper_curve = paper_curve_table(
            configuration_, "frame_paper_curve" + suffix, gpu_device_api(), approximate_);
        auto on_paper = [&](int record) {
            Expr activation = paper_activation(configuration_, paper_curve, record,
                                               relative(record));
            if (feature_mask & FOTUFILM_FRAME_DISC_GRAIN) {
                // The crystal grain model's print stage, as `PrintPipeline` lays it: the
                // paper's own crystals developed where the negative's light fell, on the
                // frame's seed and this tile's origin.
                activation = activation + paper_grain_expr(
                    configuration_, record,
                    pixel_hash(x + origin_x_, y + origin_y_, seed_,
                               kCrystalPaperStreamBase + (monochrome ? 0 : record)),
                    activation, approximate_);
            }
            return activation;
        };
        Expr paper_x = on_paper(0);
        Expr paper_y = on_paper(1);
        Expr paper_z = on_paper(2);

        auto printed = [&](Expr channel_index) {
            Expr through_paper = packed_luts_
                ? lut_sample_at(configuration_, paper_lut_base, paper_x, paper_y,
                                paper_z, channel_index, half_tetra)
                : lut_sample(paper_lut_, paper_x, paper_y, paper_z,
                             channel_index, half_tetra);
            return Halide::select(reversal_ != 0, relative(channel_index),
                                  through_paper);
        };

        Func display_linear("frame_display_linear" + suffix);
        if (no_film_) {
            // Nothing above this line is read. The spectral recovery, the characteristic curves,
            // the couplers, the grain and both cubes all fall out of the pipeline the way the
            // texture span drops the paper — they are built here and then reached by nothing,
            // which is how Halide is told a stage does not run.
            CreativeScene scene = creative_exposure(
                configuration_, decoded(x, y, 0), decoded(x, y, 1),
                decoded(x, y, 2), x + origin_x_, y + origin_y_, approximate_);
            // Monochrome with no film can only mean the luminance of the light: the film path
            // averages three emulsion records, and here there are none. Taken in the working
            // primaries luminance is defined in, and then carried through the same matrix and
            // grade as any other neutral — whose rows sum to one, so a grey stays that grey.
            Expr neutral = kLumaR * scene.r + kLumaG * scene.g + kLumaB * scene.b;
            CreativeScene delivered = monochrome
                ? CreativeScene{neutral, neutral, neutral} : scene;
            display_linear(x, y, channel) =
                plain_print(configuration_, delivered, channel);
        } else {
            Expr composed = monochrome
                ? (printed(0) + printed(1) + printed(2)) / 3.0f
                : printed(channel);
            display_linear(x, y, channel) =
                color_grade(configuration_, channel, composed);
        }

        Func final_linear = display_linear;
        if (texture_) {
            // What the two developments differ by, carried back onto the caller's own frame as
            // the transmittance a negative of that density difference has. The sign is the
            // system's polarity: a denser patch of a negative prints lighter, where a reversal
            // stock's direct positive *is* the image and a denser patch is darker.
            //
            // The print's contrast is deliberately not applied. It is the paper's curve — colour
            // — and this mode has none, so the character arrives at the negative's own amplitude.
            // Nothing above this line beyond `developed` is read: the film cube, the paper curve
            // and the paper cube all fall out of the pipeline with `display_linear`.
            Func textured("frame_texture" + suffix);
            textured(x, y, channel) = texture_carry(
                decoded(x, y, channel), developed(x, y, channel),
                flat_density(x, y, channel), reversal_);
            final_linear = textured;
        }

        // Host delivery mixes all three channels. Materialize the float film result once so
        // the matrix and gamut fit do not inline the film/print calculation into every channel.
        // This is a float32 storage boundary, with no quantization or change to the film model.
        if (float_io_ && encode_out_) {
            gpu_pointwise(final_linear, x, y, channel, 3);
        }

        Func output("frame_output" + suffix);
        Expr safe_channel = Halide::min(channel, 2);
        if (density_out_) {
            output(x, y, channel) = Halide::cast(
                float_io_ ? Float(32) : Float(16),
                Halide::select(channel == 3,
                               Halide::cast<float>(input_(x, y, 3)),
                               developed(x, y, safe_channel)));
        } else if (float_io_ && light_out_) {
            // The post-MTF light, in the float preservation format the schedule itself uses, for
            // the fields pipeline to build the halation pyramid from. The
            // variant compiles no stage past this point, so everything below prices at nothing.
            output(x, y, channel) = Halide::cast(
                Float(32),
                Halide::select(channel == 3, 1.0f,
                               light(x, y, safe_channel)));
        } else if (float_io_ && encode_out_) {
            // Apply the host output basis, shoulder, transfer, and premultiplication in the
            // kernel. The mux lets `gpu_pointwise` unroll three channel transfers instead of
            // evaluating twelve.
            // Clamp print output before the matrix, matching the host path. Texture output remains
            // scene light and preserves negative wide-gamut components.
            auto delivered = [&](int index) {
                return texture_ ? final_linear(x, y, index)
                                : Halide::max(final_linear(x, y, index), 0.0f);
            };
            Expr r = delivered(0), g = delivered(1), b = delivered(2);
            Expr alpha = input_(x, y, 3);
            // The host re-premultiplies whenever alpha is not one — including at zero, where the
            // pixel it returns is black rather than left alone.
            Expr premultiply =
                configuration_(FOTUFILM_CONFIG_OUTPUT_PREMULTIPLIED) != 0.0f
                && alpha != 1.0f;
            auto encoded = [&](int row) {
                Expr value = host_output_encode(
                    configuration_, r, g, b, row, realtime_,
                    output_transfer_shape_);
                return Halide::select(premultiply, value * alpha, value);
            };
            output(x, y, channel) = Halide::mux(
                channel, {encoded(0), encoded(1), encoded(2), alpha});
        } else if (float_io_) {
            // The browser receives the same unencoded linear float result as PrintPipeline.
            // Preserve negative working-space components until its display conversion. Native
            // print delivery keeps its existing floor; texture always preserves scene light.
            Expr delivered = texture_ || gpu_device_api() == DeviceAPI::WebGPU
                ? final_linear(x, y, safe_channel)
                : Halide::max(final_linear(x, y, safe_channel), 0.0f);
            output(x, y, channel) = Halide::select(
                channel == 3, input_(x, y, 3), delivered);
        } else {
            Func srgb("frame_srgb" + suffix);
            Expr shoulder_knee = Halide::select(
                reversal_ != 0, 0.7f, 0.9f);
            Expr linear = Halide::clamp(
                display_shoulder(final_linear(x, y, channel), shoulder_knee),
                0.0f, 1.0f);
            srgb(x, y, channel) = sample_transfer(srgb_encode_, Halide::sqrt(linear));
            Expr dither = triangular_dither(
                x + origin_x_, y + origin_y_, safe_channel,
                Halide::cast<int32_t>(
                    configuration_(FOTUFILM_CONFIG_FRAME_WIDTH)), seed_);
            Expr alpha = density_in_
                ? Halide::cast<uint8_t>(Halide::clamp(
                      Halide::cast<float>(input_(
                          Halide::min(x, input_.dim(0).extent() - 1),
                          Halide::min(y, input_.dim(1).extent() - 1), 3)),
                      0.0f, 255.0f))
                : input_(x, y, 3);
            Expr coverage = Halide::cast<float>(alpha);
            Expr color = Halide::cast<uint8_t>(Halide::clamp(
                Halide::floor(srgb(x, y, safe_channel) * coverage + 0.5f + dither),
                0.0f, coverage));
            output(x, y, channel) = Halide::select(channel == 3, alpha, color);
        }
        output.output_buffer().dim(0).set_stride(4);
        output.output_buffer().dim(2).set_stride(1);
        output.output_buffer().dim(2).set_bounds(0, 4);
        if (windowed) {
            // The AOT shim checks the complete spatial reach before selecting this
            // graph. Global coordinates and the original boundary rules remain in
            // every expression; only when and where rows are stored changes.
            Var window, row, block_x, block_y, thread_x, thread_y;
            output.compute_root().bound(channel, 0, 4)
                .reorder(channel, x, y).unroll(channel)
                .split(y, window, row, kWindowRows, Halide::TailStrategy::GuardWithIf)
                .gpu_tile(x, row, block_x, block_y, thread_x, thread_y,
                          gpu_tile_x(), gpu_tile_y(),
                          Halide::TailStrategy::GuardWithIf, gpu_device_api());
            for (Func stage : window_schedule.stores) {
                stage.store_root().compute_at(output, window).fold_storage(y, kWindowStorageRows);
            }
        } else {
            gpu_pointwise(output, x, y, channel, 4);
        }
        // Specialize only full-frame graphs. Halide's folding pass does not rewrite
        // the folded-buffer reads consistently across both consumer specializations:
        // the gamut-enabled branch can address rows past the circular allocation.
        // Keep one consumer loop for windowed graphs; host_output_encode's uniform
        // configuration select still skips fitting when it is disabled.
        if (float_io_ && encode_out_ && !windowed) {
            output.specialize(configuration_(FOTUFILM_CONFIG_OUTPUT_GAMUT) == 0.0f);
        }
        pipeline_ = Pipeline(output);
#if !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
        if (!cached_.prepare(pipeline_,
            "frame:" + std::to_string(feature_mask) + ":" + std::to_string(windowed),
            {input_, configuration_, exposure_lut_, film_lut_, paper_lut_,
            width_, height_,
            mtf_sigma_0_, mtf_sigma_1_, mtf_sigma_2_, mtf_luma_sigma_,
            mtf_radius_0_, mtf_radius_1_, mtf_radius_2_, mtf_luma_radius_,
            halation_radius_0_, halation_radius_1_, halation_radius_2_,
            coupler_sigma_, coupler_radius_, adjacency_sigma_, adjacency_radius_,
            adjacency_secondary_sigma_, adjacency_secondary_radius_,
            fringe_sigma_, fringe_radius_,
            // The mottle pair is read by the `_mottle` twins alone; everywhere else they are
            // the same harmless unused parameters the diffusion strides already are, kept in
            // every signature so the shim's single FrameFunction shape holds.
            grain_sigma_, grain_radius_, grain_lambda_,
            mottle_lambda_, mottle_radius_, print_mtf_radius_,
            seed_, reversal_,
            origin_x_, origin_y_,
            halation_stride_0_, halation_stride_1_, halation_stride_2_,
            halation_strided_radius_0_, halation_strided_radius_1_,
            halation_strided_radius_2_,
            // Unconditionally, though only the variants whose mask carries
            // FOTUFILM_FRAME_DIFFUSION reference them: a scalar the pipeline never reads is a
            // harmless unused function parameter (the texture-flat variants already carry the
            // halation strides this way), and one shared argument list is what keeps every
            // variant callable through the shim's single FrameFunction shape.
            diffusion_stride_0_, diffusion_stride_1_, diffusion_stride_2_,
            diffusion_strided_radius_0_, diffusion_strided_radius_1_,
            diffusion_strided_radius_2_,}, gpu_target())) {
            pipeline_.compile_jit(gpu_target());
        }
#endif
    }

#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    /// The iOS device/simulator target this generator was originally written for.
    static Target ios_aot_target(bool simulator) {
        Target target;
        target.os = Target::IOS;
        target.arch = Target::ARM;
        target.bits = 64;
        target.set_feature(Target::Metal);
        if (simulator) target.set_feature(Target::Simulator);
        if (getenv("FOTUFILM_HALIDE_PROFILE")) target.set_feature(Target::Profile);
        return target;
    }

    /// macOS AOT target for hosts that link kernels instead of shipping the 30 MB Halide JIT.
    static Target macos_aot_target(bool intel) {
        Target target;
        target.os = Target::OSX;
        target.arch = intel ? Target::X86 : Target::ARM;
        target.bits = 64;
        target.set_feature(Target::Metal);
        return target;
    }

    /// The Android equivalent.
    static Target android_vulkan_aot_target() {
        Target target;
        target.os = Target::Android;
        target.arch = Target::ARM;
        target.bits = 64;
        target.set_feature(Target::Vulkan);
        target.set_feature(Target::VulkanV12);
        target.set_feature(Target::VulkanFloat16);
        target.set_feature(Target::VulkanInt8);
        target.set_feature(Target::VulkanInt16);
        target.set_feature(Target::VulkanInt64);
        return target;
    }

    void compile_ios_aot(const std::string &prefix, const std::string &function_name,
                         bool include_runtime, bool simulator) {
        compile_aot(prefix, function_name, include_runtime,
                    ios_aot_target(simulator));
    }

    void compile_aot(const std::string &prefix, const std::string &function_name,
                     bool include_runtime, Target target) {
        if (!include_runtime) target.set_feature(Target::NoRuntime);
        // A packed build reads the film and paper cubes out of the configuration, so they must not
        // appear here: an argument the pipeline never references is one Halide has no bounds for.
        std::vector<Halide::Argument> arguments = packed_luts_
            ? std::vector<Halide::Argument>{input_, configuration_, exposure_lut_}
            : std::vector<Halide::Argument>{input_, configuration_, exposure_lut_,
                                            film_lut_, paper_lut_};
        for (const Halide::Argument &scalar : std::vector<Halide::Argument>{
            width_, height_,
            mtf_sigma_0_, mtf_sigma_1_, mtf_sigma_2_, mtf_luma_sigma_,
            mtf_radius_0_, mtf_radius_1_, mtf_radius_2_, mtf_luma_radius_,
            halation_radius_0_, halation_radius_1_, halation_radius_2_,
            coupler_sigma_, coupler_radius_, adjacency_sigma_, adjacency_radius_,
            adjacency_secondary_sigma_, adjacency_secondary_radius_,
            fringe_sigma_, fringe_radius_,
            // The mottle pair is read by the `_mottle` twins alone; everywhere else they are
            // the same harmless unused parameters the diffusion strides already are, kept in
            // every signature so the shim's single FrameFunction shape holds.
            grain_sigma_, grain_radius_, grain_lambda_,
            mottle_lambda_, mottle_radius_, print_mtf_radius_,
            seed_, reversal_,
            origin_x_, origin_y_,
            halation_stride_0_, halation_stride_1_, halation_stride_2_,
            halation_strided_radius_0_, halation_strided_radius_1_,
            halation_strided_radius_2_,
            // Unconditionally, though only the variants whose mask carries
            // FOTUFILM_FRAME_DIFFUSION reference them: a scalar the pipeline never reads is a
            // harmless unused function parameter (the texture-flat variants already carry the
            // halation strides this way), and one shared argument list is what keeps every
            // variant callable through the shim's single FrameFunction shape.
            diffusion_stride_0_, diffusion_stride_1_, diffusion_stride_2_,
            diffusion_strided_radius_0_, diffusion_strided_radius_1_,
            diffusion_strided_radius_2_,
        }) {
            arguments.push_back(scalar);
        }
        if (gpu_device_api() == DeviceAPI::WebGPU) arguments.push_back(runtime_features_);
        pipeline_.compile_to_static_library(prefix, arguments, function_name, target);
    }
#endif

    void prepare_luts(const float *exposure, const float *film, const float *paper,
                      int32_t dimension, uint64_t cache_id) {
        std::lock_guard<std::mutex> lock(mutex_);
        ensure_luts(exposure, film, paper, dimension, cache_id);
    }

    template<typename Pixel>
    void run_host(const Pixel *input, Pixel *output,
                  int32_t width, int32_t height, const float *configuration,
                  const float *exposure, const float *film, const float *paper,
                  int32_t dimension, uint64_t cache_id, uint32_t seed,
                  int32_t reversal, int32_t origin_x = 0, int32_t origin_y = 0,
                  int32_t out_y = 0, int32_t out_rows = 0,
                  int32_t configuration_floats = FOTUFILM_FRAME_CONFIGURATION_COUNT) {
        std::lock_guard<std::mutex> lock(mutex_);
        ensure_luts(exposure, film, paper, dimension, cache_id);
        Buffer<Pixel> input_buffer = Buffer<Pixel>::make_interleaved(
            const_cast<Pixel *>(input), width, height, 4);
        // A cropped output (`out_rows` > 0) holds only the delivered rows; its y-min places them
        // inside the strip, so bounds inference computes each apron row through exactly the
        // stages a delivered pixel reads it from. Same expressions over the same coordinates —
        // the delivered pixels do not move. See the AOT shim's twin in FotufilmHalideIOS.cpp.
        const int32_t rows = out_rows > 0 ? out_rows : height;
        Buffer<Pixel> output_buffer = Buffer<Pixel>::make_interleaved(
            output, width, rows, 4);
        if (out_y != 0) output_buffer.translate(1, out_y);
        input_buffer.set_host_dirty();
        run(input_buffer, output_buffer, width, height, configuration, seed,
            reversal, origin_x, origin_y, configuration_floats);
        output_buffer.copy_to_host();
    }

    /// `run_host` for a LIGHT_OUT pipeline: float scene rows in, float light rows out.
    void run_host_light(const float *input, float *light_out,
                        int32_t width, int32_t height, const float *configuration,
                        const float *exposure, const float *film, const float *paper,
                        int32_t dimension, uint64_t cache_id, uint32_t seed,
                        int32_t reversal, int32_t origin_x, int32_t origin_y,
                        int32_t out_y, int32_t out_rows) {
        std::lock_guard<std::mutex> lock(mutex_);
        ensure_luts(exposure, film, paper, dimension, cache_id);
        Buffer<float> input_buffer = Buffer<float>::make_interleaved(
            const_cast<float *>(input), width, height, 4);
        const int32_t rows = out_rows > 0 ? out_rows : height;
        Buffer<float> output_buffer = Buffer<float>::make_interleaved(
            light_out, width, rows, 4);
        if (out_y != 0) output_buffer.translate(1, out_y);
        input_buffer.set_host_dirty();
        run(input_buffer, output_buffer, width, height, configuration, seed,
            reversal, origin_x, origin_y);
        output_buffer.copy_to_host();
    }

    template<typename PixelIn, typename PixelOut = PixelIn>
    /// Develops a frame the caller already holds on the device, in place of the host round trip
    /// `run_host` pays. The handles are whatever the backend's native buffer is — an MTLBuffer on
    /// Metal, a CUdeviceptr on CUDA — and the pipeline reads and writes them where they already
    /// are, so nothing crosses the bus.
    ///
    /// `input_width`/`input_height` size the input buffer when it differs from the frame — the
    /// hybrid tail reads the head's density at the head's own size and lifts it in-kernel.
    void run_wrapped(uint64_t input_handle, uint64_t output_handle,
                     int32_t width, int32_t height, const float *configuration,
                     const float *exposure, const float *film, const float *paper,
                     int32_t dimension, uint64_t cache_id, uint32_t seed,
                     int32_t reversal, int32_t origin_x = 0,
                     int32_t origin_y = 0, int32_t input_width = 0,
                     int32_t input_height = 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        ensure_luts(exposure, film, paper, dimension, cache_id);
        const int32_t in_width = input_width > 0 ? input_width : width;
        const int32_t in_height = input_height > 0 ? input_height : height;
        Buffer<PixelIn> input_buffer = Buffer<PixelIn>::make_interleaved(
            static_cast<PixelIn *>(nullptr), in_width, in_height, 4);
        Buffer<PixelOut> output_buffer = Buffer<PixelOut>::make_interleaved(
            static_cast<PixelOut *>(nullptr), width, height, 4);
        const Target target = gpu_target();
        const DeviceAPI api = gpu_device_api();
        if ((cached_
                ? input_buffer.get()->device_wrap_native(cached_.device_interface(), input_handle)
                : input_buffer.device_wrap_native(api, input_handle, target)) != 0 ||
            (cached_
                ? output_buffer.get()->device_wrap_native(cached_.device_interface(), output_handle)
                : output_buffer.device_wrap_native(api, output_handle, target)) != 0) {
            if (input_buffer.has_device_allocation()) input_buffer.device_detach_native();
            if (output_buffer.has_device_allocation()) output_buffer.device_detach_native();
            throw Halide::RuntimeError("Unable to wrap caller device buffer");
        }
        input_buffer.set_device_dirty();
        try {
            run(input_buffer, output_buffer, width, height, configuration, seed,
                reversal, origin_x, origin_y);
            output_buffer.device_sync();
        } catch (...) {
            input_buffer.device_detach_native();
            output_buffer.device_detach_native();
            throw;
        }
        input_buffer.device_detach_native();
        output_buffer.device_detach_native();
    }

private:
    void ensure_luts(const float *exposure, const float *film, const float *paper,
                     int32_t dimension, uint64_t cache_id) {
        if (dimension != kLutDimension) {
            throw Halide::RuntimeError("Fotufilm spectral LUT dimension must be 33");
        }
        if (lut_cache_id_ == cache_id && exposure_buffer_.defined()) return;
        if (exposure_lut_.type() == Float(16)) {
            // Float(16) and not halide_type_t(halide_type_float, 16): the runtime type converts
            // to both Buffer<> constructors on some Halide versions, and the language Type — the
            // same one the line above compares against — picks the intended one everywhere.
            exposure_buffer_ = Buffer<>(Float(16), kLutValueCount);
            uint16_t *half_values =
                reinterpret_cast<uint16_t *>(exposure_buffer_.data());
            for (int index = 0; index < kLutValueCount; ++index) {
                half_values[index] = fotufilm_float_to_half(exposure[index]);
            }
        } else {
            exposure_buffer_ = Buffer<float>(kLutValueCount);
            std::memcpy(exposure_buffer_.data(), exposure,
                        kLutValueCount * sizeof(float));
        }
        film_buffer_ = Buffer<float>(kLutValueCount);
        paper_buffer_ = Buffer<float>(kLutValueCount);
        std::memcpy(film_buffer_.data(), film, kLutValueCount * sizeof(float));
        std::memcpy(paper_buffer_.data(), paper, kLutValueCount * sizeof(float));
        exposure_buffer_.set_host_dirty();
        film_buffer_.set_host_dirty();
        paper_buffer_.set_host_dirty();
        const Target target = gpu_target();
        if (cached_) exposure_buffer_.get()->copy_to_device(cached_.device_interface());
        else exposure_buffer_.copy_to_device(gpu_device_api(), target);
        if (cached_) film_buffer_.get()->copy_to_device(cached_.device_interface());
        else film_buffer_.copy_to_device(gpu_device_api(), target);
        if (cached_) paper_buffer_.get()->copy_to_device(cached_.device_interface());
        else paper_buffer_.copy_to_device(gpu_device_api(), target);
        lut_cache_id_ = cache_id;
    }

    template<typename PixelIn, typename PixelOut>
    void run(Buffer<PixelIn> &input_buffer, Buffer<PixelOut> &output_buffer,
             int32_t width, int32_t height, const float *configuration,
             uint32_t seed, int32_t reversal, int32_t origin_x, int32_t origin_y,
             int32_t configuration_floats = FOTUFILM_FRAME_CONFIGURATION_COUNT) {
        Buffer<float> configuration_buffer(const_cast<float *>(configuration),
                                           configuration_floats);
        configuration_buffer.set_host_dirty();
        input_.set(input_buffer);
        configuration_.set(configuration_buffer);
        exposure_lut_.set(exposure_buffer_);
        film_lut_.set(film_buffer_);
        paper_lut_.set(paper_buffer_);
        set_frame(configuration, width, height, seed, reversal, origin_x, origin_y);
        halation_radius_0_.set(std::max(0, int(configuration[FOTUFILM_CONFIG_HALATION_RADIUS])));
        halation_radius_1_.set(std::max(0, int(configuration[FOTUFILM_CONFIG_HALATION_RADIUS + 1])));
        halation_radius_2_.set(std::max(0, int(configuration[FOTUFILM_CONFIG_HALATION_RADIUS + 2])));
        if (cached_) cached_.realize(output_buffer);
        else pipeline_.realize(output_buffer, gpu_target());
    }

    const bool float_io_;
    const bool realtime_;
    const bool approximate_;
    const bool density_out_;
    const bool density_in_;
    /// Whether this variant works the veiling-glare mean out from the frame it is given rather
    /// than reading the host's. Only whole-frame callers may set it — see FOTUFILM_FRAME_FLARE_MEASURE.
    const bool measure_flare_;
    const bool encode_out_;
    /// No film in the gate: the creative controls, the delivery basis and the grade, and nothing
    /// the emulsion would have done. See FOTUFILM_FRAME_NO_FILM.
    const bool no_film_;
    /// Compile-time transfer arm for realtime host output, or -1 for the reference kernel's
    /// coefficient-driven runtime choice.
    const int output_transfer_shape_;
    /// The two halves of the two-pass striped render: return the post-MTF light as float, and
    /// develop from provided whole-frame halation grids. See FOTUFILM_FRAME_LIGHT_OUT/FIELDS_IN.
    const bool light_out_;
    const bool fields_in_;
    /// Whether this is the approximate-math float still path — the only one that may adopt the
    /// realtime techniques named in `still_fast_bits()`. The exact-math still variants stay the
    /// untouched reference those adoptions are measured against.
    const bool still_boost_;
    /// Whether the frame is developed twice and returned as the difference — see
    /// FOTUFILM_FRAME_TEXTURE.
    const bool texture_;
    /// Whether this pipeline takes the realtime technique named by `bit` (see kStillFast*).
    bool fast(int32_t bit) const {
        const int32_t precision_bits = kStillFastHalfStore | kStillFastHalfLut
            | kStillFastHalfTetra;
        // Float I/O is the preservation path for deep video and stills. Realtime may still use
        // tabulated curves and grain, but it must not silently narrow source information.
        if (float_io_ && (bit & precision_bits)) return false;
        return realtime_ || (still_boost_ && (still_fast_bits() & bit) != 0);
    }
    /// Whether the film and paper cubes ride inside `configuration_` instead of taking storage
    /// buffers of their own. See the note at its initializer.
    const bool packed_luts_ = gpu_device_api() == DeviceAPI::WebGPU;
    Buffer<float> srgb_decode_ = srgb_decode_values();
    Buffer<float> srgb_encode_ = srgb_encode_values();
    ImageParam input_, configuration_, exposure_lut_, film_lut_, paper_lut_;
    Param<int32_t> halation_radius_0_, halation_radius_1_, halation_radius_2_;
    Param<int32_t> runtime_features_;
    Pipeline pipeline_;
    compiled_cache::Pipeline cached_;
    Buffer<> exposure_buffer_;
    Buffer<float> film_buffer_, paper_buffer_;
    uint64_t lut_cache_id_ = 0;
    std::mutex mutex_;
};

/// Builds the halation pyramid's three blurred grids from a whole frame of stored light — the
/// float numbers a LIGHT_OUT pass wrote — with the same decimation chain and triple-box arithmetic
/// the frame schedule runs over a staged frame at origin zero. A strip that then samples these
/// grids reads the very values a whole-frame develop reads from its own store, which is what
/// lets the FIELDS_IN path promise the staged path's pixels.
class MetalHalationFieldsPipeline {
public:
    explicit MetalHalationFieldsPipeline(const std::string &suffix)
        : input_(Float(32), 3, "fields_light" + suffix),
          width_("fields_width" + suffix), height_("fields_height" + suffix),
          stride_0_("fields_stride_0" + suffix),
          stride_1_("fields_stride_1" + suffix),
          stride_2_("fields_stride_2" + suffix),
          radius_0_("fields_radius_0" + suffix),
          radius_1_("fields_radius_1" + suffix),
          radius_2_("fields_radius_2" + suffix) {
        Var x("x"), y("y"), channel("channel");
        input_.dim(0).set_stride(4);
        input_.dim(2).set_stride(1);
        input_.dim(2).set_bounds(0, 4);
        // The still path's own storage precision: the grids must hold exactly what the staged
        // schedule's stores hold.
        const bool half = (still_fast_bits() & kStillFastHalfStore) != 0;
        Func source("fields_source" + suffix);
        source(x, y, channel) = Halide::cast<float>(input_(x, y, channel));
        Func previous = source;
        Expr previous_stride = 1;
        Expr previous_width = width_, previous_height = height_;
        Param<int32_t> *strides[3] = {&stride_0_, &stride_1_, &stride_2_};
        Param<int32_t> *radii[3] = {&radius_0_, &radius_1_, &radius_2_};
        std::vector<Func> outputs;
        for (int scale_index = 0; scale_index < 3; ++scale_index) {
            const std::string name = "fields_halation_"
                + std::to_string(scale_index) + suffix;
            Expr stride = *strides[scale_index];
            Expr down_width = (width_ + stride - 1) / stride;
            Expr down_height = (height_ + stride - 1) / stride;
            Expr factor = stride / previous_stride;
            Func bounded_source = constant_exterior(
                previous, typed_zero(previous),
                {{0, previous_width}, {0, previous_height}, {0, 3}});
            RDom cell(0, factor, 0, factor, name + "_cell");
            Func down(name + "_down");
            Expr source_x = x * factor + cell.x;
            Expr source_y = y * factor + cell.y;
            Expr valid = Halide::select(source_x >= 0 && source_x < previous_width
                                            && source_y >= 0
                                            && source_y < previous_height,
                                        1.0f, 0.0f);
            Expr cell_count = Halide::sum(valid, name + "_down_weight");
            down(x, y, channel) = Halide::sum(
                bounded_source(x * factor + cell.x, y * factor + cell.y,
                               channel), name + "_down_sum")
                / Halide::max(cell_count, 1.0f);
            Func down_view = store_frame(down, half);
            previous = down_view;
            previous_stride = stride;
            previous_width = down_width;
            previous_height = down_height;
            Func blurred = gpu_triple_box_blur(
                down_view, *radii[scale_index], down_width, down_height, half,
                name + "_spread");
            Func out("fields_grid_" + std::to_string(scale_index) + suffix);
            out(x, y, channel) = blurred(x, y, channel);
            out.output_buffer().dim(0).set_stride(3);
            out.output_buffer().dim(2).set_stride(1);
            out.output_buffer().dim(2).set_bounds(0, 3);
            gpu_pointwise(out, x, y, channel, 3);
            outputs.push_back(out);
        }
        pipeline_ = Pipeline(outputs);
#if !defined(FOTUFILM_HALIDE_AOT_GENERATOR)
        pipeline_.compile_jit(gpu_target());
#endif
    }

#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    void compile_aot(const std::string &prefix, const std::string &function_name,
                     Target target) {
        target.set_feature(Target::NoRuntime);
        std::vector<Halide::Argument> arguments{
            input_, width_, height_,
            stride_0_, stride_1_, stride_2_, radius_0_, radius_1_, radius_2_};
        pipeline_.compile_to_static_library(prefix, arguments, function_name,
                                            target);
    }
#endif

    /// Runs the build over host light rows into three host grids sized
    /// ceil(width/stride) x ceil(height/stride) x 3, interleaved.
    void run_host(const float *light, int32_t width, int32_t height,
                  const int32_t strides[3], const int32_t radii[3],
                  float *grid_0, float *grid_1, float *grid_2) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> input_buffer = Buffer<float>::make_interleaved(
            const_cast<float *>(light), width, height, 4);
        input_buffer.set_host_dirty();
        float *grids[3] = {grid_0, grid_1, grid_2};
        std::vector<Buffer<float>> outputs;
        for (int scale = 0; scale < 3; ++scale) {
            outputs.push_back(Buffer<float>::make_interleaved(
                grids[scale],
                (width + strides[scale] - 1) / strides[scale],
                (height + strides[scale] - 1) / strides[scale], 3));
        }
        input_.set(input_buffer);
        width_.set(width);
        height_.set(height);
        stride_0_.set(strides[0]);
        stride_1_.set(strides[1]);
        stride_2_.set(strides[2]);
        radius_0_.set(radii[0]);
        radius_1_.set(radii[1]);
        radius_2_.set(radii[2]);
        Halide::Realization realization(std::vector<Buffer<>>{
            Buffer<>(outputs[0]), Buffer<>(outputs[1]), Buffer<>(outputs[2])});
        pipeline_.realize(realization, gpu_target());
        for (auto &output : outputs) output.copy_to_host();
    }

private:
    ImageParam input_;
    Param<int32_t> width_, height_;
    Param<int32_t> stride_0_, stride_1_, stride_2_;
    Param<int32_t> radius_0_, radius_1_, radius_2_;
    Pipeline pipeline_;
    std::mutex mutex_;
};

MetalHalationFieldsPipeline *halation_fields_pipeline() {
    static std::unique_ptr<MetalHalationFieldsPipeline> pipeline;
    static std::mutex pipeline_mutex;
    std::lock_guard<std::mutex> lock(pipeline_mutex);
    if (!pipeline) {
        pipeline = std::make_unique<MetalHalationFieldsPipeline>(
            "_metal_fields");
    }
    return pipeline.get();
}

/// The measure pipelines, kept for the life of the process like the frame ones. There are four:
/// the two quantities, each with and without the fast transcendentals, which is the only bit of
/// the frame's feature mask a measurement is sensitive to.
MetalMeasurePipeline *measure_pipeline_for(MetalMeasurePipeline::Quantity quantity,
                                           bool approximate) {
    const int index = (quantity == MetalMeasurePipeline::Quantity::Flare ? 2 : 0)
        + (approximate ? 1 : 0);
    static std::unique_ptr<MetalMeasurePipeline> pipelines[4];
    static std::mutex pipelines_mutex;
    std::lock_guard<std::mutex> lock(pipelines_mutex);
    if (!pipelines[index]) {
        pipelines[index] = std::make_unique<MetalMeasurePipeline>(
            quantity, approximate, "_metal_measure_" + std::to_string(index));
    }
    return pipelines[index].get();
}

/// The colour space is coefficient-driven; only the realtime approximation selects a variant.
MetalDecodePipeline *decode_pipeline(bool approximate) {
    static std::unique_ptr<MetalDecodePipeline> pipelines[2];
    static std::mutex pipeline_mutex;
    std::lock_guard<std::mutex> lock(pipeline_mutex);
    const int index = approximate ? 1 : 0;
    if (!pipelines[index]) {
        pipelines[index] = std::make_unique<MetalDecodePipeline>(
            approximate, "_metal_decode_" + std::to_string(index));
    }
    return pipelines[index].get();
}

MetalFramePipeline *pipeline_for(int32_t feature_mask) {
    // The enlarger's blur joins the key: it is a stage the pipeline either has or has not, and a
    // GPU frame that skipped it would not match the reference the consistency tests hold it to.
    // Every bit the pipeline branches on has to appear here. A bit the key drops is a bit the
    // pipeline is built without, and the stage then compiles, links, runs and does nothing.
    constexpr int32_t variant_bits =
        FOTUFILM_AOT_VARIANT_BITS | ((FOTUFILM_FRAME_COUPLER_DIFFUSION << 1) - 1)
        | FOTUFILM_FRAME_PRINT_MTF | FOTUFILM_FRAME_GRAIN_MOTTLE
        | FOTUFILM_FRAME_TEXTURE | FOTUFILM_FRAME_DIFFUSION
        | FOTUFILM_FRAME_DONOR_LAYER | FOTUFILM_FRAME_NO_FILM;
    const int variant = feature_mask & variant_bits & ~FOTUFILM_FRAME_REVERSAL;
    // Keyed by the mask in a map rather than a mask-wide sparse array. The array version cost
    // "nothing but address space" — until FOTUFILM_FRAME_DONOR_LAYER pushed the mask past bit 26
    // and the zerofill grew beyond 2 GB, at which point parts of a statically linked binary's
    // data segment land further from its text than Swift's 32-bit *relative* metadata pointers
    // can reach, and every protocol-conformance scan in the host process is one SIGBUS away.
    // The lock was already here; the map adds one hash to a per-frame lookup.
    static std::unordered_map<int32_t, std::unique_ptr<MetalFramePipeline>> pipelines;
    static std::mutex pipelines_mutex;
    std::lock_guard<std::mutex> lock(pipelines_mutex);
    std::unique_ptr<MetalFramePipeline> &slot = pipelines[variant];
    if (!slot) {
        slot = std::make_unique<MetalFramePipeline>(
            variant, "_metal_variant_" + std::to_string(variant));
    }
    return slot.get();
}

template<typename Function>
int32_t translate_metal_exceptions(Function &&function) {
    try {
        function();
        return 0;
    } catch (const Halide::Error &error) {
        std::fprintf(stderr, "Fotufilm Halide Metal error: %s\n", error.what());
        return -1;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "Fotufilm Halide Metal error: %s\n", error.what());
        return -1;
    } catch (...) {
        std::fprintf(stderr, "Fotufilm Halide Metal error: unknown exception\n");
        return -2;
    }
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

}

extern "C" int32_t fotufilm_halide_metal_available(void) {
    return Halide::host_supports_target_device(gpu_target()) ? 1 : 0;
}

extern "C" int32_t fotufilm_halide_metal_variant_exists(int32_t) {
    // A JIT build compiles whatever mask it is handed, so there is no such thing here as a
    // feature the build does not carry.
    return 1;
}

extern "C" void fotufilm_halide_metal_report_profile(void) {}

extern "C" int32_t fotufilm_halide_metal_still_fast_bits(void) {
    return still_fast_bits();
}

extern "C" int32_t fotufilm_halide_metal_prepare(
    int32_t feature_mask, const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id) {
    if (!fotufilm_halide_metal_available() || !exposure_lut ||
        !film_output_lut || !paper_output_lut) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->prepare_luts(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_srgb8(
    const uint8_t *input, uint8_t *output, int32_t width, int32_t height,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id,
    int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || !input || !output || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->run_host(
            input, output, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_linear_float_rows(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || !input || !output || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        out_y < 0 || out_rows <= 0 || out_y + out_rows > height ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask | FOTUFILM_FRAME_FLOAT_IO)->run_host(
            input, output, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0,
            origin_x, origin_y, out_y, out_rows);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_linear_float(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (height <= 0) return -1;
    return fotufilm_halide_metal_process_linear_float_rows(
        input, output, width, height, 0, height, origin_x, origin_y,
        configuration, exposure_lut, film_output_lut, paper_output_lut,
        lut_dimension, spectral_cache_id, feature_mask, seed);
}

extern "C" int32_t fotufilm_halide_metal_process_light_rows(
    const float *input, float *light_out, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || !input || !light_out ||
        !configuration || !exposure_lut || !film_output_lut ||
        !paper_output_lut || width <= 0 || height <= 0 ||
        out_y < 0 || out_rows <= 0 || out_y + out_rows > height ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask | FOTUFILM_FRAME_FLOAT_IO
                     | FOTUFILM_FRAME_LIGHT_OUT)->run_host_light(
            input, light_out, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0,
            origin_x, origin_y, out_y, out_rows);
    });
}

extern "C" int32_t fotufilm_halide_metal_halation_fields_floats(
    int32_t width, int32_t height, const int32_t *halation_radii) {
    if (width <= 0 || height <= 0 || !halation_radii) return -1;
    int32_t total = 11;
    for (int scale = 0; scale < 3; ++scale) {
        const int32_t stride = fotufilm_halation_stride(
            std::max(0, halation_radii[scale]));
        total += ((width + stride - 1) / stride)
            * ((height + stride - 1) / stride) * 3;
    }
    return total;
}

extern "C" int32_t fotufilm_halide_metal_halation_fields(
    const float *light, int32_t width, int32_t height,
    const int32_t *halation_radii, float *fields, int32_t fields_floats) {
    if (!fotufilm_halide_metal_available() || !light || !halation_radii ||
        !fields || width <= 0 || height <= 0 ||
        fields_floats != fotufilm_halide_metal_halation_fields_floats(
            width, height, halation_radii)) return -1;
    return translate_metal_exceptions([&] {
        int32_t strides[3], strided[3];
        int32_t grid_floats[3];
        for (int scale = 0; scale < 3; ++scale) {
            const int32_t radius = std::max(0, halation_radii[scale]);
            strides[scale] = fotufilm_halation_stride(radius);
            strided[scale] = fotufilm_halation_strided_radius(
                radius, strides[scale]);
            grid_floats[scale] =
                ((width + strides[scale] - 1) / strides[scale])
                * ((height + strides[scale] - 1) / strides[scale]) * 3;
        }
        fields[0] = float(width);
        fields[1] = float(height);
        int32_t offset = 0;
        for (int scale = 0; scale < 3; ++scale) {
            fields[2 + scale * 3] =
                float((width + strides[scale] - 1) / strides[scale]);
            fields[3 + scale * 3] =
                float((height + strides[scale] - 1) / strides[scale]);
            fields[4 + scale * 3] = float(offset);
            offset += grid_floats[scale];
        }
        halation_fields_pipeline()->run_host(
            light, width, height, strides, strided,
            fields + 11,
            fields + 11 + grid_floats[0],
            fields + 11 + grid_floats[0] + grid_floats[1]);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_linear_float_fields_rows(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t out_y, int32_t out_rows, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *fields, int32_t fields_floats, uint64_t fields_id,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    (void)fields_id;
    if (!fotufilm_halide_metal_available() || !input || !output ||
        !configuration || !fields || fields_floats <= 11 ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        out_y < 0 || out_rows <= 0 || out_y + out_rows > height ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        std::vector<float> combined(
            FOTUFILM_FRAME_CONFIGURATION_COUNT + fields_floats);
        std::memcpy(combined.data(), configuration,
                    FOTUFILM_FRAME_CONFIGURATION_COUNT * sizeof(float));
        std::memcpy(combined.data() + FOTUFILM_FRAME_CONFIGURATION_COUNT,
                    fields, fields_floats * sizeof(float));
        pipeline_for(feature_mask | FOTUFILM_FRAME_FLOAT_IO
                     | FOTUFILM_FRAME_FIELDS_IN)->run_host(
            input, output, width, height, combined.data(),
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0,
            origin_x, origin_y, out_y, out_rows,
            int32_t(combined.size()));
    });
}

// Wrapping a caller's texture is Metal-only: the CUDA host talks to the pipeline through the
// host-buffer entry points below, where Halide owns the device allocation.
#if defined(__APPLE__)

extern "C" int32_t fotufilm_halide_metal_process_buffers(
    uint64_t input_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || input_mtl_buffer == 0 ||
        output_mtl_buffer == 0 || !configuration || !exposure_lut ||
        !film_output_lut || !paper_output_lut || width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->run_wrapped<uint8_t>(
            input_mtl_buffer, output_mtl_buffer, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0,
            origin_x, origin_y);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_float(
    uint64_t input_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || input_mtl_buffer == 0 ||
        output_mtl_buffer == 0 || !configuration || !exposure_lut ||
        !film_output_lut || !paper_output_lut || width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask | FOTUFILM_FRAME_FLOAT_IO)->run_wrapped<float>(
            input_mtl_buffer, output_mtl_buffer, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0,
            origin_x, origin_y);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_head(
    uint64_t input_mtl_buffer, uint64_t density_mtl_buffer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || input_mtl_buffer == 0 ||
        density_mtl_buffer == 0 || !configuration || !exposure_lut ||
        !film_output_lut || !paper_output_lut || width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        // Exactly FOTUFILM_AOT_HEAD, which is what the head variants were compiled
        // from: everything up to the cut, and nothing that belongs after it. The
        // enlarger belongs after it — it images a negative that already has grain
        // in it — so stripping it here is what keeps the split path's print the
        // same picture the unsplit path makes.
        const int32_t head_mask = (feature_mask
            & ~(FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_GRAIN_MOTTLE
                | FOTUFILM_FRAME_DISC_GRAIN | FOTUFILM_FRAME_PRINT_MTF))
            | FOTUFILM_FRAME_DENSITY_OUT;
        pipeline_for(head_mask)->run_wrapped<uint8_t, Halide::float16_t>(
            input_mtl_buffer, density_mtl_buffer, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0,
            origin_x, origin_y);
    });
}

extern "C" int32_t fotufilm_halide_metal_process_buffers_tail(
    uint64_t density_mtl_buffer, uint64_t output_mtl_buffer,
    int32_t width, int32_t height,
    int32_t density_width, int32_t density_height,
    int32_t origin_x, int32_t origin_y,
    const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_metal_available() || density_mtl_buffer == 0 ||
        output_mtl_buffer == 0 || !configuration || !exposure_lut ||
        !film_output_lut || !paper_output_lut || width <= 0 || height <= 0) return -1;
    return translate_metal_exceptions([&] {
        // The grain mixture rides the tail with the grain it belongs to: the host has
        // already split the published granularity's variance between the two fields, so a
        // tail that dropped the bit would render the quiet half of the mixture. Served by
        // the `_tail_mottle` twins.
        // Exactly FOTUFILM_AOT_TAIL: grain and the enlarger that images it, in that
        // order. Both the grain model and the mixture ride through, so the tail
        // lays the field the frame actually asked for.
        const int32_t tail_mask = (feature_mask
            & (FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_REVERSAL
               | FOTUFILM_FRAME_GRAIN_MOTTLE | FOTUFILM_FRAME_DISC_GRAIN
               | FOTUFILM_FRAME_PRINT_MTF))
            | FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_DENSITY_IN;
        pipeline_for(tail_mask)->run_wrapped<Halide::float16_t, uint8_t>(
            density_mtl_buffer, output_mtl_buffer, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0,
            origin_x, origin_y, density_width, density_height);
    });
}

extern "C" int32_t fotufilm_halide_metal_measure_tone_rows(
    uint64_t input_mtl_buffer, const float *input_rows, float *rows_out,
    int32_t grid_width, int32_t width, int32_t rows,
    const float *configuration) {
    if (!fotufilm_halide_metal_available() ||
        (input_mtl_buffer == 0) == (input_rows == nullptr) ||
        !rows_out || !configuration || width <= 0 || rows <= 0 ||
        grid_width <= 0 || grid_width > width) return -1;
    return translate_metal_exceptions([&] {
        // No spectral recovery in this one, so no cube to cache; the exposure LUT is bound only
        // because the pipeline shares its parameter list with the glare pass.
        static const std::vector<float> unused(kLutValueCount, 0.0f);
        measure_pipeline_for(MetalMeasurePipeline::Quantity::Tone, false)
            ->run_metal(input_mtl_buffer, input_rows, rows_out, grid_width,
                        width, rows, 0, grid_width, configuration,
                        unused.data(), kLutDimension, 1);
    });
}

extern "C" int32_t fotufilm_halide_metal_measure_flare_rows(
    uint64_t input_mtl_buffer, const float *input_rows, float *rows_out,
    int32_t width, int32_t rows, int32_t origin_y,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id, int32_t feature_mask) {
    if (!fotufilm_halide_metal_available() ||
        (input_mtl_buffer == 0) == (input_rows == nullptr) ||
        !rows_out || !configuration || !exposure_lut || !film_output_lut ||
        !paper_output_lut || width <= 0 || rows <= 0 || origin_y < 0) return -1;
    return translate_metal_exceptions([&] {
        const bool approximate = (feature_mask & FOTUFILM_FRAME_EXACT_MATH) == 0;
        measure_pipeline_for(MetalMeasurePipeline::Quantity::Flare, approximate)
            ->run_metal(input_mtl_buffer, input_rows, rows_out, 3, width, rows,
                        origin_y, 1, configuration, exposure_lut, lut_dimension,
                        spectral_cache_id);
    });
}

extern "C" int32_t fotufilm_halide_metal_decode_rows(
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters) {
    if (!fotufilm_halide_metal_available() ||
        (input_mtl_buffer == 0) == (input_rows == nullptr) ||
        (output_mtl_buffer == 0) == (output_rows == nullptr) ||
        !report_out || !parameters || width <= 0 || rows <= 0) return -1;
    return translate_metal_exceptions([&] {
        decode_pipeline(false)->run_metal(input_mtl_buffer, input_rows, output_mtl_buffer,
                                          output_rows, report_out, width, rows, parameters);
    });
}

extern "C" int32_t fotufilm_halide_metal_decode_rows_realtime(
    uint64_t input_mtl_buffer, const float *input_rows,
    uint64_t output_mtl_buffer, float *output_rows, float *report_out,
    int32_t width, int32_t rows, const float *parameters) {
    if (!fotufilm_halide_metal_available() ||
        (input_mtl_buffer == 0) == (input_rows == nullptr) ||
        (output_mtl_buffer == 0) == (output_rows == nullptr) ||
        !report_out || !parameters || width <= 0 || rows <= 0) return -1;
    return translate_metal_exceptions([&] {
        decode_pipeline(true)->run_metal(input_mtl_buffer, input_rows, output_mtl_buffer,
                                         output_rows, report_out, width, rows, parameters);
    });
}

#endif  // __APPLE__

#if defined(FOTUFILM_HALIDE_CUDA)

// The CUDA surface is deliberately the host-buffer subset: a frame in, a frame out, with the
// spectral cubes cached on the device between calls exactly as they are on Metal.
extern "C" int32_t fotufilm_halide_cuda_available(void) {
    return Halide::host_supports_target_device(gpu_target()) ? 1 : 0;
}

extern "C" int32_t fotufilm_halide_cuda_prepare(
    int32_t feature_mask, const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id) {
    if (!fotufilm_halide_cuda_available() || !exposure_lut ||
        !film_output_lut || !paper_output_lut) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->prepare_luts(
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id);
    });
}

extern "C" int32_t fotufilm_halide_cuda_process_srgb8(
    const uint8_t *input, uint8_t *output, int32_t width, int32_t height,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id,
    int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_cuda_available() || !input || !output || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->run_host(
            input, output, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0);
    });
}

extern "C" int32_t fotufilm_halide_cuda_process_linear_float(
    const float *input, float *output, int32_t width, int32_t height,
    int32_t origin_x, int32_t origin_y, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_cuda_available() || !input || !output || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask | FOTUFILM_FRAME_FLOAT_IO)->run_host(
            input, output, width, height, configuration,
            exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0,
            origin_x, origin_y);
    });
}

// The device-pointer pair. On a discrete GPU the host round trip above is not a detail of the
// entry point, it is the frame budget: a 4K RGBA float frame is 132 MB each way, which costs
// about 21 ms on a 4090 against the 1.6 ms the whole simulation takes. A video pipeline whose
// frames are decoded and encoded on the device never needs that trip, and these are the entry
// points that let it keep them there — the CUDA counterpart of the MTLBuffer pair on Apple.
//
// The pointers are plain CUdeviceptr values, interleaved RGBA and tightly packed, and the caller
// keeps ownership: nothing here allocates, frees, or caches them.
extern "C" int32_t fotufilm_halide_cuda_process_device_srgb8(
    uint64_t input_device_pointer, uint64_t output_device_pointer,
    int32_t width, int32_t height, const float *configuration,
    const float *exposure_lut, const float *film_output_lut,
    const float *paper_output_lut, int32_t lut_dimension,
    uint64_t spectral_cache_id, int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_cuda_available() || !input_device_pointer ||
        !output_device_pointer || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask)->run_wrapped<uint8_t>(
            input_device_pointer, output_device_pointer, width, height,
            configuration, exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0);
    });
}

extern "C" int32_t fotufilm_halide_cuda_process_device_linear_float(
    uint64_t input_device_pointer, uint64_t output_device_pointer,
    int32_t width, int32_t height, int32_t origin_x, int32_t origin_y,
    const float *configuration, const float *exposure_lut,
    const float *film_output_lut, const float *paper_output_lut,
    int32_t lut_dimension, uint64_t spectral_cache_id,
    int32_t feature_mask, uint32_t seed) {
    if (!fotufilm_halide_cuda_available() || !input_device_pointer ||
        !output_device_pointer || !configuration ||
        !exposure_lut || !film_output_lut || !paper_output_lut ||
        width <= 0 || height <= 0 ||
        !valid_flare_mean(configuration, feature_mask)) return -1;
    return translate_metal_exceptions([&] {
        pipeline_for(feature_mask | FOTUFILM_FRAME_FLOAT_IO)->run_wrapped<float>(
            input_device_pointer, output_device_pointer, width, height,
            configuration, exposure_lut, film_output_lut, paper_output_lut,
            lut_dimension, spectral_cache_id, seed,
            (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0,
            origin_x, origin_y);
    });
}

#endif  // FOTUFILM_HALIDE_CUDA

#else

extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_available(void) { return 0; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_variant_exists(int32_t) { return 0; }
extern "C" FOTUFILM_FALLBACK void fotufilm_halide_metal_report_profile(void) {}
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_still_fast_bits(void) { return 0; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_prepare(
    int32_t, const float *, const float *, const float *, int32_t, uint64_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_srgb8(
    const uint8_t *, uint8_t *, int32_t, int32_t, const float *, const float *,
    const float *, const float *, int32_t, uint64_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_linear_float(
    const float *, float *, int32_t, int32_t, int32_t, int32_t, const float *,
    const float *, const float *, const float *, int32_t, uint64_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_linear_float_rows(
    const float *, float *, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, const float *, const float *, const float *, const float *,
    int32_t, uint64_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_light_rows(
    const float *, float *, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, const float *, const float *, const float *, const float *,
    int32_t, uint64_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_halation_fields_floats(
    int32_t, int32_t, const int32_t *) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_halation_fields(
    const float *, int32_t, int32_t, const int32_t *, float *,
    int32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_linear_float_fields_rows(
    const float *, float *, int32_t, int32_t, int32_t, int32_t, int32_t,
    int32_t, const float *, const float *, int32_t, uint64_t, const float *,
    const float *, const float *, int32_t, uint64_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_buffers(
    uint64_t, uint64_t, int32_t, int32_t, int32_t, int32_t,
    const float *, const float *,
    const float *, const float *, int32_t, uint64_t, int32_t, uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_measure_tone_rows(
    uint64_t, const float *, float *, int32_t, int32_t, int32_t,
    const float *) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_measure_flare_rows(
    uint64_t, const float *, float *, int32_t, int32_t, int32_t, const float *,
    const float *, const float *, const float *, int32_t, uint64_t,
    int32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_decode_rows(
    uint64_t, const float *, uint64_t, float *, float *, int32_t, int32_t,
    const float *) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_decode_rows_realtime(
    uint64_t, const float *, uint64_t, float *, float *, int32_t, int32_t,
    const float *) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_buffers_float(
    uint64_t, uint64_t, int32_t, int32_t, int32_t, int32_t, const float *,
    const float *, const float *, const float *, int32_t, uint64_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_buffers_head(
    uint64_t, uint64_t, int32_t, int32_t, int32_t, int32_t, const float *,
    const float *, const float *, const float *, int32_t, uint64_t, int32_t,
    uint32_t) { return -1; }
extern "C" FOTUFILM_FALLBACK int32_t fotufilm_halide_metal_process_buffers_tail(
    uint64_t, uint64_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
    const float *, const float *, const float *, const float *, int32_t,
    uint64_t, int32_t, uint32_t) { return -1; }

#endif
