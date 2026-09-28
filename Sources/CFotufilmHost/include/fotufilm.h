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
/* JSON: what this build's platform services let the editor offer, known without an engine
   ({"importPath", "subjectSelection", "copyImage", "printFrames", "imageExportTypes",
   "hdrExport", ...}). Free with fotufilm_free. */
char *fotufilm_capabilities(void);

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

/* The web editor's backend calls (web/src/backend/macos/host.js), answered in the engine:
 * `method` with JSON `params` and optional bytes. The answer is JSON; images it returns are
 * named byte ranges of `payload`, listed in the JSON as "payloads": {"name": [offset, length]},
 * each range starting on a 64-byte boundary. Free the answer with fotufilm_answer_free. */
typedef struct fotufilm_answer {
    char *json;
    uint8_t *payload;
    size_t payload_length;
} fotufilm_answer;

int32_t fotufilm_host_call(fotufilm_engine *engine, const char *method, const char *params_json,
                           const void *payload, size_t payload_length, fotufilm_answer *answer,
                           char **error);
void fotufilm_answer_free(fotufilm_answer *answer);

/* Progress of a long call, such as a video export: JSON like {"progress": 0.5, "frames": 12},
 * reported on the calling thread while the call runs. The string is only valid during the call. */
typedef void (*fotufilm_progress_callback)(void *context, const char *progress_json);

/* fotufilm_host_call, reporting progress to `progress` (which may be NULL). */
int32_t fotufilm_host_call_progress(fotufilm_engine *engine, const char *method,
                                    const char *params_json, const void *payload,
                                    size_t payload_length, fotufilm_progress_callback progress,
                                    void *context, fotufilm_answer *answer, char **error);

/* Native presentation. A host that draws the editor's photograph itself, beneath its web page,
 * lends the engine surfaces its compositor can show. A render whose request names a layer
 * ({"present": {"slot": "preview" | "detail", "scope": ...}}) develops into a surface and hands
 * it back with `present` instead of returning an encoded image: no image crosses to the page. The
 * answer's "presented" names the frames ({"frame", "original", "dynamicRange", "headroom"}),
 * which the page places by id. Slots take the developed picture; "<slot>.original" the
 * undeveloped one. */
enum {
    /* Display P3 with the sRGB transfer, 8 bits a channel, RGBA: an SDR picture. */
    FOTUFILM_SURFACE_RGBA8_DISPLAY_P3 = 0,
    /* Extended-linear Display P3 in half floats, RGBA: 1.0 is SDR white and values above it are
     * EDR headroom. Used only when the edit delivers light above display white and the host
     * reports a headroom above 1. */
    FOTUFILM_SURFACE_RGBA16F_EXTENDED_LINEAR_P3 = 1,
};

typedef struct fotufilm_surface {
    uint32_t width;
    uint32_t height;
    int32_t format;
    /* Writable by the engine from `acquire` until `present` or `discard`. */
    void *pixels;
    size_t row_bytes;
    /* The platform's shareable handle for GPU access (an IOSurfaceRef on macOS), or NULL. */
    void *native;
    /* The host's own reference, handed back unchanged. */
    void *host;
} fotufilm_surface;

typedef struct fotufilm_presenter {
    void *context;
    /* How far above SDR white the display showing the layer can go; 1 without EDR. Any thread. */
    float (*headroom)(void *context);
    /* Lends a surface of this size and format; FOTUFILM_OK or an error. Engine thread. */
    int32_t (*acquire)(void *context, uint32_t width, uint32_t height, int32_t format,
                       fotufilm_surface *surface);
    /* Shows a written surface in `layer`; returns the frame's id, which the page names when it
     * places the layer. `info_json` is {"scope", "dynamicRange", "headroom", "motion"}; a
     * `motion` frame, one of a playing movie, replaces the last without a fade. Engine thread. */
    uint64_t (*present)(void *context, const char *layer, const fotufilm_surface *surface,
                        const char *info_json);
    /* Returns a surface that was acquired and not presented. */
    void (*discard)(void *context, const fotufilm_surface *surface);
} fotufilm_presenter;

/* Lends the engine a presenter; NULL takes it away. The struct is copied; `context` must stay
 * valid until the presenter is replaced or the engine destroyed. */
void fotufilm_engine_set_presenter(fotufilm_engine *engine, const fotufilm_presenter *presenter);

#ifdef __cplusplus
}
#endif

#endif
