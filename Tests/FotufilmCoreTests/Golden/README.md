# Image regression tests

These tests render all 40 film profiles and three synthetic films over four
generated charts: color patches, a step wedge, gamut fields, and spatial detail.
Every render must contain finite pixels and appears in the generated review sheet.
Gold 200, Tri-X 400, Provia 100F, and the three synthetic films also have saved
image baselines, called goldens, that catch changes in rendering. Missing baselines
for those six films fail the test. Other films need no committed render images;
`ReleasedProfileRenderingTests` checks CPU/Metal agreement across all 40 profiles.

Run from the repository root:

```sh
swift test -c release --filter GoldenImageTests
```

## Update the saved images

Only update goldens after an intentional rendering change:

```sh
FOTUFILM_GOLDEN=update swift test -c release --filter GoldenImageTests
```

The update run fails on purpose so the new images must be reviewed. Open the review
page in `.build/golden-review`, check the images, and update their hashes and
provenance in `SOURCE_ASSETS.json`. Then rerun the tests without `FOTUFILM_GOLDEN`.

These tests detect changes; they do not prove a match to physical film. Use generated
charts for new tests. Do not add personal photographs or manufacturer artwork.
