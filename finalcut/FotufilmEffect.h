#ifndef FOTUFILM_FINAL_CUT_EFFECT_H
#define FOTUFILM_FINAL_CUT_EFFECT_H

#include <stdint.h>

#include <IOSurface/IOSurfaceRef.h>

#include "FotufilmBridge.h"
#include "WorkingSpace.h"

/// The parameter ids Final Cut persists. They are an ABI in exactly the sense the OFX plugin's
/// parameter *names* are: a project file keeps the id, so a value moved to a different id is a
/// value the next open reads off the wrong control. Ids are never reused and never renumbered;
/// a retired one stays retired. FxPlug reserves ids outside 1...9998, so the block below stays
/// well inside that.
enum {
    kFotufilmParam_Stage = 1,
    kFotufilmParam_Stock = 2,
    kFotufilmParam_Format = 3,
    kFotufilmParam_Paper = 4,
    kFotufilmParam_ColorSpace = 5,

    kFotufilmParam_Exposure = 6,
    kFotufilmParam_Temperature = 7,
    kFotufilmParam_Tint = 8,

    kFotufilmParam_Highlights = 9,
    kFotufilmParam_Shadows = 10,
    kFotufilmParam_LocalTone = 11,
    kFotufilmParam_Saturation = 12,
    kFotufilmParam_Vibrance = 13,

    kFotufilmParam_Grain = 14,
    kFotufilmParam_Halation = 15,
    kFotufilmParam_EstimatedHalation = 16,
    kFotufilmParam_HalationColour = 17,
    kFotufilmParam_Flare = 18,
    kFotufilmParam_Couplers = 19,
    kFotufilmParam_PrintCorrection = 20,
    kFotufilmParam_Seed = 21,

    kFotufilmParam_Push = 22,
    kFotufilmParam_BleachBypass = 23,
    kFotufilmParam_Expired = 24,
    kFotufilmParam_PrintLight = 25,

    /// Stable menu-choice IDs. Persisted indices may change when packs are updated, so rendering
    /// resolves the ID first and reconciles the menu index.
    kFotufilmParam_StageID = 26,
    kFotufilmParam_StockID = 27,
    kFotufilmParam_FormatID = 28,
    kFotufilmParam_PaperID = 29,

    /// Group headers.
    kFotufilmParam_PipelineGroup = 30,
    kFotufilmParam_FilmGroup = 31,
    kFotufilmParam_ExposureGroup = 32,
    /// Retired: the Tone controls now sit in the Exposure group, which the inspector titles
    /// Light & Colour. The number is kept out of circulation, as every parameter id is.
    kFotufilmParam_ToneGroup_Retired = 33,
    kFotufilmParam_ResponseGroup = 34,
    kFotufilmParam_LabGroup = 35,
    kFotufilmParam_OutputGroup = 36,

    /// The read-only status line: what the plugin is doing with what it has been given, and why
    /// something it was asked for is not happening. Derived state, refreshed whenever a control
    /// moves and when an instance joins a document; it is published so the inspector shows it.
    kFotufilmParam_Status = 37,

    /// One toggle per spatial stage the texture span can lay over the frame, in the order
    /// `fotufilm_bridge_texture_stage_*` hands them out. The block is sized generously so that a
    /// stage added to the engine lands on a fresh id rather than shifting the ones after it.
    kFotufilmParam_TextureStageFirst = 40,
    kFotufilmParam_TextureStageLimit = 72,

    /// The lens: what is screwed onto the front of it, and how the exposure was set behind that.
    /// The block starts where the reserved texture block ends, so nothing here can collide with a
    /// spatial stage the engine grows into.
    kFotufilmParam_LensGroup = 72,
    kFotufilmParam_LensFilter1 = 73,
    kFotufilmParam_LensFilter2 = 74,
    kFotufilmParam_LensFilter3 = 75,
    kFotufilmParam_Metering = 76,
    kFotufilmParam_Diffusion = 77,
    kFotufilmParam_DiffusionGrade = 78,
    kFotufilmParam_FocalLength = 79,

