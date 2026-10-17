// The engine's pictures are Display P3 with the sRGB transfer; Flutter draws the window in sRGB.
// Applied as an image filter over the resampled picture: decode, convert the primaries, encode.
#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform sampler2D u_texture;

out vec4 fragColor;

vec3 decode(vec3 c) {
  return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

vec3 encode(vec3 c) {
  return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

void main() {
  vec4 texel = texture(u_texture, FlutterFragCoord().xy / u_size);
  if (texel.a <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }
  vec3 p3 = decode(texel.rgb / texel.a);
  // Display P3 → linear sRGB (both D65).
  vec3 srgb = vec3(
      1.2249401 * p3.r - 0.2249404 * p3.g,
      -0.0420569 * p3.r + 1.0420571 * p3.g,
      -0.0196376 * p3.r - 0.0786361 * p3.g + 1.0982735 * p3.b);
  fragColor = vec4(encode(clamp(srgb, 0.0, 1.0)) * texel.a, texel.a);
}
