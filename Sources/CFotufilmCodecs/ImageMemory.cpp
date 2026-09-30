// Shared ownership boundary, also used by hosts which link only the RAW decoder.
#if !defined(__APPLE__) || defined(FFC_PORTABLE_CODECS)
#include "fotufilm_codecs.h"
#include <cstdlib>

extern "C" void ffc_image_free(ffc_image *image) {
    if (!image) return;
    std::free(image->rgba);
    std::free(image->capture.exif);
    *image = {};
}
#endif
