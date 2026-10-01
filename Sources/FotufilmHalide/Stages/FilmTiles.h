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
// texels that each take the tile at their own hashed offset and orientation, so nothing repeats;
// a placement reaches FOTUFILM_FILM_TILE_MARGIN texels past its block, and across
// FOTUFILM_FILM_TILE_SEAM texels either side of an edge the neighbours' grain cross-fades, so no
// cloud is cut along a straight line.
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

/// Running sum at a point up to a period past the tile's far edges: the tile repeats, so a sum
/// reaching into the next period adds the whole columns (the table's last column, read at the
/// row) or rows it crossed, and both when it crossed both.
inline Halide::Expr film_tile_sum_wrapped(Halide::ImageParam &tiles, Halide::Expr px,
                                          Halide::Expr py, Halide::Expr level,
                                          Halide::Expr record, Halide::Expr on) {
    const int side = FOTUFILM_FILM_TILE_SIDE;
    Halide::Expr wx = px >= float(side), wy = py >= float(side);
    Halide::Expr qx = Halide::select(wx, px - float(side), px);
    Halide::Expr qy = Halide::select(wy, py - float(side), py);
    Halide::Expr iy = Halide::min(Halide::cast<int32_t>(Halide::floor(qy)), side - 1);
    Halide::Expr ix = Halide::min(Halide::cast<int32_t>(Halide::floor(qx)), side - 1);
    Halide::Expr ay = qy - Halide::cast<float>(iy), ax = qx - Halide::cast<float>(ix);
    Halide::Expr column = film_tile_entry(tiles, side, iy, level, record, on);
    column = column + (film_tile_entry(tiles, side, iy + 1, level, record, on) - column) * ay;
    Halide::Expr row = film_tile_entry(tiles, ix, side, level, record, on);
    row = row + (film_tile_entry(tiles, ix + 1, side, level, record, on) - row) * ax;
    Halide::Expr corner = film_tile_entry(tiles, side, side, level, record, on);
    return film_tile_sum_inside(tiles, qx, qy, level, record, on)
        + Halide::select(wx, column, 0.0f) + Halide::select(wy, row, 0.0f)
        + Halide::select(wx && wy, corner, 0.0f);
}

