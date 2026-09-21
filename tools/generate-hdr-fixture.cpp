// Synthetic HDR/SDR pair for browser decoder verification. No camera imagery.
// Link against the pinned libultrahdr built by tools/build-hdr-wasm.sh.
#include "ultrahdr_api.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>

static void check(uhdr_error_info_t status) {
  if (status.error_code != UHDR_CODEC_OK) {
    std::fprintf(stderr, "%s\n", status.detail);
    std::exit(1);
  }
}
int main(int argc, char** argv) {
  if (argc < 2) return 1;
  constexpr unsigned w = 96, h = 64;
  const int orientation = argc > 2 ? std::atoi(argv[2]) : 1;
  const auto gamut = argc > 3 ? static_cast<uhdr_color_gamut_t>(std::atoi(argv[3])) : UHDR_CG_BT_709;
  std::vector<_Float16> hdr(w * h * 4);
  std::vector<uint8_t> sdr(w * h * 4);
  for (unsigned y = 0; y < h; y++) for (unsigned x = 0; x < w; x++) {
    const bool highlight = x > 64 && y < 32;
    const float light = highlight ? 4.0f : 0.24f + 0.16f * float(x) / w;
    for (unsigned c = 0; c < 3; c++) {
      const auto i = (y * w + x) * 4 + c;
      const float color = c == 0 ? 1.0f : c == 1 ? 0.8f : 0.6f;
      hdr[i] = light * color;
      const float standard = highlight ? 0.9f * color : light * color * 0.5f;
      sdr[i] = std::lround(255 * (standard <= 0.0031308f ? 12.92f * standard
        : 1.055f * std::pow(standard, 1.0f / 2.4f) - 0.055f));
    }
    hdr[(y * w + x) * 4 + 3] = 1;
    sdr[(y * w + x) * 4 + 3] = 255;
  }
  uhdr_raw_image_t hi{UHDR_IMG_FMT_64bppRGBAHalfFloat, gamut, UHDR_CT_LINEAR,
    UHDR_CR_FULL_RANGE, w, h, {hdr.data(), nullptr, nullptr}, {w, 0, 0}};
  uhdr_raw_image_t lo{UHDR_IMG_FMT_32bppRGBA8888, gamut, UHDR_CT_SRGB,
    UHDR_CR_FULL_RANGE, w, h, {sdr.data(), nullptr, nullptr}, {w, 0, 0}};
  auto* encoder = uhdr_create_encoder();
  if (!encoder) return 1;
  check(uhdr_enc_set_raw_image(encoder, &hi, UHDR_HDR_IMG));
  check(uhdr_enc_set_raw_image(encoder, &lo, UHDR_SDR_IMG));
  check(uhdr_enc_set_quality(encoder, 100, UHDR_BASE_IMG));
  check(uhdr_enc_set_quality(encoder, 100, UHDR_GAIN_MAP_IMG));
  check(uhdr_enc_set_gainmap_scale_factor(encoder, 1));
  // Exif prefix + little-endian TIFF, one orientation entry.
  uint8_t exif[] = {'E','x','i','f',0,0, 'I','I',42,0,8,0,0,0,
    1,0, 0x12,1,3,0,1,0,0,0,static_cast<uint8_t>(orientation),0,0,0, 0,0,0,0};
  uhdr_mem_block_t metadata{exif, sizeof(exif), sizeof(exif)};
  check(uhdr_enc_set_exif_data(encoder, &metadata));
  check(uhdr_encode(encoder));
  auto* result = uhdr_get_encoded_stream(encoder);
  if (!result) return 1;
  std::ofstream file(argv[1], std::ios::binary);
  file.write(static_cast<const char*>(result->data), result->data_sz);
  uhdr_release_encoder(encoder);
  return file ? 0 : 1;
}
