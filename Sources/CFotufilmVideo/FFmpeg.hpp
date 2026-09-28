// The system's FFmpeg, loaded with dlopen: every call goes through `ff()`, never a linked symbol,
// so libfotufilm.so has no FFmpeg dependency and a machine without it still runs the app. The
// libraries loaded are the major versions whose headers this was compiled against; their structs
// are read directly, which a different major would lay out differently.
#pragma once

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <string>

namespace fotufilm::video {

#define FFV_FUNCTIONS(X)                                                                         \
    X(avutil, av_frame_alloc) X(avutil, av_frame_free) X(avutil, av_frame_unref)                 \
    X(avutil, av_frame_get_buffer) X(avutil, av_frame_make_writable) X(avutil, av_frame_move_ref) \
    X(avutil, av_dict_get) X(avutil, av_dict_set) X(avutil, av_dict_free)                        \
    X(avutil, av_opt_set) X(avutil, av_opt_set_int) X(avutil, av_strerror)                       \
    X(avutil, av_display_rotation_get) X(avutil, av_log_set_level) X(avutil, av_rescale_q)       \
    X(avutil, av_d2q) X(avutil, av_pix_fmt_desc_get) X(avutil, av_channel_layout_default)        \
    X(avutil, av_channel_layout_uninit) X(avutil, av_channel_layout_copy)                        \
    X(avutil, av_audio_fifo_alloc) X(avutil, av_audio_fifo_free) X(avutil, av_audio_fifo_write)  \
    X(avutil, av_audio_fifo_read) X(avutil, av_audio_fifo_size)                                  \
    X(avcodec, avcodec_find_decoder) X(avcodec, avcodec_find_encoder)                            \
    X(avcodec, avcodec_find_encoder_by_name) X(avcodec, avcodec_alloc_context3)                  \
    X(avcodec, avcodec_free_context) X(avcodec, avcodec_parameters_to_context)                   \
    X(avcodec, avcodec_parameters_from_context) X(avcodec, avcodec_parameters_copy)              \
    X(avcodec, avcodec_open2) X(avcodec, avcodec_send_packet) X(avcodec, avcodec_receive_frame)  \
    X(avcodec, avcodec_send_frame) X(avcodec, avcodec_receive_packet)                            \
    X(avcodec, avcodec_flush_buffers) X(avcodec, av_packet_alloc) X(avcodec, av_packet_free)     \
    X(avcodec, av_packet_unref) X(avcodec, av_packet_rescale_ts)                                 \
    X(avcodec, av_packet_side_data_get)                                                          \
    X(avformat, avformat_open_input) X(avformat, avformat_find_stream_info)                      \
    X(avformat, av_find_best_stream) X(avformat, avformat_close_input) X(avformat, av_read_frame) \
    X(avformat, av_seek_frame) X(avformat, avformat_alloc_output_context2)                       \
    X(avformat, avformat_new_stream) X(avformat, avio_open) X(avformat, avio_closep)             \
    X(avformat, avformat_write_header) X(avformat, av_interleaved_write_frame)                   \
    X(avformat, av_write_trailer) X(avformat, avformat_free_context)                             \
    X(avformat, avformat_query_codec)                                                            \
    X(swscale, sws_alloc_context) X(swscale, sws_init_context) X(swscale, sws_freeContext)       \
    X(swscale, sws_scale) X(swscale, sws_setColorspaceDetails) X(swscale, sws_getCoefficients)   \
    X(swresample, swr_alloc_set_opts2) X(swresample, swr_init) X(swresample, swr_convert)        \
    X(swresample, swr_free) X(swresample, swr_get_delay)

struct FFmpeg {
#define FFV_MEMBER(library, name) decltype(&::name) name = nullptr;
    FFV_FUNCTIONS(FFV_MEMBER)
#undef FFV_MEMBER
};

/// The loaded libraries, or null where they are missing.
const FFmpeg *load();

/// The loaded libraries; only called once `load()` has answered.
inline const FFmpeg &ff() { return *load(); }

/// Records a failure for ffv_last_error and returns `code`.
int fail(const std::string &message, int code = -1);
/// FFmpeg's message for an error code.
std::string describe(int error);

/// Threads a conversion, decode or encode may use: the CPUs this process may run on, within its
/// cgroup quota.
int threads();

}  // namespace fotufilm::video
