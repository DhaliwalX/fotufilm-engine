#ifndef FOTUFILM_HALIDE_STAGES_FILM_TILES_H
#define FOTUFILM_HALIDE_STAGES_FILM_TILES_H

#include "FotufilmHalide.h"
#include "FilmTileLayout.h"
#include "Random.h"

#include <Halide.h>

namespace fotufilm {

// The film grain model (`GrainModel.film`, grain mode 1), sampled from its tiles.
//
// The host renders each record of the film once, crystal by crystal, on a seamless square of film
// FOTUFILM_FILM_TILE_SIDE texels a side at FOTUFILM_FILM_TILE_LEVELS gross densities, and hands
// the kernel each level as the running sum of its transmittance less the level's mean light — a
// summed-area table, (side + 1)² floats with a zero first row and column — in `tiles`, indexed
// (entry, level, record). A pixel is a rectangle of film; the light through it is four lookups
// into the table, exactly, at any pitch. The frame is cut into blocks of FOTUFILM_FILM_TILE_BLOCK
// texels that each take the tile at their own hashed offset and orientation, so nothing repeats.
// `FilmGrain` in FotufilmCore is the same arithmetic on the host, and the tests hold the two
// together.

/// Where the tile's running sums for `level` of `record` start in `tiles`' first dimension is
/// always 0; this is the entry at integer texel corner (ix, iy). `on` clamps every read to the
/// first entry when the model is off, so a frame without it binds a one-float buffer.
inline Halide::Expr film_tile_entry(Halide::ImageParam &tiles, Halide::Expr ix, Halide::Expr iy,
                                    Halide::Expr level, Halide::Expr record, Halide::Expr on) {
    const int side = FOTUFILM_FILM_TILE_SIDE;
    const int stride = side + 1;
    Halide::Expr index = Halide::clamp(iy, 0, side) * stride + Halide::clamp(ix, 0, side);
    Halide::Expr last = Halide::select(on, stride * stride - 1, 0);
    return tiles(Halide::clamp(index, 0, last),
                 Halide::clamp(level, 0, Halide::select(on, FOTUFILM_FILM_TILE_LEVELS - 1, 0)),
                 Halide::clamp(record, 0, Halide::select(on, 2, 0)));
}

/// Running sum at a real point inside one period of the tile: bilinear within a texel, which is
/// exact for texels of constant light.
inline Halide::Expr film_tile_sum_inside(Halide::ImageParam &tiles, Halide::Expr px,
                                         Halide::Expr py, Halide::Expr level, Halide::Expr record,
                                         Halide::Expr on) {
    const int side = FOTUFILM_FILM_TILE_SIDE;
    Halide::Expr ix = Halide::min(Halide::cast<int32_t>(Halide::floor(px)), side - 1);
    Halide::Expr iy = Halide::min(Halide::cast<int32_t>(Halide::floor(py)), side - 1);
    Halide::Expr ax = px - Halide::cast<float>(ix);
    Halide::Expr ay = py - Halide::cast<float>(iy);
    Halide::Expr s00 = film_tile_entry(tiles, ix, iy, level, record, on);
    Halide::Expr s10 = film_tile_entry(tiles, ix + 1, iy, level, record, on);
    Halide::Expr s01 = film_tile_entry(tiles, ix, iy + 1, level, record, on);
    Halide::Expr s11 = film_tile_entry(tiles, ix + 1, iy + 1, level, record, on);
    return s00 + (s10 - s00) * ax + (s01 - s00) * ay + (s11 - s10 - s01 + s00) * ax * ay;
}

inline Halide::Expr film_tile_box(Halide::ImageParam &tiles, Halide::Expr x0, Halide::Expr x1,
                                  Halide::Expr y0, Halide::Expr y1, Halide::Expr level,
                                  Halide::Expr record, Halide::Expr on) {
    return film_tile_sum_inside(tiles, x1, y1, level, record, on)
        - film_tile_sum_inside(tiles, x0, y1, level, record, on)
        - film_tile_sum_inside(tiles, x1, y0, level, record, on)
        + film_tile_sum_inside(tiles, x0, y0, level, record, on);
}

/// The film grain of one pixel of one record: its density less the mean density its footprint
/// reads, at the two levels either side of its developed gross density, blended so the blend
/// keeps their variance, and scaled by the record's grain amount. `px`, `py` are the pixel's
/// column and row in the whole frame. The footprint is the square of film the pixel reads,
/// centred on it: its own pitch for a sharp scan, wider for a softer one. The configuration's
/// FOTUFILM_CONFIG_FILM_TILE block carries the pitch, the footprint, the amounts, each record's
/// density range and, per record and level, the mean light, the mean density through this
/// footprint and the correlation with the next level's grain through it.
inline Halide::Expr film_tile_grain(Halide::ImageParam &configuration, Halide::ImageParam &tiles,
                                    Halide::Expr gross, Halide::Expr px, Halide::Expr py,
                                    Halide::Expr record, Halide::Expr seed, Halide::Expr on) {
    using Halide::Expr;
    const int levels = FOTUFILM_FILM_TILE_LEVELS;
    const float block = float(FOTUFILM_FILM_TILE_BLOCK);
    const int base = FOTUFILM_CONFIG_FILM_TILE;
    Expr pitch = configuration(base + kFilmTilePitch);
    Expr footprint = configuration(base + kFilmTileFootprint);
    Expr d_min = configuration(base + kFilmTileDMin + record);
    Expr d_max = configuration(base + kFilmTileDMax + record);
    Expr table = base + kFilmTileTables + record * 3 * levels;
    Expr t = Halide::clamp((gross - d_min) / Halide::max(d_max - d_min, 1.0e-6f), 0.0f, 1.0f)
        * float(levels - 1);
    Expr k = Halide::clamp(Halide::cast<int32_t>(Halide::floor(t)), 0, levels - 2);
    Expr w = t - Halide::cast<float>(k);

    // The blocks the footprint reaches, up to two each way from its corner: all of any footprint
    // up to a block wide, which is one block for nearly every pixel, so the loop runs once there.
    Expr x0 = (Halide::cast<float>(px) + 0.5f) * pitch - 0.5f * footprint, x1 = x0 + footprint;
    Expr y0 = (Halide::cast<float>(py) + 0.5f) * pitch - 0.5f * footprint, y1 = y0 + footprint;
    Expr bx0 = Halide::cast<int32_t>(Halide::floor(x0 * (1.0f / block)));
    Expr by0 = Halide::cast<int32_t>(Halide::floor(y0 * (1.0f / block)));
    Expr bx1 = Halide::min(Halide::cast<int32_t>(Halide::ceil(x1 * (1.0f / block))) - 1, bx0 + 1);
    Expr by1 = Halide::min(Halide::cast<int32_t>(Halide::ceil(y1 * (1.0f / block))) - 1, by0 + 1);
    Halide::RDom pieces(0, 2, 0, 2, "film_tile_pieces");
    pieces.where(bx0 + pieces.x <= bx1 && by0 + pieces.y <= by1);
    Expr bx = bx0 + pieces.x, by = by0 + pieces.y;
    Expr fbx = Halide::cast<float>(bx) * block, fby = Halide::cast<float>(by) * block;
    Expr u0 = Halide::max(x0, fbx) - fbx, u1 = Halide::min(x1, fbx + block) - fbx;
    Expr v0 = Halide::max(y0, fby) - fby, v1 = Halide::min(y1, fby + block) - fby;
    // Each block takes the tile at an offset that keeps it inside one period, so no read wraps.
    Expr hash = pixel_hash(bx, by, seed, kFilmTileStream + record);
    const uint32_t reach = uint32_t(FOTUFILM_FILM_TILE_SIDE - FOTUFILM_FILM_TILE_BLOCK + 1);
    Expr ox = Halide::cast<float>(hash % Expr(reach));
    Expr oy = Halide::cast<float>((hash >> 8) % Expr(reach));
    Expr turn = Halide::cast<int32_t>((hash >> 16) & Expr(uint32_t(7)));
    Expr flip_x = (turn & 1) != 0, flip_y = (turn & 2) != 0, swap = (turn & 4) != 0;
    Expr p0 = Halide::select(flip_x, block - u1, u0);
    Expr p1 = Halide::select(flip_x, block - u0, u1);
    Expr q0 = Halide::select(flip_y, block - v1, v0);
    Expr q1 = Halide::select(flip_y, block - v0, v1);
    Expr a0 = Halide::select(swap, q0, p0) + ox, a1 = Halide::select(swap, q1, p1) + ox;
    Expr b0 = Halide::select(swap, p0, q0) + oy, b1 = Halide::select(swap, p1, q1) + oy;
    Expr sum_a = Halide::sum(film_tile_box(tiles, a0, a1, b0, b1, k, record, on),
                             "film_tile_sum_a");
    Expr sum_b = Halide::sum(film_tile_box(tiles, a0, a1, b0, b1, k + 1, record, on),
                             "film_tile_sum_b");
    Expr covered = (Halide::min(x1, Halide::cast<float>(bx1 + 1) * block) - x0)
        * (Halide::min(y1, Halide::cast<float>(by1 + 1) * block) - y0);
    Expr area = Halide::max(covered, 1.0e-6f);
    Expr light_a = configuration(table + k) + sum_a / area;
    Expr light_b = configuration(table + k + 1) + sum_b / area;
    Expr density_a = -Halide::log(Halide::max(light_a, 1.0e-9f)) * float(1.0 / M_LN10)
        - configuration(table + levels + k);
    Expr density_b = -Halide::log(Halide::max(light_b, 1.0e-9f)) * float(1.0 / M_LN10)
        - configuration(table + levels + k + 1);
    Expr rho = configuration(table + 2 * levels + k);
    Expr kept = (1.0f - w) * (1.0f - w) + w * w + 2.0f * w * (1.0f - w) * rho;
    return configuration(base + kFilmTileAmount + record) * (density_a + (density_b - density_a) * w)
        / Halide::sqrt(Halide::max(kept, 1.0e-4f));
}

}

#endif
