#define FOTUFILM_HALIDE_ENABLED 1
#define FOTUFILM_HALIDE_AOT_GENERATOR 1
#include "../Sources/FotufilmHalide/FotufilmHalideMetal.cpp"

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <iterator>

int main(int argc, char **argv) {
    if (argc < 2) {
        std::cerr << "usage: generate_halide_ios OUTPUT_DIRECTORY "
                     "[--simulator|--macos|--macos-intel]\n"
                     "       [--count | --variant=I | --extras]  "
                     "(default: every pipeline)\n";
        return 2;
    }
    std::string platform;
    // Compile one variant per process. Halide AOT compilation has undocumented global state, and
    // its process-wide unique-name counter changes embedded Metal source based on compile order.
    // Isolating variants makes output deterministic across worker counts.
    enum class Work { Everything, OneVariant, ExtrasOnly };
    Work work = Work::Everything;
    int wanted = 0;
    bool count_only = false;
    for (int i = 2; i < argc; ++i) {
        const std::string argument = argv[i];
        if (argument == "--count") {
            count_only = true;
        } else if (argument.rfind("--variant=", 0) == 0) {
            work = Work::OneVariant;
            wanted = std::stoi(argument.substr(std::string("--variant=").size()));
        } else if (argument == "--extras") {
            work = Work::ExtrasOnly;
        } else if (argument == "--simulator" || argument == "--macos" ||
                   argument == "--macos-intel") {
            platform = argument;
        } else {
            std::cerr << "unknown argument: " << argument << "\n";
            return 2;
        }
    }
    const bool simulator = platform == "--simulator";
    const bool macos = platform == "--macos" || platform == "--macos-intel";
    const bool intel = platform == "--macos-intel";
    const std::filesystem::path output(argv[1]);
    std::filesystem::create_directories(output);

    struct Variant {
        const char *name;
        int features;
        bool runtime;
    };
#define FOTUFILM_AOT_GENERATOR_ENTRY(variant_name, variant_mask) \
    {"fotufilm_halide_ios_" #variant_name, (variant_mask), false},
    Variant variants[] = {FOTUFILM_AOT_VARIANTS(FOTUFILM_AOT_GENERATOR_ENTRY)};
#undef FOTUFILM_AOT_GENERATOR_ENTRY
    variants[0].runtime = true;
    const int variant_count = static_cast<int>(std::size(variants));
    if (count_only) {
        std::cout << variant_count << "\n";
        return 0;
    }
    if (work == Work::OneVariant && (wanted < 0 || wanted >= variant_count)) {
        std::cerr << "--variant=" << wanted << " is out of range (0.."
                  << variant_count - 1 << ")\n";
        return 2;
    }
    const Halide::Target target =
        macos ? MetalFramePipeline::macos_aot_target(intel)
              : MetalFramePipeline::ios_aot_target(simulator);

    // Compiled metallib embedding: the default on Halide 22+, FOTUFILM_METAL_PRECOMPILE=0 opts
    // out for local debugging. It cuts macOS archives from 517 MB to 137 MB and takes the
    // readable Metal source out of the shipped binary, which is otherwise 91% shader text anyone
    // can run strings over — the whole reason to want it. ci_scripts/fetch-halide-toolchain.sh
    // and tools/build-halide-toolchain.sh carry a Halide 22 built and pinned for exactly this;
    // a Halide older than 22 (a local brew install, most likely) falls through the #if below and
    // gets the old source-embedded archives automatically, no flag needed either way.
    //
    // The "85 of 182 variants fail" that kept this off originally was an artifact of asking for
    // bit-exactness between two different compilers. Measured against the JIT road on Halide 22,
    // the 85 are two populations and neither is a defect:
    //
    //   - 64 variants write a float picture and differ by at most 4.77e-6 on a 0..1 range, which
    //     is under half a 16-bit code. It is the offline compiler's pow, rsqrt and exp against the
    //     driver's, and no flag closes it: safe and default math modes produce identical numbers
    //     on every one of the 182, and -ffp-contract=off makes a probe worse rather than better,
    //     because the driver contracts too.
    //   - 21 variants write an 8-bit picture, and "1.0" was one code value read as full scale.
    //     They differ by a single code on at most 2 pixels of 331,776 — a rounding boundary
    //     landing the other way, 0.0006% of the frame.
    //
    // The remaining 97 agree exactly. What this cannot be checked with is one global tolerance:
    // the roads write different scales, so 1 admits any error at all on the float variants and
    // 1e-5 is unmeetable by the 8-bit ones. A tolerance for this wants to be per output scale.
#if defined(HALIDE_VERSION_MAJOR) && HALIDE_VERSION_MAJOR >= 22
    if (const char *const precompile = std::getenv("FOTUFILM_METAL_PRECOMPILE");
        precompile == nullptr || std::string(precompile) != "0") {
        const char *const metal_sdk = macos       ? "macosx"
                                      : simulator ? "iphonesimulator"
                                                  : "iphoneos";
        // -fmetal-math-mode=safe matches what the runtime does when it compiles from source:
        // halide_metal_initialize_kernels calls setFastMathEnabled:false, where the offline
        // compiler's unflagged default is fast math on. On these 182 generated kernels the flag
        // measured as a no-op — safe and the unflagged default produced byte-identical output on
        // every variant, so whatever divergence remains (see above) is not fast-math reassociation
        // in this codebase's kernels. It stays on regardless: a hand-written probe kernel (a
        // cancelling sum, a fused accumulation) does diverge under fast math and agree under safe,
        // so the flag is defending against a category of bug the current kernels don't happen to
        // trigger rather than one that cannot occur. -ffp-contract=off does not belong beside it —
        // on the same probe it went from bit-exact to 3.9e-3 wrong, because the driver contracts
        // too and turning contraction off here just disagrees with the other road.
        // FOTUFILM_METAL_MATH_MODE names the mode, so the roads can be measured against each
        // other; "fast" stands for the compiler's own default, which is to say no flag at all.
        const char *const mode_name = std::getenv("FOTUFILM_METAL_MATH_MODE");
        const std::string mode = mode_name != nullptr ? mode_name : "safe";
        const std::string math_flag =
            mode == "fast" ? std::string() : " -fmetal-math-mode=" + mode;
        // Match the Mac app's minimum OS instead of inheriting the installed SDK's target.
        const std::string deployment_flag = macos ? " -mmacosx-version-min=14.0" : "";
        Halide::set_metal_compiler_and_linker(
            std::string("xcrun -sdk ") + metal_sdk + " metal" + deployment_flag + math_flag,
            std::string("xcrun -sdk ") + metal_sdk + " metallib");
    }
#endif
    if (!macos) {
        f16_blur_default() = true;
        f16_lut_default() = true;
        metal_grain_default() = true;
        metal_mtf_default() = true;
        // Float still variants retain float stores, LUTs, and tetrahedral arithmetic. Keeping
        // this mask at zero makes the generated AOT set match the preservation contract in the
        // JIT path; byte-input realtime variants can still use their dedicated half techniques.
        still_fast_default() = 0;
    }
    // Use short unique suffixes because Halide embeds internal names in Metal source. Full variant
    // names added 83 MB to a 366 MB, 128-object set. Public AOT symbols use `function_name` and are
    // unaffected.
    int tag = 0;
    for (const Variant &variant : variants) {
        // Counted over every variant rather than every compiled one, so a variant's tag — and so
        // its object — does not depend on which process happened to build it.
        const int index = tag++;
        if (work == Work::ExtrasOnly || (work == Work::OneVariant && index != wanted)) {
            continue;
        }
        try {
            MetalFramePipeline pipeline(variant.features,
                                        "_v" + std::to_string(index));
            pipeline.compile_aot((output / variant.name).string(), variant.name,
                                 variant.runtime, target);
        } catch (const Halide::CompileError &error) {
            // Name the variant: eighty compile in a row, and a bare terminate() says only that
            // one of them did not.
            std::cerr << "compiling " << variant.name << " (mask 0x" << std::hex
                      << variant.features << std::dec << "): " << error.what() << "\n";
            return 1;
        }
    }

    // Everything past this point is a handful of small one-off pipelines, compiled together by a
    // single `--extras` process. Spreading six short objects over the pool would save nothing.
    if (work == Work::OneVariant) {
        return 0;
    }

    // The two whole-frame measurements. Four kernels: the tone base does not care about the fast
    // transcendentals, having none to take, but it is generated both ways so that the shim can
    // reach a measurement by the same rule it reaches a develop variant.
    struct Measurement {
        const char *name;
        MetalMeasurePipeline::Quantity quantity;
        bool approximate;
    };
    const Measurement measurements[] = {
        {"fotufilm_halide_ios_measure_tone", MetalMeasurePipeline::Quantity::Tone, false},
        {"fotufilm_halide_ios_measure_flare", MetalMeasurePipeline::Quantity::Flare, false},
        {"fotufilm_halide_ios_measure_flare_fast", MetalMeasurePipeline::Quantity::Flare, true},
    };
    int measurement_tag = 0;
    for (const Measurement &measurement : measurements) {
        // A distinct letter from the frame variants' tags, so the two sequences cannot collide.
        MetalMeasurePipeline pipeline(measurement.quantity,
                                      measurement.approximate,
                                      "_m" + std::to_string(measurement_tag++));
        pipeline.compile_aot((output / measurement.name).string(),
                             measurement.name, target);
    }

    // The host-to-engine decode is coefficient-driven across colour spaces. Realtime frames get a
    // second kernel with the schedule's bounded transcendental approximations.
    for (const bool approximate : {false, true}) {
        const std::string name = approximate
            ? "fotufilm_halide_ios_decode_realtime" : "fotufilm_halide_ios_decode";
        MetalDecodePipeline pipeline(approximate, approximate ? "_d1" : "_d0");
        pipeline.compile_aot((output / name).string(), name, target);
    }

    // The whole-frame halation fields build, for the two-pass striped still path: the same
    // decimation chain and triple-box blurs the frame schedule runs over a staged frame.
    {
        MetalHalationFieldsPipeline pipeline("_h0");
        pipeline.compile_aot(
            (output / "fotufilm_halide_ios_halation_fields").string(),
            "fotufilm_halide_ios_halation_fields", target);
    }
    return 0;
}
