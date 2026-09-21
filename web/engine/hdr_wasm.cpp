// JPEG gain-map decode only. Color conversion and document interpretation live
// outside the codec so preview and full-resolution rendering share one source.
#include "ultrahdr_api.h"
#include <cstdint>
#include <cstdio>

static uhdr_codec_private_t* decoder = nullptr;
static char error_text[512] = {};
static bool checked(uhdr_error_info_t result) {
  if (result.error_code == UHDR_CODEC_OK) return true;
  std::snprintf(error_text, sizeof(error_text), "%s",
                result.has_detail ? result.detail : "HDR decoding failed.");
  return false;
}

extern "C" {
void hdr_close() {
  if (decoder) uhdr_release_decoder(decoder);
  decoder = nullptr;
}
// 0: ordinary JPEG, 1: supported gain-map JPEG, -1: invalid/oversized HDR.
int hdr_open(void* bytes, int length) {
  hdr_close();
  error_text[0] = 0;
  if (!bytes || length <= 0 || !is_uhdr_image(bytes, length)) return 0;
  decoder = uhdr_create_decoder();
  if (!decoder) {
    std::snprintf(error_text, sizeof(error_text), "Not enough memory to open HDR.");
    return -1;
  }
  uhdr_compressed_image_t image{bytes, static_cast<size_t>(length),
    static_cast<size_t>(length), UHDR_CG_UNSPECIFIED, UHDR_CT_UNSPECIFIED,
    UHDR_CR_UNSPECIFIED};
  if (!checked(uhdr_dec_set_image(decoder, &image)) ||
      !checked(uhdr_dec_set_out_img_format(decoder, UHDR_IMG_FMT_64bppRGBAHalfFloat)) ||
      !checked(uhdr_dec_set_out_color_transfer(decoder, UHDR_CT_LINEAR)) ||
      !checked(uhdr_dec_probe(decoder))) return -1;
  const int w = uhdr_dec_get_image_width(decoder), h = uhdr_dec_get_image_height(decoder);
  if (w <= 0 || h <= 0 || uint64_t(w) * uint64_t(h) > 40000000) {
    std::snprintf(error_text, sizeof(error_text), "HDR photos above 40 megapixels are not supported.");
    return -1;
  }
  return 1;
}
int hdr_decode() {
  if (!decoder) return 0;
  // The decoder's default applies the complete gain map, independent of the
  // monitor's headroom. Film receives the file's decoded highlight range.
  return checked(uhdr_decode(decoder)) ? 1 : 0;
}
int hdr_width() { return decoder ? uhdr_dec_get_image_width(decoder) : 0; }
int hdr_height() { return decoder ? uhdr_dec_get_image_height(decoder) : 0; }
int hdr_gamut() {
  auto* image = decoder ? uhdr_get_decoded_image(decoder) : nullptr;
  return image ? image->cg : -1;
}
int hdr_stride() {
  auto* image = decoder ? uhdr_get_decoded_image(decoder) : nullptr;
  return image ? image->stride[UHDR_PLANE_PACKED] : 0;
}
void* hdr_pixels() {
  auto* image = decoder ? uhdr_get_decoded_image(decoder) : nullptr;
  return image ? image->planes[UHDR_PLANE_PACKED] : nullptr;
}
const char* hdr_error() { return error_text; }
}
