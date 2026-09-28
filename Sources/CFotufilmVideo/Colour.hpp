// SDR video colour management as the Mac's decoder does it: AVFoundation asked for Display P3 with
// the sRGB transfer (HostVideoSource+AVFoundation.swift) converts through ColorSync, which reads
// BT.709-family transfers as a 1.961 power with its slope limited to 1/16 near black, and takes
// untagged video as BT.709 when it is HD and as BT.601 with SMPTE C primaries when it is not.
// Measured against AVFoundation on synthetic Y'CbCr patches, this reproduces its Display P3 output
// within one 8-bit code.
#pragma once

#include <array>
#include <cstdint>
#include <vector>

namespace fotufilm::video {

using Matrix = std::array<float, 9>;

/// How a source's code values become light, from its tags and size.
struct SourceColour {
    /// H.273 transfer, primaries and matrix with the unspecified ones resolved.
    int transfer = 1;
    int primaries = 1;
    int matrix = 1;
    bool full_range = false;

    static SourceColour resolve(int transfer, int primaries, int matrix, bool full_range,
                                int width, int height);

    /// Whether the transfer carries HDR light (HLG or PQ).
    bool hdr() const { return transfer == 16 || transfer == 18; }
    /// Linear source RGB to linear Display P3, and to Rec.2020.
    Matrix to_display_p3() const;
    Matrix to_rec2020() const;
};

/// A Y'CbCr matrix by its luma weights, for an H.273 matrix code (BT.709 when unknown).
struct YCbCr {
    float kr, kb;
    float kg() const { return 1 - kr - kb; }
    /// Colour difference to B' and to R'.
    float cb() const { return 2 * (1 - kb); }
    float cr() const { return 2 * (1 - kr); }
    static YCbCr of(int matrix);
};

/// The managed decode's tables for one source: signal to linear light, and linear Display P3 to
/// 8-bit sRGB codes.
class ManagedTables {
public:
    explicit ManagedTables(int transfer);

    /// The tables by address, for a loop to keep in registers: stores through a byte pointer
    /// could otherwise change them, as far as the compiler knows.
    struct View {
        const float *decode;
        const uint8_t *encode;

        /// Signal (R', G' or B', about -0.5 to 1.5) to linear light, keeping the sign.
        float linear(float signal) const {
            float position = (signal - kLow) * kScale;
            if (!(position > 0)) return decode[0];
            if (position >= kLast) return decode[kEntries - 1];
            int index = static_cast<int>(position);
            float t = position - static_cast<float>(index);
            return decode[index] + (decode[index + 1] - decode[index]) * t;
        }
        /// Linear Display P3 to its 8-bit sRGB code, clamped.
        uint8_t code(float linear) const {
            if (!(linear > 0)) return 0;
            if (linear >= 1) return 255;
            return encode[static_cast<int>(linear * kEncodeLast + 0.5f)];
        }
    };
    View view() const { return {decode_.data(), encode_.data()}; }

private:
    static constexpr float kLow = -0.5f;
    static constexpr int kEntries = 16385;
    static constexpr float kLast = kEntries - 1;
    static constexpr float kScale = kLast / 2.0f;
    static constexpr float kEncodeLast = 65535.0f;
    std::vector<float> decode_;
    std::vector<uint8_t> encode_;
};

/// The source's transfer function, signal to linear, for the transfers the managed road reads.
float sdr_linear(int transfer, float signal);

}  // namespace fotufilm::video
