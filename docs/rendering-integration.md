# Rendering integration

The Apple app sources expose `FilmRenderBackend` in
`shared/FotufilmApp/FilmRender.swift`. Hosts compile this contract with the shared
app layer and install an implementation using `FilmRender.installDevelopmentBackend`.
Portable simulation types remain in `FotufilmCore`.

## Renderer contract

`DevelopmentRequest` carries the decoded scene, edit state, optional film and
negative-view overrides, detail measurements, HDR and histogram options, exact
math preference, progress callback, and cancellation callback. `develop` returns
the rendered image and requested histograms. `developRegion` returns the valid
image core and its viewport; the caller must not crop the returned image again.

The backend supplies `spatialSupport` to size the surrounding pixels needed by
regional effects and `detailMeasurements` for reusable whole-frame measurements.
Measurements belong to the exact backend instance that created them. A replacement
backend must measure again; `context(for:)` refuses another instance's context.

Implementations must support concurrent requests, observe cancellation, and throw
for unsupported work. An installed backend's failures do not silently select the
built-in renderer. Installing `nil` selects the built-in renderer for future calls.
Hosts should change backends when no work is running and clear renderer-dependent
caches at that boundary.

`SpectralPipelineTables` has a public initializer for renderers and diagnostics that
need to construct exposure, film-output, and optional paper-output lookup tables.
The Halide Metal frame and streaming paths accept `exactMath` for reference renders;
the generated AOT catalogue includes exact grain variants for those paths.

## Buffer storage and ownership

`MappedBuffer.StoragePreference` selects automatic storage, a memory preference up
to a byte allowance, or bounded anonymous memory. With `boundedMemory(upTo:)`, a
larger allocation must use a temporary file or fail; it cannot fall back to an
unbounded anonymous allocation. This is a per-allocation policy, not a process-wide
resident-memory cap. Mapped pages can still become resident.

The backend's `sceneStorage` selects the policy for decoded scene pixels. Callers
can also supply a storage override when preparing a scene. `residentByteCount`
reports the anonymous-memory allocation to charge to the caller's budget; it does
not measure the residency of file-backed pages. Image providers retain their buffer
until release, including correct cleanup when provider creation fails.

## Film grain assets

`FilmGrainAsset.identity` describes all population and bank inputs, including the
reference roll for altered development. `generate` produces versioned, lossless
bytes independently of any installed asset provider. Applications may compress
and package those bytes, then register a thread-safe lookup with
`FilmGrain.installAssetProvider`.

The loader verifies identity, dimensions, counts, finite values, and complete input
consumption. Missing, stale, or invalid data falls back to canonical generation.
Cross-platform generation requires output verification: serialization preserves
Float32 bits but does not make different hosts' math libraries identical. Seed,
film format, amount, and Film look controls remain runtime settings.

`FilmGrain.TileBinding` owns the canonical bank and its backend registration.
`FilmEngineInvocation` retains that binding so cache eviction cannot invalidate
an active render. The registration is released after its final owner goes away.
