#ifndef FOTUFILM_TRICHROMATIC_H
#define FOTUFILM_TRICHROMATIC_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// A trichromatic scan: one negative photographed three times, under red, green and blue light,
// its three layers lined up and merged into one scan (FotufilmTrichromaticMeasure.h,
// Pipeline/Trichromatic.h). Exposures are interleaved linear RGBA, any size; layers are planes of
// float32 transmittance, all three the same size.

// The lights an exposure can have been made under.
enum {
    FOTUFILM_TRICHROMATIC_RED = 0,
    FOTUFILM_TRICHROMATIC_GREEN = 1,
    FOTUFILM_TRICHROMATIC_BLUE = 2,
    // One of the three lights through no picture: a light frame, or the film's leader.
    FOTUFILM_TRICHROMATIC_BLANK = 3,
    // White or mixed light: not part of a trichromatic scan.
    FOTUFILM_TRICHROMATIC_OTHER = -1,
};

// Which light an exposure was made under. `measured` gets the light's colour in the exposure
// (three values, its mean over the middle of the frame) and how much picture it shows (the spread
// of its log transmittance there; a blank's is below 0.13). Any size works; the exposure is
// reduced to about 512 pixels first. Returns 0, or -1 for bad input.
int32_t fotufilm_trichromatic_measure(const float *rgba, int32_t width, int32_t height,
                                      float measured[4], int32_t *light);

// Groups exposures, in the order they were made, into frames: `lights` as measured, `frames`
// receiving (red, green, blue) index triples, room for count / 3 of them. Blank and other
// exposures are left out. Exposures alternate (red, green, blue, red, ...) or come in passes (every
// frame under red, then every frame under green, ...), in any order of the lights. Returns the
// frame count, or -(1 + i) where i is the first exposure that fits no frame.
int32_t fotufilm_trichromatic_group(const int32_t *lights, int32_t count, int32_t *frames);

// The layer an exposure records, its transmittance under its light: rgb · colour / |colour|².
int32_t fotufilm_trichromatic_layer(const float *rgba, int32_t width, int32_t height,
                                    const float colour[3], float *layer);

// Lines `moving` up with `reference`: the moving layer's sample for reference pixel (x, y) is at
// (a0 x + a1 y + a2, a3 x + a4 y + a5). `report` gets the patches that agreed and the median and
// 90th-percentile distance (pixels) by which they still disagree. Returns 0, -1 for bad input, or
// -4 when the layers share too little detail to line up.
int32_t fotufilm_trichromatic_register(const float *reference, const float *moving,
                                       int32_t width, int32_t height, float affine[6],
                                       float report[3]);

// The size of the merged scan's file: an uncompressed, untagged 16-bit RGB TIFF, which the
// editors read as linear samples.
int64_t fotufilm_trichromatic_file_size(int32_t width, int32_t height);

// Merges the three layers into the file, `size` bytes (fotufilm_trichromatic_file_size): green
// and blue sampled through their registrations, each layer's clear end near the top of its range.
int32_t fotufilm_trichromatic_merge(const float *red, const float *green, const float *blue,
                                    int32_t width, int32_t height, const float green_affine[6],
                                    const float blue_affine[6], uint8_t *file, int64_t size);
#ifdef __cplusplus
}
#endif
#endif
