// Generated from CameraLogCurve.metalSource; run tools/export-web-video.py.
fn apple_log_to_linear(code: f32) -> f32
{
    var r0: f32 = -0.05641088;
    var c: f32 = 47.287113;
    var beta: f32 = 0.00964052;
    var gamma_: f32 = 0.08550479;
    var delta: f32 = 0.69336945;
    var threshold: f32 = 0.20855531;
    if (code >= threshold) { return exp2((code - delta) / gamma_) - beta; }
    if (code >= 0.0) { return sqrt(code / c) + r0; }
    return r0;
}

fn slog3_to_linear(code: f32) -> f32
{
    var c: f32 = code * 1023.0;
    if (c >= 171.2102946929) {
        return pow(10.0, (c - 420.0) / 261.5) * 0.19 - 0.01;
    }
    return (c - 95.0) * 0.01125 / (171.2102946929 - 95.0);
}

fn slog2_to_linear(code: f32) -> f32
{
    var y: f32 = (code * 1023.0 - 64.0) / 876.0;
    var toe: f32 = 0.030001222851889303;
    var x: f32;
    if (y >= toe) {
        x = pow(10.0, (y - 0.616596 - 0.03) / 0.432699) - 0.037584;
    } else {
        x = (y - toe) / 5.0;
    }
    return x * 0.9 * (219.0 / 155.0);
}

fn hlg_to_linear(code: f32) -> f32
{
    var signal: f32 = clamp(code, 0.0, 1.0);
    var a: f32 = 0.17883277;
    var b: f32 = 0.28466892;
    var c: f32 = 0.5599107;
    var scene: f32 = select((exp((signal - c) / a) + b) / 12.0, signal * signal / 3.0, signal <= 0.5);
    return scene * 3.3967059;
}

fn flog_to_linear(code: f32) -> f32
{
    var a: f32 = 0.555556;
    var b: f32 = 0.009468;
    var c: f32 = 0.344676;
    var d: f32 = 0.790453;
    var e: f32 = 8.735631;
    var f: f32 = 0.092864;
    var cut: f32 = 0.100537775223865;
    if (code >= cut) { return (pow(10.0, (code - d) / c) - b) / a; }
    return (code - f) / e;
}

fn flog2_to_linear(code: f32) -> f32
{
    var a: f32 = 5.555556;
    var b: f32 = 0.064829;
    var c: f32 = 0.245281;
    var d: f32 = 0.384316;
    var e: f32 = 8.799461;
    var f: f32 = 0.092864;
    var cut: f32 = 0.100686685370811;
    if (code >= cut) { return (pow(10.0, (code - d) / c) - b) / a; }
    return (code - f) / e;
}

fn decode_curve(code: f32, curve: u32) -> f32
{
    switch (curve) {
    case 0u: { return apple_log_to_linear(code); }
    case 1u: { return slog3_to_linear(code); }
    case 2u: { return slog2_to_linear(code); }
    case 3u: { return hlg_to_linear(code); }
    case 4u: { return flog_to_linear(code); }
    default: { return flog2_to_linear(code); }
    }
}
