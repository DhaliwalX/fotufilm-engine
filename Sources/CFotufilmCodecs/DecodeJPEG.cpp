// JPEG through libjpeg-turbo, with its ICC profile and Exif record.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <jpeglib.h>

namespace ffc {
namespace {

struct JPEGError {
    jpeg_error_mgr manager;
    std::jmp_buf jump;
    char message[JMSG_LENGTH_MAX];
};

void jpegExit(j_common_ptr info) {
    auto *error = reinterpret_cast<JPEGError *>(info->err);
    (*info->err->format_message)(info, error->message);
    std::longjmp(error->jump, 1);
}

void jpegQuiet(j_common_ptr, int) {}

} // namespace

Raster decodeJPEG(const std::string &path, ffc_capture &capture) {
    Raster raster;
    std::vector<uint8_t> file = readFile(path);
    jpeg_decompress_struct info;
    JPEGError error;
    info.err = jpeg_std_error(&error.manager);
    error.manager.error_exit = jpegExit;
    error.manager.emit_message = jpegQuiet;
    // Nothing with a destructor is created between here and the last libjpeg call.
    if (setjmp(error.jump)) {
        jpeg_destroy_decompress(&info);
        throw Failure(std::string("The JPEG could not be read: ") + error.message);
    }
    jpeg_create_decompress(&info);
    jpeg_mem_src(&info, file.data(), static_cast<unsigned long>(file.size()));
    jpeg_save_markers(&info, JPEG_APP0 + 1, 0xFFFF);
    jpeg_save_markers(&info, JPEG_APP0 + 2, 0xFFFF);
    jpeg_read_header(&info, TRUE);

    for (auto *marker = info.marker_list; marker; marker = marker->next) {
        if (marker->marker != JPEG_APP0 + 1 || marker->data_length <= 6
            || std::memcmp(marker->data, "Exif\0\0", 6) != 0)
            continue;
        try {
            raster.orientation = parseExif(marker->data + 6, marker->data_length - 6, capture).orientation;
            keepExif(marker->data + 6, marker->data_length - 6, capture);
        } catch (const Failure &) {
        }
        break;
    }
    JOCTET *icc = nullptr;
    unsigned int iccLength = 0;
    if (jpeg_read_icc_profile(&info, &icc, &iccLength) && icc) {
        raster.encoding.kind = Encoding::Profile;
        raster.encoding.icc.assign(icc, icc + iccLength);
        std::free(icc);
    }
    if (info.jpeg_color_space == JCS_CMYK || info.jpeg_color_space == JCS_YCCK) {
        jpeg_destroy_decompress(&info);
        throw Failure("CMYK JPEGs are not supported.");
    }
    bool grey = info.jpeg_color_space == JCS_GRAYSCALE;
    info.out_color_space = grey ? JCS_GRAYSCALE : JCS_RGB;
    jpeg_start_decompress(&info);
    raster.width = info.output_width;
    raster.height = info.output_height;
    raster.channels = grey ? 1 : 3;
    raster.samples = Samples::U8;
    capture.stored_width = raster.width;
    capture.stored_height = raster.height;
    size_t rowBytes = size_t(raster.width) * raster.channels;
    raster.data.resize(rowBytes * raster.height);
    while (info.output_scanline < info.output_height) {
        JSAMPROW row = raster.data.data() + rowBytes * info.output_scanline;
        jpeg_read_scanlines(&info, &row, 1);
    }
    jpeg_finish_decompress(&info);
    jpeg_destroy_decompress(&info);
    return raster;
}

} // namespace ffc

#endif
