@group(0) @binding(0) var<storage, read> source: array<u32>;
@group(0) @binding(1) var<storage, read> p: array<u32>;
@group(0) @binding(2) var<storage, read_write> output: array<vec4f>;
fn f(i: u32) -> f32 { return bitcast<f32>(p[i]); }
fn byte(offset: u32) -> u32 { return (source[offset / 4u] >> ((offset % 4u)*8u)) & 255u; }
fn plane(i: u32, x: u32, y: u32) -> f32 {
    let offset = p[8u+i] + y*p[11u+i] + x*p[5];
    if (p[5] == 2u) { return f32(byte(offset) | (byte(offset+1u)<<8u)); }
    return f32(byte(offset));
}
fn transfer(code: f32) -> f32 {
    switch p[35] {
        case 0u: { return decode_curve(code, p[34]) / 0.9; }
        case 1u: { return hlg_to_linear(code) / 0.9; }
        case 2u: {
            let power = pow(clamp(code, 0.0, 1.0), 32.0/2523.0);
            return pow(max(power-3424.0/4096.0, 0.0) / max(2413.0/128.0-2392.0/128.0*power, 1e-12), 16384.0/2610.0)*10000.0/203.0;
        }
        case 3u: { return code; }
        case 4u: {
            let v = max(code, 0.0);
            if (v <= 0.04045) { return v/12.92; }
            return pow((v+0.055)/1.055, 2.4);
        }
        default: {
            let v = max(code, 0.0);
            if (v < 0.081) { return v/4.5; }
            return pow((v+0.099)/1.099, 1.0/0.45);
        }
    }
}
fn pixel(x: u32, y: u32) -> vec3f {
    var code: vec3f;
    if (p[6] != 0u) {
        let offset = p[8]+y*p[11]+x*4u;
        let red = select(0u, 2u, p[6] == 2u);
        code = vec3f(f32(byte(offset+red)), f32(byte(offset+1u)), f32(byte(offset+2u-red)))/255.0;
    } else {
        let cx = x/p[14]; let cy = y/p[15];
        let yy = (plane(0u,x,y)-f(30u))/f(31u);
        var u: f32; var v: f32;
        if (p[7] != 0u) { u=plane(1u,cx*2u,cy); v=plane(1u,cx*2u+1u,cy); }
        else { u=plane(1u,cx,cy); v=plane(2u,cx,cy); }
        u=(u-f(32u))/f(33u); v=(v-f(32u))/f(33u);
        let r=yy+2.0*(1.0-f(16u))*v; let b=yy+2.0*(1.0-f(17u))*u;
        code=vec3f(r,(yy-f(16u)*r-f(17u)*b)/(1.0-f(16u)-f(17u)),b);
    }
    let v=vec3f(transfer(code.r),transfer(code.g),transfer(code.b));
    let rgb=vec3f(dot(vec3f(f(20u),f(21u),f(22u)),v),dot(vec3f(f(23u),f(24u),f(25u)),v),dot(vec3f(f(26u),f(27u),f(28u)),v));
    // PQ is display light: the inverse HLG OOTF at 203 cd/m2 returns it to the scene (BT.2408).
    if (p[35] == 2u) {
        let lum=dot(vec3f(0.2627,0.678,0.0593),rgb);
        if (lum <= 1e-6) { return vec3f(0.0); }
        return rgb*pow(lum,(1.0-1.2)/1.2);
    }
    return rgb;
}
// Bilinear source position of output index i along an axis of d outputs over s inputs, as
// (whole texel, fraction). Exact integer arithmetic: f32 texel centres lose ~1e-4 of a texel
// at 4K, which S-Log3's sub-black codes (about -6 linear) turn into visible error.
fn axis(i: u32, d: u32, s: u32) -> vec2f {
    let num=i32((2u*i+1u)*s)-i32(d);
    if (num <= 0) { return vec2f(0.0); }
    let whole=u32(num)/(2u*d);
    if (whole >= s-1u) { return vec2f(f32(s-1u),0.0); }
    return vec2f(f32(whole),f32(u32(num)%(2u*d))/f32(2u*d));
}
@compute @workgroup_size(16,16)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= p[2] || id.y >= p[3]) { return; }
    var result: vec3f;
    if (p[4] == 0u && p[0] == p[2] && p[1] == p[3]) { result=pixel(id.x,id.y); }
    else if (p[4] == 180u && p[0] == p[2] && p[1] == p[3]) { result=pixel(p[0]-1u-id.x,p[1]-1u-id.y); }
    else if (p[4] == 90u && p[0] == p[3] && p[1] == p[2]) { result=pixel(id.y,p[1]-1u-id.x); }
    else if (p[4] == 270u && p[0] == p[3] && p[1] == p[2]) { result=pixel(p[0]-1u-id.y,id.x); }
    else {
        var sx: vec2f; var sy: vec2f;
        switch p[4] {
            case 90u: { sx=axis(id.y,p[3],p[0]); sy=axis(p[2]-1u-id.x,p[2],p[1]); }
            case 180u: { sx=axis(p[2]-1u-id.x,p[2],p[0]); sy=axis(p[3]-1u-id.y,p[3],p[1]); }
            case 270u: { sx=axis(p[3]-1u-id.y,p[3],p[0]); sy=axis(id.x,p[2],p[1]); }
            default: { sx=axis(id.x,p[2],p[0]); sy=axis(id.y,p[3],p[1]); }
        }
        let lo=vec2u(u32(sx.x),u32(sy.x)); let hi=min(lo+1u,vec2u(p[0]-1u,p[1]-1u)); let a=vec2f(sx.y,sy.y);
        result=mix(mix(pixel(lo.x,lo.y),pixel(hi.x,lo.y),a.x),mix(pixel(lo.x,hi.y),pixel(hi.x,hi.y),a.x),a.y);
    }
    output[id.y*p[2]+id.x]=vec4f(result,1.0);
}
