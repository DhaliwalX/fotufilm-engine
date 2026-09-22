# Crystal grain

`--grain-model crystals` (Grain Model → Crystals in the host plugins) develops the grain of a
frame from statistical crystal populations and overlapping development clouds.
This page describes the physical approximations across its three stages (exposure,
development, print), how the image forms implicitly from dye clouds, which measurements set its
numbers, and how it renders.

## Implicit dye cloud image formation

The default grain model (and the Boolean disc model) computes a smooth characteristic curve
$D_{\text{curve}}$ first, then overlays an additive noise field $\delta D$ ($D = D_{\text{curve}} + \delta D$).

In contrast, the crystal grain model forms the developed density implicitly:

$$D = D_{\min} + \sum_{s=1}^{4}
  \left(\text{dye}_s + \overline{D}_{s,\mathrm{fit}} - \mathbb{E}[\text{dye}_s]\right)$$

(or for silver negatives, developed silver filament mass). The smooth characteristic curve
fits the sublayer population weights at roll load time. At render time, activated populations
form the dye-cloud field. A deterministic mean correction keeps that field centered on the
population fit: passing a fluctuating demand through a finite, concave coupler pool forms less
dye on average than passing its mean demand through the same pool. Without this correction,
changing the sampling changes the mean developed density and can introduce a colour shift.
The correction uses the marked-Poisson expectation of the actual discrete cloud kernel; it
does not remove the field's variation. For silver's linear response, the correction is zero.
The population fit itself remains an approximation to the stock curve.

These are simulated population fields, not recovered individual crystals. At high magnification,
fine cloud populations can overlap larger clouds. Their appearance depends on the output medium,
pixel aperture and viewing scale; a scan cannot validate structures smaller than it resolves.

## Stage 1: Exposure

A record of an emulsion is coated with a population of silver halide crystals. Each crystal has a
speed—the exposure at which it absorbs one photon on average—and forms a developable latent image
once a Poisson number of absorbed photons reaches the latent-image threshold of three. A speed
class therefore develops with the fraction:

$$p_k(E) = P[\text{Poisson}(10^{E - E_{0,k}}) \ge 3]$$

The record's curve above base is fitted as a non-negative mixture of 36 such classes, 0.2 decades
apart from $-3$ to $+4 \log E$, on the sampled reference curve. The fit is linear in the class
weights (projected coordinate descent NNLS), so it is exact and deterministic on every host.

Emulsion physics maps the exposure fit into crystals:

- **Speed goes with volume.** A crystal's sensitivity rises with the silver volume it holds
  (Mees & James), so speed places each class on a size ladder, $r \propto 10^{-E_0/3}$. The ladder
  is clipped to a sixfold radius span; classes beyond it represent boundary-sized crystals whose
  sensitivity differs by chemical sensitisation rather than physical size.
- **Developability and latent distribution.** Pull processing (<1) activates only a fraction of
  threshold centres, while push processing (>1) recruits sub-threshold 2-hit centres into
  developability.

## Stage 2: Development

At development, the activated latent centres grow into silver filaments and, in chromogenic
stocks, form dye clouds:

- **Sublayers and coupler starvation.** The classes are coated across four sublayers along speed,
  from fastest/coarsest down: a quarter of the record's weight in the fast sublayer, and the
  remainder distributed equally among the slower three. Each sublayer has a finite coupler pool.
  With $\text{demand}$ the dye its developed crystals ask for, the dye that forms is:

  $$\text{dye} = C \left(1 - \exp\left(-\frac{\text{demand}}{C}\right)\right)$$

  The pool is sized so that once a sublayer is fully developed, further development yields only
  a tenth of what an unstarved cloud would—modeling the coupler-starved fast sublayer of modern
  colour negative films. This starvation causes granularity to *fall* past its peak. Silver
  negatives have no coupler pool and do not experience dye exhaustion.
- **Mark rendering.** Each developed crystal forms a dye cloud whose area scales with crystal
  mass ($d \propto r^2$). To reproduce natural crystal morphology and development variance,
  crystals form two-point marks dispersing $1 \pm 0.5$ times the sublayer mean mark weight.
- **Reversal and fog.** Reversal dye forms in the unexposed crystals remaining after first
  development ($1 - p_k$). Fog forms at sensitivity specks on a crystal's surface, so each
  class fogs in proportion to $r_k^2$, scaled so the record's fog forms `grainFogDensity`: the
  large, fast crystals carry most of it and the smallest hardly fog at all.
