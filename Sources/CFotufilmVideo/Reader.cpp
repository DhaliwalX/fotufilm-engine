// Decoding: FFmpeg's demuxer and decoders, then float R'G'B' at the size asked for (read from the
// frame's planes, or through swscale for a resize), then the colour contract the host asked for,
// written upright.
// Built where FFmpeg's headers are (Linux); elsewhere the platform's own framework decodes.
#if __has_include(<libavformat/avformat.h>)
#include "Colour.hpp"
#include "FFmpeg.hpp"
#include "Parallel.hpp"
#include "fotufilm_video.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

using namespace fotufilm::video;

struct ffv_reader {
    AVFormatContext *format = nullptr;
    AVCodecContext *decoder = nullptr;
    int stream = -1;
    AVRational time_base{1, 1};
    AVPacket *packet = nullptr;
    AVFrame *current = nullptr;
    AVFrame *upcoming = nullptr;
    bool has_current = false;
    bool has_upcoming = false;
    bool draining = false;
    ffv_info info{};
    int stored_width = 0, stored_height = 0;
    SourceColour colour;

    // The conversion last used, kept for the next frame.
    SwsContext *scaler = nullptr;
    struct Key {
        int format, width, height, target_width, target_height, matrix, full, chroma;
        bool operator==(const Key &o) const {
            return format == o.format && width == o.width && height == o.height
                && target_width == o.target_width && target_height == o.target_height
                && matrix == o.matrix && full == o.full && chroma == o.chroma;
        }
    } key{};
    std::vector<float> planes;
    std::unique_ptr<ManagedTables> tables;

    ~ffv_reader() {
        if (scaler) ff().sws_freeContext(scaler);
        ff().av_frame_free(&current);
        ff().av_frame_free(&upcoming);
        ff().av_packet_free(&packet);
        ff().avcodec_free_context(&decoder);
        if (format) ff().avformat_close_input(&format);
    }

    double seconds(const AVFrame *frame) const {
        int64_t ts = frame->best_effort_timestamp;
        if (ts == AV_NOPTS_VALUE) ts = frame->pts;
        return ts == AV_NOPTS_VALUE ? 0 : static_cast<double>(ts) * av_q2d(time_base);
    }

    double duration(const AVFrame *frame) const {
        if (frame->duration > 0) return static_cast<double>(frame->duration) * av_q2d(time_base);
        return 1 / info.frame_rate;
    }

    /// The next decoded frame into `frame`: 1, 0 at the end, -1 on an error.
    int decode(AVFrame *frame) {
        const FFmpeg &f = ff();
        f.av_frame_unref(frame);
        while (true) {
            int error = f.avcodec_receive_frame(decoder, frame);
            if (error == 0) return 1;
            if (error == AVERROR_EOF) return 0;
            if (error != AVERROR(EAGAIN)) return fail("The video stopped decoding: " + describe(error));
            if (draining) return 0;
            error = f.av_read_frame(format, packet);
            if (error < 0) {
                // The end of the file: the decoder hands over what it still holds.
                f.avcodec_send_packet(decoder, nullptr);
                draining = true;
                continue;
            }
            if (packet->stream_index == stream) {
                // A damaged packet costs its frame, not the movie.
                f.avcodec_send_packet(decoder, packet);
            }
            f.av_packet_unref(packet);
        }
    }

    int peek(double *time) {
        if (!has_upcoming) {
            const int result = decode(upcoming);
            if (result <= 0) return result;
            has_upcoming = true;
        }
        if (time) *time = seconds(upcoming);
        return 1;
    }

    int step() {
        if (has_upcoming) {
            ff().av_frame_unref(current);
            ff().av_frame_move_ref(current, upcoming);
            has_upcoming = false;
            has_current = true;
            return 1;
        }
        const int result = decode(current);
        has_current = result == 1;
        return result;
    }

    int seek(double time) {
        const FFmpeg &f = ff();
        const int64_t target = static_cast<int64_t>(std::llround(time / av_q2d(time_base)));
        if (f.av_seek_frame(format, stream, target, AVSEEK_FLAG_BACKWARD) < 0 &&
            f.av_seek_frame(format, -1, 0, AVSEEK_FLAG_BACKWARD) < 0)
            return fail("This video cannot be sought.");
        f.avcodec_flush_buffers(decoder);
        draining = false;
        has_current = has_upcoming = false;
        const int first = step();
        if (first <= 0) return first;
        const double tolerance = 0.25 / info.frame_rate;
        double next = 0;
        while (true) {
            const int result = peek(&next);
            if (result < 0) return result;
            if (result == 0 || next > time + tolerance) return 1;
            step();
        }
    }

