/*
 * Fotufilm engine C interface.
 *
 * One edit, one develop: a host passes the request the web editor's native backend sends
 * (web/src/backend/macos/session.js) as JSON and gets the developed picture in its own buffer.
 * The request is translated through the same edit model the plug-ins and the apps use.
 *
 * Every function is thread-safe. Renders on one engine run one at a time; a host that wants
 * the newest edit only calls fotufilm_engine_cancel before starting the next render.
 * Strings returned through `char **error` or by value belong to the caller: fotufilm_free.
 */
#ifndef FOTUFILM_H
#define FOTUFILM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FOTUFILM_API_VERSION 1

typedef struct fotufilm_engine fotufilm_engine;
typedef struct fotufilm_image fotufilm_image;

enum {
    FOTUFILM_OK = 0,
    FOTUFILM_ERROR = 1,
    /* fotufilm_engine_cancel was called while the render was running. */
    FOTUFILM_CANCELLED = 2,
    /* The target buffer is smaller than fotufilm_render_size says the picture is. */
    FOTUFILM_TARGET_TOO_SMALL = 3,
};

enum {
    /* Display P3 with the sRGB transfer, SDR shoulder applied, dithered. What a screen shows. */
    FOTUFILM_PIXELS_RGBA8_DISPLAY_P3 = 0,
    /* Display-linear Display P3 reflectance, before the shoulder: for HDR or further grading. */
    FOTUFILM_PIXELS_RGBA32F_LINEAR_P3 = 1,
};

typedef struct fotufilm_render_target {
    /* Longest edge of the developed picture; 0 develops at the image's own size. */
    uint32_t max_edge;
    int32_t format;
    void *pixels;
    size_t row_bytes;
    /* Bytes available at `pixels`. */
    size_t capacity;
} fotufilm_render_target;

typedef struct fotufilm_render_info {
    uint32_t width;
    uint32_t height;
    /* Wall time of the develop, excluding any first-open decode. */
    double milliseconds;
} fotufilm_render_info;

int32_t fotufilm_api_version(void);
void fotufilm_free(char *string);

fotufilm_engine *fotufilm_engine_create(char **error);
void fotufilm_engine_destroy(fotufilm_engine *engine);
/* JSON: {"apiVersion", "backend", "stocks": [{"id", "name", "nativeFormat"}]}. */
char *fotufilm_engine_describe(fotufilm_engine *engine);
/* Stops the render in progress, if any, at its next opportunity. */
void fotufilm_engine_cancel(fotufilm_engine *engine);

/* Decodes a photograph (RAW, HEIC, JPEG, PNG, TIFF, EXR) into the engine's scene light. */
fotufilm_image *fotufilm_image_open(fotufilm_engine *engine, const char *path, char **error);
void fotufilm_image_size(const fotufilm_image *image, uint32_t *width, uint32_t *height);
void fotufilm_image_release(fotufilm_image *image);

/* The size a render of `image` with this max_edge delivers. */
void fotufilm_render_size(const fotufilm_image *image, uint32_t max_edge,
                          uint32_t *width, uint32_t *height);

/* Develops `image` with the web editor's render request into `target`. */
int32_t fotufilm_render(fotufilm_engine *engine, fotufilm_image *image, const char *request_json,
                        const fotufilm_render_target *target, fotufilm_render_info *info,
                        char **error);

#ifdef __cplusplus
}
#endif

#endif
