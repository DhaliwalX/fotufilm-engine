#pragma once

#include "FotufilmHalideDevelop.h"

#include "../FotufilmHalideShared.h"
#include "../FotufilmHalideFrameParams.h"
#include "../Schedule/Cpu.h"
#include "../Graph/Frame.h"
#include "../FotufilmCompiledCache.h"
#include "FilmTileStore.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <exception>
#include <memory>
#include <mutex>
#include <set>
#include <string>


namespace fotufilm::pipelines {

using Halide::BoundaryConditions::constant_exterior;
using Halide::Buffer;
using Halide::Expr;
using Halide::Float;
using Halide::Func;
using Halide::ImageParam;
using Halide::Param;
using Halide::Pipeline;
using Halide::RDom;
using Halide::Var;

/// The JIT roads keep the film grain tiles as compiler buffers.
using FilmTileStore = BasicFilmTileStore<Buffer<float>>;

using namespace fotufilm;
using namespace fotufilm::cpu;

inline Buffer<float> planar_buffer(const float *r, const float *g, const float *b,
                            int32_t width, int32_t height) {
    Buffer<float> buffer(width, height, 3);
    const int64_t count = static_cast<int64_t>(width) * height;
    std::copy_n(r, count, buffer.data());
    std::copy_n(g, count, buffer.data() + count);
    std::copy_n(b, count, buffer.data() + count * 2);
    return buffer;
}

inline void copy_planar(const Buffer<float> &buffer, float *r, float *g, float *b,
                 int32_t width, int32_t height) {
    const int64_t count = static_cast<int64_t>(width) * height;
    std::copy_n(buffer.data(), count, r);
    std::copy_n(buffer.data() + count, count, g);
    std::copy_n(buffer.data() + count * 2, count, b);
}

inline Buffer<float> lut_buffer(const float *values) {
    Buffer<float> buffer(kLutValueCount);
    std::copy_n(values, kLutValueCount, buffer.data());
    return buffer;
}

inline Buffer<float> configuration_buffer(const float *values) {
    Buffer<float> buffer(FOTUFILM_FRAME_CONFIGURATION_COUNT);
    std::copy_n(values, FOTUFILM_FRAME_CONFIGURATION_COUNT, buffer.data());
    return buffer;
}

/// The reference schedule's placement: every materialisation point is a vectorised, parallel
/// full-frame pass in float32, so where a frame is stored never changes what it holds.
class CpuBackend : public graph::Backend {
public:
    CpuBackend(ImageParam *film_lut = nullptr, ImageParam *paper_lut = nullptr)
        : film_lut_(film_lut), paper_lut_(paper_lut) {}

    using graph::Backend::store;
    Func store(Func values, graph::Store point, int channels, Expr branch) override {
        if (!values.defined() || stored_.count(values.name())) return values;
        if (point == graph::Store::MtfSelected || point == graph::Store::Inhibition) return values;
        Var x("x"), y("y"), c("c");
        cpu_pointwise(values, x, y, c, channels);
        stored_.insert(values.name());
        return values;
    }

    Func gaussian(Func source, Expr sigma0, Expr sigma1, Expr sigma2, Expr radius,
                  Expr width, Expr height, const std::string &name, int channels,
                  Expr, Expr) override {
        Func blurred = fotufilm::cpu::gaussian(source, sigma0, sigma1, sigma2, radius,
                                               width, height, name, channels);
        stored_.insert(blurred.name());
        return blurred;
    }

    Func gaussian_decimated(Func source, Expr sigma, Expr radius, Expr origin_x,
                            Expr origin_y, Expr width, Expr height,
                            const std::string &name, int channels) override {
        return cpu_gaussian_decimated(source, sigma, radius, origin_x, origin_y,
                                      width, height, name, channels);
    }

