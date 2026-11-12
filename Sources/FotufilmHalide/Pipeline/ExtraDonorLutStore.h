#ifndef FOTUFILM_HALIDE_PIPELINE_EXTRA_DONOR_LUT_STORE_H
#define FOTUFILM_HALIDE_PIPELINE_EXTRA_DONOR_LUT_STORE_H

#include "FotufilmConfigLayout.h"

#include <cstdint>
#include <cstring>
#include <mutex>
#include <unordered_map>

namespace fotufilm {

/// Spectral exposure cubes for extra donor capture layers (`donors[1]` and `donors[2]`), keyed by
/// the host registration id written to `FOTUFILM_CONFIG_DONOR_EXTRA_LUT_ID`. Frames with zero or
/// one active donor (`FOTUFILM_CONFIG_DONOR_COUNT <= 1`), or an unregistered id, bind a single
/// zero float with `on` false so Halide bounds inference reads nothing beyond index 0.
template <typename LutBuffer>
class BasicExtraDonorLutStore {
public:
    static constexpr int kLutDimension = 33;
    static constexpr int64_t kCount =
        int64_t(kLutDimension) * kLutDimension * kLutDimension * 4;
    using Upload = int (*)(LutBuffer &);

    static BasicExtraDonorLutStore &shared() {
        static BasicExtraDonorLutStore &store = *new BasicExtraDonorLutStore;
        return store;
    }

    void upload_with(Upload upload) {
        std::lock_guard<std::mutex> lock(mutex_);
        upload_ = upload;
    }

    /// Keeps a copy of `count` floats under `id`; a null or empty source forgets it.
    bool set(int32_t id, const float *lut, int64_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!lut || count == 0) {
            luts_.erase(id);
            return true;
        }
        if (count != kCount) return false;
        LutBuffer buffer(static_cast<int>(kCount));
        std::memcpy(buffer.data(), lut, size_t(count) * sizeof(float));
        if (upload_ && upload_(buffer) != 0) return false;
        luts_[id] = buffer;
        return true;
    }

    /// The extra-donor cube named by `configuration`, or the one-float stand-in with `on` false.
    LutBuffer lut_for(const float *configuration, bool &on) {
        std::lock_guard<std::mutex> lock(mutex_);
        on = false;
        if (int32_t(configuration[FOTUFILM_CONFIG_DONOR_COUNT]) > 1) {
            const int32_t id = int32_t(configuration[FOTUFILM_CONFIG_DONOR_EXTRA_LUT_ID]);
            auto found = luts_.find(id);
            if (found != luts_.end()) {
                on = true;
                return found->second;
            }
        }
        if (!stand_in_ready_) {
            stand_in_(0) = 0.0f;
            if (upload_ && upload_(stand_in_) != 0) return stand_in_;
            stand_in_ready_ = true;
        }
        return stand_in_;
    }

    /// Frees the device copies, keeping the host tables; the next frame uploads them again.
    void device_free() {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto &entry : luts_) {
            entry.second.device_free();
            entry.second.set_host_dirty();
        }
        stand_in_.device_free();
        stand_in_ready_ = false;
    }

private:
    std::mutex mutex_;
    std::unordered_map<int32_t, LutBuffer> luts_;
    LutBuffer stand_in_{1};
    bool stand_in_ready_ = false;
    Upload upload_ = nullptr;
};

}

#endif
