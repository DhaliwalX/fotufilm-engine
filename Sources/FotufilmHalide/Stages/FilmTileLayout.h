#ifndef FOTUFILM_HALIDE_STAGES_FILM_TILE_LAYOUT_H
#define FOTUFILM_HALIDE_STAGES_FILM_TILE_LAYOUT_H

// The film grain model's tile layout, shared by the kernel (FilmTiles.h) and the hosts that hold
// the tiles (FilmTileStore.h), which include no Halide compiler headers.

namespace fotufilm {

/// Hash stream of the film tiles' block placement: one per record, above every other stream.
constexpr int kFilmTileStream = 200;

/// Offsets within the FOTUFILM_CONFIG_FILM_TILE block: the pixel pitch and the side of film a
/// pixel reads, in tile texels; the tiles' id; per record the grain amount; the colour grain;
/// per record the levels' density range; then the per-record level tables.
constexpr int kFilmTilePitch = 0;
constexpr int kFilmTileFootprint = 1;
constexpr int kFilmTileId = 2;
constexpr int kFilmTileAmount = 3;
constexpr int kFilmTileColour = 6;
constexpr int kFilmTileDMin = 7;
constexpr int kFilmTileDMax = 10;
constexpr int kFilmTileTables = 13;

}

#endif
