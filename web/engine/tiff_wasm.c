// One worker owns this decoder. libtiff supplies native-order samples; Little CMS
// converts unassociated color directly to linear Rec.2020 float, before delivery.
#include <tiffio.h>
#include <lcms2.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <math.h>

static struct {
    TIFF *tif;
    const unsigned char *input;
    uint64_t input_size, offset;
    unsigned width, height, tile_width, tile_height, blocks, x, y, bw, bh, capacity;
    uint16_t depth, format, photo, samples, planar, orientation, alpha_type;
    int alpha, channels, tiled, palette, linear;
    uint16_t *map[3];
    unsigned char *raw[8];
    size_t raw_capacity, row_bytes;
    float *values, *converted, *coverage;
    cmsHPROFILE source, destination;
    cmsHTRANSFORM transform;
} state;
static char error_text[256];
const char *tiff_decoder_error(void) { return error_text; }
static int fail(const char *message) { snprintf(error_text, sizeof(error_text), "%s", message); return 0; }
static int error_handler(TIFF *tif, void *user, const char *module, const char *format, va_list args) {
    (void)tif; (void)user; (void)module;
    vsnprintf(error_text, sizeof(error_text), format, args); return 1;
}
static int warning_handler(TIFF *tif, void *user, const char *module, const char *format, va_list args) {
    (void)tif; (void)user; (void)module; (void)format; (void)args; return 1;
}
static tmsize_t read_bytes(thandle_t handle, void *output, tmsize_t count) {
    (void)handle;
    if (count < 0 || state.offset > state.input_size) return 0;
    uint64_t size = (uint64_t)count;
    if (size > state.input_size - state.offset) size = state.input_size - state.offset;
    memcpy(output, state.input + state.offset, (size_t)size); state.offset += size;
    return (tmsize_t)size;
}
static tmsize_t no_write(thandle_t h, void *p, tmsize_t n) { (void)h; (void)p; (void)n; return 0; }
static toff_t seek_bytes(thandle_t h, toff_t offset, int whence) {
    (void)h;
    uint64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? state.offset : state.input_size;
    // toff_t is unsigned, but relative offsets may encode a negative displacement.
    if (whence != SEEK_SET && (int64_t)offset < 0) {
        uint64_t back = ~(uint64_t)offset + 1;
        if (back > base) return (toff_t)-1;
        state.offset = base - back;
    } else {
        if (offset > UINT64_MAX - base) return (toff_t)-1;
        state.offset = base + offset;
    }
    return state.offset;
}
static int no_close(thandle_t h) { (void)h; return 0; }
static toff_t input_size(thandle_t h) { (void)h; return state.input_size; }
static int map_bytes(thandle_t h, void **base, toff_t *size) {
    (void)h; *base = (void *)state.input; *size = state.input_size; return 1;
}
static void no_unmap(thandle_t h, void *base, toff_t size) { (void)h; (void)base; (void)size; }
void tiff_decoder_close(void) {
    if (state.tif) TIFFClose(state.tif);
    if (state.transform) cmsDeleteTransform(state.transform);
    if (state.source) cmsCloseProfile(state.source);
    if (state.destination) cmsCloseProfile(state.destination);
    for (unsigned i = 0; i < 8; i++) free(state.raw[i]);
    free(state.values); free(state.converted); free(state.coverage);
    memset(&state, 0, sizeof(state));
}
static cmsHPROFILE default_profile(void) {
    cmsCIExyY white = {.3127, .3290, 1};
    cmsCIExyYTRIPLE primaries = {{.64, .33, 1}, {.30, .60, 1}, {.15, .06, 1}};
    cmsHPROFILE srgb = cmsCreate_sRGBProfile();
    if (!srgb) return NULL;
    cmsToneCurve *curves[3], *owned[3] = {NULL, NULL, NULL};
    for (int c = 0; c < 3; c++) curves[c] = cmsReadTag(srgb, cmsSigRedTRCTag);
    if (state.linear || state.format == SAMPLEFORMAT_IEEEFP) {
        owned[0] = cmsBuildGamma(NULL, 1);
        for (int c = 0; c < 3; c++) curves[c] = owned[0];
    }
    if (!state.linear) {
        float *point, *colors;
        if (TIFFGetField(state.tif, TIFFTAG_WHITEPOINT, &point)) white = (cmsCIExyY){point[0], point[1], 1};
        if (TIFFGetField(state.tif, TIFFTAG_PRIMARYCHROMATICITIES, &colors))
            primaries = (cmsCIExyYTRIPLE){{colors[0], colors[1], 1}, {colors[2], colors[3], 1}, {colors[4], colors[5], 1}};
        uint16_t *tables[3] = {NULL, NULL, NULL};
        if (state.depth <= 16 && TIFFGetField(state.tif, TIFFTAG_TRANSFERFUNCTION, &tables[0], &tables[1], &tables[2])) {
            if (owned[0]) { cmsFreeToneCurve(owned[0]); owned[0] = NULL; }
            for (int c = 0; c < 3; c++) {
                const uint16_t *table = tables[c] ? tables[c] : tables[0];
                owned[c] = cmsBuildTabulatedToneCurve16(NULL, 1u << state.depth, table);
                curves[c] = owned[c];
            }
        }
    }
    cmsHPROFILE result = NULL;
    if (curves[0] && curves[1] && curves[2])
        result = state.channels == 1 ? cmsCreateGrayProfile(&white, curves[0]) : cmsCreateRGBProfile(&white, &primaries, curves);
    for (int c = 0; c < 3; c++) if (owned[c]) cmsFreeToneCurve(owned[c]);
    cmsCloseProfile(srgb); return result;
}
int tiff_decoder_open(const unsigned char *input, unsigned size, int linear_samples) {
    tiff_decoder_close(); error_text[0] = 0;
    if (size < 8 || size > 512u * 1024 * 1024) return fail("Invalid TIFF file size.");
    state.input = input; state.input_size = size; state.linear = linear_samples != 0; state.alpha = -1;
    TIFFOpenOptions *options = TIFFOpenOptionsAlloc();
    if (!options) return fail("Not enough memory to read TIFF.");
    TIFFOpenOptionsSetMaxSingleMemAlloc(options, 256 * 1024 * 1024);
    TIFFOpenOptionsSetMaxCumulatedMemAlloc(options, 384 * 1024 * 1024);
    TIFFOpenOptionsSetErrorHandlerExtR(options, error_handler, NULL);
    TIFFOpenOptionsSetWarningHandlerExtR(options, warning_handler, NULL);
    state.tif = TIFFClientOpenExt("photo", "r", (thandle_t)&state, read_bytes, no_write, seek_bytes,
        no_close, input_size, map_bytes, no_unmap, options);
    TIFFOpenOptionsFree(options);
    if (!state.tif) return 0;
    if (!TIFFGetField(state.tif, TIFFTAG_IMAGEWIDTH, &state.width) || !TIFFGetField(state.tif, TIFFTAG_IMAGELENGTH, &state.height)
        || !state.width || !state.height || state.width > 120000 || state.height > 120000
        || (uint64_t)state.width * state.height > 120000000) return fail("TIFF images above 120 megapixels are not supported.");
    TIFFGetFieldDefaulted(state.tif, TIFFTAG_BITSPERSAMPLE, &state.depth);
    TIFFGetFieldDefaulted(state.tif, TIFFTAG_SAMPLEFORMAT, &state.format);
    TIFFGetFieldDefaulted(state.tif, TIFFTAG_SAMPLESPERPIXEL, &state.samples);
    TIFFGetFieldDefaulted(state.tif, TIFFTAG_PLANARCONFIG, &state.planar);
    TIFFGetFieldDefaulted(state.tif, TIFFTAG_ORIENTATION, &state.orientation);
    if (!TIFFGetField(state.tif, TIFFTAG_PHOTOMETRIC, &state.photo)) return fail("This TIFF does not specify its color interpretation.");
    if (state.orientation < 1 || state.orientation > 8) return fail("Invalid TIFF orientation.");
    if (state.planar != PLANARCONFIG_CONTIG && state.planar != PLANARCONFIG_SEPARATE) return fail("Unsupported TIFF plane layout.");
    if (!((state.format == SAMPLEFORMAT_UINT && (state.depth == 1 || state.depth == 2 || state.depth == 4 || state.depth == 8 || state.depth == 16))
        || (state.format == SAMPLEFORMAT_IEEEFP && state.depth == 32))) return fail("Use unsigned 1/2/4/8/16-bit or floating-point 32-bit TIFF samples.");
    uint16_t compression;
    TIFFGetFieldDefaulted(state.tif, TIFFTAG_COMPRESSION, &compression);
    if (!TIFFIsCODECConfigured(compression)) return fail("This TIFF compression is unavailable. Use lossless LZW, ZIP, PackBits or uncompressed TIFF.");
    if (state.photo == PHOTOMETRIC_YCBCR && compression == COMPRESSION_JPEG && state.depth == 8 && state.planar == PLANARCONFIG_CONTIG) {
        if (!TIFFSetField(state.tif, TIFFTAG_JPEGCOLORMODE, JPEGCOLORMODE_RGB)) return fail("Cannot decode JPEG TIFF color.");
        state.photo = PHOTOMETRIC_RGB;
    }
    state.palette = state.photo == PHOTOMETRIC_PALETTE;
    if (state.photo == PHOTOMETRIC_RGB || state.palette) state.channels = 3;
    else if (state.photo == PHOTOMETRIC_MINISBLACK || state.photo == PHOTOMETRIC_MINISWHITE) state.channels = 1;
    else if (state.photo == PHOTOMETRIC_SEPARATED) {
        uint16_t inkset; TIFFGetFieldDefaulted(state.tif, TIFFTAG_INKSET, &inkset);
        if (inkset != INKSET_CMYK) return fail("Only CMYK separated TIFF images are supported.");
        state.channels = 4;
    } else return fail("Use an RGB, grayscale, palette or color-profiled CMYK TIFF.");
    unsigned base_samples = state.palette ? 1 : (unsigned)state.channels;
    if (state.samples < base_samples || state.samples > 8) return fail("Unsupported TIFF sample count.");
    if (state.palette && (state.format != SAMPLEFORMAT_UINT || state.depth > 16
        || !TIFFGetField(state.tif, TIFFTAG_COLORMAP, &state.map[0], &state.map[1], &state.map[2]))) return fail("Invalid TIFF palette.");
    uint16_t extras = 0, *extra_types = NULL;
    if (TIFFGetField(state.tif, TIFFTAG_EXTRASAMPLES, &extras, &extra_types)) {
        if (extras > state.samples || state.samples - extras < base_samples) return fail("Invalid TIFF extra samples.");
        for (unsigned c = 0; c < extras; c++) {
            if (extra_types[c] == EXTRASAMPLE_ASSOCALPHA || extra_types[c] == EXTRASAMPLE_UNASSALPHA) {
                if (state.alpha >= 0) return fail("Multiple TIFF alpha channels are not supported.");
                state.alpha = state.samples - extras + c; state.alpha_type = extra_types[c];
            }
        }
    }
    uint32_t profile_size; void *profile_bytes;
    if (!state.linear && TIFFGetField(state.tif, TIFFTAG_ICCPROFILE, &profile_size, &profile_bytes)) {
        if (!profile_size || profile_size > 16 * 1024 * 1024) return fail("Invalid TIFF color profile size.");
        state.source = cmsOpenProfileFromMem(profile_bytes, profile_size);
    } else {
        if (state.channels == 4) return fail("CMYK TIFF images need an embedded ICC color profile.");
        state.source = default_profile();
    }
    if (!state.source) return fail("Cannot read this TIFF color profile.");
    cmsColorSpaceSignature space = state.channels == 1 ? cmsSigGrayData : state.channels == 4 ? cmsSigCmykData : cmsSigRgbData;
    if (cmsGetColorSpace(state.source) != space) return fail("The TIFF color profile does not match its pixel channels.");
    cmsCIExyY white = {.3127, .3290, 1};
    cmsCIExyYTRIPLE primaries = {{.708, .292, 1}, {.170, .797, 1}, {.131, .046, 1}};
    cmsToneCurve *linear = cmsBuildGamma(NULL, 1), *curves[3] = {linear, linear, linear};
    if (!linear) return fail("Not enough memory for TIFF color conversion.");
    state.destination = cmsCreateRGBProfile(&white, &primaries, curves); cmsFreeToneCurve(linear);
    if (!state.destination) return fail("Cannot initialize TIFF color conversion.");
    cmsUInt32Number format = state.channels == 1 ? TYPE_GRAY_FLT : state.channels == 4 ? TYPE_CMYK_FLT : TYPE_RGB_FLT;
    state.transform = cmsCreateTransform(state.source, format, state.destination, TYPE_RGBA_FLT,
        INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOOPTIMIZE);
    if (!state.transform) return fail("Cannot convert this TIFF color profile.");
    state.tiled = TIFFIsTiled(state.tif);
    if (state.tiled) {
        if (!TIFFGetField(state.tif, TIFFTAG_TILEWIDTH, &state.tile_width) || !TIFFGetField(state.tif, TIFFTAG_TILELENGTH, &state.tile_height))
            return fail("Invalid TIFF tile dimensions.");
    } else {
        state.tile_width = state.width;
        TIFFGetFieldDefaulted(state.tif, TIFFTAG_ROWSPERSTRIP, &state.tile_height);
        if (state.tile_height > state.height) state.tile_height = state.height;
    }
    if (!state.tile_width || !state.tile_height) return fail("Invalid TIFF block dimensions.");
    uint64_t columns = ((uint64_t)state.width + state.tile_width - 1) / state.tile_width;
    uint64_t rows = ((uint64_t)state.height + state.tile_height - 1) / state.tile_height;
    if (columns * rows > 120000000) return fail("Too many TIFF blocks.");
    state.blocks = (unsigned)(columns * rows);
    return 1;
}
int tiff_decoder_block(unsigned index) {
    if (!state.tif || index >= state.blocks) return fail("Invalid TIFF block.");
    unsigned columns = (unsigned)(((uint64_t)state.width + state.tile_width - 1) / state.tile_width);
    state.x = index % columns * state.tile_width; state.y = index / columns * state.tile_height;
    state.bw = state.width - state.x; if (state.bw > state.tile_width) state.bw = state.tile_width;
    state.bh = state.height - state.y; if (state.bh > state.tile_height) state.bh = state.tile_height;
    uint64_t row_bytes = state.tiled ? TIFFTileRowSize64(state.tif) : TIFFScanlineSize64(state.tif);
    uint64_t bytes = state.tiled ? TIFFTileSize64(state.tif) : TIFFVStripSize64(state.tif, state.bh);
    unsigned planes = state.planar == PLANARCONFIG_SEPARATE ? state.samples : 1;
    uint64_t needed_row = ((uint64_t)state.tile_width * state.depth * (planes == 1 ? state.samples : 1) + 7) / 8;
    if (row_bytes < needed_row || !bytes || bytes < row_bytes * state.bh || bytes * planes > 1024u * 1024 * 1024)
        return fail("This TIFF block is too large or has an invalid layout.");
    state.row_bytes = (size_t)row_bytes;
    if (bytes > state.raw_capacity) {
        for (unsigned c = 0; c < planes; c++) {
            unsigned char *next = realloc(state.raw[c], (size_t)bytes);
            if (!next) return fail("Not enough memory to decode this TIFF block.");
            state.raw[c] = next;
        }
        state.raw_capacity = (size_t)bytes;
    }
    for (unsigned c = 0; c < planes; c++) {
        tmsize_t count = state.tiled
            ? TIFFReadEncodedTile(state.tif, TIFFComputeTile(state.tif, state.x, state.y, 0, c), state.raw[c], (tmsize_t)bytes)
            : TIFFReadEncodedStrip(state.tif, TIFFComputeStrip(state.tif, state.y, c), state.raw[c], (tmsize_t)bytes);
        if (count < 0 || (uint64_t)count < row_bytes * state.bh) {
            if (!error_text[0]) fail("Truncated TIFF pixel data."); return 0;
        }
    }
    state.capacity = 65536 / state.bw; if (!state.capacity) state.capacity = 1;
    size_t pixels = (size_t)state.capacity * state.bw;
    free(state.values); free(state.converted); free(state.coverage);
    state.values = malloc(pixels * state.channels * sizeof(float));
    state.converted = malloc(pixels * 4 * sizeof(float));
    state.coverage = malloc(pixels * sizeof(float));
    if (!state.values || !state.converted || !state.coverage) return fail("Not enough memory for TIFF color conversion.");
    return 1;
}
static float sample(unsigned x, unsigned y, unsigned channel) {
    unsigned plane = state.planar == PLANARCONFIG_SEPARATE ? channel : 0;
    size_t at = state.planar == PLANARCONFIG_SEPARATE ? x : (size_t)x * state.samples + channel;
    const unsigned char *row = state.raw[plane] + (size_t)y * state.row_bytes;
    int white = state.photo == PHOTOMETRIC_MINISWHITE && channel == 0;
    if (state.format == SAMPLEFORMAT_IEEEFP) { float value; memcpy(&value, row + at * 4, 4); return white ? 1 - value : value; }
    unsigned value, maximum = (1u << state.depth) - 1;
    if (state.depth == 16) { uint16_t word; memcpy(&word, row + at * 2, 2); value = word; }
    else if (state.depth == 8) value = row[at];
    else {
        unsigned bit = (unsigned)(at * state.depth);
        value = (row[bit / 8] >> (8 - state.depth - bit % 8)) & maximum;
    }
    return (white ? maximum - value : value) / (float)maximum;
}
float *tiff_decoder_rows(unsigned start, unsigned count) {
    if (!state.converted || !count || count > state.capacity || start >= state.bh || count > state.bh - start) {
        fail("Invalid TIFF row request."); return NULL;
    }
    for (unsigned y = 0; y < count; y++) for (unsigned x = 0; x < state.bw; x++) {
        size_t i = (size_t)y * state.bw + x;
        float alpha = state.alpha < 0 ? 1 : sample(x, start + y, state.alpha);
        alpha = isfinite(alpha) ? fminf(1, fmaxf(0, alpha)) : 0;
        state.coverage[i] = alpha;
        unsigned palette_index = state.palette ? (unsigned)roundf(sample(x, start + y, 0) * ((1u << state.depth) - 1)) : 0;
        for (int c = 0; c < state.channels; c++) {
            float value = state.palette ? state.map[c][palette_index] / 65535.f : sample(x, start + y, c);
            if (state.alpha_type == EXTRASAMPLE_ASSOCALPHA) value = alpha > 0 ? value / alpha : 0;
            if (!isfinite(value)) { fail("TIFF contains nonfinite color samples."); return NULL; }
            state.values[i * state.channels + c] = state.channels == 4 ? value * 100 : value;
        }
    }
    cmsDoTransform(state.transform, state.values, state.converted, state.bw * count);
    for (size_t i = 0; i < (size_t)state.bw * count; i++) state.converted[i * 4 + 3] = state.coverage[i];
    return state.converted;
}
unsigned tiff_decoder_width(void) { return state.width; }
unsigned tiff_decoder_height(void) { return state.height; }
unsigned tiff_decoder_orientation(void) { return state.orientation; }
unsigned tiff_decoder_depth(void) { return state.depth; }
unsigned tiff_decoder_blocks(void) { return state.blocks; }
unsigned tiff_decoder_x(void) { return state.x; }
unsigned tiff_decoder_y(void) { return state.y; }
unsigned tiff_decoder_block_width(void) { return state.bw; }
unsigned tiff_decoder_block_height(void) { return state.bh; }
unsigned tiff_decoder_capacity(void) { return state.capacity; }
