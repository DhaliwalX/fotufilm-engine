# Physical print borders

The iPhone photo editor offers None, Film Border and Paper Border. Border metadata lives with
film stock definitions. The finishing compositor is shared by preview and export and runs after
image formation, with no photograph resampling or changes to its colour profile.

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
No manufacturer edge lettering, fake frame numbers, random damage or orange rim is added.

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