    /// How a developed negative is read. It lives in the Output group with the rest of what
    /// happens after the film, not in the Lens group.
    kFotufilmParam_NegativeViewing = 80,

    /// Stable menu-choice IDs for the four catalogue menus in the Lens group, following the
    /// 26...29 pattern above: hidden, never published, and the thing a project actually keeps.
    /// The filter drawer is the one menu here that will certainly grow, and a drawer that gains a
    /// filter renumbers every entry after it.
    kFotufilmParam_LensFilter1ID = 81,
    kFotufilmParam_LensFilter2ID = 82,
    kFotufilmParam_LensFilter3ID = 83,
    kFotufilmParam_DiffusionID = 84,

    /// Group headers added when the inspector was laid out to match the Resolve plug-in:
    /// Input at the top, and Halation and Colour Separation split out of what was one
    /// Film Response group. Groups hold no value, so only the order they are declared in
    /// matters to a project.
    kFotufilmParam_InputGroup = 85,
    kFotufilmParam_HalationGroup = 86,
    kFotufilmParam_CouplerGroup = 87,
};

/// The id the plugin writes for the "None" entry the filter and diffusion menus open with. The
/// engine has no name for an empty filter thread, so this one belongs to the bridge contract,
/// which spells it once for both hosts: it is a persisted project id, and a second spelling here
/// would orphan every filter choice the OFX plugin saved.
#define kFotufilmNoFilterID FOTUFILM_BRIDGE_NO_FILTER_ID

/// The id of the Full span, which is the identity a brand-new instance holds for the Stage menu.
/// It is `PipelineStage.full`'s own raw value, the same string `fotufilm_bridge_stage_id(0)`
/// hands back, and the same one the OFX plugin persists for a node created against a placeholder
/// panel. Spelled here because a placeholder Stage menu has to name it before the engine that
/// would have supplied it is up.
#define kFotufilmFullStageID "full"

/// The index of "Auto (from host)" in the colour space menu, and the frozen layout around it. The
/// menu persists by index, so the order is an ABI: the seven spaces the plugin shipped with keep
/// their original indices, Auto sits at 7, and a space added since is appended after Auto.
/// `fotufilm::Encoding::Count` is the sentinel this maps Auto to.
enum { kFotufilmColorSpaceAuto = 7 };

/// The viewing-illuminant menu in its persisted order. Zero means the medium reference: D50 for
/// reflection paper or calibrated 5400 K xenon for projection. D65 is appended so existing menu
/// indices are not renumbered.
static const float kFotufilmPrintLightKelvin[] = {0.0f, 5003.0f, 2856.0f, 6504.0f};

/// The identity a saved project holds for the gauge that follows the stock. It is the plugin's
/// own, not the bridge's: "match film" is expressed to the engine by passing a format index at
/// or past `fotufilm_bridge_format_count()`, which the bridge reads as "the gauge this stock is
/// known on".
#define kFotufilmMatchFilmFormatID "match-film"

/// The output-menu sentinel passed one past the bridge's concrete media, leaving the engine to
/// choose the stock's physically native output.
#define kFotufilmMatchFilmPaperID "match-film-output"

/// Everything the render needs, packed in `pluginState:atTime:quality:error:` and unpacked in
/// `renderDestinationImage:...`. The split is not a style choice: the host parameter APIs are
/// reachable only from the state call, and the render runs on threads — and, for a rendered
/// range, on frames — that cannot reach back.
///
/// The struct is memcpy'd into an NSData and back, so it must stay a fixed-layout POD: no
/// pointers, no ObjC objects, no bitfields. `version` guards a state blob written by one build
/// and read by another during a live plugin update.
typedef struct {
    uint32_t version;

    /// Already resolved against the persisted id strings, so the render never sees a menu index.
    int32_t stock;
    int32_t format;
    int32_t paper;

    /// The colour space *menu index*, not an encoding: `kFotufilmColorSpaceAuto` still has to be
    /// resolved against the image, which only the render holds.
    int32_t colorSpace;

    uint32_t seed;

    /// The host's quality hint for this frame, raw. See `kFotufilmDeliveryQuality`.
    uint32_t quality;

    /// Slots 16 and 17 — the span and the texture mask — are already composed into this array,
    /// as `fotufilm_bridge_render` wants them.
    float parameters[FOTUFILM_BRIDGE_PARAMETER_COUNT];
} FotufilmState;