    bool prepare_scaler(int target_width, int target_height) {
        const FFmpeg &f = ff();
        const AVFrame *frame = current;
        const bool full = full_range();
        const Key wanted{frame->format, frame->width, frame->height, target_width, target_height,
                         colour.matrix, full, frame->chroma_location};
        if (scaler && key == wanted) return true;
        if (scaler) f.sws_freeContext(scaler);
        scaler = f.sws_alloc_context();
        if (!scaler) return false;
        const bool reduces = target_width * 2 <= frame->width;
        const int64_t flags = (reduces ? SWS_AREA : SWS_BILINEAR) | SWS_ACCURATE_RND
            | SWS_FULL_CHR_H_INT | SWS_FULL_CHR_H_INP;
        f.av_opt_set_int(scaler, "srcw", frame->width, 0);
        f.av_opt_set_int(scaler, "srch", frame->height, 0);
        f.av_opt_set_int(scaler, "src_format", frame->format, 0);
        f.av_opt_set_int(scaler, "dstw", target_width, 0);
        f.av_opt_set_int(scaler, "dsth", target_height, 0);
        f.av_opt_set_int(scaler, "dst_format", AV_PIX_FMT_GBRPF32LE, 0);
        f.av_opt_set_int(scaler, "sws_flags", flags, 0);
        f.av_opt_set_int(scaler, "threads", threads(), 0);
        // Chroma where the direct read puts it (`chroma_centred_h`), in 1/256 of a pixel.
        f.av_opt_set_int(scaler, "src_h_chr_pos", chroma_centred_h() ? 128 : 0, 0);
        f.av_opt_set_int(scaler, "src_v_chr_pos", chroma_centred_v() ? 128 : 0, 0);
        if (f.sws_init_context(scaler, nullptr, nullptr) < 0) {
            f.sws_freeContext(scaler);
            scaler = nullptr;
            return false;
        }
        int space = SWS_CS_ITU709;
        switch (colour.matrix) {
        case 4: space = SWS_CS_FCC; break;
        case 5: case 6: space = SWS_CS_ITU601; break;
        case 7: space = SWS_CS_SMPTE240M; break;
        case 9: case 10: space = SWS_CS_BT2020; break;
        default: break;
        }
        const int *coefficients = f.sws_getCoefficients(space);
        f.sws_setColorspaceDetails(scaler, coefficients, full, coefficients, 1, 0, 1 << 16, 1 << 16);
        key = wanted;
        return true;
    }

    /// A planar Y'CbCr layout read here directly: sample depth and chroma subsampling.
    struct Planar {
        int bits = 0, cw = 1, ch = 1;
    };

    static bool planar(int format, Planar &layout) {
        switch (format) {
        case AV_PIX_FMT_YUV420P: case AV_PIX_FMT_YUVJ420P: layout = {8, 2, 2}; return true;
        case AV_PIX_FMT_YUV422P: case AV_PIX_FMT_YUVJ422P: layout = {8, 2, 1}; return true;
        case AV_PIX_FMT_YUV444P: case AV_PIX_FMT_YUVJ444P: layout = {8, 1, 1}; return true;
        case AV_PIX_FMT_YUV420P10LE: layout = {10, 2, 2}; return true;
        case AV_PIX_FMT_YUV422P10LE: layout = {10, 2, 1}; return true;
        case AV_PIX_FMT_YUV444P10LE: layout = {10, 1, 1}; return true;
        case AV_PIX_FMT_YUV420P12LE: layout = {12, 2, 2}; return true;
        case AV_PIX_FMT_YUV422P12LE: layout = {12, 2, 1}; return true;
        case AV_PIX_FMT_YUV444P12LE: layout = {12, 1, 1}; return true;
        default: return false;
        }
    }

    bool full_range() const {
        const AVFrame *frame = current;
        return frame->color_range == AVCOL_RANGE_JPEG || frame->format == AV_PIX_FMT_YUVJ420P
            || frame->format == AV_PIX_FMT_YUVJ422P || frame->format == AV_PIX_FMT_YUVJ444P
            || (frame->color_range != AVCOL_RANGE_MPEG && info.full_range);
    }

