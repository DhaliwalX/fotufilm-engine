// Encoding: the formats the Mac app writes (H.264, 10-bit HEVC, ProRes), each through the GPU's
// encoder where one answers and FFmpeg's software encoder otherwise, tagged as the Mac tags them,
// with the source's sound carried across the way AVAssetWriter carries it.
// Built where FFmpeg's headers are (Linux); elsewhere the platform's own framework decodes.
#if __has_include(<libavformat/avformat.h>)
#include "Colour.hpp"
#include "FFmpeg.hpp"
#include "Parallel.hpp"
#include "fotufilm_video.h"

#include <unistd.h>

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

using namespace fotufilm::video;

namespace {

constexpr AVRational kVideoTime{1, 90000};

/// The encoders tried for a codec, first choice first. FOTUFILM_VIDEO_ENCODER=software skips the
/// GPU's; a name picks that encoder.
std::vector<std::string> encoders(int codec) {
    const char *wanted = std::getenv("FOTUFILM_VIDEO_ENCODER");
    const std::string choice = wanted ? wanted : "";
    std::vector<std::string> names;
    switch (codec) {
    case FFV_CODEC_H264: names = {"h264_nvenc", "libx264"}; break;
    case FFV_CODEC_HEVC10: names = {"hevc_nvenc", "libx265"}; break;
    // prores_aw writes at about four times prores_ks's speed for the same picture (luma PSNR
    // within 0.3 dB on the same frames), a little under Apple's rates where prores_ks meets them.
    default: names = {"prores_aw", "prores_ks"}; break;
    }
    if (choice == "software") {
        names.erase(std::remove_if(names.begin(), names.end(),
                                   [](const std::string &name) {
                                       return name.find("_nvenc") != std::string::npos;
                                   }),
                    names.end());
    }
    else if (!choice.empty()) {
        for (const auto &name : names)
            if (name == choice) return {choice};
    }
    return names;
}

AVPixelFormat encoder_format(const std::string &name, int prores_profile) {
    if (name == "hevc_nvenc") return AV_PIX_FMT_P010LE;
    if (name == "libx265") return AV_PIX_FMT_YUV420P10LE;
    if (name == "prores_aw" || name == "prores_ks")
        return prores_profile >= 4 ? AV_PIX_FMT_YUVA444P10LE : AV_PIX_FMT_YUV422P10LE;
    return AV_PIX_FMT_YUV420P;
}

/// The Mac's encoder settings: quality where the rate is the encoder's, the rate where it is set.
void configure(AVCodecContext *c, const std::string &name, const ffv_writer_config &config) {
    const FFmpeg &f = ff();
    void *options = c->priv_data;
    if (name == "prores_aw" || name == "prores_ks") {
        // Proxy, LT, 422, HQ, 4444 and 4444 XQ, numbered alike by both encoders.
        if (name == "prores_aw") c->profile = config.prores_profile;
        else f.av_opt_set_int(options, "profile", config.prores_profile, 0);
        f.av_opt_set(options, "vendor", "apl0", 0);
        return;
    }
    if (config.bit_rate > 0) {
        c->bit_rate = config.bit_rate;
        c->rc_max_rate = config.bit_rate * 3 / 2;
        c->rc_buffer_size = static_cast<int>(std::min<int64_t>(config.bit_rate * 2, INT32_MAX));
    }
    if (name == "libx264") {
        f.av_opt_set(options, "preset", "fast", 0);
        if (config.bit_rate <= 0) f.av_opt_set(options, "crf", "18", 0);
    } else if (name == "libx265") {
        f.av_opt_set(options, "preset", "fast", 0);
        f.av_opt_set(options, "x265-params", "log-level=error", 0);
        if (config.bit_rate <= 0) f.av_opt_set(options, "crf", "18", 0);
    } else {
        // NVENC: its high-quality preset, variable rate, and a constant quality when automatic.
        // No B-frames: its decode timestamps assume a time base of one tick a frame, and these
        // frames keep their own times.
        c->max_b_frames = 0;
        f.av_opt_set(options, "preset", "p5", 0);
        f.av_opt_set(options, "tune", "hq", 0);
        f.av_opt_set(options, "rc", "vbr", 0);
        if (name == "hevc_nvenc") f.av_opt_set(options, "profile", "main10", 0);
        if (config.bit_rate <= 0) f.av_opt_set_int(options, "cq", 19, 0);
    }
}

/// RGBA codes (`Sample` a channel, `scale` taking a code to [0, 1]) into the encoder's planar
/// video-range Y'CbCr, `bits` deep, each chroma sample the mean of a `cw` x `ch` block of the
/// pixels' own, as the Mac's 4:2:0 fill reduces them (`SDRVideoTransfer.encode420`). Alpha, where
/// the frame has a plane for it, is opaque.
template <typename Sample, typename Out>
void to_ycbcr(const uint8_t *bytes, size_t row_bytes, float scale, YCbCr m, int bits,
              int cw, int ch, AVFrame *frame) {
    const int width = frame->width, height = frame->height;
    const float top = static_cast<float>((1 << bits) - 1);
    const float black = static_cast<float>(16 << (bits - 8));
    const float luma_span = static_cast<float>(219 << (bits - 8));
    const float middle = static_cast<float>(128 << (bits - 8));
    const float chroma_span = static_cast<float>(224 << (bits - 8));
    auto code = [top](float value) {
        return static_cast<Out>(std::fmin(std::fmax(value + 0.5f, 0.0f), top));
    };
    auto plane = [frame](int index, int y) {
        return reinterpret_cast<Out *>(frame->data[index] + static_cast<size_t>(y) * frame->linesize[index]);
    };
    const bool alpha = frame->data[3] != nullptr;
    const float kg = m.kg(), to_cb = 1 / m.cb(), to_cr = 1 / m.cr();
    parallel_rows(height / ch, [&](int first, int last) {
        for (int cy = first; cy < last; ++cy) {
            Out *cb_row = plane(1, cy), *cr_row = plane(2, cy);
            for (int cx = 0; cx < width / cw; ++cx) {
                float cb = 0, cr = 0;
                for (int dy = 0; dy < ch; ++dy) {
                    const int y = cy * ch + dy;
                    const auto *row = reinterpret_cast<const Sample *>(bytes + y * row_bytes);
                    Out *luma = plane(0, y);
                    for (int dx = 0; dx < cw; ++dx) {
                        const int x = cx * cw + dx;
                        const Sample *p = row + x * 4;
                        const float r = std::fmin(p[0] * scale, 1.0f);
                        const float g = std::fmin(p[1] * scale, 1.0f);
                        const float b = std::fmin(p[2] * scale, 1.0f);
                        const float l = m.kr * r + kg * g + m.kb * b;
                        luma[x] = code(black + luma_span * l);
                        cb += (b - l) * to_cb;
                        cr += (r - l) * to_cr;
                    }
                }
                const float share = 1.0f / static_cast<float>(cw * ch);
                cb_row[cx] = code(middle + chroma_span * cb * share);
                cr_row[cx] = code(middle + chroma_span * cr * share);
            }
            if (alpha)
                for (int dy = 0; dy < ch; ++dy) std::fill_n(plane(3, cy * ch + dy), width, code(top));
        }
    });
}

/// P010's two planes, codes in the high ten bits, into planar 10-bit 4:2:0.
void p010_to_planar(const uint8_t *bytes, size_t row_bytes, AVFrame *frame) {
    const int width = frame->width, height = frame->height;
    parallel_rows(height / 2, [&](int first, int last) {
        for (int cy = first; cy < last; ++cy) {
            for (int y = cy * 2; y < cy * 2 + 2; ++y) {
                const auto *source = reinterpret_cast<const uint16_t *>(bytes + y * row_bytes);
                auto *luma = reinterpret_cast<uint16_t *>(frame->data[0] + y * frame->linesize[0]);
                for (int x = 0; x < width; ++x) luma[x] = source[x] >> 6;
            }
            const auto *chroma = reinterpret_cast<const uint16_t *>(
                bytes + (static_cast<size_t>(height) + cy) * row_bytes);
            auto *cb = reinterpret_cast<uint16_t *>(frame->data[1] + cy * frame->linesize[1]);
            auto *cr = reinterpret_cast<uint16_t *>(frame->data[2] + cy * frame->linesize[2]);
            for (int x = 0; x < width / 2; ++x) {
                cb[x] = chroma[x * 2] >> 6;
                cr[x] = chroma[x * 2 + 1] >> 6;
            }
        }
    });
}

/// P010 as it is, into an encoder that takes it.
void p010_copy(const uint8_t *bytes, size_t row_bytes, AVFrame *frame) {
    const int height = frame->height;
    const size_t row = static_cast<size_t>(frame->width) * 2;
    for (int y = 0; y < height; ++y)
        std::memcpy(frame->data[0] + y * frame->linesize[0], bytes + y * row_bytes, row);
    const uint8_t *chroma = bytes + row_bytes * height;
    for (int y = 0; y < height / 2; ++y)
        std::memcpy(frame->data[1] + y * frame->linesize[1], chroma + y * row_bytes, row);
}

/// The source's sound over the movie's range: its packets copied where the container takes the
/// codec, as AVAssetWriter passes sound through, and AAC otherwise.
struct Sound {
    AVFormatContext *input = nullptr;
    int index = -1;
    AVStream *output = nullptr;
    AVRational in_base{1, 1};
    int64_t start_ts = 0;
    double start = 0, end = 0;
    AVPacket *packet = nullptr;
    bool pending = false;
    bool ended = false;
    // Transcoding.
    AVCodecContext *decoder = nullptr;
    AVCodecContext *encoder = nullptr;
    SwrContext *resampler = nullptr;
    AVAudioFifo *fifo = nullptr;
    AVFrame *frame = nullptr;
    int64_t samples_written = 0;