    std::array<Expr, 3> scattered(Func light, std::array<Expr, 3> strides,
                                  std::array<Expr, 3> strided_radii, Expr width, Expr height,
                                  Expr origin_x, Expr origin_y, Var x, Var y, Var c,
                                  int ring_config_base, bool annular, const std::string &name,
                                  int channels) override {
        std::array<Expr, 3> result;
        for (int k = 0; k < 3; ++k) {
            Expr ring = ring_config_base >= 0
                ? Expr(configuration_(ring_config_base + k)) : Expr(0.0f);
            result[k] = halation_scale(light, strides[k], strided_radii[k], width, height,
                                       origin_x, origin_y, x, y, c, ring, annular,
                                       name + std::to_string(k), channels);
        }
        return result;
    }

    Func frame_mean(Func light, int channels, Expr width, Expr height,
                    const std::string &name) override {
        Var y("y"), c("c");
        Func row_sum(name + "_row_sum");
        row_sum(y, c) = Halide::cast<double>(0);
        RDom row_domain(0, width, name + "_row_domain");
        row_sum(y, c) += Halide::cast<double>(light(row_domain.x, y, c));
        Func total(name + "_total");
        total(c) = Halide::cast<double>(0);
        RDom column_domain(0, height, name + "_column_domain");
        total(c) += row_sum(column_domain.x, c);
        Func measured(name + "_measured");
        measured(c) = Halide::cast<float>(
            total(c) / (Halide::cast<double>(width) * height));
        row_sum.compute_root().bound(c, 0, channels);
        row_sum.update().parallel(y);
        total.compute_root().bound(c, 0, channels);
        measured.compute_root().bound(c, 0, channels);
        Func mean(name + "_mean");
        mean(c) = Halide::select(
            configuration_(FOTUFILM_CONFIG_FLARE_MEAN) >= 0.0f,
            configuration_(FOTUFILM_CONFIG_FLARE_MEAN + c), measured(c));
        mean.compute_root().bound(c, 0, channels);
        return mean;
    }

    graph::GrainFields grain_fields(ImageParam &configuration, FrameParams &p, Expr monochrome,
                                    bool use_mottle, Var x, Var y, Var c, Expr width,
                                    Expr height, const std::string &prefix,
                                    const std::string &suffix) override {
        graph::GrainFields fields;
        Func poisson_table = poisson_inverse_cdf(p.grain_lambda_, prefix + "poisson_cdf" + suffix);
        Func normal_table = normal_inverse_cdf(prefix + "normal_cdf" + suffix);
        Func noise(prefix + "noise" + suffix);
        Expr own_draw = poisson_sample_lut(
            poisson_table, normal_table, x + p.origin_x_, y + p.origin_y_,
            p.seed_, p.grain_lambda_, c);
        Expr shared_draw = poisson_sample_lut(
            poisson_table, normal_table, x + p.origin_x_, y + p.origin_y_,
            p.seed_, p.grain_lambda_, kGrainSharedLayer);
        Expr silver_draw = normal_sample_lut(
            normal_table, x + p.origin_x_, y + p.origin_y_, p.seed_, kGrainSharedLayer);
        noise(x, y, c) = Halide::select(
            monochrome != 0, silver_draw, grain_mix(configuration, own_draw, shared_draw));
        cpu_pointwise(noise, x, y, c);
        noise.specialize(p.grain_lambda_ >= 16.0f);
        fields.grain = fotufilm::cpu::gaussian(
            noise,
            configuration(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER),
            configuration(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 1),
            configuration(FOTUFILM_CONFIG_GRAIN_SIGMA_LAYER + 2),
            p.grain_radius_, width, height, prefix + "grain_field" + suffix);
        if (use_mottle) {
            Func mottle_table = poisson_inverse_cdf(p.mottle_lambda_, prefix + "mottle_cdf" + suffix);
            Func mottle_noise(prefix + "mottle_noise" + suffix);
            Expr own_mottle = poisson_sample_lut(
                mottle_table, normal_table, x + p.origin_x_, y + p.origin_y_,
                p.seed_, p.mottle_lambda_, c + kGrainMottleLayerBase);
            Expr shared_mottle = poisson_sample_lut(
                mottle_table, normal_table, x + p.origin_x_, y + p.origin_y_,
                p.seed_, p.mottle_lambda_, kGrainMottleSharedLayer);
            Expr silver_mottle = normal_sample_lut(
                normal_table, x + p.origin_x_, y + p.origin_y_, p.seed_,
                kGrainMottleSharedLayer);
            mottle_noise(x, y, c) = Halide::select(
                monochrome != 0, silver_mottle,
                grain_mix(configuration, own_mottle, shared_mottle));
            cpu_pointwise(mottle_noise, x, y, c);
            mottle_noise.specialize(p.mottle_lambda_ >= 16.0f);
            fields.mottle = fotufilm::cpu::gaussian(
                mottle_noise,
                configuration(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER),
                configuration(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER + 1),
                configuration(FOTUFILM_CONFIG_MOTTLE_SIGMA_LAYER + 2),
                p.mottle_radius_, width, height, prefix + "mottle_field" + suffix);
        }
        fields.channels = 3;
        return fields;
    }

