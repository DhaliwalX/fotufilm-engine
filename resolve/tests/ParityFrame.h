#ifndef FOTUFILM_PARITY_FRAME_H
#define FOTUFILM_PARITY_FRAME_H

#include <stdint.h>

namespace parity {

constexpr int kWidth = 640;
constexpr int kHeight = 360;

void fillFrame(float *pixels);

bool writeDump(const char *path, const float *pixels, int width, int height);

}  // namespace parity

#endif