    /// Where the frame's chroma samples sit, horizontally and vertically: centred between their
    /// pixels, or on the first of them. Matched against AVFoundation's decode of H.264 tagged
    /// left-sited: it takes such chroma as sitting on its top-left pixel, and only a centred
    /// tag moves it.
    bool chroma_centred_h() const {
        const int location = current->chroma_location;
        return location == AVCHROMA_LOC_CENTER || location == AVCHROMA_LOC_TOP
            || location == AVCHROMA_LOC_BOTTOM;
    }
    bool chroma_centred_v() const { return current->chroma_location == AVCHROMA_LOC_CENTER; }

    /// Row `y` of the frame as R'G'B' signal, straight from its planes: chroma upsampled
    /// bilinearly from where its samples sit.
    template <typename Sample>
    void signal_row(int y, const Planar &layout, float *cb_line, float *cr_line, float *r,
                    float *g, float *b) const {
        const AVFrame *frame = current;
        const int width = frame->width;
        const int chroma_w = (width + layout.cw - 1) / layout.cw;
        const int chroma_h = (frame->height + layout.ch - 1) / layout.ch;
        const bool full = full_range();
        const float unit = static_cast<float>(1 << (layout.bits - 8));
        const float top = static_cast<float>((1 << layout.bits) - 1);
        const float black = full ? 0 : 16 * unit, luma_span = full ? top : 219 * unit;
        const float middle = 128 * unit, chroma_span = full ? top : 224 * unit;
        const YCbCr m = YCbCr::of(colour.matrix);
        const float to_r = m.cr(), to_b = m.cb();
        const float g_from_cb = m.cb() * m.kb / m.kg(), g_from_cr = m.cr() * m.kr / m.kg();

        auto row = [frame](int plane, int index) {
            return reinterpret_cast<const Sample *>(frame->data[plane]
                                                    + static_cast<ptrdiff_t>(index) * frame->linesize[plane]);
        };
        // Where the row falls between chroma rows.
        int c0 = y, c1 = y;
        float tv = 0;
        if (layout.ch == 2) {
            const float position = static_cast<float>(y) * 0.5f - (chroma_centred_v() ? 0.25f : 0);
            const int low = static_cast<int>(std::floor(position));
            tv = position - static_cast<float>(low);
            c0 = std::clamp(low, 0, chroma_h - 1);
            c1 = std::clamp(low + 1, 0, chroma_h - 1);
        }
        const Sample *cb0 = row(1, c0), *cb1 = row(1, c1), *cr0 = row(2, c0), *cr1 = row(2, c1);
        for (int i = 0; i < chroma_w; ++i) {
            cb_line[i] = (cb0[i] + (static_cast<float>(cb1[i]) - cb0[i]) * tv - middle) / chroma_span;
            cr_line[i] = (cr0[i] + (static_cast<float>(cr1[i]) - cr0[i]) * tv - middle) / chroma_span;
        }
        const Sample *luma = row(0, y);
        const bool centred = chroma_centred_h();
        for (int x = 0; x < width; ++x) {
            float cb = cb_line[x], cr = cr_line[x];
            if (layout.cw == 2) {
                const int i = x >> 1;
                if (centred) {
                    // Even pixels sit a quarter of a chroma sample before theirs, odd ones after.
                    const int other = std::clamp(x & 1 ? i + 1 : i - 1, 0, chroma_w - 1);
                    cb = 0.75f * cb_line[i] + 0.25f * cb_line[other];
                    cr = 0.75f * cr_line[i] + 0.25f * cr_line[other];
                } else if (x & 1) {
                    // Even pixels carry their sample; odd ones sit halfway to the next.
                    const int next = std::min(i + 1, chroma_w - 1);
                    cb = 0.5f * (cb_line[i] + cb_line[next]);
                    cr = 0.5f * (cr_line[i] + cr_line[next]);
                } else {
                    cb = cb_line[i];
                    cr = cr_line[i];
                }
            }
            const float l = (luma[x] - black) / luma_span;
            r[x] = l + to_r * cr;
            g[x] = l - g_from_cb * cb - g_from_cr * cr;
            b[x] = l + to_b * cb;
        }
    }

