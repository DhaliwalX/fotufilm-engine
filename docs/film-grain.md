# Film grain

`--grain-model film` (API: `GrainModel.film`) lays grain the way it exists on a negative: as
crystals at fixed places on the emulsion, each developed crystal forming a dye cloud or a
silver grain of its own physical size, with every output pixel the light that passes through
that patch of film. The stock's film is rendered once, crystal by crystal, onto tiles; every
frame after that is sampled from them by a Halide stage (grain mode 1), so the model runs on
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
3. **A dye cloud spreads as Jarvis measured it.** Couplers are dispersed evenly through a
   sublayer, so no point of it can form more dye than the sublayer's coupler capacity (its
   pool). Each developed crystal releases oxidised developer that spreads as the dye cloud
   Jarvis measured on C-41 coatings, `exp(-r / k)` with `k` = 1.45 µm, the value he gives for a
   coupler-starved commercial colour-negative layer (J. Photogr. Sci. 40:105, 1992; 43:136,
   1995). The dye that forms is `C (1 - exp(-demand / C))`, summed over all clouds of the
   sublayer before it saturates, so clouds merge where they meet and a crystal whose demand
   passes the capacity grows a flat top. The sheet fixes how much dye a crystal forms and sets
   the cloud's peak demand; the coupler, not the dye, fixes how far it spreads. The clouds are
   laid as four separable Gaussian blurs of the developed crystals, fitted to Jarvis's transfer
   function `[1 + (2π k f)²]^(-3/2)` to 9 % wherever it is above 10⁻³.
4. **A silver grain follows from the sheet.** Silver grains use the flat-topped Gaussian
   construction with an opaque grain (local density 2), their width solved so that the sheet's
   granularity read backwards through Nutting's `D = 0.434 n a` gives their projected area:
   Tri-X grains of 0.3–1.7 µm, in line with photomicrographs of negative emulsions. No grain is
   narrower than its crystal, whose width follows the population's size ladder down from 1.2 µm
   for the fastest class; one that would be keeps the crystal's width and forms its silver
   fainter.
5. **Pixels average light, not density.** A pixel's density is `-log10` of the mean
   transmittance through its patch of film.
6. **The anchors stay the measurements.** The frame's mean is the pipeline's developed density.
   The dye per crystal is solved on the model's own film so that a flat patch at the sheet's
   read density reads the sheet's RMS granularity through the 48 µm aperture, averaged in
   transmittance as a microdensitometer does. Frames lay the tile in 64 µm blocks at
   independent offsets, so the reading counts each lag of the tile's covariance only for the
   share of pairs that fall in one block. Each step of the solve takes the slope the last one
   measured, and a scaled population is the same crystals, so the solve converges.

## How it runs

- **Tiles.** Each record is rendered once on a seamless square of film 256 µm a side, at
  1 µm texels (where the render has converged), at 17 gross densities from D-min to D-max.
  Each level is kept as the running sum of its transmittance less its mean (a summed-area
  table), so the light through any rectangle of film is four lookups, exact at any pitch.
  A sublayer's dye clouds are its developed crystals blurred by the cloud's four Gaussian
  terms, the two widest on a grid four and two samples coarser. The tiles are built on the GPU
  in Metal wherever it runs — each cell's crystals drawn once, every level laid in one pass —
  and by a Halide CPU builder or the Swift reference elsewhere; all three lay the same film.
  Solving a colour stock's population and building its tiles takes about 0.17 s on an M4 Pro
  in Metal (0.8 s in Halide on the CPU, 1.1 s in Swift), once per stock. The frame's grain amount scales the grain in the kernel, so
  moving the slider rebuilds nothing.
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

## Controls

None of these rebuilds the tiles: each is the kernel's pitch, footprint, amounts or mix, so
they move as freely as the grain amount does.

- **Grain Size** (0.5–4) magnifies the film under the frame and divides its fluctuation by as
  much. Grain far finer than an aperture reads a variance that falls with the aperture's area,
  so the 48 µm aperture still reads the sheet's granularity while the texture grows; at 48 µm
  pixels the test holds it within a quarter. Crystal size cannot be set from the sheet (the
  anchor trades crystal count for dye per crystal at the same granularity), so this is a look.
- **Colour Grain** (0–1) mixes each record's grain toward the three records' mean with weights
  that keep their total variance: 1 is the independent records the layers lay, 0 one shared
  grain.
- **Red, Green and Blue Layer** (0–2) scale each record's grain. The layer and colour controls are
  offered on colour film only.
- **Scan Softness** (0.5–4) is the side of the square of film each pixel reads, in pixels,
  centred on the pixel: wider averages the grain down as a softer scan does, narrower reads a
  patch smaller than the pixel. The tone tables are read through that footprint.

Hosts offer these while the grain model is Film.

## What it is checked against

| Check | Result |
|---|---|
| σ48 at the sheet's read density, every record of Portra 400, Gold 200, UltraMax 400, Ektar 100, Superia X-TRA 400, Provia 100F and Tri-X | 0.86–1.21 of the sheet |
| Tone | mean within 0.006 D of the curve on Portra 400 and Provia 100F, 0.001 D on Tri-X at 4 µm pixels |
| Tiles against the full render at 1 µm | pixel σ 0.97–1.01 of it, same neighbour correlation, similar skew |
| Resolution | a 0.25 µm render averaged back to 1 µm correlates above 0.9 with the 1 µm render |
| Halide against Swift | within 0.002 D per pixel, with every control above moved |
| Tile builders (Metal, Halide) against the Swift reference | correlation above 0.9999, within 0.002 D per texel |

On an M4 Pro, a 1080p frame takes 19 ms on the Metal preview road (Standard: 16 ms), 31 ms
on the Metal still road and 93 ms on the CPU. At 24 MP it matches the standard grain on
Metal (0.20 s preview, 0.40 s still) and adds about 0.8 s on the CPU.

## What is not measured

- The cloud's decay length is Jarvis's for a coupler-starved single-layer C-41 coating, not a
  measurement of any stock; his coupler-rich coatings reach 0.76 µm, and no stock's coupler
  laydown is published. Every sublayer of every dye stock takes 1.45 µm.
- The silver grain's rim (12) and local density (2) and the fastest crystal's width (1.2 µm)
  are stances.
- The records are independent, so the grain carries more colour than the standard model's
  scan-fitted record correlation of 0.6.
- The only colour-negative micrograph at hand is a soft web JPEG at unknown density and gain. It
  cannot settle cloud size or tail shape, so none of these numbers are fitted to it.
- The anchor is solved on one 256 µm tile, and its reading of the 48 µm aperture varies by a
  few percent between tiles; that is the scatter in the σ48 row above.
- The tone tables are read from 16 384 footprints. At 1 µm pixels a silver film's pixels vary
  by most of a density unit, and that sample leaves Tri-X about 0.01 D under the curve; at the
  pitches frames are rendered at it is well under 0.001 D.

## Where it runs

Every Halide road but WebGPU carries the stage: the JIT roads, the ahead-of-time table the Mac
app, Resolve and Final Cut link, Android's CPU and Vulkan kernels, and the browser's CPU
kernels. Each host keeps the tiles `fotufilm_halide_set_film_tiles` hands it and uploads them
to its device once per stock. A browser pack sealed with the film grain model closes with its
tiles, their float count last. WebGPU has no storage binding left for them, so a mode-3 frame
there renders the standard grain. The iOS app's handwritten Metal carries its own port of the
stage.
