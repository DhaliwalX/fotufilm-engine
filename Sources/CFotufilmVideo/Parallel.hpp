#pragma once

#include <algorithm>
#include <thread>
#include <vector>

#include "FFmpeg.hpp"

namespace fotufilm::video {

/// Runs `body(first, last)` over bands of `rows` rows on the machine's cores.
template <typename Body>
void parallel_rows(int rows, Body body) {
    const int workers = std::min(threads(), std::max(1, rows / 16));
    if (workers <= 1) return body(0, rows);
    std::vector<std::thread> pool;
    pool.reserve(workers);
    const int band = (rows + workers - 1) / workers;
    for (int first = 0; first < rows; first += band)
        pool.emplace_back([=] { body(first, std::min(rows, first + band)); });
    for (auto &thread : pool) thread.join();
}

}  // namespace fotufilm::video