    Expr film_lut_sample(Expr ar, Expr ag, Expr ab, Expr channel) override {
        return lut_sample(*film_lut_, ar, ag, ab, channel);
    }

    Expr paper_lut_sample(Expr ax, Expr ay, Expr az, Expr channel) override {
        return lut_sample(*paper_lut_, ax, ay, az, channel);
    }


    void bind_configuration(ImageParam &configuration) { configuration_ = configuration; }

private:
    ImageParam configuration_;
    ImageParam *film_lut_;
    ImageParam *paper_lut_;
    std::set<std::string> stored_;
};

/// Stages 1-7: scene-linear planar RGB to developed per-layer density.
class DevelopPipeline : FrameParams {
public:
    DevelopPipeline(int32_t features, const std::string &suffix)
        : FrameParams("develop_", suffix),
          input_r_(Float(32), 2, "develop_input_r" + suffix),
          input_g_(Float(32), 2, "develop_input_g" + suffix),
          input_b_(Float(32), 2, "develop_input_b" + suffix),
          configuration_(Float(32), 1, "develop_configuration" + suffix),
          exposure_lut_(Float(32), 1, "develop_exposure_lut" + suffix),
          film_tiles_(Float(32), 3, "develop_film_tiles" + suffix),
          grain_mode_("develop_grain_mode" + suffix),
          film_grain_("develop_film_on" + suffix),
          monochrome_("develop_monochrome" + suffix),
          features_("develop_features" + suffix) {
        const bool texture = features & FOTUFILM_FRAME_TEXTURE;
        Var x("x"), y("y"), c("c");
        exposure_lut_.dim(0).set_bounds(0, kLutValueCount);

        CpuBackend backend;
        backend.bind_configuration(configuration_);
        auto source = [&](Expr channel) {
            return Halide::mux(channel, {input_r_(x, y), input_g_(x, y), input_b_(x, y)});
        };
        graph::Inputs inputs{
            configuration_, exposure_lut_, *this, features_, features,
            [&](int channel) {
                return channel == 0 ? input_r_(x, y) : channel == 1 ? input_g_(x, y)
                                                                    : input_b_(x, y);
            },
            source, source,
            Expr(monochrome_), Expr(grain_mode_), texture,
            (features & FOTUFILM_FRAME_DENSITY_IN) != 0,
            (features & FOTUFILM_FRAME_RECORD_EXPOSURE_IN) != 0,
            (features & FOTUFILM_FRAME_LIGHT_OUT) != 0,
#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
            true,
#else
            false,
#endif
            "develop_", suffix};
        inputs.film_tiles = &film_tiles_;
        inputs.film_on = film_grain_ != 0;
        graph::Developed developed = graph::build_develop(backend, inputs, x, y, c);

        Func output = developed.developed;
        if (features & FOTUFILM_FRAME_LIGHT_OUT) {
            output = developed.light;
        } else if (texture) {
            Func textured("develop_texture" + suffix);
            textured(x, y, c) = texture_carry(
                source(c), developed.developed(x, y, c), developed.flat_density(x, y, c),
                reversal_);
            output = textured;
        }
        output = backend.store(output, graph::Store::Output, 3);
        pipeline_ = Pipeline(output);
        cached_.prepare(pipeline_, "develop:" + std::to_string(features),
            {
            input_r_, input_g_, input_b_, configuration_, exposure_lut_,
            width_, height_,
            mtf_sigma_0_, mtf_sigma_1_, mtf_sigma_2_, mtf_luma_sigma_,
            mtf_radius_0_, mtf_radius_1_, mtf_radius_2_, mtf_luma_radius_,
            halation_stride_0_, halation_stride_1_, halation_stride_2_,
            halation_strided_radius_0_, halation_strided_radius_1_,
            halation_strided_radius_2_,
            coupler_sigma_, coupler_radius_, adjacency_sigma_, adjacency_radius_,
            adjacency_secondary_sigma_, adjacency_secondary_radius_,
            fringe_sigma_, fringe_radius_,
            grain_sigma_, grain_radius_, grain_lambda_, print_mtf_radius_,
            seed_, reversal_, monochrome_, origin_x_, origin_y_,
                grain_mode_, mottle_radius_, mottle_lambda_,
                diffusion_stride_0_, diffusion_stride_1_, diffusion_stride_2_,
                diffusion_strided_radius_0_, diffusion_strided_radius_1_,
                diffusion_strided_radius_2_, features_, film_tiles_, film_grain_,},
            reference_target());
    }

