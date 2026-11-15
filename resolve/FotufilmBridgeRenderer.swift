import Foundation
#if !os(Linux)
import Metal
#endif

import FotufilmHalide

// The engine the bridge develops through, one per platform, answering the calls
// `FotufilmBridge.swift` makes: on the Mac the Metal renderer the app uses, on Linux the same
// desktop graph ahead-of-time compiled for CUDA and Vulkan.

#if !os(Linux)
typealias BridgeRenderer = HalideMetalFilmRenderer
typealias BridgeStaging = FilmFrameStaging

extension HalideMetalFilmRenderer {
    static let missingDevice = "no Metal device the Halide engine can use"
    /// Metal decodes and encodes the host's colour in its kernels.
    static let transformsOnDevice = true
}

/// One effect instance's Metal arguments, bound around each call that renders.
final class BridgeDevice {
    private let context: UnsafeMutableRawPointer

    init?() {
        guard let context = fotufilm_halide_metal_context_create() else { return nil }
        self.context = context
    }

    func run<Result>(_ body: () -> Result) -> Result {
        let previous = fotufilm_halide_metal_context_bind(context)
        defer { fotufilm_halide_metal_context_restore(previous) }
        return body()
    }

    deinit { fotufilm_halide_metal_context_destroy(context) }
}

/// A host's frames when it hands them over as Metal buffers (the OFX GPU render extension): moved
/// between the host's buffers and the engine's staging on the GPU, on the host's own queue, so
/// the frame never visits CPU memory and the copies are ordered after the work that drew it.
final class BridgeHostFrames {
    private var mirrors: [MTLBuffer?] = [nil, nil]
    private var repairedFlagBuffer: MTLBuffer?

    static func object<T>(_ pointer: UnsafeMutableRawPointer?) -> T? {
        guard let pointer else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }

