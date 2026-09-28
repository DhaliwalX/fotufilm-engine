// Movies where there is no AVFoundation (Linux): decoding and encoding through the system's FFmpeg,
// which is loaded when first asked for rather than linked, so the app starts without it and never
// carries it. Frames leave the reader in the colour contracts the Mac's decoder delivers
// (HostVideoSource+AVFoundation.swift); the writer takes the pixels the Mac's writer does.
#ifndef FOTUFILM_VIDEO_H
#define FOTUFILM_VIDEO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Whether the system's FFmpeg libraries (the major versions this build was compiled against)
/// load. Without them the host offers no video.
int32_t ffv_available(void);
/// The last failure on this thread, for a message.
const char *ffv_last_error(void);
void ffv_free(void *pointer);

// MARK: Reading

typedef struct ffv_reader ffv_reader;

typedef struct ffv_info {
    /// Upright size, after the track's own rotation.
    int32_t width, height;
    /// Clockwise quarter turns from the stored frame to the upright one.
    int32_t quarter_turns;
    /// Bits per component the codec stores.
    int32_t bits;
    /// The first frame's time and the movie's end, in seconds.
    double start, end;
    double frame_rate;
    int32_t has_audio;
    /// ITU-T H.273 code points as the file declares them; 2 is unspecified.
    int32_t primaries, transfer, matrix;
    int32_t full_range;
    char make[64];
    char model[64];
} ffv_info;

enum {
    /// RGBA8 Display P3 with the sRGB transfer, colour-managed as the Mac decodes SDR video.
    FFV_DISPLAY_P3_8 = 0,
    /// RGBA float scene-linear Rec.2020, colour-managed the same way in float.
    FFV_LINEAR_REC2020 = 1,
    /// RGBA float R'G'B' signal in the source's own transfer and primaries, video range expanded:
    /// HDR transfers and camera log, for the host to convert.
    FFV_SIGNAL = 2,
};

ffv_reader *ffv_open(const char *path, ffv_info *info);
void ffv_close(ffv_reader *reader);
/// Makes the frame showing at `seconds` current: 1, 0 when the movie has no frame there, -1 on
/// an error.
int32_t ffv_seek(ffv_reader *reader, double seconds);
/// Decodes the frame after the current one, if it is not already, and reports its time: 1, 0 at
/// the end, -1 on an error.
int32_t ffv_peek(ffv_reader *reader, double *time);
/// Makes the next frame current: 1, 0 at the end, -1 on an error.
int32_t ffv_step(ffv_reader *reader);
/// The current frame's presentation time and duration, in seconds.
void ffv_current(const ffv_reader *reader, double *time, double *duration);
/// The current frame, upright, at `width` x `height` (upright sizes) in `format`: 0, or -1.
int32_t ffv_convert(ffv_reader *reader, int32_t format, int32_t width, int32_t height,
                    void *pixels, size_t row_bytes);

/// The sound as interleaved 16-bit stereo at `rate`, freed with ffv_free: 1, 0 for a silent
/// movie, -1 on an error.
int32_t ffv_audio(const char *path, int32_t rate, int16_t **samples, size_t *count);

// MARK: Writing

typedef struct ffv_writer ffv_writer;

enum { FFV_CODEC_H264 = 0, FFV_CODEC_HEVC10 = 1, FFV_CODEC_PRORES = 2 };

/// The codecs this machine encodes, as a mask of 1 << FFV_CODEC_*.
int32_t ffv_codecs(void);

enum {
    /// RGBA8 Display P3 with the sRGB transfer.
    FFV_PIXELS_RGBA8 = 0,
    /// RGBA, 16 bits a channel, little-endian: R'G'B' codes and opaque alpha.
    FFV_PIXELS_RGBA64 = 1,
    /// 10-bit 4:2:0 Y'CbCr in P010: a luma plane of `height` rows, then the interleaved chroma
    /// plane of `height / 2` rows, both `row_bytes` apart.
    FFV_PIXELS_P010 = 2,
};

typedef struct ffv_writer_config {
    const char *path;
    int32_t codec;
    /// ProRes: 0 Proxy, 1 LT, 2 422, 3 HQ, 4 4444, 5 4444 XQ.
    int32_t prores_profile;
    int32_t width, height;
    double frame_rate;
    /// Bits a second; 0 leaves the rate to the encoder.
    int64_t bit_rate;
    /// BT.2100 HLG in BT.2020 rather than SDR Display P3.
    int32_t hdr;
    /// The source range the movie covers; its first frame is at `start`.
    double start, end;
    /// The movie whose sound is carried across, or NULL for none.
    const char *audio_path;
} ffv_writer_config;

ffv_writer *ffv_writer_open(const ffv_writer_config *config);
/// The layout `ffv_writer_append` takes: FFV_PIXELS_*.
int32_t ffv_writer_pixels(const ffv_writer *writer);
/// The encoder chosen, such as "h264_nvenc" or "libx264".
const char *ffv_writer_encoder(const ffv_writer *writer);
/// One frame shown from `seconds` on the source timeline: 0, or -1.
int32_t ffv_writer_append(ffv_writer *writer, const void *pixels, size_t row_bytes,
                          double seconds);
/// Completes the file and frees the writer: 0, or -1.
int32_t ffv_writer_finish(ffv_writer *writer);
/// Stops, removes the partial file and frees the writer.
void ffv_writer_cancel(ffv_writer *writer);

#ifdef __cplusplus
}
#endif

#endif