    ~Sound() {
        const FFmpeg &f = ff();
        f.av_packet_free(&packet);
        f.av_frame_free(&frame);
        if (fifo) f.av_audio_fifo_free(fifo);
        f.swr_free(&resampler);
        f.avcodec_free_context(&decoder);
        f.avcodec_free_context(&encoder);
        if (input) f.avformat_close_input(&input);
    }

    bool open(const char *path, AVFormatContext *out, double range_start, double range_end) {
        const FFmpeg &f = ff();
        start = range_start;
        end = range_end;
        if (f.avformat_open_input(&input, path, nullptr, nullptr) < 0) return false;
        if (f.avformat_find_stream_info(input, nullptr) < 0) return false;
        const AVCodec *codec = nullptr;
        index = f.av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
        if (index < 0) return false;
        const AVStream *source = input->streams[index];
        in_base = source->time_base;
        start_ts = static_cast<int64_t>(std::llround(start / av_q2d(in_base)));
        packet = f.av_packet_alloc();
        if (!packet) return false;
        const bool passes = f.avformat_query_codec(out->oformat, source->codecpar->codec_id,
                                                   FF_COMPLIANCE_NORMAL) == 1;
        // The stream is added only once its sound is ready, so a failure leaves the movie silent
        // rather than with a track the muxer refuses.
        if (!passes && !open_transcode(out, codec, source)) return false;
        output = f.avformat_new_stream(out, nullptr);
        if (!output) return false;
        if (passes) {
            if (f.avcodec_parameters_copy(output->codecpar, source->codecpar) < 0) return false;
            output->codecpar->codec_tag = 0;
            output->time_base = in_base;
        } else {
            if (f.avcodec_parameters_from_context(output->codecpar, encoder) < 0) return false;
            output->time_base = encoder->time_base;
        }
        f.av_seek_frame(input, index, start_ts, AVSEEK_FLAG_BACKWARD);
        return true;
    }

