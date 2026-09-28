// PNG through libpng: 8- and 16-bit, grey or colour, with alpha; iCCP, sRGB, gAMA/cHRM and eXIf.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#include <csetjmp>
#include <cstdio>
#include <cstring>
#include <memory>

#include <png.h>

namespace ffc {

Raster decodePNG(const std::string &path, ffc_capture &capture) {
    Raster raster;
    std::unique_ptr<FILE, int (*)(FILE *)> file(std::fopen(path.c_str(), "rb"), std::fclose);
    if (!file) throw Failure("Could not open " + path);
    std::vector<png_bytep> rows;
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop info = png ? png_create_info_struct(png) : nullptr;
    if (!info) {
        png_destroy_read_struct(&png, nullptr, nullptr);
        throw Failure("The PNG could not be read.");
    }
    // Nothing with a destructor is created between here and the last libpng call.
    if (setjmp(png_jmpbuf(png))) {
        png_destroy_read_struct(&png, &info, nullptr);
        throw Failure("The PNG could not be read.");
    }
    png_init_io(png, file.get());
    png_read_info(png, info);
    png_uint_32 width = 0, height = 0;
    int depth = 0, type = 0;
    png_get_IHDR(png, info, &width, &height, &depth, &type, nullptr, nullptr, nullptr);

    png_charp name = nullptr;
    int compression = 0;
    png_bytep profile = nullptr;
    png_uint_32 profileLength = 0;
    int intent = 0;
    double gamma = 0;
    if (png_get_iCCP(png, info, &name, &compression, &profile, &profileLength) && profile) {
        raster.encoding.kind = Encoding::Profile;
        raster.encoding.icc.assign(profile, profile + profileLength);
    } else if (png_get_sRGB(png, info, &intent)) {
        raster.encoding.kind = Encoding::Unstated;
    } else if (png_get_gAMA(png, info, &gamma) && gamma > 0) {
        raster.encoding.kind = Encoding::Power;
        raster.encoding.gamma = float(1 / gamma);
        double wx, wy, rx, ry, gx, gy, bx, by;
        if (png_get_cHRM(png, info, &wx, &wy, &rx, &ry, &gx, &gy, &bx, &by))
            raster.encoding.chromaticities = {float(rx), float(ry), float(gx), float(gy),
                                              float(bx), float(by), float(wx), float(wy)};
    }
    png_uint_32 exifLength = 0;
    png_bytep exif = nullptr;
    if (png_get_eXIf_1(png, info, &exifLength, &exif) && exif && exifLength > 0) {
        try {
            // A PNG's own pixels are upright as stored; like ImageIO, its Exif orientation turns them.
            raster.orientation = parseExif(exif, exifLength, capture).orientation;
            keepExif(exif, exifLength, capture);
        } catch (const Failure &) {
        }
    }

    if (type == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (type == PNG_COLOR_TYPE_GRAY && depth < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
    if (depth == 16) png_set_swap(png); // host (little-endian) order
    png_set_interlace_handling(png);
    png_read_update_info(png, info);

    raster.width = width;
    raster.height = height;
    raster.channels = png_get_channels(png, info);
    raster.samples = png_get_bit_depth(png, info) == 16 ? Samples::U16 : Samples::U8;
    capture.stored_width = width;
    capture.stored_height = height;
    size_t rowBytes = png_get_rowbytes(png, info);
    raster.data.resize(rowBytes * height);
    rows.resize(height);
    for (png_uint_32 y = 0; y < height; ++y) rows[y] = raster.data.data() + rowBytes * y;
    png_read_image(png, rows.data());
    png_read_end(png, nullptr);
    png_destroy_read_struct(&png, &info, nullptr);
    return raster;
}

} // namespace ffc

#endif
