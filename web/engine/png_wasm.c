// Lossless 16-bit PNG decode and ICC conversion, owned by one short-lived worker.
// The PNG rows stay 16-bit until Little CMS converts them to linear Rec.2020 float.
#include <png.h>
#include <lcms2.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

static struct {
    const unsigned char *input;
    size_t input_size, offset, row_bytes;
    png_structp png;
    png_infop info;
    png_bytep pixels;
    png_bytep *rows;
    float *converted;
    cmsHPROFILE source, destination;
    cmsHTRANSFORM transform;
    unsigned width, height, capacity;
    int decoded;
} state;
static char error_text[256];
const char *png_decoder_error(void) { return error_text; }
static void failure(const char *message) { snprintf(error_text, sizeof(error_text), "%s", message); }
static void png_failure(png_structp png, png_const_charp message) {
    failure(message); png_longjmp(png, 1);
}
static void png_warning_ignored(png_structp png, png_const_charp message) { (void)png; (void)message; }
static void read_bytes(png_structp png, png_bytep out, png_size_t count) {
    if (count > state.input_size - state.offset) png_error(png, "Truncated PNG data.");
    memcpy(out, state.input + state.offset, count); state.offset += count;
}
void png_decoder_close(void) {
    if (state.png) png_destroy_read_struct(&state.png, &state.info, NULL);
    if (state.transform) cmsDeleteTransform(state.transform);
    if (state.source) cmsCloseProfile(state.source);
    if (state.destination) cmsCloseProfile(state.destination);
    free(state.pixels); free(state.rows); free(state.converted);
    memset(&state, 0, sizeof(state));
}
static uint32_t be32(const unsigned char *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static cmsHPROFILE input_profile(int gray) {
    png_charp name; int method; png_bytep bytes; png_uint_32 size;
    int icc_present = 0, cicp_present = 0;
    unsigned char cicp[4] = {0};
    for (size_t at = 8; at + 12 <= state.input_size;) {
        uint32_t length = be32(state.input + at);
        if ((uint64_t)length + 12 > state.input_size - at) return NULL;
        const unsigned char *type = state.input + at + 4;
        if (!memcmp(type, "iCCP", 4)) icc_present = 1;
        if (!memcmp(type, "cICP", 4)) {
            if (length != 4) return NULL;
            cicp_present = 1; memcpy(cicp, type + 4, 4);
        }
        at += (size_t)length + 12;
        if (!memcmp(type, "IEND", 4)) break;
    }
    // PNG's cICP declaration takes precedence over an ICC profile. SDR sRGB
    // transfer in common RGB primaries is supported; do not misread PQ/HLG as SDR.
    if (cicp_present && (cicp[1] != 13 || cicp[2] != 0 || cicp[3] != 1 ||
        (cicp[0] != 1 && cicp[0] != 9 && cicp[0] != 12))) {
        failure("This PNG color encoding is not supported yet. Use a color-managed SDR PNG or linear EXR.");
        return NULL;
    }
    if (!cicp_present && png_get_iCCP(state.png, state.info, &name, &method, &bytes, &size))
        return cmsOpenProfileFromMem(bytes, size);
    if (!cicp_present && icc_present) {
        failure("The PNG's embedded color profile is invalid."); return NULL;
    }
    cmsHPROFILE srgb = cmsCreate_sRGBProfile();
    if (!srgb) return NULL;
    cmsToneCurve *curve = cmsReadTag(srgb, cmsSigRedTRCTag), *gamma_curve = NULL;
    cmsCIExyY white = {.3127, .3290, 1};
    cmsCIExyYTRIPLE primaries = {{.64, .33, 1}, {.30, .60, 1}, {.15, .06, 1}};
    int intent;
    if (cicp_present) {
        if (cicp[0] == 12) primaries = (cmsCIExyYTRIPLE){{.68, .32, 1}, {.265, .69, 1}, {.15, .06, 1}};
        if (cicp[0] == 9) primaries = (cmsCIExyYTRIPLE){{.708, .292, 1}, {.170, .797, 1}, {.131, .046, 1}};
    } else if (!png_get_sRGB(state.png, state.info, &intent)) {
        double gamma;
        if (png_get_gAMA(state.png, state.info, &gamma) && isfinite(gamma) && gamma > 0) {
            gamma_curve = cmsBuildGamma(NULL, 1 / gamma); curve = gamma_curve;
        }
        double wx, wy, rx, ry, gx, gy, bx, by;
        if (png_get_cHRM(state.png, state.info, &wx, &wy, &rx, &ry, &gx, &gy, &bx, &by)) {
            white = (cmsCIExyY){wx, wy, 1};
            primaries = (cmsCIExyYTRIPLE){{rx, ry, 1}, {gx, gy, 1}, {bx, by, 1}};
        }
    }
    cmsToneCurve *curves[3] = {curve, curve, curve};
    cmsHPROFILE profile = curve ? (gray ? cmsCreateGrayProfile(&white, curve) : cmsCreateRGBProfile(&white, &primaries, curves)) : NULL;
    if (gamma_curve) cmsFreeToneCurve(gamma_curve);
    cmsCloseProfile(srgb);
    return profile;
}
int png_decoder_open(const unsigned char *input, unsigned size) {
    png_decoder_close(); error_text[0] = 0;
    if (size < 33 || png_sig_cmp(input, 0, 8)) { failure("Invalid PNG file."); return -1; }
    if (input[24] != 16) return 0;
    state.input = input; state.input_size = size;
    state.png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, png_failure, png_warning_ignored);
    if (!state.png) { failure("Not enough memory to decode PNG."); return -1; }
    state.info = png_create_info_struct(state.png);
    if (!state.info) { failure("Not enough memory to decode PNG."); return -1; }
    if (setjmp(png_jmpbuf(state.png))) return -1;
    png_set_read_fn(state.png, NULL, read_bytes);
    png_set_user_limits(state.png, 100000, 100000);
    png_set_chunk_malloc_max(state.png, 16 * 1024 * 1024);
    png_set_crc_action(state.png, PNG_CRC_ERROR_QUIT, PNG_CRC_ERROR_QUIT);
    png_read_info(state.png, state.info);
    state.width = png_get_image_width(state.png, state.info);
    state.height = png_get_image_height(state.png, state.info);
    if (!state.width || !state.height || (uint64_t)state.width * state.height > 120000000) {
        failure("PNG images above 120 megapixels are not supported."); return -1;
    }
    int type = png_get_color_type(state.png, state.info);
    int gray = !(type & PNG_COLOR_MASK_COLOR);
    state.source = input_profile(gray);
    if (!state.source) { if (!error_text[0]) failure("Cannot read this PNG color profile."); return -1; }
    if (cmsGetColorSpace(state.source) != (gray ? cmsSigGrayData : cmsSigRgbData)) {
        failure("The PNG color profile does not match its pixel channels."); return -1;
    }
    cmsCIExyY white = {.3127, .3290, 1};
    cmsCIExyYTRIPLE primaries = {{.708, .292, 1}, {.170, .797, 1}, {.131, .046, 1}};
    cmsToneCurve *linear = cmsBuildGamma(NULL, 1), *curves[3] = {linear, linear, linear};
    if (!linear) { failure("Not enough memory for PNG color conversion."); return -1; }
    state.destination = cmsCreateRGBProfile(&white, &primaries, curves);
    cmsFreeToneCurve(linear);
    if (!state.destination) { failure("Cannot initialize PNG color conversion."); return -1; }
    state.transform = cmsCreateTransform(state.source, gray ? TYPE_GRAYA_16 : TYPE_RGBA_16,
        state.destination, TYPE_RGBA_FLT, INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_COPY_ALPHA | cmsFLAGS_NOOPTIMIZE);
    if (!state.transform) { failure("Cannot convert this PNG color profile."); return -1; }
    if (png_get_valid(state.png, state.info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(state.png);
    else if (!(type & PNG_COLOR_MASK_ALPHA)) png_set_add_alpha(state.png, 65535, PNG_FILLER_AFTER);
    // WebAssembly is little-endian; libpng's file samples are big-endian.
    png_set_swap(state.png);
    png_set_interlace_handling(state.png);
    png_read_update_info(state.png, state.info);
    state.row_bytes = png_get_rowbytes(state.png, state.info);
    if (png_get_bit_depth(state.png, state.info) != 16 || state.row_bytes != (size_t)state.width * (gray ? 4 : 8)) {
        failure("Unexpected PNG sample layout."); return -1;
    }
    state.pixels = malloc(state.row_bytes * state.height);
    state.rows = malloc(sizeof(png_bytep) * state.height);
    state.capacity = 65536 / state.width; if (!state.capacity) state.capacity = 1;
    state.converted = malloc((size_t)state.capacity * state.width * 4 * sizeof(float));
    if (!state.pixels || !state.rows || !state.converted) { failure("Not enough memory to decode this PNG."); return -1; }
    for (unsigned y = 0; y < state.height; y++) state.rows[y] = state.pixels + y * state.row_bytes;
    return 1;
}
int png_decoder_decode(void) {
    if (!state.png || !state.rows) return 0;
    if (setjmp(png_jmpbuf(state.png))) return 0;
    png_read_image(state.png, state.rows); png_read_end(state.png, NULL); state.decoded = 1; return 1;
}
float *png_decoder_rows(unsigned start, unsigned count) {
    if (!state.decoded || !count || count > state.capacity || start >= state.height || count > state.height - start) return NULL;
    cmsDoTransform(state.transform, state.pixels + start * state.row_bytes, state.converted, state.width * count);
    return state.converted;
}
unsigned png_decoder_width(void) { return state.width; }
unsigned png_decoder_height(void) { return state.height; }
unsigned png_decoder_capacity(void) { return state.capacity; }
