# Third-party notices

These notices cover the third-party material in this repository. Anything
built over the engine and shipped as a binary carries the same obligations to
its own readers, and discharges them wherever that binary can — so a change
here is a change there too.

These notices do not change the licence of Fotufilm-authored material; see
[LICENSING.md](LICENSING.md).

## Halide

The image pipeline is written against Halide and compiled by it. On macOS and
Linux `FotufilmHalide` links `libHalide` and JITs; where no compiler can ship
alongside the binary — iOS, and the Resolve plugin — the kernels are generated
ahead of time and linked in as static archives, which brings part of the
Halide runtime into the shipped binary. Halide is Copyright (c) 2012-2020 MIT
CSAIL, Google, Facebook, Adobe,
NVIDIA CORPORATION, and other contributors, and is distributed under the MIT
License: <https://github.com/halide/Halide>.

Because an ahead-of-time binary carries Halide runtime code, the MIT
copyright and permission notice travels with it and must be reproduced in full
wherever that binary is distributed. No part of Halide is vendored into this repository; the build fetches
it from the system (`brew install halide`).

## Measured-reflectance recovery prior

`Sources/FotufilmCore/Resources/rec2020-reflectance-prior.coeff` is a derived
posterior table fitted by `tools/spectral/generate_reflectance_prior.py`. The
generator resamples, bounds and statistically aggregates the following open
measurement sets; the original records and archives are downloaded into a
local cache and are not copied into this repository:

- Roger N. Clark and others, *USGS Spectral Library Version 7*,
  <https://doi.org/10.5066/F7RR1WDJ>, CC0 1.0 / United States public domain.
- Academy Software Foundation, `rawtoaces-data` training spectra at commit
  `e9b8503cf8a0641f40e5345d9757bde60c15f423`,
  <https://github.com/AcademySoftwareFoundation/rawtoaces-data>, Apache 2.0.
- Agustín Gutiérrez, Bárbara Silva, José M. Fanchini, Takuma Morimoto,
  Pablo A. Barrionuevo and María L. Sandoval-Salinas, *Spectral dataset of
  natural objects' reflectance from the Southern cone of South America*,
  <https://doi.org/10.6084/m9.figshare.25705380.v4>, CC BY 4.0.
- Daniel Lipsky, Lily Pitcher, Juan C. Osorio-Ospina and Helene C.
  Muller-Landau, *Hyperspectral Reflectance Data for Flowers, Fruits, Bark,
  and Leaves of Plants on Barro Colorado Island, Panama*,
  <https://doi.org/10.60635/C37W2T>, CC BY 4.0.
- P. Yvonne Barnes, David Allen and Benjamin K. Tsai, *Reference Data Set of
  Human Skin Reflectance*, <https://doi.org/10.6028/jres.122.026>, NIST open
  data / United States public domain.
- Yan Lu and others, *The International Skin Spectra Archive (ISSA): a
  multicultural human skin phenotype and colour spectra collection*,
  <https://doi.org/10.6084/m9.figshare.28228571.v4>, CC BY 4.0.

The generated table is an adaptation: measurements are resampled to the
engine's 41 bands, implausible records are rejected, small out-of-range values
are clipped, and the resulting mean and covariance, with a curvature penalty,
drive bounded quadratic optimisations over the Rec.2020 anchor faces. The coefficient file is recorded by hash in `SOURCE_ASSETS.json`. The CC BY 4.0 licence is at
<https://creativecommons.org/licenses/by/4.0/>.

## OFX image effect API

`resolve/openfx/` holds ten headers from the OpenFX image effect API, the
interface the DaVinci Resolve plugin is written against. They are Copyright
(c) 2003-2015 The Open Effects Association Ltd and OpenFX contributors, and
distributed under the BSD
3-Clause License: <https://github.com/AcademySoftwareFoundation/openfx>. Each
file carries the full copyright, conditions and disclaimer in its own header
comment, unmodified. The base API headers are from `OFX_Release_1_4_TAG`; the
colour exchange and native-config headers are the OFX 1.5 versions distributed
with the DaVinci Resolve 21 SDK.

The API is headers only: there is no OpenFX code in the built plugin, which
implements the interface rather than linking an implementation of it. It is
also the only notice here that applies to the plugin alone — nothing in
`resolve/openfx/` reaches the library or the CLI.

## rawtoaces camera spectral sensitivity data

`Sources/FotufilmCore/CameraProfiles/` holds measured camera spectral
sensitivity datasets copied from the Academy Software Foundation's
rawtoaces data repository
(<https://github.com/AcademySoftwareFoundation/rawtoaces-data>, commit
`e9b8503cf8a0641f40e5345d9757bde60c15f423`, files unmodified). The data is
distributed under the Apache License 2.0; the licence text is reproduced in
full at `Sources/FotufilmCore/CameraProfiles/LICENSE`, and each JSON file
declares `"license": "Apache-2.0"` in its own header.

The directory ships as a copied resource, so the datasets — and the licence
file beside them — travel inside every binary that links `FotufilmCore`. The
apps' acknowledgements screens carry the attribution and point at that
bundled copy of the licence.

## Synthetic films and print receivers

`Sources/FotufilmCore/Stocks/` contains only project-authored synthetic examples.
Print receivers and projection illumination are project-authored analytic models.

## CIE colorimetric data

The 10 nm samples in `SpectralModel.swift` are drawn from the CIE open data
sets “CIE 1931 colour-matching functions, 2 degree observer” and “CIE standard
illuminant D65”, published by the International Commission on Illumination.

## App Store badge

`docs/assets/download-on-the-app-store.svg` is the unmodified "Download on the
App Store" badge artwork that Apple provides for linking to an app's App Store
listing, used here under Apple's App Store Marketing Guidelines. Apple, the
Apple logo and App Store are trademarks of Apple Inc., registered in the U.S.
and other countries and regions.