    bool open_transcode(AVFormatContext *out, const AVCodec *codec, const AVStream *source) {
        const FFmpeg &f = ff();
        if (!codec) return false;
        decoder = f.avcodec_alloc_context3(codec);
        if (!decoder || f.avcodec_parameters_to_context(decoder, source->codecpar) < 0) return false;
        decoder->pkt_timebase = source->time_base;
        if (f.avcodec_open2(decoder, codec, nullptr) < 0) return false;
        const AVCodec *aac = f.avcodec_find_encoder(AV_CODEC_ID_AAC);
        if (!aac || !(encoder = f.avcodec_alloc_context3(aac))) return false;
        f.av_channel_layout_default(&encoder->ch_layout,
                                    std::min(2, std::max(1, decoder->ch_layout.nb_channels)));
        encoder->sample_rate = 48000;
        encoder->sample_fmt = AV_SAMPLE_FMT_FLTP;
        encoder->bit_rate = 256000;
        encoder->time_base = AVRational{1, 48000};
        if (out->oformat->flags & AVFMT_GLOBALHEADER) encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if (f.avcodec_open2(encoder, aac, nullptr) < 0) return false;
        if (f.swr_alloc_set_opts2(&resampler, &encoder->ch_layout, encoder->sample_fmt,
                                  encoder->sample_rate, &decoder->ch_layout, decoder->sample_fmt,
                                  decoder->sample_rate, 0, nullptr) < 0
            || f.swr_init(resampler) < 0)
            return false;
        fifo = f.av_audio_fifo_alloc(encoder->sample_fmt, encoder->ch_layout.nb_channels, 4096);
        frame = f.av_frame_alloc();
        return fifo && frame;
    }