inline Halide::Expr film_tile_box(Halide::ImageParam &tiles, Halide::Expr x0, Halide::Expr x1,
                                  Halide::Expr y0, Halide::Expr y1, Halide::Expr level,
                                  Halide::Expr record, Halide::Expr on) {
    return film_tile_sum_wrapped(tiles, x1, y1, level, record, on)
        - film_tile_sum_wrapped(tiles, x0, y1, level, record, on)
        - film_tile_sum_wrapped(tiles, x1, y0, level, record, on)
        + film_tile_sum_wrapped(tiles, x0, y0, level, record, on);
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

    // The blocks whose fade reaches the pixel's centre, one or two each way: each reads the whole
    // footprint through its own placement (the part within its margin, past that), and their
    // grain is summed by the fade's weights and divided by the weights' norm, which keeps the
    // variance where two independent placements meet.
    const float margin = float(FOTUFILM_FILM_TILE_MARGIN);
    const float seam = float(FOTUFILM_FILM_TILE_SEAM);
    Expr cx = (Halide::cast<float>(px) + 0.5f) * pitch;
    Expr cy = (Halide::cast<float>(py) + 0.5f) * pitch;
    Expr x0 = cx - 0.5f * footprint, x1 = x0 + footprint;
    Expr y0 = cy - 0.5f * footprint, y1 = y0 + footprint;
    Expr bx0 = Halide::cast<int32_t>(Halide::floor((cx - seam) * (1.0f / block)));
    Expr by0 = Halide::cast<int32_t>(Halide::floor((cy - seam) * (1.0f / block)));
    Expr bx1 = Halide::min(Halide::cast<int32_t>(Halide::floor((cx + seam) * (1.0f / block))),
                           bx0 + 1);
    Expr by1 = Halide::min(Halide::cast<int32_t>(Halide::floor((cy + seam) * (1.0f / block))),
                           by0 + 1);
    // Block `b`'s share at `c` along one axis: one inside, falling to zero across each edge's band.
    auto share = [&](Expr c, Expr b) {
        Expr start = Halide::cast<float>(b) * block;
        return Halide::clamp((c - start + seam) * (0.5f / seam), 0.0f, 1.0f)
            * Halide::clamp((start + block + seam - c) * (0.5f / seam), 0.0f, 1.0f);
    };
    auto norm_axis = [&](Expr c, Expr b0, Expr b1) {
        Expr first = share(c, b0), second = Halide::select(b1 > b0, share(c, b1), 0.0f);
        return first * first + second * second;
    };
    Expr norm = norm_axis(cx, bx0, bx1) * norm_axis(cy, by0, by1);
    Halide::RDom pieces(0, 2, 0, 2, "film_tile_pieces");
    pieces.where(bx0 + pieces.x <= bx1 && by0 + pieces.y <= by1);
    Expr bx = bx0 + pieces.x, by = by0 + pieces.y;
    Expr fbx = Halide::cast<float>(bx) * block, fby = Halide::cast<float>(by) * block;
    Expr u0 = Halide::max(x0, fbx - margin) - fbx, u1 = Halide::min(x1, fbx + block + margin) - fbx;
    Expr v0 = Halide::max(y0, fby - margin) - fby, v1 = Halide::min(y1, fby + block + margin) - fby;
    Expr area = Halide::max((u1 - u0) * (v1 - v0), 1.0e-6f);
    // Each block takes the tile at an offset anywhere in the period, and a read past its far edge
    // wraps: offsets confined to part of the period would overlap neighbouring blocks' reads of
    // the one mean-free tile and anticorrelate their grain.
    Expr hash = pixel_hash(bx, by, seed, kFilmTileStream + record);
    const uint32_t period = uint32_t(FOTUFILM_FILM_TILE_SIDE);
    Expr ox = Halide::cast<float>(hash % Expr(period)) + margin;
    Expr oy = Halide::cast<float>((hash >> 8) % Expr(period)) + margin;
    Expr turn = Halide::cast<int32_t>((hash >> 16) & Expr(uint32_t(7)));
    Expr flip_x = (turn & 1) != 0, flip_y = (turn & 2) != 0, swap = (turn & 4) != 0;
    Expr p0 = Halide::select(flip_x, block - u1, u0);
    Expr p1 = Halide::select(flip_x, block - u0, u1);
    Expr q0 = Halide::select(flip_y, block - v1, v0);
    Expr q1 = Halide::select(flip_y, block - v0, v1);
    Expr a0 = Halide::select(swap, q0, p0) + ox, a1 = Halide::select(swap, q1, p1) + ox;
    Expr b0 = Halide::select(swap, p0, q0) + oy, b1 = Halide::select(swap, p1, q1) + oy;
    Expr light_a = configuration(table + k)
        + film_tile_box(tiles, a0, a1, b0, b1, k, record, on) / area;
    Expr light_b = configuration(table + k + 1)
        + film_tile_box(tiles, a0, a1, b0, b1, k + 1, record, on) / area;
    Expr density_a = -Halide::log(Halide::max(light_a, 1.0e-9f)) * float(1.0 / M_LN10)
        - configuration(table + levels + k);
    Expr density_b = -Halide::log(Halide::max(light_b, 1.0e-9f)) * float(1.0 / M_LN10)
        - configuration(table + levels + k + 1);
    Expr grain = Halide::sum(share(cx, bx) * share(cy, by)
                                 * (density_a + (density_b - density_a) * w),
                             "film_tile_grain_sum");
    Expr rho = configuration(table + 2 * levels + k);
    Expr kept = (1.0f - w) * (1.0f - w) + w * w + 2.0f * w * (1.0f - w) * rho;
    return configuration(base + kFilmTileAmount + record) * grain
        / Halide::sqrt(Halide::max(kept * norm, 1.0e-12f));
}

}

#endif
