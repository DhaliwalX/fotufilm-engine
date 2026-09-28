// Built where FFmpeg's headers are (Linux); elsewhere the platform's own framework decodes.
#if __has_include(<libavformat/avformat.h>)
#include "FFmpeg.hpp"

#include "fotufilm_video.h"

#include <dlfcn.h>
#include <sched.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <thread>

#define FFV_TEXT(x) #x
#define FFV_SONAME(library, major) "lib" #library ".so." FFV_TEXT(major)

namespace fotufilm::video {
namespace {

thread_local std::string last_error;

}  // namespace

const FFmpeg *load() {
    static const FFmpeg *loaded = []() -> const FFmpeg * {
        static FFmpeg table;
        // Each library by the major version whose headers describe its structs.
        void *avutil = dlopen(FFV_SONAME(avutil, LIBAVUTIL_VERSION_MAJOR), RTLD_NOW | RTLD_LOCAL);
        void *swresample =
            dlopen(FFV_SONAME(swresample, LIBSWRESAMPLE_VERSION_MAJOR), RTLD_NOW | RTLD_LOCAL);
        void *swscale = dlopen(FFV_SONAME(swscale, LIBSWSCALE_VERSION_MAJOR), RTLD_NOW | RTLD_LOCAL);
        void *avcodec = dlopen(FFV_SONAME(avcodec, LIBAVCODEC_VERSION_MAJOR), RTLD_NOW | RTLD_LOCAL);
        void *avformat =
            dlopen(FFV_SONAME(avformat, LIBAVFORMAT_VERSION_MAJOR), RTLD_NOW | RTLD_LOCAL);
        if (!avutil || !swresample || !swscale || !avcodec || !avformat) return nullptr;
#define FFV_LOAD(library, name)                                                         \
    table.name = reinterpret_cast<decltype(table.name)>(dlsym(library, FFV_TEXT(name))); \
    if (!table.name) return nullptr;
        FFV_FUNCTIONS(FFV_LOAD)
#undef FFV_LOAD
        table.av_log_set_level(std::getenv("FOTUFILM_VIDEO_LOG") ? AV_LOG_INFO : AV_LOG_QUIET);
        return &table;
    }();
    return loaded;
}

int fail(const std::string &message, int code) {
    last_error = message;
    return code;
}

std::string describe(int error) {
    char text[AV_ERROR_MAX_STRING_SIZE] = {0};
    ff().av_strerror(error, text, sizeof(text));
    return text;
}

namespace {

/// The CPUs a cgroup quota grants (v2 `cpu.max`, v1 `cpu.cfs_quota_us`), or 0 when unlimited.
/// Threads past the quota do not run in parallel; they spend it early and the whole process
/// waits out the rest of the period.
int quota_cpus() {
    double quota = -1, period = 0;
    if (FILE *file = std::fopen("/sys/fs/cgroup/cpu.max", "r")) {
        char text[32] = {0};
        if (std::fscanf(file, "%31s %lf", text, &period) == 2 && text[0] != 'm')
            quota = std::atof(text);
        std::fclose(file);
    } else if (FILE *file = std::fopen("/sys/fs/cgroup/cpu/cpu.cfs_quota_us", "r")) {
        if (std::fscanf(file, "%lf", &quota) != 1) quota = -1;
        std::fclose(file);
        if (FILE *file = std::fopen("/sys/fs/cgroup/cpu/cpu.cfs_period_us", "r")) {
            if (std::fscanf(file, "%lf", &period) != 1) period = 0;
            std::fclose(file);
        }
    }
    return quota > 0 && period > 0 ? std::max(1, static_cast<int>(std::floor(quota / period))) : 0;
}

}  // namespace

int threads() {
    static const int count = [] {
        int cpus = static_cast<int>(std::thread::hardware_concurrency());
        cpu_set_t set;
        if (sched_getaffinity(0, sizeof(set), &set) == 0) cpus = CPU_COUNT(&set);
        if (const int quota = quota_cpus()) cpus = std::min(cpus, quota);
        return std::clamp(cpus, 1, 32);
    }();
    return count;
}

}  // namespace fotufilm::video

using namespace fotufilm::video;

extern "C" int32_t ffv_available(void) { return load() != nullptr; }

extern "C" const char *ffv_last_error(void) { return last_error.c_str(); }

extern "C" void ffv_free(void *pointer) { std::free(pointer); }
#endif