    double time(const AVPacket *p) const {
        const int64_t ts = p->pts != AV_NOPTS_VALUE ? p->pts : p->dts;
        return ts == AV_NOPTS_VALUE ? start : static_cast<double>(ts) * av_q2d(in_base);
    }

    /// Writes the sound heard before `until` on the source timeline.
    int pump(AVFormatContext *out, double until) {
        const FFmpeg &f = ff();
        until = std::min(until, end);
        while (!ended) {
            if (!pending) {
                if (f.av_read_frame(input, packet) < 0) {
                    ended = true;
                    break;
                }
                if (packet->stream_index != index) {
                    f.av_packet_unref(packet);
                    continue;
                }
                pending = true;
            }
            const double at = time(packet);
            if (at >= end) {
                ended = true;
                break;
            }
            if (at >= until) break;
            pending = false;
            const double length = packet->duration > 0 ? packet->duration * av_q2d(in_base) : 0;
            if (at + length <= start + 1e-6 || at < start - 1e-6) {
                // Sound before the trim: the movie starts at its first frame.
                f.av_packet_unref(packet);
                continue;
            }
            const int error = encoder ? transcode(out, packet) : copy(out, packet);
            f.av_packet_unref(packet);
            if (error < 0) return error;
        }
        return 0;
    }

    int copy(AVFormatContext *out, AVPacket *p) {
        if (p->pts != AV_NOPTS_VALUE) p->pts -= start_ts;
        if (p->dts != AV_NOPTS_VALUE) p->dts -= start_ts;
        ff().av_packet_rescale_ts(p, in_base, output->time_base);
        p->stream_index = output->index;
        p->pos = -1;
        return ff().av_interleaved_write_frame(out, p);
    }

    int transcode(AVFormatContext *out, AVPacket *p) {
        const FFmpeg &f = ff();
        f.avcodec_send_packet(decoder, p);
        return receive_decoded(out);
    }