    /// Develops into `result`, which the caller owns.
    void run(const float *input_r, const float *input_g, const float *input_b,
             Buffer<float> &result,
             int32_t width, int32_t height, const float *configuration,
             const float *exposure_lut, int32_t feature_mask, uint32_t seed,
             int32_t origin_x = 0, int32_t origin_y = 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> red(const_cast<float *>(input_r), width, height);
        Buffer<float> green(const_cast<float *>(input_g), width, height);
        Buffer<float> blue(const_cast<float *>(input_b), width, height);
        Buffer<float> config(const_cast<float *>(configuration),
                             FOTUFILM_FRAME_CONFIGURATION_COUNT);
        Buffer<float> lut(const_cast<float *>(exposure_lut), kLutValueCount);
        input_r_.set(red);
        input_g_.set(green);
        input_b_.set(blue);
        configuration_.set(config);
        exposure_lut_.set(lut);
        set_frame(configuration, width, height, seed,
                  (feature_mask & FOTUFILM_FRAME_REVERSAL) != 0 ? 1 : 0, origin_x, origin_y);
        grain_mode_.set(int32_t(configuration[FOTUFILM_CONFIG_GRAIN_MODE]));
        bool film_on = false;
        film_tiles_.set(FilmTileStore::shared().tiles_for(configuration, film_on));
        film_grain_.set(film_on ? 1 : 0);
        monochrome_.set((feature_mask & FOTUFILM_FRAME_MONOCHROME) != 0 ? 1 : 0);
        features_.set(feature_mask);
        if (cached_) cached_.realize(result);
        else pipeline_.realize(result, reference_target());
    }

#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    /// The arguments in the order the generated function takes them.
    std::vector<Halide::Argument> arguments(bool extended = false) {
        std::vector<Halide::Argument> args = {
            input_r_, input_g_, input_b_, configuration_, exposure_lut_,
            width_, height_,
            mtf_sigma_0_, mtf_sigma_1_, mtf_sigma_2_, mtf_luma_sigma_,
            mtf_radius_0_, mtf_radius_1_, mtf_radius_2_, mtf_luma_radius_,
            halation_stride_0_, halation_stride_1_, halation_stride_2_,
            halation_strided_radius_0_, halation_strided_radius_1_,
            halation_strided_radius_2_,
            coupler_sigma_, coupler_radius_, adjacency_sigma_, adjacency_radius_,
            adjacency_secondary_sigma_, adjacency_secondary_radius_,
            fringe_sigma_, fringe_radius_,
            grain_sigma_, grain_radius_, grain_lambda_, print_mtf_radius_,
            seed_, reversal_, monochrome_, origin_x_, origin_y_,
        };
        if (extended) {
            args.insert(args.end(), {
                grain_mode_, mottle_radius_, mottle_lambda_,
                diffusion_stride_0_, diffusion_stride_1_, diffusion_stride_2_,
                diffusion_strided_radius_0_, diffusion_strided_radius_1_,
                diffusion_strided_radius_2_,
            });
        }
        args.insert(args.end(), {features_, film_tiles_, film_grain_});
        return args;
    }