    int convert(int kind, int width, int height, void *pixels, size_t row_bytes) {
        if (!has_current) return fail("There is no frame here.");
        const int turns = info.quarter_turns;
        const int stored_w = turns % 2 ? height : width;
        const int stored_h = turns % 2 ? width : height;
        // At the frame's own size its planes are read here; a resize, or a layout not read here,
        // goes through swscale to float planes first.
        Planar layout;
        const bool direct = stored_w == current->width && stored_h == current->height
            && planar(current->format, layout);
        const size_t plane = static_cast<size_t>(stored_w) * stored_h;
        float *green = nullptr, *blue = nullptr, *red = nullptr;
        if (!direct) {
            if (!prepare_scaler(stored_w, stored_h))
                return fail("This video's frames cannot be converted.");
            planes.resize(plane * 3);
            // GBR planes, as swscale orders them.
            green = planes.data(), blue = green + plane, red = blue + plane;
            uint8_t *targets[4] = {reinterpret_cast<uint8_t *>(green),
                                   reinterpret_cast<uint8_t *>(blue),
                                   reinterpret_cast<uint8_t *>(red), nullptr};
            const int strides[4] = {stored_w * 4, stored_w * 4, stored_w * 4, 0};
            ff().sws_scale(scaler, current->data, current->linesize, 0, current->height, targets,
                           strides);
        }
        if (kind != FFV_SIGNAL && !tables) tables = std::make_unique<ManagedTables>(colour.transfer);
        const Matrix p3_matrix = colour.to_display_p3(), rec2020_matrix = colour.to_rec2020();
        const ManagedTables::View no_tables{nullptr, nullptr};
        const ManagedTables::View tables_view = tables ? tables->view() : no_tables;
        auto *out = static_cast<uint8_t *>(pixels);
        const ptrdiff_t pixel = kind == FFV_DISPLAY_P3_8 ? 4 : 16;
        const ptrdiff_t stride = static_cast<ptrdiff_t>(row_bytes);
        parallel_rows(stored_h, [&](int first, int last) {
            // Locals, so the stores below cannot be taken to change them.
            const Matrix p3 = p3_matrix, rec2020 = rec2020_matrix;
            const ManagedTables::View managed = tables_view;
            std::vector<float> scratch(direct ? static_cast<size_t>(stored_w) * 5 : 0);
            for (int y = first; y < last; ++y) {
                const float *r, *g, *b;
                if (direct) {
                    float *rs = scratch.data(), *gs = rs + stored_w, *bs = gs + stored_w;
                    float *cb_line = bs + stored_w, *cr_line = cb_line + stored_w;
                    if (layout.bits == 8) signal_row<uint8_t>(y, layout, cb_line, cr_line, rs, gs, bs);
                    else signal_row<uint16_t>(y, layout, cb_line, cr_line, rs, gs, bs);
                    r = rs, g = gs, b = bs;
                } else {
                    const size_t row = static_cast<size_t>(y) * stored_w;
                    r = red + row, g = green + row, b = blue + row;
                }
                // Where this stored row lands upright: its first pixel and the step to the next.
                uint8_t *target = out;
                ptrdiff_t step = pixel;
                switch (turns) {
                case 1: target += (stored_h - 1 - y) * pixel; step = stride; break;
                case 2: target += (stored_h - 1 - y) * stride + (stored_w - 1) * pixel; step = -pixel; break;
                case 3: target += (stored_w - 1) * stride + y * pixel; step = -stride; break;
                default: target += y * stride; break;
                }
                for (int x = 0; x < stored_w; ++x, target += step) {
                    if (kind == FFV_DISPLAY_P3_8) {
                        const float lr = managed.linear(r[x]), lg = managed.linear(g[x]),
                                    lb = managed.linear(b[x]);
                        target[0] = managed.code(p3[0] * lr + p3[1] * lg + p3[2] * lb);
                        target[1] = managed.code(p3[3] * lr + p3[4] * lg + p3[5] * lb);
                        target[2] = managed.code(p3[6] * lr + p3[7] * lg + p3[8] * lb);
                        target[3] = 255;
                        continue;
                    }
                    float *p = reinterpret_cast<float *>(target);
                    if (kind == FFV_LINEAR_REC2020) {
                        const float lr = managed.linear(r[x]), lg = managed.linear(g[x]),
                                    lb = managed.linear(b[x]);
                        p[0] = rec2020[0] * lr + rec2020[1] * lg + rec2020[2] * lb;
                        p[1] = rec2020[3] * lr + rec2020[4] * lg + rec2020[5] * lb;
                        p[2] = rec2020[6] * lr + rec2020[7] * lg + rec2020[8] * lb;
                    } else {
                        p[0] = r[x];
                        p[1] = g[x];
                        p[2] = b[x];
                    }
                    for (int c = 0; c < 3; ++c)
                        if (!std::isfinite(p[c])) p[c] = 0;
                    p[3] = 1;
                }
            }
        });
        return 0;
    }
};