    int receive_decoded(AVFormatContext *out) {
        const FFmpeg &f = ff();
        AVFrame *decoded = f.av_frame_alloc();
        while (f.avcodec_receive_frame(decoder, decoded) == 0) {
            const int room = static_cast<int>(f.swr_get_delay(resampler, encoder->sample_rate))
                + decoded->nb_samples * encoder->sample_rate / std::max(1, decoder->sample_rate)
                + 64;
            std::vector<uint8_t *> planes(encoder->ch_layout.nb_channels);
            std::vector<std::vector<float>> storage(planes.size(), std::vector<float>(room));
            for (size_t c = 0; c < planes.size(); ++c)
                planes[c] = reinterpret_cast<uint8_t *>(storage[c].data());
            const int made = f.swr_convert(resampler, planes.data(), room,
                                           const_cast<const uint8_t **>(decoded->extended_data),
                                           decoded->nb_samples);
            if (made > 0)
                f.av_audio_fifo_write(fifo, reinterpret_cast<void **>(planes.data()), made);
            f.av_frame_unref(decoded);
        }
        f.av_frame_free(&decoded);
        return encode_ready(out, false);
    }

    /// Encodes whole frames from the FIFO, and the remainder when `last`.
    int encode_ready(AVFormatContext *out, bool last) {
        const FFmpeg &f = ff();
        const int size = encoder->frame_size > 0 ? encoder->frame_size : 1024;
        while (f.av_audio_fifo_size(fifo) >= size || (last && f.av_audio_fifo_size(fifo) > 0)) {
            const int count = std::min(size, f.av_audio_fifo_size(fifo));
            f.av_frame_unref(frame);
            frame->nb_samples = count;
            frame->format = encoder->sample_fmt;
            frame->sample_rate = encoder->sample_rate;
            f.av_channel_layout_copy(&frame->ch_layout, &encoder->ch_layout);
            if (f.av_frame_get_buffer(frame, 0) < 0) return fail("The sound could not be encoded.");
            f.av_audio_fifo_read(fifo, reinterpret_cast<void **>(frame->data), count);
            frame->pts = samples_written;
            samples_written += count;
            if (f.avcodec_send_frame(encoder, frame) < 0) return fail("The sound could not be encoded.");
            if (const int error = write_encoded(out); error < 0) return error;
        }
        return 0;
    }

    int write_encoded(AVFormatContext *out) {
        const FFmpeg &f = ff();
        AVPacket *encoded = f.av_packet_alloc();
        int error = 0;
        while (f.avcodec_receive_packet(encoder, encoded) == 0) {
            f.av_packet_rescale_ts(encoded, encoder->time_base, output->time_base);
            encoded->stream_index = output->index;
            error = f.av_interleaved_write_frame(out, encoded);
            if (error < 0) break;
        }
        f.av_packet_free(&encoded);
        return error;
    }

    int finish(AVFormatContext *out) {
        if (const int error = pump(out, end); error < 0) return error;
        if (!encoder) return 0;
        const FFmpeg &f = ff();
        f.avcodec_send_packet(decoder, nullptr);
        receive_decoded(out);
        encode_ready(out, true);
        f.avcodec_send_frame(encoder, nullptr);
        return write_encoded(out);
    }
};

}  // namespace

struct ffv_writer {
    AVFormatContext *output = nullptr;
    AVStream *stream = nullptr;
    AVCodecContext *encoder = nullptr;
    AVFrame *frame = nullptr;
    AVPacket *packet = nullptr;
    std::unique_ptr<Sound> sound;
    std::string path, encoder_name;
    int pixels = FFV_PIXELS_RGBA8;
    double start = 0;
    int64_t last_pts = AV_NOPTS_VALUE;
    bool header_written = false;

    ~ffv_writer() {
        const FFmpeg &f = ff();
        sound.reset();
        f.av_frame_free(&frame);
        f.av_packet_free(&packet);
        f.avcodec_free_context(&encoder);
        if (output) {
            if (output->pb) f.avio_closep(&output->pb);
            f.avformat_free_context(output);
        }
    }