    void compile_aot(const std::string &prefix, const std::string &function_name,
                     bool include_runtime, Halide::Target target, bool extended_arguments = false) {
        target.set_feature(Halide::Target::StrictFloat);
        if (!include_runtime) target.set_feature(Halide::Target::NoRuntime);
        pipeline_.compile_to_static_library(prefix, arguments(extended_arguments), function_name,
                                            target);
    }
#endif

private:
    ImageParam input_r_, input_g_, input_b_, configuration_, exposure_lut_;
    /// The film grain model's tiles (FilmTileStore), and whether this frame samples them.
    ImageParam film_tiles_;
    Param<int32_t> grain_mode_;
    Param<int32_t> film_grain_;
    Param<int32_t> monochrome_;
    Param<int32_t> features_;
    Pipeline pipeline_;
    compiled_cache::Pipeline cached_;
    std::mutex mutex_;
};

/// Stage 8: developed density to display-linear RGB through the spectral output model.
class PrintPipeline {
public:
    PrintPipeline(bool reversal, bool monochrome, const std::string &suffix,
                  bool encode = false, int transfer_shape = -1)
        : input_(Float(32), 3, "print_input" + suffix),
          configuration_(Float(32), 1, "print_configuration" + suffix),
          film_lut_(Float(32), 1, "print_film_lut" + suffix),
          paper_lut_(Float(32), 1, "print_paper_lut" + suffix) {
        Var x("x"), y("y"), c("c");
        film_lut_.dim(0).set_bounds(0, kLutValueCount);
        paper_lut_.dim(0).set_bounds(0, kLutValueCount);

        CpuBackend backend(&film_lut_, &paper_lut_);
        backend.bind_configuration(configuration_);
        Func developed("print_developed" + suffix);
        developed(x, y, c) = input_(x, y, c);
        graph::PrintInputs inputs{configuration_, Expr(reversal ? 1 : 0), monochrome, "", suffix};
        Func printed = graph::build_print(backend, inputs, developed, x, y, c);

        Func output("print_output" + suffix);
        if (!encode) {
            output(x, y, c) = printed(x, y, c);
        } else {
            cpu_pointwise(printed, x, y, c);
            Expr r = Halide::max(printed(x, y, 0), 0.0f);
            Expr g = Halide::max(printed(x, y, 1), 0.0f);
            Expr b = Halide::max(printed(x, y, 2), 0.0f);
            output(x, y, c) = Halide::mux(
                c, {host_output_encode(configuration_, r, g, b, 0, false,
                                       transfer_shape),
                    host_output_encode(configuration_, r, g, b, 1, false,
                                       transfer_shape),
                    host_output_encode(configuration_, r, g, b, 2, false,
                                       transfer_shape)});
        }
        cpu_pointwise(output, x, y, c);
        pipeline_ = Pipeline(output);
        cached_.prepare(pipeline_, "print:" + std::to_string(reversal) + ":" + std::to_string(monochrome)
                + ":" + std::to_string(encode) + ":" + std::to_string(transfer_shape),
            {input_, configuration_, film_lut_, paper_lut_}, reference_target());
    }

    /// Prints `density` — the buffer the develop pass just filled — into
    /// `result`, both caller-owned.
    void run(Buffer<float> &density, Buffer<float> &result,
             int32_t width, int32_t height, const float *configuration,
             const float *film_lut, const float *paper_lut, int32_t feature_mask) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> config(const_cast<float *>(configuration),
                             FOTUFILM_FRAME_CONFIGURATION_COUNT);
        Buffer<float> film(const_cast<float *>(film_lut), kLutValueCount);
        Buffer<float> paper(const_cast<float *>(paper_lut), kLutValueCount);
        input_.set(density);
        configuration_.set(config);
        film_lut_.set(film);
        paper_lut_.set(paper);
        if (cached_) cached_.realize(result);
        else pipeline_.realize(result, reference_target());
    }

#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    void compile_aot(const std::string &prefix, const std::string &function_name,
                     bool include_runtime, Halide::Target target) {
        target.set_feature(Halide::Target::StrictFloat);
        if (!include_runtime) target.set_feature(Halide::Target::NoRuntime);
        std::vector<Halide::Argument> arguments = {
            input_, configuration_, film_lut_, paper_lut_};
        pipeline_.compile_to_static_library(prefix, arguments, function_name,
                                            target);
    }
