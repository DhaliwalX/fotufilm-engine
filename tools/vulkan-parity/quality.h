#pragma once
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <algorithm>

// Match web/test/quality/metrics.js. These are image-quality limits, not an
// assertion that Vulkan arithmetic is bit-identical to the CPU reference.
struct Quality {
    double squared = 0, rmse = 0;
    uint32_t rgba8_maximum = 0, rgba16_maximum = 0;
    size_t rgba8_samples = 0, rgba8_changed = 0;
    template<class T> uint32_t display_error(const void *reference, const void *actual,
                                           size_t bytes, bool eight_bit) {
        auto a = static_cast<const uint8_t *>(reference), b = static_cast<const uint8_t *>(actual);
        uint32_t maximum = 0;
        for (size_t i = 0; i < bytes / sizeof(T); ++i) {
            T av, bv;
            std::memcpy(&av, a + i * sizeof(T), sizeof(T));
            std::memcpy(&bv, b + i * sizeof(T), sizeof(T));
            auto delta = uint32_t(std::abs(int(av) - int(bv)));
            maximum = std::max(maximum, delta);
            if (eight_bit) { ++rgba8_samples; rgba8_changed += delta != 0; }
        }
        return maximum;
    }
    bool accepts(float linear_maximum) const {
        return linear_maximum <= 0.0001f && rmse <= 0.00001
            && rgba8_maximum <= 1 && rgba8_samples > 0
            && double(rgba8_changed) / double(rgba8_samples) <= 0.001
            && rgba16_maximum <= 4;
    }
};
