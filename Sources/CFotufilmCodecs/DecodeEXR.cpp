// OpenEXR: linear light, associated alpha, in the file's chromaticities or Rec. 709.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#if __has_include(<OpenEXR/ImfRgbaFile.h>) || __has_include(<ImfRgbaFile.h>)
#define FFC_HAS_EXR 1
#if __has_include(<OpenEXR/ImfRgbaFile.h>)
#include <OpenEXR/ImfArray.h>
#include <OpenEXR/ImfChromaticities.h>
#include <OpenEXR/ImfRgbaFile.h>
#include <OpenEXR/ImfStandardAttributes.h>
#else
#include <ImfArray.h>
#include <ImfChromaticities.h>
#include <ImfRgbaFile.h>
#include <ImfStandardAttributes.h>
#endif
#endif

#include <cstring>

namespace ffc {

Raster decodeEXR(const std::string &path, ffc_capture &capture) {
#ifdef FFC_HAS_EXR
    try {
        Imf::RgbaInputFile file(path.c_str());
        const Imath::Box2i window = file.dataWindow();
        const int width = window.max.x - window.min.x + 1, height = window.max.y - window.min.y + 1;
        if (width <= 0 || height <= 0) throw Failure("The EXR has no pixels.");
        Imf::Array2D<Imf::Rgba> pixels(height, width);
        file.setFrameBuffer(&pixels[0][0] - window.min.x - window.min.y * width, 1, width);
        file.readPixels(window.min.y, window.max.y);

        Raster raster;
        raster.width = uint32_t(width);
        raster.height = uint32_t(height);
        raster.channels = 4;
        raster.samples = Samples::F32;
        raster.associated = true;
        raster.encoding.kind = Encoding::Linear;
        if (Imf::hasChromaticities(file.header())) {
            const Imf::Chromaticities &c = Imf::chromaticities(file.header());
            raster.encoding.chromaticities = {c.red.x, c.red.y, c.green.x, c.green.y,
                                              c.blue.x, c.blue.y, c.white.x, c.white.y};
        }
        const bool alpha = file.channels() & Imf::WRITE_A;
        raster.data.resize(size_t(width) * height * 4 * sizeof(float));
        auto *out = reinterpret_cast<float *>(raster.data.data());
        for (int y = 0; y < height; ++y)
            for (int x = 0; x < width; ++x) {
                const Imf::Rgba &p = pixels[y][x];
                float *o = out + (size_t(y) * width + x) * 4;
                o[0] = float(p.r);
                o[1] = float(p.g);
                o[2] = float(p.b);
                o[3] = alpha ? float(p.a) : 1.0f;
            }
        capture.stored_width = raster.width;
        capture.stored_height = raster.height;
        return raster;
    } catch (const Failure &) {
        throw;
    } catch (const std::exception &error) {
        throw Failure(std::string("The EXR could not be read: ") + error.what());
    }
#else
    (void)path;
    (void)capture;
    throw Failure("This build reads no OpenEXR files.");
#endif
}

} // namespace ffc

#endif