    int drain() {
        const FFmpeg &f = ff();
        while (true) {
            const int error = f.avcodec_receive_packet(encoder, packet);
            if (error == AVERROR(EAGAIN) || error == AVERROR_EOF) return 0;
            if (error < 0) return fail("The video could not be encoded: " + describe(error));
            f.av_packet_rescale_ts(packet, encoder->time_base, stream->time_base);
            packet->stream_index = stream->index;
            if (const int written = f.av_interleaved_write_frame(output, packet); written < 0)
                return fail("The video could not be written: " + describe(written));
        }
    }
};

namespace {

bool open_encoder(ffv_writer &w, const ffv_writer_config &config) {
    const FFmpeg &f = ff();
    for (const auto &name : encoders(config.codec)) {
        const AVCodec *codec = f.avcodec_find_encoder_by_name(name.c_str());
        if (!codec) continue;
        AVCodecContext *c = f.avcodec_alloc_context3(codec);
        if (!c) continue;
        c->width = config.width;
        c->height = config.height;
        c->time_base = kVideoTime;
        c->framerate = f.av_d2q(config.frame_rate, 100000);
        c->pix_fmt = encoder_format(name, config.prores_profile);
        c->gop_size = std::max(1, static_cast<int>(std::lround(config.frame_rate)) * 2);
        c->thread_count = threads();
        c->color_range = AVCOL_RANGE_MPEG;
        if (config.hdr) {
            // The Mac app's HDR colorimetry: BT.2020 primaries, HLG, the BT.2020 matrix.
            c->color_primaries = AVCOL_PRI_BT2020;
            c->color_trc = AVCOL_TRC_ARIB_STD_B67;
            c->colorspace = AVCOL_SPC_BT2020_NCL;
        } else {
            // Its SDR colorimetry: Display P3 primaries, the sRGB transfer, the BT.709 matrix.
            c->color_primaries = AVCOL_PRI_SMPTE432;
            c->color_trc = AVCOL_TRC_IEC61966_2_1;
            c->colorspace = AVCOL_SPC_BT709;
        }
        if (w.output->oformat->flags & AVFMT_GLOBALHEADER) c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        configure(c, name, config);
        if (f.avcodec_open2(c, codec, nullptr) >= 0) {
            w.encoder = c;
            w.encoder_name = name;
            return true;
        }
        f.avcodec_free_context(&c);
    }
    return false;
}

}  // namespace

extern "C" int32_t ffv_codecs(void) {
    if (!load()) return 0;
    const FFmpeg &f = ff();
    int32_t mask = 0;
    for (int codec : {FFV_CODEC_H264, FFV_CODEC_HEVC10, FFV_CODEC_PRORES})
        for (const auto &name : encoders(codec))
            if (f.avcodec_find_encoder_by_name(name.c_str())) mask |= 1 << codec;
    return mask;
}

extern "C" ffv_writer *ffv_writer_open(const ffv_writer_config *config) {
    if (!load()) return fail("FFmpeg is not installed."), nullptr;
    const FFmpeg &f = ff();
    auto w = std::make_unique<ffv_writer>();
    w->path = config->path;
    w->start = config->start;
    unlink(config->path);
    if (f.avformat_alloc_output_context2(&w->output, nullptr, nullptr, config->path) < 0)
        return fail("This container cannot be written."), nullptr;
    if (!open_encoder(*w, *config))
        return fail("No encoder for this format answers on this computer."), nullptr;
    w->stream = f.avformat_new_stream(w->output, nullptr);
    if (!w->stream || f.avcodec_parameters_from_context(w->stream->codecpar, w->encoder) < 0)
        return fail("The video track could not be written."), nullptr;
    w->stream->time_base = w->encoder->time_base;
    // QuickTime players read HEVC tagged hvc1.
    if (config->codec == FFV_CODEC_HEVC10) w->stream->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');

    w->pixels = config->codec == FFV_CODEC_H264 ? FFV_PIXELS_RGBA8
        : config->codec == FFV_CODEC_HEVC10     ? FFV_PIXELS_P010
                                                : FFV_PIXELS_RGBA64;
    w->frame = f.av_frame_alloc();
    w->packet = f.av_packet_alloc();
    if (!w->frame || !w->packet) return nullptr;
    w->frame->format = w->encoder->pix_fmt;
    w->frame->width = w->encoder->width;
    w->frame->height = w->encoder->height;
    if (f.av_frame_get_buffer(w->frame, 0) < 0) return nullptr;

    if (config->audio_path) {
        auto sound = std::make_unique<Sound>();
        // A movie whose sound cannot be carried is written silent, as the Mac's writer does.
        if (sound->open(config->audio_path, w->output, config->start, config->end))
            w->sound = std::move(sound);
    }
    if (f.avio_open(&w->output->pb, config->path, AVIO_FLAG_WRITE) < 0)
        return fail("The video could not be written here."), nullptr;
    if (const int error = f.avformat_write_header(w->output, nullptr); error < 0)
        return fail("The video could not be written: " + describe(error)), nullptr;
    w->header_written = true;
    return w.release();
}