/// Bumped to 2 when the Lens group's eight slots were appended to the parameter block. The blob
/// is memcpy'd, so a state written by the previous build is a different length as well as a
/// different shape.
enum { kFotufilmStateVersion = 2 };

/// The `quality` value at which a frame is being kept rather than shown and discarded.
///
/// It gates one thing: whether the engine may measure veiling glare on the GPU instead of on the
/// host. The GPU sums float32 in its own order and lands about 1.3e-5 from the host's
/// double-precision sum — under a 16-bit LSB, invisible in a viewer, and not a thing to write to
/// disk. So anything at or above this is developed the exact way.
///
/// FxPlug's `FxQuality` orders its values low to high, and this is the top one. Confirm it
/// against the `FxQuality` enum in the installed SDK's headers: too low and a delivered frame
/// takes the fast path, which is the failure that matters. Too high only costs the viewer speed.
enum { kFotufilmDeliveryQuality = 2 };

/// How long a failed engine start waits before it is tried again. The engine is initialised once
/// per XPC process, and the reason it can fail — the Mac app not yet activated — is one the user
/// fixes while Final Cut stays open, so the failure is not latched: the next use after this many
/// seconds asks again. Short enough to feel immediate, long enough that a clip full of effect
/// instances does not hammer the licence check.
enum { kFotufilmEngineRetrySeconds = 3 };

/// What one Timeline Color Space menu index means, split into the two halves that are decided
/// separately.
///
/// `FotufilmMenuPrimaries` is the encoding whose *matrices* the choice is decoded with, or
/// `fotufilm::Encoding::Count` for Auto, which only the render can resolve against the image.
/// `FotufilmMenuTransfer` is the encoding whose *transfer curve* is applied, which is a linear
/// one for every choice: the plugin asks Final Cut for `kFxImageColorInfo_RGB_LINEAR`, so the
/// light it is handed has already had the library's curve taken off it, and applying a second
/// one would bend it twice. Four menu entries name a curved library — Rec.709 Gamma 2.4, sRGB,
/// DaVinci Intermediate, ACEScct — and they are the four this matters to.
///
/// Exposed so the harness can check the pairing without a render; they are not part of the
/// effect's interface.
__attribute__((visibility("hidden")))
fotufilm::Encoding FotufilmMenuPrimaries(int choice);
__attribute__((visibility("hidden")))
fotufilm::Encoding FotufilmMenuTransfer(int choice);

/// A 64-bit hash over every pixel byte of a `width * height` frame held in `surface`, top-left
/// corner first, rows walked at the surface's own stride. It is what tells the tiled path's frame
/// cache that the picture upstream changed while every parameter stayed still. Exposed so the
/// harness can time it on a full-size frame; it is not part of the effect's interface.
__attribute__((visibility("hidden")))
uint64_t FotufilmContentHash(IOSurfaceRef surface, int width, int height);

#if defined(FOTUFILM_FXPLUG_STUB)
/// Two counters the harness reads and nothing else compiles. Both exist because what is under
/// test is work that does *not* happen: `fotufilm_bridge_initialize` not being called a second
/// time after a failure that arrived once it had already succeeded, and the whole-frame content
/// hash not being taken again for the second tile of the same untouched surface. Neither absence
/// is visible in a rendered frame, a status line or an error.
#ifdef __cplusplus
extern "C" {
#endif
extern uint32_t FotufilmTestBridgeInitializeCount;
uint32_t FotufilmTestContentHashCount(void);
#ifdef __cplusplus
}
#endif
#endif

#endif