- **Push/pull refit.** When pushed or pulled (e.g. Delta 3200 pushed 1–2 stops or pulled 2 stops),
  the crystal population is held fixed while developability and per-sublayer gains are refitted
  to the measured process curve using coordinate descent.

## Stage 3: Print

When printing a negative optically onto photographic paper:

- **Paper crystal population.** Photographic paper (such as Kodak Endura or Ilford Multigrade)
  uses an approximate population of fine cubic silver chloride crystals
  ($\approx 0.25\,\mu\text{m}$ edge, $\approx 3.1/\mu\text{m}^2$).
  The assumed coating weight is expressed as elemental silver. Crystal counts therefore use
  the AgCl crystal mass multiplied by its silver mass fraction, using
  [CIAAW atomic weights](https://www.ciaaw.org/atomic-weights.htm), before comparing with that coating.
  This mass balance is not a measurement of a particular paper's granularity.
- **Optical transmission.** The negative's dye clouds modulate exposure light across the paper.
  Paper crystals undergo Poisson latent-image activation according to transmittance through the
  negative.
- **emergent print grain.** The output image contains both the projected negative grain (blurred
  by enlarger MTF) and the paper's intrinsic high-density crystal noise.

Frame coverage retains the corresponding region of the original print. Cropping the frame at
unchanged film sampling therefore preserves the paper pixel area and crystal counts; it does
not enlarge the crop to fill a new sheet. Contact-print media use the film pixel pitch directly.

Paper grain and print optics are separate from film grain. Compare a lab scan with a compatible
scan receiver before using its texture to adjust a film's grain parameters. A shared stock name
alone does not match exposure, processing, optics or granularity measurement conditions.

## What sets the numbers

Two measurements per record anchor the physical scale:

- **RMS granularity $\sigma_{48}$** at read density (net 1.0 above base for negatives, gross or
  net 1.0 for reversals) sets the dye produced by a reference-size crystal through a 48 µm
  aperture. This anchors class weights to physical crystal counts per square millimetre.
- **`grainSizeMM`**, the scan-fitted clump radius, sets the cloud radius of the fastest sublayer.
  The remaining sublayers follow the size ladder downward.

Kodak's published granularity-against-density curves for Vision3 250D (5207) and 500T (5219)
established the universal geometric constants: pool gain ($0.1$), fast sublayer share ($0.25$),
and radius span ($6.0$).

## Gold 200, green record

Physical parameters derived for the pack's green record (`FOTUFILM_CRYSTAL_REPORT=gold200` on
`CrystalGrainTests`):

| Sublayer | Speed classes ($\log E$) | Cloud radius | Dye per cloud | Crystals | Pool |
|---|---|---|---|---|---|
| fast | −1.6 … −0.8 | 5.00 µm | 7.0 D·µm² | 0.15 /µm² | 0.46 D |
| | −0.6 … 0.0 | 3.33 µm | 3.1 D·µm² | 0.40 /µm² | 0.53 D |
| | +0.2 … +1.0 | 1.70 µm | 0.81 D·µm² | 1.7 /µm² | 0.60 D |
| slow | +1.2 … +2.4 | 0.86 µm | 0.21 D·µm² | 6.6 /µm² | 0.59 D |

The sublayers form the pack's curve to within 0.054 D, and reproduce the measured Vision3
granularity profile through the 48 µm aperture (in thousandths):

| net D | 0.1 | 0.2 | 0.3 | 0.5 | 0.7 | 1.0 | 1.3 | 1.6 | 1.8 |
|---|---|---|---|---|---|---|---|---|---|
| model | 17.0 | 18.0 | 16.0 | 14.3 | 13.8 | 10.5 | 9.3 | 8.6 | 8.3 |
| profile | 15.6 | 16.2 | 15.5 | 13.6 | 12.1 | 10.5 | 9.6 | 9.2 | 9.0 |

## Execution and performance

The crystal grain pipeline runs entirely within Halide on CPU and Metal:

1. Per pixel and sublayer, Poisson latent crystal counts are generated using hash-based PRNGs.
2. Two-point marks modulate individual crystal contributions.
3. Separable blurs deposit Gaussian dye clouds at the sublayer's physical radius.
4. Sublayer coupler pools exhaust available dye according to local demand.
5. In print mode, paper AgCl crystal activation is simulated across the projected image.

The crystal model is available in full reference-quality renders. Realtime preview schedules
and mobile/AOT targets fall back to the clump model to maintain interactive framerates.
