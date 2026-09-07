#include <libraw/libraw.h>
#include <cstdint>
#include <cmath>
#include <memory>
#include <emscripten.h>

EM_JS(void, report_raw_progress, (const char *stage, int iteration, int expected), {
    if (globalThis.onRawProgress)
        globalThis.onRawProgress(UTF8ToString(stage), iteration, expected);
});

namespace {
std::unique_ptr<LibRaw> decoder;
libraw_processed_image_t *image = nullptr;
int status = 0;
float sceneScale = 1;
constexpr uint64_t maxPixels = 120000000;

int progress(void *, LibRaw_progress stage, int iteration, int expected) {
    const char *label = nullptr;
    switch (stage) {
        case LIBRAW_PROGRESS_OPEN: label = "Reading camera metadata"; break;
        case LIBRAW_PROGRESS_IDENTIFY: label = "Identifying camera and sensor"; break;
        case LIBRAW_PROGRESS_SIZE_ADJUST: label = "Reading sensor dimensions"; break;
        case LIBRAW_PROGRESS_LOAD_RAW: label = "Unpacking RAW sensor data"; break;
        case LIBRAW_PROGRESS_RAW2_IMAGE: label = "Preparing sensor pixels"; break;
        case LIBRAW_PROGRESS_REMOVE_ZEROES:
        case LIBRAW_PROGRESS_BAD_PIXELS: label = "Correcting sensor pixels"; break;
        case LIBRAW_PROGRESS_DARK_FRAME: label = "Subtracting dark frame"; break;
        case LIBRAW_PROGRESS_SCALE_COLORS: label = "Applying camera white balance"; break;
        case LIBRAW_PROGRESS_PRE_INTERPOLATE: label = "Preparing demosaic"; break;
        case LIBRAW_PROGRESS_FOVEON_INTERPOLATE:
        case LIBRAW_PROGRESS_INTERPOLATE: label = "Demosaicing sensor colors"; break;
        case LIBRAW_PROGRESS_MIX_GREEN: label = "Combining green channels"; break;
        case LIBRAW_PROGRESS_MEDIAN_FILTER: label = "Reducing color artifacts"; break;
        case LIBRAW_PROGRESS_HIGHLIGHTS: label = "Blending clipped highlights"; break;
        case LIBRAW_PROGRESS_FUJI_ROTATE:
        case LIBRAW_PROGRESS_FLIP: label = "Applying camera orientation"; break;
        case LIBRAW_PROGRESS_APPLY_PROFILE: label = "Applying camera color profile"; break;
        case LIBRAW_PROGRESS_CONVERT_RGB: label = "Converting to linear working color"; break;
        case LIBRAW_PROGRESS_STRETCH: label = "Correcting pixel aspect ratio"; break;
        default: break;
    }
    if (label) report_raw_progress(label, iteration, expected);
    return 0;
}
}

extern "C" {
void raw_close() {
    if (image) LibRaw::dcraw_clear_mem(image);
    image = nullptr;
    decoder.reset();
    sceneScale = 1;
}
int raw_open(void *bytes, unsigned length) {
    raw_close();
    decoder = std::make_unique<LibRaw>();
    decoder->set_progress_handler(progress, nullptr);
    decoder->imgdata.rawparams.max_raw_memory_mb = 768;
    auto &p = decoder->imgdata.params;
    p.output_color = 8; // Linear Rec.2020, the film engine's scene space.
    p.output_bps = 16;
    p.gamm[0] = p.gamm[1] = 1;
    p.no_auto_bright = 1;
    p.adjust_maximum_thr = 0; // Keep the camera's white level, not the frame's peak.
    p.use_camera_wb = 1;
    p.use_camera_matrix = 1;
    // Repair chroma where sensor channels clip at different white-balance gains.
    // Unclip (1) leaves those unequal channels magenta after color conversion.
    p.highlight = 2;
    p.user_qual = 3;
    p.user_flip = -1; // Apply the file's orientation exactly once.
    status = decoder->open_buffer(bytes, length);
    if (!status) {
        const auto &s = decoder->imgdata.sizes;
        if (!s.width || !s.height || uint64_t(s.width) * s.height > maxPixels
            || uint64_t(s.raw_width) * s.raw_height > maxPixels + 4000000)
            status = LIBRAW_TOO_BIG;
    }
    return status;
}
int raw_unpack() {
    return status = decoder ? decoder->unpack() : LIBRAW_OUT_OF_ORDER_CALL;
}
int raw_process() {
    if (!decoder) return status = LIBRAW_OUT_OF_ORDER_CALL;
    status = decoder->dcraw_process();
    if (!status) image = decoder->dcraw_make_mem_image(&status);
    if (!status && (!image || image->type != LIBRAW_IMAGE_BITMAP || image->bits != 16
        || (image->colors != 3 && image->colors != 1)
        || uint64_t(image->width) * image->height > maxPixels))
        status = LIBRAW_DATA_ERROR;
    if (!status) {
        const auto &color = decoder->imgdata.color;
        // LibRaw normalizes camera multipliers to their maximum to fit RGB16.
        // Restore the camera's green-channel exposure reference later, in float,
        // so daylight and tungsten white balance keep the same scene grey level.
        int reference = 1;
        for (int channel = 0; channel < 4; ++channel)
            if (decoder->imgdata.idata.cdesc[channel] == 'G') {
                reference = channel;
                break;
            }
        sceneScale = image->colors == 1 ? 1 : 1 / color.pre_mul[reference];
        const float baseline = color.dng_levels.baseline_exposure;
        // -999 is LibRaw's missing-value sentinel. Vendor RAWs need no guessed
        // baseline; honor the explicit DNG tag when the file supplies one.
        if (decoder->imgdata.idata.dng_version && baseline != -999.f)
            sceneScale *= std::exp2(baseline);
        if (!std::isfinite(sceneScale) || sceneScale <= 0)
            status = LIBRAW_DATA_ERROR;
    }
    return status;
}
unsigned raw_width() { return image ? image->width : 0; }
unsigned raw_height() { return image ? image->height : 0; }
unsigned raw_colors() { return image ? image->colors : 0; }
float raw_scene_scale() { return sceneScale; }
void *raw_pixels() { return image ? image->data : nullptr; }
const char *raw_error() { return libraw_strerror(status); }
}
