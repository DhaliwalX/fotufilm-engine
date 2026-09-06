# Sampled-curve camera performance

Measured on an 11-inch iPad Pro (iPad8,1), Apple A12X GPU, iPadOS 26.5.2, on 6 September 2026. These are measurements of the native Metal camera renderer, including HDR YUV delivery. Capture, display, video encoding, and UI work are excluded.

The cubic cache brings the tested Gold 200 and Provia 100F cases within 1.4% of the original analytic GPU baseline. The analytic path also benefits from pipeline specialization: in the updated build, sampled curves remain about 2–4% slower than the paired analytic control. Matching the original baseline does not establish a 30 fps or 60 fps camera budget on this device.

| Stock | Resolution | Grain | Original analytic baseline (ms) | Sampled before optimization (ms) | Sampled after optimization (ms) | Change from baseline |
|---|---|---|---:|---:|---:|---:|
| Gold 200 | 1920 × 1080 | Off | 24.15 | 34.15 | 24.22 | +0.3% |
| Gold 200 | 1920 × 1080 | On | 33.59 | 43.70 | 33.65 | +0.2% |
| Provia 100F | 1920 × 1080 | Off | 19.47 | 29.66 | 19.45 | -0.1% |
| Provia 100F | 1920 × 1080 | On | 21.21 | 31.96 | 21.48 | +1.3% |
| Gold 200 | 3840 × 2160 | Off | 79.57 | 118.89 | 79.66 | +0.1% |
| Gold 200 | 3840 × 2160 | On | 97.39 | 138.11 | 98.18 | +0.8% |
| Provia 100F | 3840 × 2160 | Off | 69.72 | 109.02 | 69.85 | +0.2% |
| Provia 100F | 3840 × 2160 | On | 89.80 | 131.47 | 90.65 | +0.9% |

Each case used six warm-up frames per curve and 60 measured frames per curve, alternating the analytic and sampled versions in AB/BA order with one frame in flight. Both used the same current stock parameters; the control replaced only the characteristic curves with their earlier analytic definitions. Input was a synthetic 10-bit HLG YUV gradient, Digital Reference output, and the exact specialized spatial path. All optimized cases stayed at nominal thermal state. The original Provia 4K grain run changed from nominal to fair; its timing is less directly comparable. These results cover the two named stocks, rather than every stock or Apple device.

The cache stores the two original Hermite cubics adjacent to each selected knot. At a knot, the displacement is zero and the GPU returns the original Float32 density. It does not remove or refit points. Mixed analytic/sampled channels, close knots, and records outside the cache domain retain a general evaluator. The curve texture is 640 KiB for these two stocks and at most 2.5 MiB for denser records; it is created when preparing a stock, outside the frame loop.

Validation checks every runtime knot in all 33 sampled profiles for exact Float32 equality, probes both neighboring floats and points inside each interval, and checks every finite Float16 exposure used by the activation table. Both general and specialized curve pipelines are covered, including mixed channels and shifted curves outside the cache domain. The fused HDR tail must also match separate density development and print evaluation.

A separate 60-second paired Gold 200 4K grain run measured 95.22 ms for the updated analytic control and 98.17 ms for sampled curves (3.1% overhead), with 278 frames per curve. Thermal state changed from nominal to fair for both. This sustained result is not compared directly with the earlier sustained run, which reached serious thermal state.