extern "C" int32_t ffv_writer_pixels(const ffv_writer *writer) { return writer->pixels; }

extern "C" const char *ffv_writer_encoder(const ffv_writer *writer) {
    return writer->encoder_name.c_str();
}

extern "C" int32_t ffv_writer_append(ffv_writer *w, const void *pixels, size_t row_bytes,
                                     double seconds) {
    const FFmpeg &f = ff();
    if (f.av_frame_make_writable(w->frame) < 0) return fail("The video ran out of frame buffers.");
    const auto *bytes = static_cast<const uint8_t *>(pixels);
    // The Mac's matrices: BT.709 for SDR, BT.2020 for HLG.
    const YCbCr matrix = YCbCr::of(w->encoder->colorspace == AVCOL_SPC_BT2020_NCL ? 9 : 1);
    switch (w->encoder->pix_fmt) {
    case AV_PIX_FMT_YUV420P:
        to_ycbcr<uint8_t, uint8_t>(bytes, row_bytes, 1.0f / 255, matrix, 8, 2, 2, w->frame);
        break;
    case AV_PIX_FMT_YUV422P10LE:
        to_ycbcr<uint16_t, uint16_t>(bytes, row_bytes, 1.0f / 65535, matrix, 10, 2, 1, w->frame);
        break;
    case AV_PIX_FMT_YUVA444P10LE:
        to_ycbcr<uint16_t, uint16_t>(bytes, row_bytes, 1.0f / 65535, matrix, 10, 1, 1, w->frame);
        break;
    case AV_PIX_FMT_YUV420P10LE: p010_to_planar(bytes, row_bytes, w->frame); break;
    default: p010_copy(bytes, row_bytes, w->frame); break;
    }
    int64_t pts = std::llround((seconds - w->start) * kVideoTime.den);
    if (w->last_pts != AV_NOPTS_VALUE && pts <= w->last_pts) pts = w->last_pts + 1;
    w->last_pts = pts;
    w->frame->pts = pts;
    if (const int error = f.avcodec_send_frame(w->encoder, w->frame); error < 0)
        return fail("The video could not be encoded: " + describe(error));
    if (const int error = w->drain(); error < 0) return error;
    // The sound up to this frame, so the file interleaves as it grows.
    if (w->sound) return w->sound->pump(w->output, seconds);
    return 0;
}

extern "C" int32_t ffv_writer_finish(ffv_writer *w) {
    std::unique_ptr<ffv_writer> owned(w);
    const FFmpeg &f = ff();
    f.avcodec_send_frame(w->encoder, nullptr);
    if (w->drain() < 0) return -1;
    if (w->sound && w->sound->finish(w->output) < 0) return fail("The sound could not be written.");
    if (const int error = f.av_write_trailer(w->output); error < 0)
        return fail("The video could not be finished: " + describe(error));
    return 0;
}

extern "C" void ffv_writer_cancel(ffv_writer *w) {
    const std::string path = w->path;
    delete w;
    unlink(path.c_str());
}
#endif
