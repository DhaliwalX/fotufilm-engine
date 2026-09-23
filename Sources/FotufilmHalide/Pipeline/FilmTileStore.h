#ifndef FOTUFILM_HALIDE_PIPELINE_FILM_TILE_STORE_H
#define FOTUFILM_HALIDE_PIPELINE_FILM_TILE_STORE_H

#include "FotufilmConfigLayout.h"
#include "../Stages/FilmTiles.h"

#include <Halide.h>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <unordered_map>

namespace fotufilm {

/// The film grain model's tiles the host has rendered, by the id it gave them. A frame in grain
/// mode 3 names its tiles in the configuration's FILM_TILE block; a frame that names none, or
/// tiles never registered, binds a single float and reads nothing from it. The buffers are kept
/// whole, so a GPU pipeline uploads a stock's tiles once and reuses the copy frame after frame.
class FilmTileStore {
public:
    static constexpr int kEntries = (FOTUFILM_FILM_TILE_SIDE + 1) * (FOTUFILM_FILM_TILE_SIDE + 1);
    static constexpr int64_t kCount = int64_t(kEntries) * FOTUFILM_FILM_TILE_LEVELS * 3;

    static FilmTileStore &shared() {
        static FilmTileStore store;
        return store;
    }

    /// Keeps a copy of `count` floats as tiles `id`; a null or empty source forgets them.
    bool set(int32_t id, const float *tiles, int64_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!tiles || count == 0) {
            tiles_.erase(id);
            return true;
        }
        if (count != kCount) return false;
        Halide::Buffer<float> buffer(kEntries, FOTUFILM_FILM_TILE_LEVELS, 3);
        std::memcpy(buffer.data(), tiles, size_t(count) * sizeof(float));
        tiles_[id] = buffer;
        return true;
    }

    /// The tiles a configuration names, or the one-float stand-in with `on` false.
    Halide::Buffer<float> tiles_for(const float *configuration, bool &on) {
        std::lock_guard<std::mutex> lock(mutex_);
        on = false;
        if (int32_t(configuration[FOTUFILM_CONFIG_GRAIN_MODE]) == 3) {
            const int32_t id = int32_t(configuration[FOTUFILM_CONFIG_FILM_TILE + kFilmTileId]);
            auto found = tiles_.find(id);
            if (found != tiles_.end()) {
                on = true;
                return found->second;
            }
        }
        if (!stand_in_.defined()) {
            stand_in_ = Halide::Buffer<float>(1, 1, 1);
            stand_in_(0, 0, 0) = 0.0f;
        }
        return stand_in_;
    }

private:
    std::mutex mutex_;
    std::unordered_map<int32_t, Halide::Buffer<float>> tiles_;
    Halide::Buffer<float> stand_in_;
};

}

#endif
