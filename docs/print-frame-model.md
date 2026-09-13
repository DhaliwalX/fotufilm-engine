# Physical print borders

The iPhone photo editor offers None, Film Border and Paper Border. Film Border shows a negative
stock's developed negative on its film, using the existing density-to-transmission renderer.
Reversal and integral instant film retain their developed positive image. The paper selection
is retained: None and Paper Border return to the chosen output medium. Menu previews, the canvas,
zoomed detail, saved thumbnails and exports use the same material-dependent image.

Border metadata lives with film stock definitions. The finishing compositor runs after image
formation, with no photograph resampling or changes to its colour profile. Negative delivery is SDR.

## Film geometry

An automatic border uses the stock's native format. An explicit Film Gauge overrides it. Camera
sensor metadata does not select a different border. A crop that differs from the physical camera
aperture is centred inside it; the film and holes are never stretched to the crop.

| Format | Image aperture, mm | Film segment, mm | Edge construction |
| --- | --- | --- | --- |
| 135 still | 36 × 24 | 38 × 35 | Two rows of KS holes, eight pitches per frame |
| Super 35 | 24.92 × 18.67 | 35 × 18.96 | Two rows of BH holes, four pitches per frame |
| Super 16 (the app's 16mm gauge) | 12.35 × 7.42 | 16 × 7.605 | Single perforation row, holes at frame lines |
| Super 8 | 5.79 × 4.01 | 7.976 × 4.234 | Single small-perforation row, hole at frame centre |
| 120, 6 × 6 | 56 × 56 | 61 × 60 | Unperforated roll film |
| 4 × 5 sheet | 95 × 120 | 100 × 125 | Unperforated sheet, stock-specific notch code when documented |
| Instax Mini | 46 × 62 | 54 × 86 | Integral positive border |
| Instax Square | 62 × 62 | 72 × 86 | Integral positive border |
| Instax Wide | 99 × 62 | 108 × 86 | Integral positive border |

KS holes are rounded rectangles, 2.794 mm across the film and 1.981 mm along transport,
with a 0.510 mm corner radius and 4.75 mm pitch. A motion stock used in a 135 camera retains
its BH holes and 4.74 mm pitch. BH holes are circular sides bounded by
parallel flats (2.794 mm circle diameter, 1.854 mm height), at 4.74 mm pitch. 16 mm holes
measure 1.829 × 1.270 mm with a 0.250 mm corner radius. These dimensions and profiles
come from [Kodak's motion-picture catalogue, Perforations, page 13](https://www.kodak.com/content/pdfs/motion/Kodak-Motion-Picture-Products-Price-Catalog-EAMER.pdf).
Super 8 uses the Type S geometry described by SMPTE ST 149, including a 0.914 × 1.143 mm
hole and 4.234 mm long pitch. Instax image and outer dimensions follow
Fujifilm's specifications for [Mini](https://www.instax.com/mini_link/en/spec.html),
[Square](https://www.instax.com/sq1/en/) and
[Wide](https://asset.fujifilm.com/master/apac/files/2020-06/acf110878e2c263a1a0c13b762fb1cbe/instax_datasheet.pdf).

The chosen 120 frame-to-frame spacing, sheet-film camera aperture, and instant border's top/bottom
allocation are representative presentation conventions: cameras, holders and product revisions
can differ. Instant borders require the matching instant-film stock. A gauge chosen for a stock
that was never sold in that size represents the selected simulation gauge, not an availability claim.

## Stock-specific notches

`FilmStockDefinition.sheetNotches` carries a source URL and the shape, relative position, width
and depth of each notch. FP4 Plus and HP5 Plus use the patterns for sizes up to 10 × 12 inches
in [Ilford's Notch Codes guide, page 1](https://www.ilfordphoto.com/wp/wp-content/uploads/2017/06/Notch-Codes-Guide..pdf).
Both have a wide shallow arc at each end and a smaller round notch between; its different
position distinguishes the stocks. They appear at the upper right with the sheet upright and
the emulsion facing the viewer, and rotate with the sheet.

The guide gives identification diagrams, not machining dimensions. Their relative profiles are
modelled within a representative 20 mm span, ending 10 mm from the corner. These sizes are
not measured manufacturer tolerances. A stock without a documented code has no invented
notches and the frame menu identifies that missing information. Roll film and paper never
receive sheet-film notches. The neutral background seen through cutouts is a scan-bed convention.
Random edge fogging and gate damage are not added.

## Edge printing

Optional `FilmStockDefinition.edgePrinting` records carry the exact inscription, source URLs,
physical text boxes and supported gauge. The renderer draws a representative segment of the
manufacturer's edge print in the outer rebate, rotating it with the film. Roll-film markings are
viewed from the base side, as in the source diagrams. The existing sheet view remains emulsion-side
up for notch identification; sheet lettering has not been verified and is omitted.

| Stock | Gauges with verified inscriptions | Inscription |
| --- | --- | --- |
| Portra 400 | 135, 120 | KODAK PORTRA 400 |
| Ektar 100 | 135, 120 | KODAK EKTAR 100 |
| Tri-X 400 | 135, 120 | KODAK 400 TX |
| T-Max 100 | 135, 120 | KODAK 100 TMX |
| HP5 Plus | 135 | ILFORD HP5 PLUS |
| Velvia 50 | 135, 120 | FUJI / RVP50 |
| Vision3 250D | 35 mm still, Super 35, Super 16 | 5207 / EN |
| Vision3 500T | 35 mm still, Super 35, Super 16 | 5219 / EJ |
| Double-X | 35 mm still, Super 35, Super 16 | 5222 / KE |

Sources:

- [Kodak Portra 400 product specification](https://www.kodakprofessional.com/photographers/film/color/kodak-professional-portra-400-film/516)
  and [Ektar 100 specification](https://www.kodakprofessional.com/photographers/film/color/kodak-professional-ektar-100-film/530): literal edge-print names.
- [Kodak Professional catalog, L-9 (2003)](https://filmcolors.org/wp-content/uploads/2025/11/2003KodakProfessionalCatalog_L9.pdf),
  printed pp. 6R and 16R: 135 and 120 layout families and black-and-white stock inscriptions.
  The old Portra NC/VC product names are not reused. Kodak's 120 dual numbering is distinct
  from its 135 full/half-frame numbering; full/half-frame spacing on 135 is 38/19 mm.
- [Ilford's processing examples](https://www.ilfordphoto.com/common-film-processing-problems/):
  HP5 Plus lettering and full/half-frame locations in the overexposure example.
- [Fujifilm Velvia 50, AF3-0221E2](https://asset.fujifilm.com/master/emea/files/2020-10/a71dda63e2662f012b3b74110794918a/films_velvia-50_datasheet_01.pdf),
  PDF p. 6: RVP50 inscriptions and different 135/120 arrangements.
- [Kodak 35 mm KEYKODE diagram](https://www.kodak.com/content/products-brochures/Film/post-production-35mm-keykode-diagram.pdf)
  and [16 mm KEYKODE guide](https://www.kodak.com/content/products-brochures/Film/post-production-16mm-keykode-diagram.pdf),
  PDF p. 2: gauge-specific production inscriptions. A single cinema frame shows only a stock-code
  fragment, not an entire foot of KEYKODE data squeezed into one frame.

These are reference cuts, not reproductions of an identified manufactured roll. The still-film
numbers select a representative position; they are not the imported photograph's original frame
number. Production batch, emulsion/roll serials, year and machine-readable barcodes are omitted.
Unknown stock/gauge pairs, sheet film, Super 8, instant masks and paper fronts stay unlettered.

The published diagrams and scans establish text and layout families but do not provide precise
printer font outlines, exposure spectra or tolerances. System vector lettering and its millimetre
boxes approximate those shapes and positions. Letter density is a representative 72% of the
negative stock's density span, or 8% of a reversal stock's span above minimum density. The same
stock dye spectra, light-box gain and lamp produce the resulting letter colour. This makes negative
letters dark and reversal letters light without a universal painted amber colour. Edge density does
not claim to measure the particular roll or follow its lab development. No source images or fonts
are embedded. Image pixels, profiles and bit depth remain unchanged by the compositor.

## Film colour

Film Border depicts the material surrounding the image. Colour-negative borders use the stock's
minimum-density records and dye spectra, retaining its base-plus-fog and orange mask. Monochrome
negative borders retain their modelled clear-base tint. A common light-box gain is used for negatives,
so it does not neutralise their colours. Reversal borders use the stock's maximum-density records:
unexposed slide-film rebate develops dark. Film Border uses the renderer's standard reference
light box for both the image and its rebate, retaining the mask even when the separate negative
preview preference is Scanner. Viewing Light remains the paper's setting and is restored with
that output. Integral instant film keeps its attached white mask, separate from the image dyes.

These colours follow the existing spectral stock models; they are not separately measured samples of
individual roll edges. The photograph inside the aperture retains the stock's development,
grain and exposure; its density is viewed through the film instead of printed to paper.

## Paper construction

Paper Border is offered for Ektacolor Edge, ENDURA Premier and Crystal Archive Type CA.
All use a real supported lustre surface on resin-coated photographic paper, with clean cut edges.
It represents a 4 × 6 inch (101.6 × 152.4 mm) print cut from a roll, with a chosen 3 mm easel
margin. Paper roll width and trim are print choices, not intrinsic dimensions of the emulsion.

- [Kodak Ektacolor Edge product sheet](https://business.kodakmoments.com/sites/default/files/files/products/EKTACOLOREDGE_LTR_EN_LR.pdf), surfaces E and F.
- Kodak ENDURA Premier technical publication E-4070, page 1: resin-coated paper, including E lustre.
- [Fujifilm Crystal Archive Type CA product sheet](https://asset.fujifilm.com/www/us/files/2020-02/dcbe0cc43213e90b8d4e177cf01b6c48/Fujicolor_Crystal_Archive_Paper_Type_CA.pdf): glossy, matte and lustre surfaces.

The base is calculated through the selected paper's existing minimum-density records, dye
spectra and viewing light. It is the engine's substrate approximation, not a new measurement
of paper-white reflectance or optical brighteners. Crystal Archive retains the engine's documented
RA-4 curve proxy. Fine surface stipple is procedural: published surface names do not provide
measured microtopography. Cotton fibres, baryta bases, deckled edges and artificial ageing are
not appropriate to these stocks and are not offered. Screen, scans, negatives and motion-picture
print films do not become paper sheets; Paper Border is inactive on those outputs.