#endif

private:
    ImageParam input_, configuration_, film_lut_, paper_lut_;
    Pipeline pipeline_;
    compiled_cache::Pipeline cached_;
    std::mutex mutex_;
};

/// No film in the gate: the creative controls, the delivery basis, the grade — and, when the
/// caller asked for it, the host's own last step. See FOTUFILM_FRAME_NO_FILM.
///
/// Its own pipeline rather than a branch in `DevelopPipeline`, because it shares nothing with
/// one: no spectral recovery, no curve, no cube, no density at all. What it does share is
/// `creative_exposure`, which is the point — the controls have to mean the same thing with and
/// without a stock loaded, and there is only one expression of them.
class PlainPipeline {
public:
    PlainPipeline(bool monochrome, const std::string &suffix, bool encode,
                  int transfer_shape)
        : input_r_(Float(32), 2, "plain_input_r" + suffix),
          input_g_(Float(32), 2, "plain_input_g" + suffix),
          input_b_(Float(32), 2, "plain_input_b" + suffix),
          configuration_(Float(32), 1, "plain_configuration" + suffix),
          origin_x_("plain_origin_x" + suffix),
          origin_y_("plain_origin_y" + suffix) {
        Var x("x"), y("y"), c("c");
        CreativeScene scene = creative_exposure(
            configuration_, input_r_(x, y), input_g_(x, y), input_b_(x, y),
            x + origin_x_, y + origin_y_);
        // As on the fused road: with no emulsion there are no records to average, so the
        // neutral is the luminance of the light.
        Expr neutral = kLumaR * scene.r + kLumaG * scene.g + kLumaB * scene.b;
        CreativeScene delivered = monochrome
            ? CreativeScene{neutral, neutral, neutral} : scene;

        Func printed("plain_printed" + suffix);
        printed(x, y, c) = plain_print(configuration_, delivered, c);

        Func output("plain_output" + suffix);
        if (!encode) {
            output(x, y, c) = printed(x, y, c);
        } else {
            cpu_pointwise(printed, x, y, c);
            Expr r = Halide::max(printed(x, y, 0), 0.0f);
            Expr g = Halide::max(printed(x, y, 1), 0.0f);
            Expr b = Halide::max(printed(x, y, 2), 0.0f);
            output(x, y, c) = Halide::mux(
                c, {host_output_encode(configuration_, r, g, b, 0, false,
                                       transfer_shape),
                    host_output_encode(configuration_, r, g, b, 1, false,
                                       transfer_shape),
                    host_output_encode(configuration_, r, g, b, 2, false,
                                       transfer_shape)});
        }
        cpu_pointwise(output, x, y, c);
        pipeline_ = Pipeline(output);
        cached_.prepare(pipeline_, "plain:" + std::to_string(monochrome) + ":" + std::to_string(encode)
                + ":" + std::to_string(transfer_shape),
            {input_r_, input_g_, input_b_, configuration_, origin_x_, origin_y_}, reference_target());
    }

    void run(const float *input_r, const float *input_g, const float *input_b,
             Buffer<float> &result, int32_t width, int32_t height,
             const float *configuration, int32_t origin_x, int32_t origin_y) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> red(const_cast<float *>(input_r), width, height);
        Buffer<float> green(const_cast<float *>(input_g), width, height);
        Buffer<float> blue(const_cast<float *>(input_b), width, height);
        Buffer<float> config(const_cast<float *>(configuration),
                             FOTUFILM_FRAME_CONFIGURATION_COUNT);
        input_r_.set(red);
        input_g_.set(green);
        input_b_.set(blue);
        configuration_.set(config);
        origin_x_.set(origin_x);
        origin_y_.set(origin_y);
        if (cached_) cached_.realize(result);
        else pipeline_.realize(result, reference_target());
    }

