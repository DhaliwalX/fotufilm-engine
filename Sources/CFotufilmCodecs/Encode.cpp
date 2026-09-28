// Stills as the Mac app writes them: Display P3 RGB with the Display P3 profile, the kept Exif
// record, PNG and TIFF at 8 or 16 bits, JPEG and HEIC at 8 bits. A TIFF carries only the Exif
// record's text fields (camera, software, date, artist, copyright); the others carry it whole.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#include <algorithm>
#include <csetjmp>
#include <cstdio>
#include <cstring>
#include <memory>

#include <jpeglib.h>
#include <png.h>
#include <tiffio.h>
#if __has_include(<libheif/heif.h>)
#define FFC_HAS_HEIF 1
#include <libheif/heif.h>
#endif

namespace ffc {
namespace {

using File = std::unique_ptr<FILE, int (*)(FILE *)>;

File create(const std::string &path) {
    File file(std::fopen(path.c_str(), "wb"), std::fclose);
    if (!file) throw Failure("The image could not be written to " + path + ".");
    return file;
}

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

std::vector<uint8_t> exifMarker(const std::vector<uint8_t> &exif) {
    std::vector<uint8_t> marker{'E', 'x', 'i', 'f', 0, 0};
    marker.insert(marker.end(), exif.begin(), exif.end());
    return marker;
}

} // namespace

void encodePNG(const std::string &path, const uint8_t *rgb, int bits, uint32_t width,
               uint32_t height, const std::vector<uint8_t> &exif) {
    File file = create(path);
    std::vector<png_bytep> rows(height);
    const size_t rowBytes = size_t(width) * 3 * (bits / 8);
    for (uint32_t y = 0; y < height; ++y) rows[y] = const_cast<png_bytep>(rgb + rowBytes * y);
    const auto &icc = displayP3Profile();
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop info = png ? png_create_info_struct(png) : nullptr;
    if (!info) {
        png_destroy_write_struct(&png, nullptr);
        throw Failure("The image could not be encoded.");
    }
    // Nothing with a destructor is created between here and the last libpng call.
    if (setjmp(png_jmpbuf(png))) {
        png_destroy_write_struct(&png, &info);
        throw Failure("The image could not be written to " + path + ".");
    }
    png_init_io(png, file.get());
    png_set_IHDR(png, info, width, height, bits, PNG_COLOR_TYPE_RGB, PNG_INTERLACE_NONE,
                 PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_set_iCCP(png, info, "Display P3", PNG_COMPRESSION_TYPE_BASE, icc.data(),
                 png_uint_32(icc.size()));
    if (!exif.empty())
        png_set_eXIf_1(png, info, png_uint_32(exif.size()), const_cast<png_bytep>(exif.data()));
    png_write_info(png, info);
    if (bits == 16) png_set_swap(png); // from host (little-endian) order
    png_write_image(png, rows.data());
    png_write_end(png, nullptr);
    png_destroy_write_struct(&png, &info);
    if (std::fflush(file.get()) != 0) throw Failure("The image could not be written to " + path + ".");
}

void encodeJPEG(const std::string &path, const uint8_t *rgb, uint32_t width, uint32_t height,
                float quality, const std::vector<uint8_t> &exif) {
    File file = create(path);
    const auto &icc = displayP3Profile();
    const std::vector<uint8_t> marker = exif.empty() ? std::vector<uint8_t>() : exifMarker(exif);
    if (marker.size() > 65533) throw Failure("The Exif record is too large for a JPEG.");
    jpeg_compress_struct info;
    JPEGError error;
    info.err = jpeg_std_error(&error.manager);
    error.manager.error_exit = jpegExit;
    // Nothing with a destructor is created between here and the last libjpeg call.
    if (setjmp(error.jump)) {
        jpeg_destroy_compress(&info);
        throw Failure(std::string("The JPEG could not be written: ") + error.message);
    }
    jpeg_create_compress(&info);
    jpeg_stdio_dest(&info, file.get());
    info.image_width = width;
    info.image_height = height;
    info.input_components = 3;
    info.in_color_space = JCS_RGB;
    jpeg_set_defaults(&info);
    jpeg_set_quality(&info, std::max(1, std::min(100, int(quality * 100 + 0.5f))), TRUE);
    info.optimize_coding = TRUE;
    // Full-resolution colour at high qualities, as a photograph's export wants.
    if (quality >= 0.9f) {
        for (int c = 0; c < 3; ++c) {
            info.comp_info[c].h_samp_factor = 1;
            info.comp_info[c].v_samp_factor = 1;
        }
    }
    if (!marker.empty()) info.write_JFIF_header = FALSE;
    jpeg_start_compress(&info, TRUE);
    if (!marker.empty()) jpeg_write_marker(&info, JPEG_APP0 + 1, marker.data(), unsigned(marker.size()));
    jpeg_write_icc_profile(&info, icc.data(), unsigned(icc.size()));
    const size_t rowBytes = size_t(width) * 3;
    while (info.next_scanline < height) {
        JSAMPROW row = const_cast<JSAMPROW>(rgb + rowBytes * info.next_scanline);
        jpeg_write_scanlines(&info, &row, 1);
    }
    jpeg_finish_compress(&info);
    jpeg_destroy_compress(&info);
    if (std::fflush(file.get()) != 0) throw Failure("The image could not be written to " + path + ".");
}

void encodeTIFF(const std::string &path, const uint8_t *rgb, int bits, uint32_t width,
                uint32_t height, const std::vector<std::pair<uint16_t, std::string>> &text) {
    TIFFSetWarningHandler(nullptr);
    TIFF *tiff = TIFFOpen(path.c_str(), "w");
    if (!tiff) throw Failure("The image could not be written to " + path + ".");
    const auto &icc = displayP3Profile();
    TIFFSetField(tiff, TIFFTAG_IMAGEWIDTH, width);
    TIFFSetField(tiff, TIFFTAG_IMAGELENGTH, height);
    TIFFSetField(tiff, TIFFTAG_BITSPERSAMPLE, bits);
    TIFFSetField(tiff, TIFFTAG_SAMPLESPERPIXEL, 3);
    TIFFSetField(tiff, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB);
    TIFFSetField(tiff, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
    TIFFSetField(tiff, TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT);
    TIFFSetField(tiff, TIFFTAG_COMPRESSION, COMPRESSION_LZW);
    TIFFSetField(tiff, TIFFTAG_PREDICTOR, PREDICTOR_HORIZONTAL);
    TIFFSetField(tiff, TIFFTAG_ROWSPERSTRIP, TIFFDefaultStripSize(tiff, 0));
    TIFFSetField(tiff, TIFFTAG_ICCPROFILE, uint32_t(icc.size()), icc.data());
    for (const auto &[tag, value] : text) {
        switch (tag) {
        case TIFFTAG_IMAGEDESCRIPTION: case TIFFTAG_MAKE: case TIFFTAG_MODEL:
        case TIFFTAG_SOFTWARE: case TIFFTAG_DATETIME: case TIFFTAG_ARTIST: case TIFFTAG_COPYRIGHT:
            TIFFSetField(tiff, tag, value.c_str());
            break;
        default:
            break;
        }
    }
    const size_t rowBytes = size_t(width) * 3 * (bits / 8);
    std::vector<uint8_t> row(rowBytes);
    for (uint32_t y = 0; y < height; ++y) {
        std::memcpy(row.data(), rgb + rowBytes * y, rowBytes); // libtiff may encode in place
        if (TIFFWriteScanline(tiff, row.data(), y, 0) < 0) {
            TIFFClose(tiff);
            throw Failure("The image could not be written to " + path + ".");
        }
    }
    TIFFClose(tiff);
}

bool heifEncodes() {
#ifdef FFC_HAS_HEIF
    return heif_have_encoder_for_format(heif_compression_HEVC);
#else
    return false;
#endif
}

void encodeHEIF(const std::string &path, const uint8_t *rgb, uint32_t width, uint32_t height,
                float quality, const std::vector<uint8_t> &exif) {
#ifdef FFC_HAS_HEIF
    struct Resources {
        heif_context *context = heif_context_alloc();
        heif_encoder *encoder = nullptr;
        heif_image *image = nullptr;
        heif_image_handle *handle = nullptr;
        ~Resources() {
            if (handle) heif_image_handle_release(handle);
            if (image) heif_image_release(image);
            if (encoder) heif_encoder_release(encoder);
            heif_context_free(context);
        }
    } heif;
    auto check = [](heif_error error) {
        if (error.code != heif_error_Ok)
            throw Failure(std::string("The HEIC could not be written: ")
                          + (error.message ? error.message : "unknown error"));
    };
    check(heif_context_get_encoder_for_format(heif.context, heif_compression_HEVC, &heif.encoder));
    check(heif_encoder_set_lossy_quality(heif.encoder, std::max(1, std::min(100, int(quality * 100 + 0.5f)))));
    // x265's default (slow) preset takes some 18 s over 24 megapixels; fast writes the same size
    // in under half the time. Encoders without the parameter ignore it.
    heif_encoder_set_parameter_string(heif.encoder, "preset", "fast");
    check(heif_image_create(int(width), int(height), heif_colorspace_RGB, heif_chroma_interleaved_RGB,
                            &heif.image));
    check(heif_image_add_plane(heif.image, heif_channel_interleaved, int(width), int(height), 8));
    int stride = 0;
    uint8_t *plane = heif_image_get_plane(heif.image, heif_channel_interleaved, &stride);
    for (uint32_t y = 0; y < height; ++y)
        std::memcpy(plane + size_t(stride) * y, rgb + size_t(width) * 3 * y, size_t(width) * 3);
    const auto &icc = displayP3Profile();
    check(heif_image_set_raw_color_profile(heif.image, "prof", icc.data(), icc.size()));
    check(heif_context_encode_image(heif.context, heif.image, heif.encoder, nullptr, &heif.handle));
    if (!exif.empty()) check(heif_context_add_exif_metadata(heif.context, heif.handle, exif.data(), int(exif.size())));
    check(heif_context_write_to_file(heif.context, path.c_str()));
#else
    (void)path; (void)rgb; (void)width; (void)height; (void)quality; (void)exif;
    throw Failure("This build writes no HEIC files.");
#endif
}

} // namespace ffc

#endif
