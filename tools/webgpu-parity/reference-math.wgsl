// Binary32 arithmetic shared by the strict WebGPU compiler and parity probe.
// Every arithmetic result rounds to nearest, ties to even, through integer operations.
fn sf_jam(a: u32, n: u32) -> u32 {
  if n == 0u { return a; }
  if n >= 32u { return select(0u, 1u, a != 0u); }
  return (a >> n) | select(0u, 1u, (a << (32u - n)) != 0u);
}
// Normalized significand with 3 guard/round/sticky bits and unbiased exponent.
fn sf_pack(sign: u32, exp0: i32, sig0: u32) -> u32 {
  if sig0 == 0u { return sign; }
  var sig = sig0;
  var ex = exp0;
  let p = 31u - countLeadingZeros(sig);
  if p > 26u { sig = sf_jam(sig, p - 26u); ex += i32(p - 26u); }
  if p < 26u { sig <<= 26u - p; ex -= i32(26u - p); }
  if ex < -126 { sig = sf_jam(sig, u32(-126 - ex)); ex = -126; }
  let bits = sig & 7u;
  var m = (sig >> 3u) + select(0u, 1u, bits > 4u || (bits == 4u && (sig & 8u) != 0u));
  if m >= 0x1000000u { m >>= 1u; ex += 1; }
  if ex > 127 { return sign | 0x7f800000u; }
  let exponent = select(0u, u32(ex + 127), m >= 0x800000u);
  return sign | (exponent << 23u) | (m & 0x7fffffu);
}
struct SFParts { m: u32, e: i32 }
fn sf_parts(bits: u32) -> SFParts {
  let eb = (bits >> 23u) & 255u;
  var m = bits & 0x7fffffu;
  if eb != 0u { return SFParts(m | 0x800000u, i32(eb) - 127); }
  if m == 0u { return SFParts(0u, -126); }
  let n = countLeadingZeros(m) - 8u;
  return SFParts(m << n, -126 - i32(n));
}
fn sf_nan(a: u32) -> bool { return (a & 0x7fffffffu) > 0x7f800000u; }
fn sf_add_bits(aa: u32, bb: u32) -> u32 {
  var a = aa; var b = bb;
  if sf_nan(a) { return a | 0x400000u; }
  if sf_nan(b) { return b | 0x400000u; }
  let ax = a & 0x7fffffffu; let bx = b & 0x7fffffffu;
  if ax == 0x7f800000u || bx == 0x7f800000u {
    if ax == bx && (a ^ b) == 0x80000000u { return 0x7fc00000u; }
    return select(b, a, ax == 0x7f800000u);
  }
  if ax == 0u && bx == 0u { return (a & b) & 0x80000000u; }
  if ax < bx { let t = a; a = b; b = t; }
  let pa = sf_parts(a); let pb = sf_parts(b);
  let sa = pa.m << 3u; let sb = sf_jam(pb.m << 3u, u32(max(pa.e - pb.e, 0)));
  let sign = a & 0x80000000u;
  if ((a ^ b) & 0x80000000u) == 0u { return sf_pack(sign, pa.e, sa + sb); }
  if sa == sb { return 0u; }
  return sf_pack(sign, pa.e, sa - sb);
}
fn sf_mul_wide(a: u32, b: u32) -> vec2<u32> {
  let a0 = a & 65535u; let a1 = a >> 16u;
  let b0 = b & 65535u; let b1 = b >> 16u;
  let p0 = a0*b0; let p1 = a1*b0; let p2 = a0*b1;
  let mid = (p0 >> 16u) + (p1 & 65535u) + (p2 & 65535u);
  return vec2<u32>(a1*b1 + (p1 >> 16u) + (p2 >> 16u) + (mid >> 16u), (mid << 16u) | (p0 & 65535u));
}
fn sf_mul_bits(a: u32, b: u32) -> u32 {
  if sf_nan(a) { return a | 0x400000u; }
  if sf_nan(b) { return b | 0x400000u; }
  let ax = a & 0x7fffffffu; let bx = b & 0x7fffffffu;
  let sign = (a ^ b) & 0x80000000u;
  if ax == 0x7f800000u || bx == 0x7f800000u {
    return select(sign | 0x7f800000u, 0x7fc00000u, ax == 0u || bx == 0u);
  }
  if ax == 0u || bx == 0u { return sign; }
  let pa = sf_parts(a); let pb = sf_parts(b);
  let p = sf_mul_wide(pa.m, pb.m);
  // 24x24 product; keep bit 46 and the following 26 bits, plus sticky.
  let sig = (p.x << 12u) | (p.y >> 20u) | select(0u, 1u, (p.y & 0xfffffu) != 0u);
  return sf_pack(sign, pa.e + pb.e, sig);
}
fn sf_div_bits(a: u32, b: u32) -> u32 {
  if sf_nan(a) { return a | 0x400000u; }
  if sf_nan(b) { return b | 0x400000u; }
  let ax = a & 0x7fffffffu; let bx = b & 0x7fffffffu;
  let sign = (a ^ b) & 0x80000000u;
  if (ax == 0x7f800000u && bx == ax) || (ax == 0u && bx == 0u) { return 0x7fc00000u; }
  if ax == 0x7f800000u || bx == 0u { return sign | 0x7f800000u; }
  if ax == 0u || bx == 0x7f800000u { return sign; }
  let pa = sf_parts(a); let pb = sf_parts(b);
  var r = pa.m; var ex = pa.e - pb.e;
  if r < pb.m { r <<= 1u; ex -= 1; }
  var q = 0u;
  for (var i = 0u; i < 27u; i += 1u) {
    q <<= 1u;
    if r >= pb.m { r -= pb.m; q |= 1u; }
    r <<= 1u;
  }
  q |= select(0u, 1u, r != 0u);
  return sf_pack(sign, ex, q);
}
fn sf_sqrt_bits(a: u32) -> u32 {
  let ax = a & 0x7fffffffu;
  if sf_nan(a) { return a | 0x400000u; }
  if ax == 0u { return a; }
  if (a >> 31u) != 0u { return 0x7fc00000u; }
  if ax == 0x7f800000u { return a; }
  let p = sf_parts(a);
  let odd = u32(p.e) & 1u;
  let shift = 29u + odd;
  let hi = p.m >> (32u - shift); let lo = p.m << shift;
  var q = 0u; var r = 0u;
  for (var i = 27u; i > 0u; i -= 1u) {
    let s = (i - 1u) * 2u;
    var pair = 0u;
    if s >= 32u { pair = (hi >> (s - 32u)) & 3u; }
    else { pair = (lo >> s) & 3u; }
    r = (r << 2u) | pair;
    let trial = (q << 2u) | 1u;
    q <<= 1u;
    if r >= trial { r -= trial; q |= 1u; }
  }
  q |= select(0u, 1u, r != 0u);
  return sf_pack(0u, (p.e - i32(odd))/2, q);
}
fn sf_add(a: f32, b: f32) -> f32 { return bitcast<f32>(sf_add_bits(bitcast<u32>(a), bitcast<u32>(b))); }
fn sf_sub(a: f32, b: f32) -> f32 { return bitcast<f32>(sf_add_bits(bitcast<u32>(a), bitcast<u32>(b) ^ 0x80000000u)); }
fn sf_mul(a: f32, b: f32) -> f32 { return bitcast<f32>(sf_mul_bits(bitcast<u32>(a), bitcast<u32>(b))); }
fn sf_div(a: f32, b: f32) -> f32 { return bitcast<f32>(sf_div_bits(bitcast<u32>(a), bitcast<u32>(b))); }
fn sf_sqrt(a: f32) -> f32 { return bitcast<f32>(sf_sqrt_bits(bitcast<u32>(a))); }
// WGSL translation of Halide's CPU exp/log/pow lowering, with explicit binary32 rounding.
// Copyright (c) 2012-2020 MIT CSAIL, Google, Facebook, Adobe, NVIDIA CORPORATION,
// and other contributors. See HALIDE-LICENSE.txt for the Halide MIT license.
// StrictFloat keeps exp's split ln(2) reduction and adds log's exponent term
// after the polynomial, without reassociation or fused multiply-add operations.
fn sf_float(bits: u32) -> f32 { return bitcast<f32>(bits); }
fn sf_exp(a: f32) -> f32 {
  let scaled=sf_mul(a,1.44269502162933349609375);
  let kr=floor(scaled); let k=i32(kr);
  let x=sf_sub(sf_sub(a,sf_mul(kr,0.6931457519)),sf_mul(kr,1.4286067653e-6));
  let x2=sf_mul(x,x);
  var even=0.00031965933071842413; var odd=0.00119156835564003744;
  even=sf_add(sf_mul(even,x2),0.00848988645943932717);
  odd=sf_add(sf_mul(odd,x2),0.04160188091348320655);
  even=sf_add(sf_mul(even,x2),0.16667983794100929562);
  odd=sf_add(sf_mul(odd,x2),0.49999899033463041098);
  even=sf_add(sf_mul(even,x2),1.0);
  odd=sf_add(sf_mul(odd,x2),1.0);
  let p=sf_add(sf_mul(even,x),odd);
  let biased=k+127;
  if biased>=255 { return sf_float(0x7f800000u); }
  if biased<=0 { return 0.0; }
  return sf_mul(p,bitcast<f32>(u32(biased)<<23u));
}
fn sf_log(a: f32) -> f32 {
  if a<0.0 { return sf_float(0x7fc00000u); }
  if a==0.0 { return sf_float(0xff800000u); }
  let bits=bitcast<u32>(a); let no_exp=bits&0x807fffffu;
  let new_exp=no_exp>>22u; let new_bias=127u-new_exp;
  let old_bias=bitcast<i32>(bits)>>23u;
  let e=old_bias-i32(new_bias);
  let reduced=bitcast<f32>(no_exp|(new_bias<<23u));
  let x=sf_sub(reduced,1.0); let x2=sf_mul(x,x);
  var even=0.05111976432738144643; var odd=-0.11793923497136414580;
  even=sf_add(sf_mul(even,x2),0.14971993724699017569);
  odd=sf_add(sf_mul(odd,x2),-0.16862004708254804686);
  even=sf_add(sf_mul(even,x2),0.19980668101718729313);
  odd=sf_add(sf_mul(odd,x2),-0.24991211576292837737);
  even=sf_add(sf_mul(even,x2),0.33333435275479328386);
  odd=sf_add(sf_mul(odd,x2),-0.50000106292873236491);
  even=sf_add(sf_mul(even,x2),1.0);
  odd=sf_mul(odd,x2);
  let p=sf_add(sf_mul(even,x),odd);
  return sf_add(p,sf_mul(f32(e),0.693147182464599609375));
}
fn sf_pow(a: f32, b: f32) -> f32 {
  let p=sf_exp(sf_mul(sf_log(abs(a)),b));
  if a>0.0 { return p; }
  if b==0.0 { return 1.0; }
  if a==0.0 { return 0.0; }
  let iy=floor(b);
  if b!=iy { return sf_float(0x7fc00000u); }
  if (bitcast<u32>(b)&0x7fffffffu)>=0x4b800000u || i32(iy)%2==0 { return p; }
  return bitcast<f32>(bitcast<u32>(p)^0x80000000u);
}