#if defined(FOTUFILM_HALIDE_AOT_GENERATOR)
    void compile_aot(const std::string &prefix, const std::string &function_name,
                     bool include_runtime, Halide::Target target) {
        target.set_feature(Halide::Target::StrictFloat);
        if (!include_runtime) target.set_feature(Halide::Target::NoRuntime);
        std::vector<Halide::Argument> arguments = {
            input_r_, input_g_, input_b_, configuration_, origin_x_, origin_y_};
        pipeline_.compile_to_static_library(prefix, arguments, function_name,
                                            target);
    }
#endif

private:
    ImageParam input_r_, input_g_, input_b_, configuration_;
    Param<int32_t> origin_x_, origin_y_;
    Pipeline pipeline_;
    compiled_cache::Pipeline cached_;
    std::mutex mutex_;
};

class GaussianPipeline {
public:
    GaussianPipeline() : input_(Float(32), 3, "gaussian_input") {
        Var x("x"), y("y"), c("c");
        Func source("gaussian_source");
        source(x, y, c) = input_(x, y, c);
        Func output = gaussian(source, sigma_, sigma_, sigma_, radius_, width_,
                               height_, "gaussian_output");
        pipeline_ = Pipeline(output);
        cached_.prepare(pipeline_, "gaussian",
            {input_, width_, height_, sigma_, radius_}, reference_target());
    }

    void run(const float *input, float *output, int32_t width, int32_t height,
             float sigma, int32_t radius) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> source(width, height, 3);
        const int64_t count = static_cast<int64_t>(width) * height;
        for (int c = 0; c < 3; ++c) std::copy_n(input, count, source.data() + count * c);
        input_.set(source);
        width_.set(width);
        height_.set(height);
        sigma_.set(sigma);
        radius_.set(radius);
        Buffer<float> result(width, height, 3);
        if (cached_) cached_.realize(result);
        else pipeline_.realize(result, reference_target());
        std::copy_n(result.data(), count, output);
    }

private:
    ImageParam input_;
    Param<int32_t> width_{"standalone_gaussian_width"};
    Param<int32_t> height_{"standalone_gaussian_height"};
    Param<float> sigma_{"standalone_gaussian_sigma"};
    Param<int32_t> radius_{"standalone_gaussian_radius"};
    Pipeline pipeline_;
    compiled_cache::Pipeline cached_;
    std::mutex mutex_;
};

class ApproximateGaussianPipeline {
public:
    ApproximateGaussianPipeline() : input_(Float(32), 3, "approximate_input") {
        Var x("x"), y("y"), c("c");
        Func source("approximate_source");
        source(x, y, c) = input_(x, y, c);
        Func box1 = box_blur(source, radius_, width_, height_, "approximate_box_1");
        Func box2 = box_blur(box1, radius_, width_, height_, "approximate_box_2");
        Func output = box_blur(box2, radius_, width_, height_, "approximate_box_3");
        pipeline_ = Pipeline(output);
        cached_.prepare(pipeline_, "approximate-gaussian",
            {input_, width_, height_, radius_}, reference_target());
    }

    void run(const float *input, float *output, int32_t width, int32_t height,
             int32_t radius) {
        std::lock_guard<std::mutex> lock(mutex_);
        Buffer<float> source(width, height, 3);
        const int64_t count = static_cast<int64_t>(width) * height;
        for (int c = 0; c < 3; ++c) std::copy_n(input, count, source.data() + count * c);
        input_.set(source);
        width_.set(width);
        height_.set(height);
        radius_.set(radius);
        Buffer<float> result(width, height, 3);
        if (cached_) cached_.realize(result);
        else pipeline_.realize(result, reference_target());
        std::copy_n(result.data(), count, output);
    }

private:
    ImageParam input_;
    Param<int32_t> width_{"standalone_approximate_width"};
    Param<int32_t> height_{"standalone_approximate_height"};
    Param<int32_t> radius_{"standalone_approximate_radius"};
    Pipeline pipeline_;
    compiled_cache::Pipeline cached_;
    std::mutex mutex_;
};


} // namespace fotufilm::pipelines
