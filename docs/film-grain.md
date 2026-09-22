# Film grain

`--grain-model film` (API: `GrainModel.film`) lays grain the way it exists on a negative: as
crystals at fixed places on the emulsion, each developed crystal forming a dye cloud or a
silver grain of its own physical size, with every output pixel the light that passes through
that patch of film. The stock's film is rendered once, crystal by crystal, onto tiles; every
frame after that is sampled from them by a Halide stage (grain mode 3), so the model runs on
the CPU and Metal roads at the cost of the standard grain.

## What it does

1. **The film is fixed; the pixels sample it.** Each crystal's position, dye amount and
   development draw come from a hash of its cell in film millimetres. Rendering the same frame
   at a higher resolution resolves the grains a lower one averaged. Averaged back, the finer
   render reproduces the coarser one (correlation above 0.9 in the tests), which the other
   grain models, tied to the output lattice, do not.
2. **Exposure decides which crystals develop.** The crystal population is the one
   `CrystalGrainModel` fits to the record's characteristic curve, with four sublayers along
   speed. A crystal develops with the probability its speed class has at the local developed
   density.
3. **A dye cloud's size follows from its dye and its coupler.** Couplers are dispersed evenly
   through a sublayer, so no point of it can form more dye than the sublayer's coupler capacity
   (its pool). Each developed crystal releases a Gaussian of oxidised developer. The dye that
   forms is `C (1 - exp(-demand / C))`, summed over all clouds of the sublayer before it
   saturates, so clouds are flat-topped where they formed and merge where they meet. Silver
   grains use the same construction with an opaque grain (local density 2). The sheet's
   granularity read backwards through Nutting's `D = 0.434 n a` then gives Tri-X grains of
   0.3–1.7 µm, in line with photomicrographs of negative emulsions.
4. **Pixels average light, not density.** A pixel's density is `-log10` of the mean
   transmittance through its patch of film.
5. **The anchors stay the measurements.** The frame's mean is the pipeline's developed density.
   The dye per crystal is solved on the model's own film so that a flat patch at the sheet's
   read density reads the sheet's RMS granularity through the 48 µm aperture, averaged in
   transmittance as a microdensitometer does. Each step of the solve takes the slope the last
   one measured, and a scaled population is the same crystals, so the solve converges.

## How it runs

- **Tiles.** Each record is rendered once on a seamless square of film 256 µm a side, at
  1 µm texels (where the render has converged), at 17 gross densities from D-min to D-max.
  Each level is kept as the running sum of its transmittance less its mean (a summed-area
  table), so the light through any rectangle of film is four lookups, exact at any pitch.
  Rendering and registering a stock's tiles takes about 1.5 s, once per stock. The frame's
  grain amount scales the grain in the kernel, so moving the slider rebuilds nothing.
- **Blocks.** The frame is cut into 64 µm blocks. Each takes the tile at its own hashed offset,
  inside one period so no read wraps, and one of the eight flips and turns of the square, per
  record and per frame seed. Nothing repeats, and a new seed is another placement of the same
  coating.
- **Tone.** For each pitch the host reads every level's mean density through footprints laid
  as the frame's pixels are, and a pixel's grain is its density less that mean. Between the
  two levels either side of its developed density, the pixel blends their grain, renormalised
  by the two fields' correlation at that pitch so the blend keeps their variance.
- **The kernel.** `Stages/FilmTiles.h` samples the tiles after development and before the
  enlarger, so the print's spread applies to the film grain as it does to the other models.
  The host packs the pitch, the amount, the tiles' id and the per-pitch tables into the
  configuration's `FILM_TILE` block, and `fotufilm_halide_set_film_tiles` hands the tiles to
  the engine. `FilmGrain.apply` is the same arithmetic in Swift, and the tests hold the two
  within 0.002 D of each other.

## What it is checked against

| Check | Result |
|---|---|
| σ48 at the sheet's read density, Portra 400, Tri-X, Provia 100F, Vision3 250D, every record | within ±13 % of the sheet |
| Tone | mean within 0.006 D of the curve on Portra 400 and Provia 100F, 0.001 D on Tri-X at 4 µm pixels |
| Tiles against the full render at 1 µm | pixel σ 0.97–1.01 of it, same neighbour correlation, similar skew |
| Resolution | a 0.25 µm render averaged back to 1 µm correlates above 0.9 with the 1 µm render |
| Halide against Swift | within 0.002 D per pixel |

On an M4 Pro, a 1080p frame takes 19 ms on the Metal preview road (Standard: 16 ms), 31 ms
on the Metal still road and 93 ms on the CPU. At 24 MP it matches the standard grain on
Metal (0.20 s preview, 0.40 s still) and adds about 0.8 s on the CPU.

## What is not measured

- The cloud rim (`dyeCloudEdge`, 4) and the silver grain's local density (2) are stances.
- The records are independent, so the grain carries more colour than the standard model's
  scan-fitted record correlation of 0.6.
- The only colour-negative micrograph at hand is a soft web JPEG at unknown density and gain. It
  cannot settle cloud size or tail shape, so none of these numbers are fitted to it.
- The anchor is solved on one 256 µm tile, and its reading of the 48 µm aperture varies by a
  few percent between tiles; that is the scatter in the σ48 row above.
- The tone tables are read from 16 384 footprints. At 1 µm pixels a silver film's pixels vary
  by most of a density unit, and that sample leaves Tri-X about 0.01 D under the curve; at the
  pitches frames are rendered at it is well under 0.001 D.

## Where it does not run yet

Ahead-of-time variants (the iOS-style AOT table, Android, the web) and WebGPU leave the stage
out, and a frame that asks for the film grain there renders the standard grain. The iOS app's
handwritten Metal needs its own port of the stage. Hosts without Swift will also need the
tiles built without `FilmGrain`.
