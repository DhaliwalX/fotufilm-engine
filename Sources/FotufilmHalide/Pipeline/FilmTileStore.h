#ifndef FOTUFILM_HALIDE_PIPELINE_FILM_TILE_STORE_H
#define FOTUFILM_HALIDE_PIPELINE_FILM_TILE_STORE_H

#include "FotufilmConfigLayout.h"
#include "../Stages/FilmTileLayout.h"

#include <cstdint>
#include <cstring>
#include <mutex>
#include <unordered_map>

namespace fotufilm {

/// The film grain model's tiles the host has rendered, by the id it gave them. A frame in grain
/// mode 1 names its tiles in the configuration's FILM_TILE block; a frame that names none, or
/// tiles never registered, binds a single float and reads nothing from it. The buffers are kept
/// whole, so a GPU pipeline uploads a stock's tiles once and reuses the copy frame after frame.
///
/// `Tiles` is the JIT's `Halide::Buffer<float>` or, in the ahead-of-time hosts, the runtime's
/// `Halide::Runtime::Buffer<float>`. An AOT host whose kernels run on a device gives the store its
/// upload, which runs once per buffer as it is kept, so frames on any thread only read the copy.
template <typename Tiles>
class BasicFilmTileStore {
public:
    static constexpr int kEntries = (FOTUFILM_FILM_TILE_SIDE + 1) * (FOTUFILM_FILM_TILE_SIDE + 1);
    static constexpr int64_t kCount = int64_t(kEntries) * FOTUFILM_FILM_TILE_LEVELS * 3;
    using Upload = int (*)(Tiles &);

    static BasicFilmTileStore &shared() {
        static BasicFilmTileStore store;
        return store;
    }

    void upload_with(Upload upload) {
        std::lock_guard<std::mutex> lock(mutex_);
        upload_ = upload;
    }

    /// Keeps a copy of `count` floats as tiles `id`; a null or empty source forgets them.
    bool set(int32_t id, const float *tiles, int64_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!tiles || count == 0) {
            tiles_.erase(id);
            return true;
        }
        if (count != kCount) return false;
        Tiles buffer(kEntries, FOTUFILM_FILM_TILE_LEVELS, 3);
        std::memcpy(buffer.data(), tiles, size_t(count) * sizeof(float));
        if (upload_ && upload_(buffer) != 0) return false;
        tiles_[id] = buffer;
        return true;
    }

    /// The tiles a configuration names, or the one-float stand-in with `on` false.
    Tiles tiles_for(const float *configuration, bool &on) {
        std::lock_guard<std::mutex> lock(mutex_);
        on = false;
        if (int32_t(configuration[FOTUFILM_CONFIG_GRAIN_MODE]) == 1) {
            const int32_t id = int32_t(configuration[FOTUFILM_CONFIG_FILM_TILE + kFilmTileId]);
            auto found = tiles_.find(id);
            if (found != tiles_.end()) {
                on = true;
                return found->second;
            }
        }
        if (!stand_in_ready_) {
            stand_in_(0, 0, 0) = 0.0f;
            if (upload_ && upload_(stand_in_) != 0) return stand_in_;
            stand_in_ready_ = true;
        }
        return stand_in_;
    }

private:
    std::mutex mutex_;
    std::unordered_map<int32_t, Tiles> tiles_;
    Tiles stand_in_{1, 1, 1};
    bool stand_in_ready_ = false;
    Upload upload_ = nullptr;
};

}

#endif
