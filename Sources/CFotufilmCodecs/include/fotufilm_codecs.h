#ifndef FOTUFILM_CODECS_H
#define FOTUFILM_CODECS_H

/* Still-image decoding and encoding through portable system libraries (libjpeg-turbo, libpng,
 * libtiff, LibRaw, OpenEXR, libheif, lcms2), for hosts without Core Image and ImageIO. Plain C so
 * any port can call it. Decoded pixels are what the engine takes: associated, scene-referred
 * linear Rec. 2020 RGBA floats, upright. */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    /* A photograph as the editor opens it: RAW with its baseline exposure. */
    FFC_DECODE_SCENE = 0,
    /* A scanned negative: RAW with no exposure of its own. */
    FFC_DECODE_SCAN = 1 << 0,
    /* Read samples with no stated colour encoding as linear sRGB light (not RAW). */
    FFC_DECODE_LINEAR_SAMPLES = 1 << 1,
    /* With FFC_DECODE_SCAN, one exposure of a trichromatic scan (RAW): the camera's daylight
     * balance rather than the shot's, each colour from its own photosites (half size). */
    FFC_DECODE_EXPOSURE = 1 << 2,
};

/* What the file records about how it was made; strings are empty when unknown. */
typedef struct ffc_capture {
    char make[64];
    char model[96];
    char lens_make[64];
    char lens_model[128];
    float focal_length;       /* mm, 0 when unknown */
    float focal_length_35mm;  /* mm, 0 when unknown */
    float f_number;           /* 0 when unknown */
    double focal_plane_x_resolution; /* 0 when unknown */
    double focal_plane_y_resolution;
    int32_t focal_plane_unit;
    /* The pixels the file stores, before any turn. */
    uint32_t stored_width;
    uint32_t stored_height;
    /* The file's Exif record as a TIFF structure (no "Exif\0\0" prefix), NULL when none. */
    uint8_t *exif;
    size_t exif_length;
} ffc_capture;

typedef struct ffc_image {
    /* Associated linear Rec. 2020 RGBA, row by row from the top. */
    float *rgba;
    uint32_t width;
    uint32_t height;
    int32_t is_raw;
    /* The range above diffuse white the file declares; 1 for none. */
    float content_headroom;
    /* A RAW file's as-shot white, 0 when unknown. */
    float as_shot_kelvin;
    float as_shot_x;
    float as_shot_y;
    ffc_capture capture;
} ffc_image;

/* Decodes `path`. A RAW is demosaiced no larger than needed for `raw_long_edge` (0 for full size).
 * Returns 0 and fills `out` (release with ffc_image_free), or nonzero with a message in `error`. */
int32_t ffc_decode(const char *path, uint32_t options, uint32_t raw_long_edge, ffc_image *out,
                   char *error, size_t error_size);
void ffc_image_free(ffc_image *image);

/* RAW-only entry point, linkable without the other image codecs. Identification uses the file's
 * contents, including when an imported private copy has no extension. All limits must be > 0.
 * max_working_bytes is a conservative admission estimate, not a process RSS limit; LibRaw also
 * receives that ceiling for its own RAW allocations. Files and sensor dimensions are checked
 * before demosaicing. The estimate includes input, sensor/intermediate images, and float output.
 * long_edge bounds the delivered raster (0 for native size); it never enlarges the source.
 * source_width/height describe the upright default crop before preview reduction.
 * Returns FFC_RAW_OK, FFC_RAW_UNSUPPORTED (not recognized by LibRaw), or
 * FFC_RAW_ERROR. Failure clears out and source dimensions. Release success with ffc_image_free.
 * options accepts FFC_DECODE_SCENE or FFC_DECODE_SCAN. */
typedef struct ffc_raw_limits {
    uint64_t max_file_bytes;
    uint64_t max_sensor_pixels;
    uint64_t max_working_bytes;
} ffc_raw_limits;
enum { FFC_RAW_OK = 0, FFC_RAW_UNSUPPORTED = 1, FFC_RAW_ERROR = 2 };
int32_t ffc_decode_raw(const char *path, uint32_t options, uint32_t long_edge,
                       const ffc_raw_limits *limits, ffc_image *out,
                       uint32_t *source_width, uint32_t *source_height,
                       char *error, size_t error_size);

/* Bounded non-RAW TIFF import. Reads the first image, preserving unsigned integer or floating
 * precision and colour profiles. Preview reduction happens in associated linear light; source
 * dimensions remain native and upright. Strips/tile bands are decoded without a full-size float
 * intermediate. LibTIFF 4.7+ also enforces a per-handle allocation budget. Camera-RAW TIFFs must
 * go through ffc_decode_raw first; this entry point rejects TIFF directories carrying RAW markers.
 * The capture structure contains basic camera/lens fields, not an opaque full-file EXIF copy.
 * All limits must be positive. Release successful output with ffc_image_free. */
typedef struct ffc_tiff_limits {
    uint64_t max_file_bytes;
    uint64_t max_pixels;
    uint64_t max_working_bytes;
} ffc_tiff_limits;
enum { FFC_TIFF_OK = 0, FFC_TIFF_UNSUPPORTED = 1, FFC_TIFF_ERROR = 2 };
int32_t ffc_decode_tiff(const char *path, uint32_t options, uint32_t long_edge,
                       const ffc_tiff_limits *limits, ffc_image *out,
                       uint32_t *source_width, uint32_t *source_height,
                       char *error, size_t error_size);

/* Whether this build writes `mime` ("image/png", "image/jpeg", "image/tiff", "image/heic"). */
int32_t ffc_can_encode(const char *mime);

/* Writes Display P3 RGBA (8 or 16 bits per sample, host order, sRGB transfer; alpha is ignored)
 * to `path` with the Display P3 profile, quality 0-1 for the lossy formats, and the Exif record
 * `exif` (as ffc_capture holds it, may be NULL) without its orientation, pixel size, thumbnail
 * and maker notes, and without GPS unless `keep_location`. Returns 0 on success. */
int32_t ffc_encode(const char *path, const char *mime, const void *rgba, int32_t bits,
                   uint32_t width, uint32_t height, float quality, const uint8_t *exif,
                   size_t exif_length, int32_t keep_location, char *error, size_t error_size);

#ifdef __cplusplus
}
#endif

#endif