namespace {

void copy_tag(AVDictionary *metadata, std::initializer_list<const char *> keys, char *into,
              size_t capacity) {
    if (into[0] || !metadata) return;
    for (const char *key : keys) {
        if (const AVDictionaryEntry *entry = ff().av_dict_get(metadata, key, nullptr, 0);
            entry && entry->value && entry->value[0]) {
            std::strncpy(into, entry->value, capacity - 1);
            return;
        }
    }
}

/// Opens `path`'s best stream of `type` with its decoder.
bool open_stream(const char *path, AVMediaType type, AVFormatContext **format,
                 AVCodecContext **decoder, int *stream) {
    const FFmpeg &f = ff();
    if (f.avformat_open_input(format, path, nullptr, nullptr) < 0) return false;
    if (f.avformat_find_stream_info(*format, nullptr) < 0) return false;
    const AVCodec *codec = nullptr;
    *stream = f.av_find_best_stream(*format, type, -1, -1, &codec, 0);
    if (*stream < 0 || !codec) return false;
    *decoder = f.avcodec_alloc_context3(codec);
    if (!*decoder) return false;
    const AVStream *s = (*format)->streams[*stream];
    if (f.avcodec_parameters_to_context(*decoder, s->codecpar) < 0) return false;
    (*decoder)->pkt_timebase = s->time_base;
    (*decoder)->thread_count = threads();
    (*decoder)->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    return f.avcodec_open2(*decoder, codec, nullptr) >= 0;
}

}  // namespace

