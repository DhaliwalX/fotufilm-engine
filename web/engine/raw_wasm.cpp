#include <libraw/libraw.h>
#include <cstdint>
#include <memory>

namespace {
std::unique_ptr<LibRaw> decoder;
libraw_processed_image_t *image = nullptr;
int status = 0;
constexpr uint64_t maxPixels = 120000000;
}

extern "C" {
void raw_close() {
    if (image) LibRaw::dcraw_clear_mem(image);
    image = nullptr;
    decoder.reset();
}
int raw_open(void *bytes, unsigned length) {
    raw_close();
    decoder = std::make_unique<LibRaw>();
    decoder->imgdata.rawparams.max_raw_memory_mb = 768;
    auto &p = decoder->imgdata.params;
    p.output_color = 8; // Linear Rec.2020, the film engine's scene space.
    p.output_bps = 16;
    p.gamm[0] = p.gamm[1] = 1;
    p.no_auto_bright = 1;
    p.use_camera_wb = 1;
    p.use_camera_matrix = 1;
    p.highlight = 1;
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
    return status;
}
unsigned raw_width() { return image ? image->width : 0; }
unsigned raw_height() { return image ? image->height : 0; }
unsigned raw_colors() { return image ? image->colors : 0; }
void *raw_pixels() { return image ? image->data : nullptr; }
const char *raw_error() { return libraw_strerror(status); }
}
