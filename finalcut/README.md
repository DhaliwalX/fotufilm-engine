# Fotufilm for Final Cut Pro

Default builds include Gold 200, Tri-X 400, and Provia 100F from the free
[Starter pack](../licenses/STARTER-PACK.txt).

This plugin adds Fotufilm to a clip in Final Cut Pro or Motion. It shares the engine,
stock files, and color-space conversions used by the Resolve plugin.

## Requirements

Install Xcode 26 or newer, Halide (`brew install halide`), and Apple's FxPlug SDK.
The SDK is available from [Apple Developer Downloads](https://developer.apple.com/download/all/).
The plugin targets macOS 14 or newer.

The build expects both parts of the SDK:

| Part | Default location |
| --- | --- |
| Headers | `/Library/Developer/SDKs/FxPlug.sdk` |
| FxPlug and PluginManager frameworks | `/Library/Developer/Frameworks` |

Set `FXPLUG_SDK` and `FXPLUG_FRAMEWORKS` if they are installed elsewhere.

## Build and install

Run commands from the repository root:

```sh
finalcut/build.sh
```

The result is `build/finalcut/Fotufilm for Final Cut Pro.app`. To install it:

```sh
finalcut/build.sh --install
```

This copies the app to `/Applications`, registers the plugin, and installs its
Motion effect template in your Movies folder. Restart Final Cut Pro, then find
**Fotufilm** under **Effects**.

The Fotufilm Mac app can also install the plugin. `macos/build.sh` includes it when
the FxPlug SDK is available. Without the SDK, the Mac app builds without this plugin.

## Test without Final Cut or the SDK

```sh
finalcut/build.sh --test
```

This runs a small test host with a substitute SDK interface. It checks real engine
renders, controls, color conversions, image tiles, and the effect template. It does
not build the installable plugin or test the Final Cut user interface. Also build
with the real SDK and check the effect in Final Cut or Motion before distribution.

The test host accepts `--parity-dump <path>` to save the same test frame used by the
Resolve test host.

## Use the plugin

To add a pack, open the Fotufilm Mac app and choose **Load custom pack…**.
Restart your video editor after importing or updating it. Its films appear in the
plugin automatically on the same Mac and user account. Keep the app and plugins
updated together; packs that need a newer version are skipped.

1. Add **Fotufilm** to a clip.
2. Choose a film and gauge.
3. Leave **Timeline Color Space** on **Auto (from host)** unless you need an override.
4. Leave **Stage** on **Full** for the complete film and print process.
5. Adjust exposure, output medium, lens filters, film response, and development.

The **Status** line explains input color handling, unavailable controls, and render
errors. The plugin includes the three Starter films and needs no activation.
A smaller film gauge makes grain and other spatial effects larger in the image.

Final Cut supplies linear-light images. The color-space choices therefore select
color primaries, without applying a second gamma or log conversion. Auto reads the
image's color information. An unnamed color space falls back to linear Rec.709,
and the status line reports that choice.

## Pipeline stages

**Full** produces the final image. **Negative Only** produces density data for a
**Print Only** effect. **Texture Only** adds selected spatial effects to the input.

For a split pipeline, place Negative Only directly before Print Only. Match the
film, gauge, and development settings. Do not add other effects between them. The
intermediate values are optical-density data, so they need a 32-bit float path.
Print Only requires an explicit timeline color-space choice; Auto is unavailable.

## Build for distribution

`--universal` builds for Apple silicon and Intel Macs. Local builds use an ad-hoc
signature. Set a Developer ID identity to sign for distribution:

```sh
FOTUFILM_CODESIGN_IDENTITY="Developer ID Application: …" finalcut/build.sh --universal
```

The build signs and checks the frameworks, plugin extension, and wrapper app.
Notarization is a separate step. Version numbers come from `version.env`.

## Troubleshooting

If the effect is missing, confirm that the plugin is registered and restart the host:

```sh
pluginkit -m -p FxPlug -v
```

Look for `com.fotufilm.fxplug`. The plugin and its Motion template must both be
installed. The template controls which parameters appear in Final Cut's inspector;
`tools/validate-fcp-template.py` checks its structure during the build.

See [Build support](../docs/support.html), the [Resolve guide](../resolve/README.md),
and [Licensing](../LICENSING.md) for more information.