extern "C" ffv_reader *ffv_open(const char *path, ffv_info *info) {
    if (!load()) return fail("FFmpeg is not installed."), nullptr;
    const FFmpeg &f = ff();
    auto reader = std::make_unique<ffv_reader>();
    if (!open_stream(path, AVMEDIA_TYPE_VIDEO, &reader->format, &reader->decoder, &reader->stream))
        return fail("This file doesn’t contain a video this computer can decode."), nullptr;
    const AVStream *stream = reader->format->streams[reader->stream];
    const AVCodecParameters *par = stream->codecpar;
    reader->time_base = stream->time_base;
    reader->packet = f.av_packet_alloc();
    reader->current = f.av_frame_alloc();
    reader->upcoming = f.av_frame_alloc();
    if (!reader->packet || !reader->current || !reader->upcoming) return nullptr;

    ffv_info &i = reader->info;
    reader->stored_width = par->width;
    reader->stored_height = par->height;
    if (const AVPacketSideData *matrix = f.av_packet_side_data_get(
            par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
        matrix && matrix->size >= 9 * sizeof(int32_t)) {
        // The display matrix turns counterclockwise; upright is the clockwise turn back.
        const double clockwise =
            -f.av_display_rotation_get(reinterpret_cast<const int32_t *>(matrix->data));
        if (std::isfinite(clockwise))
            i.quarter_turns = static_cast<int>(((std::lround(clockwise / 90) % 4) + 4) % 4);
    }
    i.width = i.quarter_turns % 2 ? par->height : par->width;
    i.height = i.quarter_turns % 2 ? par->width : par->height;
    if (i.width <= 0 || i.height <= 0)
        return fail("This file doesn’t contain a video."), nullptr;
    const AVPixFmtDescriptor *descriptor =
        f.av_pix_fmt_desc_get(static_cast<AVPixelFormat>(par->format));
    i.bits = descriptor ? descriptor->comp[0].depth
                        : (par->bits_per_raw_sample > 0 ? par->bits_per_raw_sample : 8);
    const double base = av_q2d(stream->time_base);
    i.start = stream->start_time != AV_NOPTS_VALUE ? std::max(0.0, stream->start_time * base) : 0;
    const double length = stream->duration != AV_NOPTS_VALUE ? stream->duration * base
        : reader->format->duration != AV_NOPTS_VALUE
            ? static_cast<double>(reader->format->duration) / AV_TIME_BASE
            : 0;
    i.end = std::max(i.start, i.start + length);
    const AVRational rate = stream->avg_frame_rate.num > 0 ? stream->avg_frame_rate
                                                           : stream->r_frame_rate;
    i.frame_rate = rate.num > 0 && rate.den > 0 ? av_q2d(rate) : 30;
    i.has_audio = f.av_find_best_stream(reader->format, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0) >= 0;
    i.primaries = par->color_primaries;
    i.transfer = par->color_trc;
    i.matrix = par->color_space;
    i.full_range = par->color_range == AVCOL_RANGE_JPEG;
    for (AVDictionary *metadata : {reader->format->metadata, stream->metadata}) {
        copy_tag(metadata, {"com.apple.quicktime.make", "make", "com.android.manufacturer"}, i.make,
                 sizeof(i.make));
        copy_tag(metadata, {"com.apple.quicktime.model", "model", "com.android.model"}, i.model,
                 sizeof(i.model));
    }
    reader->colour = SourceColour::resolve(i.transfer, i.primaries, i.matrix, i.full_range,
                                           reader->stored_width, reader->stored_height);
    if (info) *info = i;
    return reader.release();
}

extern "C" void ffv_close(ffv_reader *reader) { delete reader; }

extern "C" int32_t ffv_seek(ffv_reader *reader, double seconds) { return reader->seek(seconds); }

extern "C" int32_t ffv_peek(ffv_reader *reader, double *time) { return reader->peek(time); }

extern "C" int32_t ffv_step(ffv_reader *reader) { return reader->step(); }

extern "C" void ffv_current(const ffv_reader *reader, double *time, double *duration) {
    if (!reader->has_current) {
        if (time) *time = 0;
        if (duration) *duration = 1 / reader->info.frame_rate;
        return;
    }
    if (time) *time = reader->seconds(reader->current);
    if (duration) *duration = reader->duration(reader->current);
}

extern "C" int32_t ffv_convert(ffv_reader *reader, int32_t format, int32_t width, int32_t height,
                               void *pixels, size_t row_bytes) {
    return reader->convert(format, width, height, pixels, row_bytes);
}

extern "C" int32_t ffv_audio(const char *path, int32_t rate, int16_t **samples, size_t *count) {
    *samples = nullptr;
    *count = 0;
    if (!load()) return fail("FFmpeg is not installed.");
    const FFmpeg &f = ff();
    AVFormatContext *format = nullptr;
    AVCodecContext *decoder = nullptr;
    int stream = -1;
    const bool opened = open_stream(path, AVMEDIA_TYPE_AUDIO, &format, &decoder, &stream);
    std::vector<int16_t> out;
    int result = 0;
    SwrContext *resampler = nullptr;
    AVChannelLayout stereo;
    f.av_channel_layout_default(&stereo, 2);
    AVPacket *packet = f.av_packet_alloc();
    AVFrame *frame = f.av_frame_alloc();
    if (opened &&
        f.swr_alloc_set_opts2(&resampler, &stereo, AV_SAMPLE_FMT_S16, rate, &decoder->ch_layout,
                              decoder->sample_fmt, decoder->sample_rate, 0, nullptr) >= 0 &&
        f.swr_init(resampler) >= 0) {
        auto drain = [&](const AVFrame *input) {
            const int room = input ? static_cast<int>(f.swr_get_delay(resampler, rate))
                    + input->nb_samples * rate / std::max(1, decoder->sample_rate) + 256
                                   : 4096;
            const size_t at = out.size();
            out.resize(at + static_cast<size_t>(room) * 2);
            uint8_t *target = reinterpret_cast<uint8_t *>(out.data() + at);
            const int made = f.swr_convert(resampler, &target, room,
                                           input ? const_cast<const uint8_t **>(input->extended_data)
                                                 : nullptr,
                                           input ? input->nb_samples : 0);
            out.resize(at + static_cast<size_t>(std::max(made, 0)) * 2);
            return made;
        };
        bool ended = false;
        while (!ended) {
            if (f.av_read_frame(format, packet) < 0) {
                f.avcodec_send_packet(decoder, nullptr);
                ended = true;
            } else {
                if (packet->stream_index == stream) f.avcodec_send_packet(decoder, packet);
                f.av_packet_unref(packet);
            }
            while (f.avcodec_receive_frame(decoder, frame) == 0) {
                drain(frame);
                f.av_frame_unref(frame);
            }
        }
        while (drain(nullptr) > 0) {}
        result = 1;
    } else if (opened) {
        result = fail("This video's sound cannot be converted.");
    }
    f.av_frame_free(&frame);
    f.av_packet_free(&packet);
    f.swr_free(&resampler);
    f.av_channel_layout_uninit(&stereo);
    f.avcodec_free_context(&decoder);
    if (format) f.avformat_close_input(&format);
    if (result == 1 && !out.empty()) {
        *samples = static_cast<int16_t *>(std::malloc(out.size() * sizeof(int16_t)));
        if (!*samples) return fail("Out of memory.");
        std::memcpy(*samples, out.data(), out.size() * sizeof(int16_t));
        *count = out.size();
    }
    return result == 1 && *count > 0 ? 1 : result;
}
#endif