    static func handle(_ object: AnyObject) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(object).toOpaque()
    }

    /// Whether the queue and every buffer are on the device the engine develops on: a copy
    /// between devices is not a copy the GPU can make.
    static func usable(queue: UnsafeMutableRawPointer?,
                       buffers: [UnsafeMutableRawPointer?]) -> Bool {
        guard let queue: MTLCommandQueue = object(queue),
              let device = MTLCreateSystemDefaultDevice(), queue.device === device
        else { return false }
        return buffers.allSatisfy { pointer in
            (object(pointer) as MTLBuffer?).map { $0.device === device } ?? false
        }
    }

    static func staging(_ staging: BridgeStaging?)
        -> (scene: UnsafeMutableRawPointer, developed: UnsafeMutableRawPointer)? {
        guard let staging else { return nil }
        return (handle(staging.sceneBuffer), handle(staging.developedBuffer))
    }

    /// A shared buffer of at least `bytes` this context keeps for the frames that still need the
    /// CPU, and its CPU view.
    func mirror(slot: Int, bytes: Int)
        -> (buffer: UnsafeMutableRawPointer, contents: UnsafeMutableRawPointer)? {
        guard mirrors.indices.contains(slot), bytes > 0 else { return nil }
        if mirrors[slot].map({ $0.length < bytes }) ?? true {
            mirrors[slot] = nil
            mirrors[slot] = MTLCreateSystemDefaultDevice()?
                .makeBuffer(length: bytes, options: .storageModeShared)
        }
        guard let buffer = mirrors[slot] else { return nil }
        return (Self.handle(buffer), buffer.contents())
    }

    private static let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Rows { int sourceBase; int sourceStep; int destinationBase; int destinationStep;
                      uint width; uint rows; };
        kernel void fotufilm_copy_rows(device const float4 *source [[buffer(0)]],
                                       device float4 *destination [[buffer(1)]],
                                       constant Rows &rows [[buffer(2)]],
                                       uint2 at [[thread_position_in_grid]]) {
            if (at.x >= rows.width || at.y >= rows.rows) return;
            destination[rows.destinationBase + rows.destinationStep * int(at.y) + int(at.x)] =
                source[rows.sourceBase + rows.sourceStep * int(at.y) + int(at.x)];
        }
        """
    private static let pipelineLock = NSLock()
    nonisolated(unsafe) private static var pipelines: [ObjectIdentifier: MTLComputePipelineState] = [:]

    private static func pipeline(_ device: MTLDevice) -> MTLComputePipelineState? {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let built = pipelines[ObjectIdentifier(device)] { return built }
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "fotufilm_copy_rows"),
              let built = try? device.makeComputePipelineState(function: function)
        else { return nil }
        pipelines[ObjectIdentifier(device)] = built
        return built
    }

    /// Whether pixels `base + step * row + x` for every row and x stay inside a buffer.
    private static func fits(_ buffer: MTLBuffer, base: Int, step: Int, width: Int,
                             rows: Int) -> Bool {
        let first = base + min(0, step * (rows - 1))
        let last = base + max(0, step * (rows - 1)) + width - 1
        return first >= 0 && (last + 1) * 16 <= buffer.length && last < Int(Int32.max)
    }

    /// Copies `rows` rows of `width` RGBA-float pixels, pixel (x, row) of each side at
    /// `base + step * row + x`; a negative step walks the rows the other way.
    ///
    /// When `fotufilm_halide_metal_host_compute_encoder()` returns a non-nil encoder (the host
    /// Metal scope is open), the kernel is encoded directly on that encoder **without**
    /// endEncoding / commit / semaphore — the scope will commit it in `fotufilm_bridge_host_metal_end`.
    ///
    /// Otherwise, opens its own command buffer on `queue`, commits, and waits (semaphore).
    /// Returns 1 when copied, 0 when it could not be, -1 on timeout.
    static func copy(queue queuePointer: UnsafeMutableRawPointer?,
                     source sourcePointer: UnsafeMutableRawPointer?, sourceBase: Int,
                     sourceStep: Int, destination destinationPointer: UnsafeMutableRawPointer?,
                     destinationBase: Int, destinationStep: Int, width: Int, rows: Int,
                     timeout: Double = 4) -> Int32 {
        guard width > 0, rows > 0,
              let queue: MTLCommandQueue = object(queuePointer),
              let source: MTLBuffer = object(sourcePointer),
              let destination: MTLBuffer = object(destinationPointer),
              fits(source, base: sourceBase, step: sourceStep, width: width, rows: rows),
              fits(destination, base: destinationBase, step: destinationStep, width: width,
                   rows: rows),
              let pipeline = pipeline(queue.device)
        else { return 0 }
        var arguments = (Int32(sourceBase), Int32(sourceStep), Int32(destinationBase),
                         Int32(destinationStep), UInt32(width), UInt32(rows))
        let across = min(width, pipeline.threadExecutionWidth)
        let threadgroup = MTLSize(width: across,
                                  height: max(1, min(rows, pipeline.maxTotalThreadsPerThreadgroup / across)),
                                  depth: 1)
        // Fast path: encode onto the open host Metal encoder (async scope — no wait needed).
        if let rawEnc = fotufilm_halide_metal_host_compute_encoder(),
           let encoder = Unmanaged<AnyObject>.fromOpaque(rawEnc).takeUnretainedValue()
                            as? MTLComputeCommandEncoder {
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(source, offset: 0, index: 0)
            encoder.setBuffer(destination, offset: 0, index: 1)
            encoder.setBytes(&arguments, length: MemoryLayout.size(ofValue: arguments), index: 2)
            encoder.dispatchThreads(MTLSize(width: width, height: rows, depth: 1),
                                    threadsPerThreadgroup: threadgroup)
            // Do NOT endEncoding / commit / wait — the scope will do that.
            return 1
        }
        // Slow path: own command buffer on the host queue, commit and wait.
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder()
        else { return 0 }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(destination, offset: 0, index: 1)
        encoder.setBytes(&arguments, length: MemoryLayout.size(ofValue: arguments), index: 2)
        encoder.dispatchThreads(MTLSize(width: width, height: rows, depth: 1),
                                threadsPerThreadgroup: threadgroup)
        encoder.endEncoding()
        commands.label = "Fotufilm host frame copy"
        let done = DispatchSemaphore(value: 0)
        commands.addCompletedHandler { _ in done.signal() }
        commands.commit()
        if done.wait(timeout: .now() + timeout) == .timedOut { return -1 }
        return commands.status == .completed ? 1 : 0
    }

    // MARK: - GPU Apple Log / Apple Log 2 Decode

    /// The embedded MSL Apple Log decode kernel. Evaluates `exp2(Double(idx) / 128.0)` and the
    /// degree-2 Remez minimax polynomial for `2^r - 1` on `[-1/256, 1/256]` as `(hi, lo)`
    /// double-float pairs (`#pragma clang fp contract(off)`), matching the float32 host curve at
    /// 0 ULP across every representable float32 input.
    private static let appleLogSource: String = {
        let kExp2RemezC2: UInt64 = 0x3fcebfbdff30d656
        let kExp2RemezC1: UInt64 = 0x3fe62e4453e10dae
        func mslFloat(_ f: Float) -> String {
            let hex = String(f.bitPattern, radix: 16)
            let padded = String(repeating: "0", count: max(0, 8 - hex.count)) + hex
            return "as_type<float>(0x\(padded)u)"
        }
        func splitDouble(_ raw: UInt64) -> (hi: String, lo: String) {
            let d = Double(bitPattern: raw)
            let hi = Float(d)
            let lo = Float(d - Double(hi))
            return (mslFloat(hi), mslFloat(lo))
        }
        var tabHiLines: [String] = []
        var tabLoLines: [String] = []
        tabHiLines.reserveCapacity(128)
        tabLoLines.reserveCapacity(128)
        for idx in 0..<128 {
            let pair = splitDouble(Foundation.exp2(Double(idx) / 128.0).bitPattern)
            tabHiLines.append("                \(pair.hi)")
            tabLoLines.append("                \(pair.lo)")
        }
        let tabHi = tabHiLines.joined(separator: ",\n")
        let tabLo = tabLoLines.joined(separator: ",\n")
        let c2 = splitDouble(kExp2RemezC2)
        let c1 = splitDouble(kExp2RemezC1)
        return """
            #include <metal_stdlib>
            using namespace metal;

            #pragma clang fp contract(off)

            constant float kTabHi[128] = {
            \(tabHi)
            };
            constant float kTabLo[128] = {
            \(tabLo)
            };

            // Division-free IEEE-754 round-to-nearest-even fdiv (full general form).
            static inline float ieee_fdiv(float a, float b) {
                uint32_t ua = as_type<uint32_t>(a);
                uint32_t ub = as_type<uint32_t>(b);
                uint32_t sign = (ua ^ ub) & 0x80000000u;
                uint32_t abs_a = ua & 0x7fffffffu;
                uint32_t abs_b = ub & 0x7fffffffu;
                if (abs_a >= 0x7f800000u || abs_b >= 0x7f800000u || abs_b == 0u || abs_a == 0u) {
                    if (abs_a == 0u && abs_b != 0u && abs_b < 0x7f800000u) return as_type<float>(sign);
                    if (abs_b == 0u && abs_a != 0u && abs_a < 0x7f800000u) return as_type<float>(sign | 0x7f800000u);
                    return a / b;
                }
                int ea = int(abs_a >> 23);
                int eb = int(abs_b >> 23);
                uint32_t ma = abs_a & 0x7fffffu;
                uint32_t mb = abs_b & 0x7fffffu;
                if (ea == 0) { int lz = clz(ma) - 8; ma <<= lz; ea = 1 - lz; } else { ma |= (1u << 23); }
                if (eb == 0) { int lz = clz(mb) - 8; mb <<= lz; eb = 1 - lz; } else { mb |= (1u << 23); }
                int exp_out = ea - eb;
                int shift = 24;
                if (ma < mb) { exp_out -= 1; shift = 25; }
                if (exp_out > 127) return as_type<float>(sign | 0x7f800000u);
                float fma_b = float(mb);
                float rcp = 1.0f / fma_b;
                rcp = fma(fma(-fma_b, rcp, 1.0f), rcp, rcp);
                float q_approx = float(ma) * rcp;
                uint32_t uq = as_type<uint32_t>(q_approx);
                int eq = int((uq >> 23) & 0xffu) - 127;
                uint64_t mq = (uq & 0x7fffffu) | (1ULL << 23);
                int expected_eq = (shift == 24) ? 0 : -1;
                if (eq > expected_eq) mq <<= (eq - expected_eq);
                else if (eq < expected_eq) mq >>= (expected_eq - eq);
                if (exp_out >= -126) {
                    uint64_t target = uint64_t(ma) << shift;
                    uint64_t lo_mid = (2ULL * mq - 1ULL) * uint64_t(mb);
                    if (lo_mid > target || (lo_mid == target && (mq & 1ULL))) { mq -= 1ULL; }
                    else {
                        uint64_t hi_mid = (2ULL * mq + 1ULL) * uint64_t(mb);
                        if (hi_mid < target || (hi_mid == target && (mq & 1ULL))) {
                            mq += 1ULL;
                            if (mq == (1ULL << 24)) { mq >>= 1; exp_out += 1; if (exp_out > 127) return as_type<float>(sign | 0x7f800000u); }
                        }
                    }
                    uint32_t biased = uint32_t(exp_out + 127);
                    return as_type<float>(sign | (biased << 23) | uint32_t(mq & 0x7fffffu));
                }
                int sub_shift = -126 - exp_out;
                if (sub_shift > 25) return as_type<float>(sign);
                uint64_t ms = mq >> sub_shift;
                uint64_t target = uint64_t(ma) << shift;
                uint64_t mb_scaled = uint64_t(mb) << sub_shift;
                if (ms > 0ULL) {
                    uint64_t lo_mid = (2ULL * ms - 1ULL) * mb_scaled;
                    if (lo_mid > target || (lo_mid == target && (ms & 1ULL))) ms -= 1ULL;
                    else { uint64_t hi_mid = (2ULL * ms + 1ULL) * mb_scaled; if (hi_mid < target || (hi_mid == target && (ms & 1ULL))) ms += 1ULL; }
                } else if (mb_scaled < target) { ms = 1ULL; }
                return as_type<float>(sign | uint32_t(ms));
            }

            // Specialized division by compile-time positive normal constant `b` (with precomputed `mb` and `rcp`).
            static inline float ieee_fdiv_const(float a, uint32_t ub, uint32_t mb, int eb, float rcp_b) {
                uint32_t ua = as_type<uint32_t>(a);
                uint32_t sign = (ua ^ ub) & 0x80000000u;
                uint32_t abs_a = ua & 0x7fffffffu;
                if (abs_a == 0u) return as_type<float>(sign);
                if (abs_a >= 0x7f800000u) return a;
                int ea = int(abs_a >> 23);
                uint32_t ma = abs_a & 0x7fffffu;
                if (ea == 0) { int lz = int(clz(ma)) - 8; ma <<= lz; ea = 1 - lz; } else { ma |= (1u << 23); }

                int exp_out = ea - eb;
                int shift = 24;
                if (ma < mb) { exp_out -= 1; shift = 25; }
                if (exp_out > 127) return as_type<float>(sign | 0x7f800000u);

                float q_approx = float(ma) * rcp_b;
                uint32_t uq = as_type<uint32_t>(q_approx);
                int eq = int((uq >> 23) & 0xffu) - 127;
                uint64_t mq = (uq & 0x7fffffu) | (1ULL << 23);
                int expected_eq = (shift == 24) ? 0 : -1;
                if (eq > expected_eq) mq <<= (eq - expected_eq);
                else if (eq < expected_eq) mq >>= (expected_eq - eq);

                if (exp_out >= -126) {
                    uint64_t target = uint64_t(ma) << shift;
                    uint64_t lo_mid = (2ULL * mq - 1ULL) * uint64_t(mb);
                    if (lo_mid > target || (lo_mid == target && (mq & 1ULL))) {
                        mq -= 1ULL;
                    } else {
                        uint64_t hi_mid = (2ULL * mq + 1ULL) * uint64_t(mb);
                        if (hi_mid < target || (hi_mid == target && (mq & 1ULL))) {
                            mq += 1ULL;
                            if (mq == (1ULL << 24)) {
                                mq >>= 1;
                                exp_out += 1;
                                if (exp_out > 127) return as_type<float>(sign | 0x7f800000u);
                            }
                        }
                    }
                    return as_type<float>(sign | (uint32_t(exp_out + 127) << 23) | uint32_t(mq & 0x7fffffu));
                }
                int sub_shift = -126 - exp_out;
                if (sub_shift > 25) return as_type<float>(sign);
                uint64_t ms = mq >> sub_shift;
                uint64_t target = uint64_t(ma) << shift;
                uint64_t mb_scaled = uint64_t(mb) << sub_shift;
                if (ms > 0ULL) {
                    uint64_t lo_mid = (2ULL * ms - 1ULL) * mb_scaled;
                    if (lo_mid > target || (lo_mid == target && (ms & 1ULL))) ms -= 1ULL;
                    else {
                        uint64_t hi_mid = (2ULL * ms + 1ULL) * mb_scaled;
                        if (hi_mid < target || (hi_mid == target && (ms & 1ULL))) ms += 1ULL;
                    }
                } else if (mb_scaled < target) {
                    ms = 1ULL;
                }
                return as_type<float>(sign | uint32_t(ms));
            }

            static inline float ieee_fsqrt_pos(float x) {
                uint32_t ux = as_type<uint32_t>(x);
                if (ux == 0u || ux == 0x80000000u) return x;
                int e = int((ux >> 23) & 0xffu);
                uint32_t m = ux & 0x7fffffu;
                if (e == 0) { int lz = clz(m) - 8; m <<= lz; e = 1 - lz; } else { m |= (1u << 23); }
                int exp_unbiased = e - 127;
                uint64_t rad = uint64_t(m);
                if (exp_unbiased & 1) { rad <<= 1; exp_unbiased -= 1; }
                int out_exp = exp_unbiased >> 1;
                float q = precise::sqrt(float(rad) * 0x1.0p-23f);
                uint32_t uq = as_type<uint32_t>(q);
                int eq = int((uq >> 23) & 0xffu) - 127;
                uint64_t s = (uq & 0x7fffffu) | (1ULL << 23);
                if (eq > 0) s <<= eq;
                else if (eq < 0) s >>= (-eq);
                uint64_t target = rad << 25;
                uint64_t lo_mid = 2ULL * s - 1ULL;
                if (lo_mid * lo_mid > target) s -= 1ULL;
                else { uint64_t hi_mid = 2ULL * s + 1ULL; if (hi_mid * hi_mid < target) s += 1ULL; }
                if (s == (1ULL << 24)) { s >>= 1; out_exp += 1; }
                uint32_t biased = uint32_t(out_exp + 127);
                return as_type<float>((biased << 23) | uint32_t(s & 0x7fffffu));
            }

            struct df64 { float hi; float lo; };
            static inline df64 two_sum(float a, float b) { float s=a+b, v=s-a; return {s,(a-(s-v))+(b-v)}; }
            static inline df64 quick_two_sum(float a, float b) { float s=a+b; return {s, b-(s-a)}; }
            static inline df64 two_prod(float a, float b) { float p=a*b; return {p, fma(a,b,-p)}; }
            static inline df64 df_mul(df64 a, df64 b) {
                df64 p = two_prod(a.hi, b.hi);
                p.lo = fma(a.hi, b.lo, fma(a.lo, b.hi, p.lo));
                return quick_two_sum(p.hi, p.lo);
            }
            static inline df64 df_mul_f(df64 a, float b) {
                df64 p = two_prod(a.hi, b);
                p.lo = fma(a.lo, b, p.lo);
                return quick_two_sum(p.hi, p.lo);
            }
            static inline df64 df_add(df64 a, df64 b) {
                df64 s = two_sum(a.hi, b.hi);
                s.lo += (a.lo + b.lo);
                return quick_two_sum(s.hi, s.lo);
            }

            static inline float exp2f_df(float s0) {
                uint32_t w0 = as_type<uint32_t>(s0);
                uint32_t w4 = (w0 >> 23) & 0xffu;
                if (w4 >= 0x87u) {
                    if (isnan(s0)) return s0;
                    return s0 >= 0.0f ? as_type<float>(0x7f800000u) : 0.0f;
                }
                int N = int(rint(s0 * 128.0f));
                float r = s0 - float(N) * 0.0078125f;
                int k = N >> 7;
                int idx = N & 127;
                const df64 c2 = {\(c2.hi), \(c2.lo)};
                const df64 c1 = {\(c1.hi), \(c1.lo)};
                const df64 t  = {kTabHi[idx], kTabLo[idx]};
                df64 d1 = df_add(df_mul_f(c2, r), c1);
                df64 d0 = df_mul_f(d1, r);
                df64 res = df_add(df_mul(d0, t), t);
                return ldexp(res.hi + res.lo, k);
            }

            static inline float apple_log_fast_exact(float code) {
                const float r0 = -0.05641088f;
                const float beta = 0.00964052f;
                uint32_t ucode = as_type<uint32_t>(code);
                bool non_neg = (ucode & 0x80000000u) == 0u || (ucode == 0x80000000u);
                if ((ucode & 0x7f800000u) == 0x7f800000u && (ucode & 0x007fffffu) != 0u) return r0;
                if (!non_neg) return r0;
                if (ucode >= 0x3e558f86u && ucode != 0x80000000u) {
                    float u = (code - 0.69336945f) / 0.08550479f;
                    return exp2f_df(u) - beta;
                }
                float q = ieee_fdiv_const(code, 0x423d2601u, 0xbd2601u, 132, 8.06709711e-8f);
                return ieee_fsqrt_pos(q) + r0;
            }

            static inline float msl_finite(float v, thread uint &repaired, float fallback = 0.0f) {
                uint32_t u = as_type<uint32_t>(v);
                if ((u & 0x7f800000u) != 0x7f800000u) return v;
                repaired = 1u;
                return fallback;
            }

            struct AppleLogDecodeArgs {
                int sourceBase;
                int sourceStep;
                int destBase;
                int destStep;
                uint width;
                uint rows;
                uint premultiplied;
                uint trackRepaired;
                float m0, m1, m2, m3, m4, m5, m6, m7, m8;
            };

            kernel void fotufilm_decode_apple_log(device const float4 *source [[buffer(0)]],
                                                   device float4 *destination [[buffer(1)]],
                                                   constant AppleLogDecodeArgs &args [[buffer(2)]],
                                                   device atomic_uint *repairedOut [[buffer(3)]],
                                                   uint2 at [[thread_position_in_grid]]) {
                if (at.x >= args.width || at.y >= args.rows) return;
                float4 px = source[args.sourceBase + args.sourceStep * int(at.y) + int(at.x)];
                uint repaired = 0u;
                float alpha = msl_finite(px.w, repaired, 1.0f);
                uint32_t ua = as_type<uint32_t>(alpha);
                bool need_unpremul = (args.premultiplied != 0u && ua > 0u && ua < 0x7f800000u && ua != 0x3f800000u);
                float scale = need_unpremul ? ieee_fdiv(1.0f, alpha) : 1.0f;
                float inR = msl_finite(px.x, repaired);
                float inG = msl_finite(px.y, repaired);
                float inB = msl_finite(px.z, repaired);
                if (need_unpremul) {
                    inR = msl_finite(inR * scale, repaired);
                    inG = msl_finite(inG * scale, repaired);
                    inB = msl_finite(inB * scale, repaired);
                }
                float r = msl_finite(apple_log_fast_exact(inR), repaired);
                float g = msl_finite(apple_log_fast_exact(inG), repaired);
                float b = msl_finite(apple_log_fast_exact(inB), repaired);
                float outR = msl_finite(((args.m0 * r) + (args.m1 * g)) + (args.m2 * b), repaired);
                float outG = msl_finite(((args.m3 * r) + (args.m4 * g)) + (args.m5 * b), repaired);
                float outB = msl_finite(((args.m6 * r) + (args.m7 * g)) + (args.m8 * b), repaired);
                destination[args.destBase + args.destStep * int(at.y) + int(at.x)] = float4(outR, outG, outB, alpha);
                if (repaired != 0u && args.trackRepaired != 0u) {
                    atomic_store_explicit(repairedOut, 1u, memory_order_relaxed);
                }
            }
            """
    }()

    private struct AppleLogDeviceState {
        let pipeline: MTLComputePipelineState
        let queue: MTLCommandQueue
        let dummyRepaired: MTLBuffer
    }

    private struct AppleLogDecodeArgs {
        var sourceBase: Int32
        var sourceStep: Int32
        var destBase: Int32
        var destStep: Int32
        var width: UInt32
        var rows: UInt32
        var premultiplied: UInt32
        var trackRepaired: UInt32
        var m0: Float
        var m1: Float
        var m2: Float
        var m3: Float
        var m4: Float
        var m5: Float
        var m6: Float
        var m7: Float
        var m8: Float
    }

    private static let appleLogPipelineLock = NSLock()
    nonisolated(unsafe) private static var appleLogStates:
        [ObjectIdentifier: AppleLogDeviceState] = [:]

    private static func appleLogState(_ device: MTLDevice) -> AppleLogDeviceState? {
        appleLogPipelineLock.lock()
        defer { appleLogPipelineLock.unlock() }
        if let built = appleLogStates[ObjectIdentifier(device)] { return built }
        let opts = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            opts.mathMode = .safe
        } else {
            opts.fastMathEnabled = false
        }
        guard let library = try? device.makeLibrary(source: appleLogSource, options: opts),
              let function = library.makeFunction(name: "fotufilm_decode_apple_log"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue(),
              let dummyRepaired = device.makeBuffer(length: 4, options: .storageModeShared)
        else { return nil }
        dummyRepaired.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        let built = AppleLogDeviceState(pipeline: pipeline, queue: queue,
                                        dummyRepaired: dummyRepaired)
        appleLogStates[ObjectIdentifier(device)] = built
        return built
    }

    private func repairedBuffer(_ device: MTLDevice) -> MTLBuffer? {
        if let existing = repairedFlagBuffer, existing.device === device, existing.length >= 4 {
            return existing
        }
        let created = device.makeBuffer(length: 4, options: .storageModeShared)
        repairedFlagBuffer = created
        return created
    }

    /// Dispatches the division-free 0-ULP GPU Apple Log / Apple Log 2 decode kernel.
    /// Encodes onto the open host Metal compute encoder when active; otherwise executes
    /// synchronously on a cached command queue (for CPU OFX host staged frames).
    /// Returns 1 on success, 0 on failure.
    static func decodeAppleLog(
        hostFrames: BridgeHostFrames?,
        source sourcePointer: UnsafeMutableRawPointer?,
        sourceBase: Int, sourceStep: Int,
        destination destinationPointer: UnsafeMutableRawPointer?,
        destinationBase: Int, destinationStep: Int,
        width: Int, rows: Int,
        premultiplied: Bool,
        matrix: [Float],
        repairedOut: UnsafeMutablePointer<UInt32>?
    ) -> Int32 {
        guard width > 0, rows > 0, matrix.count == 9,
              let srcBase32 = Int32(exactly: sourceBase),
              let srcStep32 = Int32(exactly: sourceStep),
              let dstBase32 = Int32(exactly: destinationBase),
              let dstStep32 = Int32(exactly: destinationStep),
              let width32 = UInt32(exactly: width),
              let rows32 = UInt32(exactly: rows),
              let source: MTLBuffer = object(sourcePointer),
              let destination: MTLBuffer = object(destinationPointer),
              let device = MTLCreateSystemDefaultDevice(),
              source.device === device, destination.device === device,
              fits(source, base: sourceBase, step: sourceStep, width: width, rows: rows),
              fits(destination, base: destinationBase, step: destinationStep, width: width,
                   rows: rows),
              let state = appleLogState(device)
        else { return 0 }

        let pipeline = state.pipeline
        let across = min(width, pipeline.threadExecutionWidth)
        let threadgroup = MTLSize(
            width: across,
            height: max(1, min(rows, pipeline.maxTotalThreadsPerThreadgroup / across)),
            depth: 1)
        let grid = MTLSize(width: width, height: rows, depth: 1)

        func encode(encoder: MTLComputeCommandEncoder, repBuf: MTLBuffer, trackRepaired: Bool) {
            var args = AppleLogDecodeArgs(
                sourceBase: srcBase32, sourceStep: srcStep32,
                destBase: dstBase32, destStep: dstStep32,
                width: width32, rows: rows32,
                premultiplied: premultiplied ? 1 : 0,
                trackRepaired: trackRepaired ? 1 : 0,
                m0: matrix[0], m1: matrix[1], m2: matrix[2],
                m3: matrix[3], m4: matrix[4], m5: matrix[5],
                m6: matrix[6], m7: matrix[7], m8: matrix[8])
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(source, offset: 0, index: 0)
            encoder.setBuffer(destination, offset: 0, index: 1)
            encoder.setBytes(&args, length: MemoryLayout<AppleLogDecodeArgs>.size, index: 2)
            encoder.setBuffer(repBuf, offset: 0, index: 3)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: threadgroup)
        }

        if let rawEnc = fotufilm_halide_metal_host_compute_encoder(),
           let encoder = Unmanaged<AnyObject>.fromOpaque(rawEnc).takeUnretainedValue()
                            as? MTLComputeCommandEncoder {
            // Encode onto the open host encoder — no endEncoding / commit / wait.
            encode(encoder: encoder, repBuf: state.dummyRepaired, trackRepaired: false)
            return 1
        }

        // No open encoder — use a standalone command buffer on the cached queue (CPU decode path).
        let track = repairedOut != nil
        let repBuf: MTLBuffer
        if track {
            guard let buf = hostFrames?.repairedBuffer(device)
                    ?? device.makeBuffer(length: 4, options: .storageModeShared)
            else { return 0 }
            buf.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            repBuf = buf
        } else {
            repBuf = state.dummyRepaired
        }

        guard let cb = state.queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder()
        else { return 0 }

        encode(encoder: enc, repBuf: repBuf, trackRepaired: track)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let repairedOut {
            repairedOut.pointee = repBuf.contents().load(as: UInt32.self)
        }
        return cb.status == .completed ? 1 : 0
    }
}
#else
/// Linux keeps its device state process-wide (`FotufilmHalideLinux.cpp`), so an instance has
/// nothing of its own to bind.
final class BridgeDevice {
    init?() {}
    func run<Result>(_ body: () -> Result) -> Result { body() }
}

/// No host hands a Linux build Metal buffers: the plugin advertises the extension only on the Mac.
final class BridgeHostFrames {
    static func usable(queue: UnsafeMutableRawPointer?,
                       buffers: [UnsafeMutableRawPointer?]) -> Bool { false }
    static func staging(_ staging: BridgeStaging?)
        -> (scene: UnsafeMutableRawPointer, developed: UnsafeMutableRawPointer)? { nil }
    func mirror(slot: Int, bytes: Int)
        -> (buffer: UnsafeMutableRawPointer, contents: UnsafeMutableRawPointer)? { nil }
    static func copy(queue: UnsafeMutableRawPointer?, source: UnsafeMutableRawPointer?,
                     sourceBase: Int, sourceStep: Int,
                     destination: UnsafeMutableRawPointer?, destinationBase: Int,
                     destinationStep: Int, width: Int, rows: Int,
                     timeout: Double = 4) -> Int32 { 0 }
}

/// A frame's pair of host buffers, as the Metal staging is a pair of shared ones: the host decodes
/// into `scenePixels` and encodes out of `developedPixels`, and the kernels read and write them in
/// place.
final class BridgeStaging {
    let capacityPixels: Int
    let scenePixels: UnsafeMutablePointer<Float>
    let developedPixels: UnsafeMutablePointer<Float>

    init(pixels: Int) {
        capacityPixels = pixels
        scenePixels = .allocate(capacity: pixels * 4)
        developedPixels = .allocate(capacity: pixels * 4)
    }

    deinit {
        scenePixels.deallocate()
        developedPixels.deallocate()
    }
}

/// The develop on CUDA or Vulkan, whichever `fotufilm_halide_gpu_device` chose, measured on the
/// host as `HalideGPUDeveloper` measures a still. A film whose layered transport runs outside the
/// graph, or a machine with neither device, develops through the CPU engine; a frame the kernels
/// have no variant for fails, as it does on the Mac, so the controls the host dims agree. The host
/// decodes and encodes: no output transform is carried in the kernel.
final class BridgeRenderer {
    static let shared: BridgeRenderer? = BridgeRenderer()
    static let missingDevice = "no GPU the Halide engine can use"
    static let transformsOnDevice = false

    private let onDevice = fotufilm_halide_gpu_device() != 0
    private let poolLock = NSLock()
    private var idle: BridgeStaging?

    /// What a pixel costs in flight: the staging pair, and the graph's light chain and develop
    /// as the Mac measured them (`HalideMetalFilmRenderer.stripBytesPerRow`); the graph is the same.
    private static let bytesPerPixel = 32 + 48 + 144

    /// Frames up to 16384 on a side develop whole: the staging is host memory. The Mac's
    /// `FOTUFILM_STRIP_BUDGET` bounds a frame here too, so a host can test its striped road.
    static func developsInOnePass(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return false }
        return fitsBudget(pixels: width * height)
    }

    private static func fitsBudget(pixels: Int) -> Bool {
        guard let raw = getenv("FOTUFILM_STRIP_BUDGET"), let budget = Int(String(cString: raw)),
              budget > 0 else { return true }
        return pixels * bytesPerPixel <= budget
    }

    func borrowFrameStaging(pixels: Int, hostQueueID: UInt = 0) -> BridgeStaging? {
        Self.fitsBudget(pixels: pixels) ? pooledStaging(pixels: pixels) : nil
    }

    private func pooledStaging(pixels: Int) -> BridgeStaging? {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let staging = idle, staging.capacityPixels >= pixels {
            idle = nil
            return staging
        }
        return BridgeStaging(pixels: pixels)
    }

    /// Keeps one idle pair, the largest, for the next frame. queueID/fence ignored on Linux.
    func recycleFrameStaging(_ staging: BridgeStaging, queueID: UInt = 0, fence: AnyObject? = nil) {
        poolLock.lock()
        defer { poolLock.unlock() }
        if idle.map({ $0.capacityPixels < staging.capacityPixels }) ?? true { idle = staging }
    }

    /// Uploads the film's tables, so the first frame costs what later ones do.
    @discardableResult
    func prepare(stock: FilmStock, options: FotufilmEngine.Options,
                 frameWidth: Int, frameHeight: Int) -> Bool {
        guard onDevice, options.transportConstruction(for: stock) == nil,
              let invocation = try? FilmEngineInvocation(
                validating: stock, options: options, width: frameWidth, height: frameHeight)
        else { return true }
        return invocation.withSpectralPointers { exposure, film, paper in
            fotufilm_halide_cuda_prepare(invocation.featureMask, exposure, film, paper,
                                         Int32(invocation.spectral.exposure.dimension),
                                         invocation.spectralCacheID) == 0
        }
    }

    func carriesOutputTransform(stock: FilmStock, options: FotufilmEngine.Options,
                                width: Int, height: Int, realtime: Bool,
                                measuresGlareOnDevice: Bool) -> Bool { false }

    func decodeStaged(_ staging: BridgeStaging, skipReport: Bool = false,
                      width: Int, height: Int,
                      transform: FilmInputTransform, realtime: Bool) -> FilmDecodeReport? { nil }

    func decodeRows(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>,
                    width: Int, rows: Int, transform: FilmInputTransform,
                    realtime: Bool) -> FilmDecodeReport? { nil }

    func developStaged(_ staging: BridgeStaging, width: Int, height: Int, stock: FilmStock,
                       options: FotufilmEngine.Options, outputTransform: inout FilmOutputTransform?,
                       frameIndex: UInt64, realtime: Bool, measuresGlareOnDevice: Bool,
                       shouldContinue: (() -> Bool)?) -> Bool {
        outputTransform = nil
        guard staging.capacityPixels >= width * height else { return false }
        return develop(staging.scenePixels, into: staging.developedPixels, width: width,
                       height: height, stock: stock, options: options, frameIndex: frameIndex,
                       realtime: realtime, shouldContinue: shouldContinue ?? { true })
    }

    /// The whole frame read, developed and written back at once: the staging is host memory, so
    /// there is nothing a strip would save, and a budget too small for a staged frame still takes
    /// this road.
    func developStreaming(width: Int, height: Int, stock: FilmStock,
                          options: FotufilmEngine.Options,
                          outputTransform: inout FilmOutputTransform?, frameIndex: UInt64,
                          realtime: Bool, shouldContinue: (() -> Bool)?,
                          readRows: (Range<Int>, UnsafeMutableBufferPointer<Float>) -> Void,
                          writeRows: (Range<Int>, UnsafeBufferPointer<Float>) -> Void) -> Bool {
        outputTransform = nil
        guard let staging = pooledStaging(pixels: width * height) else { return false }
        defer { recycleFrameStaging(staging) }
        let count = width * height * 4
        readRows(0..<height, UnsafeMutableBufferPointer(start: staging.scenePixels, count: count))
        guard develop(staging.scenePixels, into: staging.developedPixels, width: width,
                      height: height, stock: stock, options: options, frameIndex: frameIndex,
                      realtime: realtime, shouldContinue: shouldContinue ?? { true })
        else { return false }
        writeRows(0..<height, UnsafeBufferPointer(start: staging.developedPixels, count: count))
        return true
    }

    private func develop(_ scene: UnsafeMutablePointer<Float>,
                         into output: UnsafeMutablePointer<Float>, width: Int, height: Int,
                         stock: FilmStock, options: FotufilmEngine.Options, frameIndex: UInt64,
                         realtime: Bool, shouldContinue: () -> Bool) -> Bool {
        guard shouldContinue() else { return false }
        let layered = options.transportConstruction(for: stock) != nil
        if onDevice, !layered {
            return developOnDevice(scene, into: output, width: width, height: height, stock: stock,
                                   options: options, frameIndex: frameIndex, realtime: realtime)
                && shouldContinue()
        }
        if developOnCPU(scene, into: output, width: width, height: height, stock: stock,
                        options: options, frameIndex: frameIndex) {
            return shouldContinue()
        }
        // The layered transport needs a Halide backend this build does not carry; the frame
        // develops with the film's own halation rather than not at all.
        guard onDevice, layered, shouldContinue() else { return false }
        return developOnDevice(scene, into: output, width: width, height: height, stock: stock,
                               options: options.withoutLayeredTransport, frameIndex: frameIndex,
                               realtime: realtime) && shouldContinue()
    }

    private func developOnDevice(_ scene: UnsafeMutablePointer<Float>,
                                 into output: UnsafeMutablePointer<Float>, width: Int,
                                 height: Int, stock: FilmStock, options: FotufilmEngine.Options,
                                 frameIndex: UInt64, realtime: Bool) -> Bool {
        guard var invocation = try? FilmEngineInvocation(
            validating: stock, options: options, width: width, height: height,
            frameIndex: frameIndex) else { return false }
        if realtime { invocation.featureMask |= FilmEngineFeature.realtime }
        // Whole-frame measurements, as the Mac's renderer takes them before developing.
        if invocation.featureMask & FilmEngineFeature.flare != 0 {
            invocation.flareMean = invocation.measuredAreaWeightedFlareMean(
                linearRGBA: scene, width: width, height: height)
        }
        if invocation.sceneMeteringActive {
            var measurement = invocation.toneBaseMeasurement()
            measurement.add(linearRGBA: scene, rows: 0..<height)
            invocation.setToneBase(measurement)
        }
        let dimension = Int32(invocation.spectral.exposure.dimension)
        let developed = invocation.configuration.withUnsafeBufferPointer { configuration in
            invocation.withSpectralPointers { exposure, film, paper in
                fotufilm_halide_cuda_prepare(invocation.featureMask, exposure, film, paper,
                                             dimension, invocation.spectralCacheID) == 0
                    && fotufilm_halide_cuda_process_linear_float(
                        scene, output, Int32(width), Int32(height), 0, 0,
                        configuration.baseAddress, exposure, film, paper, dimension,
                        invocation.spectralCacheID, invocation.featureMask,
                        invocation.seed) == 0
            }
        }
        guard developed else { return false }
        // Vulkan's graph leaves negative light in a finished print for a host's display
        // conversion; Metal and CUDA floor it in the kernel. The other spans hand back what they
        // were given, out-of-gamut values included, on every device.
        if fotufilm_halide_gpu_device() == 2, options.stage == .full || options.stage == .print {
            let count = width * height * 4
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for i in (y * width * 4)..<min(count, (y + 1) * width * 4) where i & 3 != 3 {
                    if !(output[i] > 0) { output[i] = 0 }
                }
            }
        }
        return true
    }

    /// The CPU engine, the frame's alpha carried across as the kernels carry it.
    private func developOnCPU(_ scene: UnsafeMutablePointer<Float>,
                              into output: UnsafeMutablePointer<Float>, width: Int, height: Int,
                              stock: FilmStock, options: FotufilmEngine.Options,
                              frameIndex: UInt64) -> Bool {
        var linear = ImageBuffer(width: width, height: height)
        for i in 0..<(width * height) {
            for channel in 0..<3 {
                let value = scene[i * 4 + channel]
                linear.planes[channel][i] = value.isFinite ? value : 0
            }
        }
        // The CPU pipeline has no frame index; the grain moves with the seed instead.
        var options = options
        options.seed &+= frameIndex
        guard let developed = try? FotufilmEngine(stock: stock, options: options)
            .processChecked(linearRGB: linear) else { return false }
        for i in 0..<(width * height) {
            output[i * 4] = developed.planes[0][i]
            output[i * 4 + 1] = developed.planes[1][i]
            output[i * 4 + 2] = developed.planes[2][i]
            output[i * 4 + 3] = scene[i * 4 + 3]
        }
        return true
    }
}
#endif
