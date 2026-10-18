// JPEG through libjpeg-turbo, with its ICC profile and Exif record; for thumbnails, decoded at a
// reduced DCT scale.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#include <algorithm>
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

Raster decodeJPEGReduced(const uint8_t *bytes, size_t length, uint32_t minEdge) {
    Raster raster;
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
    jpeg_mem_src(&info, bytes, static_cast<unsigned long>(length));
    jpeg_save_markers(&info, JPEG_APP0 + 1, 0xFFFF);
    jpeg_save_markers(&info, JPEG_APP0 + 2, 0xFFFF);
    jpeg_read_header(&info, TRUE);
    for (auto *marker = info.marker_list; marker; marker = marker->next) {
        if (marker->marker != JPEG_APP0 + 1 || marker->data_length <= 6
            || std::memcmp(marker->data, "Exif\0\0", 6) != 0)
            continue;
        try {
            ffc_capture capture{};
            raster.orientation = parseExif(marker->data + 6, marker->data_length - 6, capture).orientation;
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
    // The inverse DCT runs at 1/8, 1/4 or 1/2 scale: only the coefficients the picture needs.
    const uint32_t longEdge = std::max(info.image_width, info.image_height);
    unsigned denominator = 1;
    for (unsigned candidate : {8u, 4u, 2u}) {
        if ((longEdge + candidate - 1) / candidate >= minEdge) {
            denominator = candidate;
            break;
        }
    }
    info.scale_num = 1;
    info.scale_denom = denominator;
    info.dct_method = JDCT_IFAST;
    info.do_fancy_upsampling = FALSE;
    const bool grey = info.jpeg_color_space == JCS_GRAYSCALE;
    info.out_color_space = grey ? JCS_GRAYSCALE : JCS_RGB;
    jpeg_start_decompress(&info);
    raster.width = info.output_width;
    raster.height = info.output_height;
    raster.channels = grey ? 1 : 3;
    raster.samples = Samples::U8;
    const size_t rowBytes = size_t(raster.width) * raster.channels;
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
