// HEIF and AVIF through libheif: the primary image, turned by its own transforms, 8 or 10+ bits,
// with its ICC profile or nclx colour and its Exif record. The HDR gain map is not read.
// Apple platforms decode and encode through ImageIO; this target builds empty there.
#if !defined(__APPLE__)
#include "Codecs.hpp"

#if __has_include(<libheif/heif.h>)
#define FFC_HAS_HEIF 1
#include <libheif/heif.h>
#endif

#include <algorithm>
#include <cstring>
#include <memory>

namespace ffc {

#ifdef FFC_HAS_HEIF
namespace {

struct Context {
    heif_context *context = heif_context_alloc();
    heif_image_handle *handle = nullptr;
    heif_image *image = nullptr;
    ~Context() {
        if (image) heif_image_release(image);
        if (handle) heif_image_handle_release(handle);
        heif_context_free(context);
    }
};

void check(heif_error error, const char *what) {
    if (error.code != heif_error_Ok)
        throw Failure(std::string(what) + ": " + (error.message ? error.message : "unknown error"));
}

/// Colour an nclx box states, where it names a transfer the colour stage can read.
void nclx(const heif_color_profile_nclx *profile, Encoding &encoding) {
    switch (profile->color_primaries) {
    case heif_color_primaries_ITU_R_BT_2020_2_and_2100_0:
        encoding.chromaticities = {0.708f, 0.292f, 0.170f, 0.797f, 0.131f, 0.046f, 0.3127f, 0.3290f};
        break;
    case heif_color_primaries_SMPTE_EG_432_1:
        encoding.chromaticities = {0.680f, 0.320f, 0.265f, 0.690f, 0.150f, 0.060f, 0.3127f, 0.3290f};
        break;
    default:
        break; // Rec. 709 / sRGB
    }
    switch (profile->transfer_characteristics) {
    case heif_transfer_characteristic_linear:
        encoding.kind = Encoding::Linear;
        break;
    case heif_transfer_characteristic_ITU_R_BT_2100_0_PQ:
    case heif_transfer_characteristic_ITU_R_BT_2100_0_HLG:
        // Gap: PQ and HLG are read through the sRGB curve, with no headroom; the Mac decodes them
        // to scene light (`GainMapHeadroom.Transfer`).
    default:
        // The sRGB curve over these primaries, as the colour stage builds for a stated gamut.
        encoding.kind = Encoding::Power;
        encoding.gamma = 0; // sRGB piecewise curve
        break;
    }
}

} // namespace
#endif

Raster decodeHEIF(const std::string &path, ffc_capture &capture) {
#ifdef FFC_HAS_HEIF
    Context heif;
    check(heif_context_read_from_file(heif.context, path.c_str(), nullptr), "The HEIF could not be read");
    check(heif_context_get_primary_image_handle(heif.context, &heif.handle), "The HEIF has no image");
    const bool alpha = heif_image_handle_has_alpha_channel(heif.handle);
    const int bits = heif_image_handle_get_luma_bits_per_pixel(heif.handle);
    const bool deep = bits > 8;
    heif_chroma chroma = deep ? (alpha ? heif_chroma_interleaved_RRGGBBAA_LE : heif_chroma_interleaved_RRGGBB_LE)
                              : (alpha ? heif_chroma_interleaved_RGBA : heif_chroma_interleaved_RGB);
    check(heif_decode_image(heif.handle, &heif.image, heif_colorspace_RGB, chroma, nullptr),
          "The HEIF could not be decoded");

    Raster raster;
    raster.width = uint32_t(heif_image_get_width(heif.image, heif_channel_interleaved));
    raster.height = uint32_t(heif_image_get_height(heif.image, heif_channel_interleaved));
    raster.channels = alpha ? 4 : 3;
    raster.samples = deep ? Samples::U16 : Samples::U8;
    capture.stored_width = uint32_t(heif_image_handle_get_width(heif.handle));
    capture.stored_height = uint32_t(heif_image_handle_get_height(heif.handle));
    int stride = 0;
    const uint8_t *plane = heif_image_get_plane_readonly(heif.image, heif_channel_interleaved, &stride);
    if (!plane) throw Failure("The HEIF could not be decoded.");
    const size_t rowBytes = size_t(raster.width) * raster.channels * (deep ? 2 : 1);
    raster.data.resize(rowBytes * raster.height);
    for (uint32_t y = 0; y < raster.height; ++y)
        std::memcpy(raster.data.data() + rowBytes * y, plane + size_t(stride) * y, rowBytes);
    if (deep) {
        // 10- or 12-bit samples in 16-bit words, scaled to the full 16-bit range.
        const int stored = heif_image_get_bits_per_pixel_range(heif.image, heif_channel_interleaved);
        const float scale = 65535.0f / float((1 << std::max(1, stored)) - 1);
        auto *samples = reinterpret_cast<uint16_t *>(raster.data.data());
        for (size_t i = 0; i < raster.data.size() / 2; ++i)
            samples[i] = uint16_t(std::min(65535.0f, samples[i] * scale + 0.5f));
    }

    switch (heif_image_handle_get_color_profile_type(heif.handle)) {
    case heif_color_profile_type_prof:
    case heif_color_profile_type_rICC: {
        size_t size = heif_image_handle_get_raw_color_profile_size(heif.handle);
        raster.encoding.icc.resize(size);
        if (size && heif_image_handle_get_raw_color_profile(heif.handle, raster.encoding.icc.data()).code
                        == heif_error_Ok)
            raster.encoding.kind = Encoding::Profile;
        break;
    }
    case heif_color_profile_type_nclx: {
        heif_color_profile_nclx *profile = nullptr;
        if (heif_image_handle_get_nclx_color_profile(heif.handle, &profile).code == heif_error_Ok && profile) {
            nclx(profile, raster.encoding);
            heif_nclx_color_profile_free(profile);
        }
        break;
    }
    default:
        break;
    }

    // The Exif record, after its offset word. Orientation is libheif's to apply (irot/imir).
    heif_item_id exifID;
    if (heif_image_handle_get_list_of_metadata_block_IDs(heif.handle, "Exif", &exifID, 1) == 1) {
        size_t size = heif_image_handle_get_metadata_size(heif.handle, exifID);
        std::vector<uint8_t> block(size);
        if (size > 4 && heif_image_handle_get_metadata(heif.handle, exifID, block.data()).code == heif_error_Ok) {
            size_t offset = 4 + (size_t(block[0]) << 24 | size_t(block[1]) << 16 | size_t(block[2]) << 8 | block[3]);
            if (offset < size) {
                try {
                    parseExif(block.data() + offset, size - offset, capture);
                    keepExif(block.data() + offset, size - offset, capture);
                } catch (const Failure &) {
                }
            }
        }
    }
    return raster;
#else
    (void)path;
    (void)capture;
    throw Failure("This build reads no HEIF files.");
#endif
}

} // namespace ffc

#endif
