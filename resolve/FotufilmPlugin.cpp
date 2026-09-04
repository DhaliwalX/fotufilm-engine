
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include <dlfcn.h>
#include <libgen.h>

#include "openfx/ofxImageEffect.h"
#include "openfx/ofxColour.h"
#include "openfx/ofxMemory.h"
#include "openfx/ofxMessage.h"
#include "openfx/ofxMultiThread.h"

#include "FotufilmBridge.h"
#include "WorkingSpace.h"

/// The version the OfxPlugin struct carries. build.sh reads MARKETING_VERSION out of project.yml
/// and passes both halves in, so the plugin, its Info.plist and the app agree on one line; the
/// fallback only exists so a bare `clang++ resolve/FotufilmPlugin.cpp` still compiles. OFX treats a
/// change of major as a different plugin — a host may refuse to open a project saved with the other
/// — so a marketing version that crosses 2.0 needs a decision here, not just a new number.
#ifndef FOTUFILM_VERSION_MAJOR
#define FOTUFILM_VERSION_MAJOR 1
#endif
#ifndef FOTUFILM_VERSION_MINOR
#define FOTUFILM_VERSION_MINOR 6
#endif

namespace {

OfxHost *gHost = nullptr;
const OfxImageEffectSuiteV1 *gEffect = nullptr;
const OfxPropertySuiteV1 *gProperty = nullptr;
const OfxParameterSuiteV1 *gParameter = nullptr;
/// Optional: a host without it still works, it just keeps its errors to stderr.
const OfxMessageSuiteV1 *gMessage = nullptr;
/// Optional: a host without it transcodes on one core instead of all of them.
const OfxMultiThreadSuiteV1 *gThread = nullptr;
/// Cached host CPU count used by strip transcoding. Initialized on first use because some hosts
/// cannot provide it during plugin loading.
unsigned int gCPUs = 0;

/// Filled in at load. The ids run parallel to the labels and are the identity that survives a
/// project file; the labels and menu indices are display.
bool gEngineReady = false;
/// `fotufilm_bridge_initialize` has returned a count in this load, so the sealed packs are open
/// and the process-wide stock registry is built. That call is the expensive and the dangerous
/// half of coming up: it reads the packs off disk, and everything read out of the bridge after it
/// is copied into the vectors below, which `isIdentity`, `getClipPreferences` and `reconcile`
/// read from the host's own threads without a lock. Once it has succeeded there is nothing in it
/// left to retry — the failures that can still be standing afterwards, no Metal device or an
/// empty pack, are not repaired by reopening the packs — so it is latched here and the retry
/// below re-reads the answer rather than rebuilding it. Cleared by `unload`, which is the host
/// letting go of the plugin entirely.
bool gBridgeInitialized = false;
/// When `initializeEngine` last ran, and whether it ever has. A node created while the engine is
/// down retries it, and a timeline full of them would otherwise retry it once per node — each
/// attempt reopening the packs and refilling every vector above. The FxPlug side throttles the
/// same retry with the same interval, for the same reason.
constexpr double kEngineRetrySeconds = 3.0;
std::chrono::steady_clock::time_point gLastInitialization;
bool gEverInitialized = false;
/// Why the engine is not ready, verbatim from the bridge — the licence being inactive, or the
/// stock pack refusing to load. Empty once it is. The menus, the status line and the first render
/// all repeat it, because a plugin that says "no stocks installed" when the truth is "not
/// activated" sends the user to reinstall something that is not broken.
std::string gInitializationError;
/// The Resources directory beside the plugin, found once at load so a later retry can find it.
std::string gResourcesPath;
std::vector<std::string> gStockLabels, gStockIDs;
std::vector<std::string> gFormatLabels, gFormatIDs;
std::vector<std::string> gPaperLabels, gPaperIDs;
std::vector<std::string> gStageLabels, gStageIDs;
/// Selectable texture stages and their bridge-provided feature-mask bits.
std::vector<std::string> gTextureLabels, gTextureIDs, gTextureParams;
std::vector<int32_t> gTextureMasks;
/// What can be screwed onto the front of the lens, and how the exposure was set behind it. The
/// filter and diffusion menus carry a "None" the plugin owns at index 0, so a menu index is one
/// past its entry in these lists; the metering and negative-viewing menus do not.
///
/// Only the two catalogue menus keep their ids. A filter drawer and a diffusion range gain
/// entries, so what those two menus persist has to be a name rather than a position; metering and
/// negative viewing are engine enumerations whose order is the engine's ABI, and an index into one
/// of them means the same thing in every build that has it.
std::vector<std::string> gLensFilterLabels, gLensFilterIDs;
std::vector<std::string> gMeteringLabels;
std::vector<std::string> gDiffusionLabels, gDiffusionIDs;
std::vector<std::string> gDiffusionGradeLabels;
std::vector<std::string> gNegativeViewingLabels;

/// How many entries each menu actually carried when the host described it, or -1 before it did.
///
/// A menu is fixed the moment `describeInContext` returns: the host builds the panel from it and
/// nothing this side can rewrite it. If the engine was refused at load and only came up on the
/// retry in `createInstance`, the lists above are full while the described menus still hold the
/// one-entry placeholder — so an index resolved out of a persisted id can name an entry the menu
/// does not have, and a texture toggle can be missing from the panel entirely. Everything that
/// writes a menu index or reads a texture toggle has to know which of the two it is looking at.
int gDescribedStages = -1, gDescribedStocks = -1, gDescribedFormats = -1, gDescribedPapers = -1;
int gDescribedLensFilters = -1, gDescribedDiffusions = -1;

void report(const char *format, ...) __attribute__((format(printf, 1, 2)));
void initializeEngine();

/// Where a frame's time went, printed every `kProfileFrames` frames when FOTUFILM_PROFILE is set
/// in the environment. Off by default and reading one atomic when off: the point of it is to be
/// available on a machine that has the host, the media and the timeline that are actually slow,
/// rather than only on a bench that approximates them.
namespace Profile {

constexpr int kProfileFrames = 24;

using Clock = std::chrono::steady_clock;

bool enabled() {
    static const bool on = [] {
        const char *value = std::getenv("FOTUFILM_PROFILE");
        return value && value[0] && std::strcmp(value, "0") != 0;
    }();
    return on;
}

Clock::time_point now() {
    return enabled() ? Clock::now() : Clock::time_point{};
}

std::mutex gProfileLock;
double gSetupMs = 0, gDecodeMs = 0, gQueryMs = 0, gEngineMs = 0, gEncodeMs = 0;
int gFrames = 0;

void frame(Clock::time_point began, Clock::time_point decodeBegan,
           Clock::time_point decodeEnded,
           Clock::time_point engineBegan, Clock::time_point engineEnded,
           Clock::time_point ended, int width, int height, bool staged, bool viewer) {
    if (!enabled()) return;
    const auto ms = [](Clock::time_point from, Clock::time_point to) {
        return std::chrono::duration<double, std::milli>(to - from).count();
    };
    std::lock_guard<std::mutex> held(gProfileLock);
    gSetupMs += ms(began, decodeBegan);
    gDecodeMs += ms(decodeBegan, decodeEnded);
    gQueryMs += ms(decodeEnded, engineBegan);
    gEngineMs += ms(engineBegan, engineEnded);
    // Everything after the engine returned: writing the developed frame back to the host, and
    // for a streamed frame nothing at all, the encode having happened inside the engine call.
    gEncodeMs += ms(engineEnded, ended);
    if (++gFrames < kProfileFrames) return;
    const double total = gSetupMs + gDecodeMs + gQueryMs + gEngineMs + gEncodeMs;
    report("%d frames of %dx%d (%s, %s): %.1f ms each — decode %.1f (%.0f%%), "
           "setup %.1f (%.0f%%), query %.1f (%.0f%%), engine %.1f (%.0f%%), "
           "encode %.1f (%.0f%%)",
           gFrames, width, height, staged ? "staged" : "striped",
           viewer ? "viewer" : "delivered", total / gFrames, gDecodeMs / gFrames,
           100 * gDecodeMs / total, gSetupMs / gFrames, 100 * gSetupMs / total,
           gQueryMs / gFrames, 100 * gQueryMs / total,
           gEngineMs / gFrames, 100 * gEngineMs / total,
           gEncodeMs / gFrames, 100 * gEncodeMs / total);
    gSetupMs = gDecodeMs = gQueryMs = gEngineMs = gEncodeMs = 0;
    gFrames = 0;
}

}  // namespace Profile

/// Named `report` rather than `log`, which would shadow the C library's. Declared above the
/// profiler, which reports before this definition is reached.
void report(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    std::fprintf(stderr, "[Fotufilm] ");
    std::vfprintf(stderr, format, arguments);
    std::fprintf(stderr, "\n");
    va_end(arguments);
}

/// Tells the user, not just the terminal: stderr always, and the host's own message surface when
/// it offers one. `effect` may be null when nothing more specific is at hand.
void post(const char *type, OfxImageEffectHandle effect, const char *format, ...)
    __attribute__((format(printf, 3, 4)));
void post(const char *type, OfxImageEffectHandle effect, const char *format, ...) {
    char message[1024];
    va_list arguments;
    va_start(arguments, format);
    std::vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);
    report("%s", message);
    if (gMessage && gMessage->message) {
        gMessage->message(effect, type, "fotufilm", "%s", message);
    }
}

/// OFX Raw is a data sentinel, not a transfer function or set of primaries. Resolve uses it for
/// ordinary colour clips when project colour management is inactive, so route it through a
/// documented compatibility path instead of presenting it as an unsupported encoding.
bool isRawColourspace(const char *name) {
    return name && (std::strcmp(name, kOfxColourspaceRaw) == 0 ||
                    std::strcmp(name, kOfxColourspaceOfxRaw) == 0);
}

/// Resolve reports its unmanaged YRGB node graph as the config's named `Raw` space, including
/// after a CST has put the image into DaVinci Wide Gamut / Intermediate. That graph carries no
/// colour metadata for OFX to read, so Auto follows the scene-referred working-space convention
/// used by this effect. The generic OFX raw sentinel keeps the legacy Rec.709 fallback.
fotufilm::Encoding rawFallback(const char *name) {
    return name && std::strcmp(name, kOfxColourspaceRaw) == 0
        ? fotufilm::Encoding::DaVinciIntermediate
        : fotufilm::Encoding::Rec709Gamma24;
}

/// Resolve gives status labels half the inspector width. Keep the one long working-space name
/// readable there; the menu and its tooltip retain the full public label.
const char *compactEncodingLabel(fotufilm::Encoding encoding) {
    return encoding == fotufilm::Encoding::DaVinciIntermediate
        ? "DWG / Intermediate"
        : fotufilm::encodingLabel(encoding);
}

/// The OFX parameter behind each slot of the bridge's block, or null where the slot is composed
/// rather than read from one parameter: the span is resolved through its persisted id, and the
/// texture selection is an OR of several booleans.
const char *const kParameterNames[FOTUFILM_BRIDGE_PARAMETER_COUNT] = {
    "exposure", "temperature", "tint", "highlights", "shadows",
    "saturation", "vibrance", "grain", "halation", "couplers",
    "printCorrection", "localTone", "push", "bleachBypass", "expired",
    "printLight", nullptr, nullptr, "flare", "estimatedHalation",
    "halationColour", "lensFilter1", "lensFilter2", "lensFilter3",
    "metering", "diffusion", "diffusionGrade", "focalLength",
    "negativeViewing",
};

/// The Lens group's slots that a choice parameter fills, and how the menu's index becomes the
/// number the bridge wants.
///
/// The bridge asks for "engine index plus one, zero meaning off" from the filter, diffusion,
/// metering and negative-viewing slots, so that a slot an older project never filled is that
/// lever's off position. Two of those menus already carry the offset in their entries: the filter
/// and diffusion menus open with a "None" this side owns, so their menu index *is* the offset
/// number, and only the two whose entries come straight out of an engine enum need the one added.
/// The grade is the one bare index here, gated by its family being chosen rather than by a zero
/// of its own, so it is read as it stands.
bool isOffsetChoice(int slot) {
    return slot == FOTUFILM_BRIDGE_LENS_METERING ||
           slot == FOTUFILM_BRIDGE_NEGATIVE_VIEWING;
}

/// What each viewing-illuminant choice hands the bridge, in menu order. Zero means the selected
/// medium's own reference: D50 for reflection paper and calibrated 5400 K xenon for projection.
/// D65 is appended so the three indices shipped by older versions are not renumbered.
const float kPrintLightKelvin[] = {0.0f, 5003.0f, 2856.0f, 6504.0f};

constexpr const char *kStageParam = "stage";
constexpr const char *kStockParam = "stock";
constexpr const char *kFormatParam = "format";
constexpr const char *kPaperParam = "paper";
constexpr const char *kColorSpaceParam = "colorSpace";
constexpr const char *kSeedParam = "seed";
/// The three filter threads and the diffusion filter, which are the menus in the Lens group whose
/// entries come out of an engine catalogue and therefore need a durable identity beside them.
constexpr const char *kLensFilterParams[3] = {"lensFilter1", "lensFilter2", "lensFilter3"};
constexpr const char *kDiffusionParam = "diffusion";
constexpr const char *kNegativeViewingParam = "negativeViewing";

struct Instance;
void readParameters(Instance *instance, OfxTime time,
                    float parameters[FOTUFILM_BRIDGE_PARAMETER_COUNT]);

/// The bridge's bit for the grain stage, or 0 if this build has no such stage — in which case
/// nothing in the texture span is seeded by the frame.
int32_t textureGrainMask() {
    for (size_t i = 0; i < gTextureIDs.size() && i < gTextureMasks.size(); ++i) {
        if (gTextureIDs[i] == "grain") return gTextureMasks[i];
    }
    return 0;
}

/// Hidden stable IDs for menu choices. Persisted menu indices can change when packs are updated,
/// so rendering resolves the ID first and keeps the menu index synchronized.
constexpr const char *kStageIDParam = "stageID";
constexpr const char *kStockIDParam = "stockID";
constexpr const char *kFormatIDParam = "formatID";
constexpr const char *kPaperIDParam = "paperID";
/// The filter catalogue is the one menu here that will certainly grow — it is a drawer, and a
/// drawer gains filters. An entry inserted anywhere but the end renumbers everything after it, so
/// the id beside each thread is what a project actually keeps.
constexpr const char *kLensFilterIDParams[3] = {"lensFilter1ID", "lensFilter2ID", "lensFilter3ID"};
constexpr const char *kDiffusionIDParam = "diffusionID";

/// The id of the appended "Match Film" gauge entry, which is the plugin's, not the bridge's.
constexpr const char *kMatchFilmFormatID = "match-film";
constexpr const char *kMatchFilmPaperID = "match-film-output";

/// The colour space menu persists by index, so its order is an ABI. The frozen layout: the
/// seven spaces the plugin shipped with at their original indices, "Auto (from host)" at 7 —
/// the index every saved project holds for it — and any space added since appended after
/// Auto. `menuEncoding` is the one mapping from a menu index to its encoding.
constexpr int kColorSpaceAuto = 7;

fotufilm::Encoding menuEncoding(int choice) {
    if (choice >= 0 && choice < kColorSpaceAuto) {
        return static_cast<fotufilm::Encoding>(choice);
    }
    const int appended = choice - kColorSpaceAuto - 1;
    if (appended >= 0 &&
        kColorSpaceAuto + appended < static_cast<int>(fotufilm::Encoding::Count)) {
        return static_cast<fotufilm::Encoding>(kColorSpaceAuto + appended);
    }
    return fotufilm::Encoding::Count;
}

/// The read-only line under the colour space menu that says what the plugin is actually doing.
constexpr const char *kColorSpaceStatusParam = "colorSpaceStatus";

/// The read-only line under the span menu saying what this node is reading and writing. Derived
/// state, refreshed like the colour-space line and persisted like it: not at all.
constexpr const char *kStageStatusParam = "stageStatus";

/// Everything an instance needs at render time, resolved once at creation.
struct Instance {
    FotufilmBridgeContext bridge = nullptr;
    OfxImageClipHandle sourceClip = nullptr;
    OfxImageClipHandle outputClip = nullptr;
    OfxParamHandle parameters[FOTUFILM_BRIDGE_PARAMETER_COUNT] = {};
    OfxParamHandle stage = nullptr;
    OfxParamHandle stageID = nullptr;
    /// One boolean per selectable spatial stage, parallel to `gTextureMasks`.
    std::vector<OfxParamHandle> textureStages;
    OfxParamHandle stock = nullptr;
    OfxParamHandle format = nullptr;
    OfxParamHandle paper = nullptr;
    OfxParamHandle colorSpace = nullptr;
    OfxParamHandle seed = nullptr;
    OfxParamHandle stockID = nullptr;
    OfxParamHandle formatID = nullptr;
    OfxParamHandle paperID = nullptr;
    /// The Lens group's catalogue menus and the identities beside them.
    OfxParamHandle lensFilters[3] = {};
    OfxParamHandle lensFilterIDs[3] = {};
    OfxParamHandle diffusion = nullptr;
    OfxParamHandle diffusionID = nullptr;
    OfxParamHandle colorSpaceStatus = nullptr;
    OfxParamHandle stageStatus = nullptr;

    /// The decoded input, reused between frames. Only a frame the engine will not stage — one too
    /// large to develop in a single pass — is decoded into here; the rest go straight into the
    /// engine's own GPU-resident staging and this stays empty.
    std::vector<float> frame;
    /// One band of the host's rows, straightened into the layout the decode kernel reads, and
    /// reused between frames for the same reason `frame` is. Only a frame with no staging to
    /// decode into fills this; a staged frame's scratch is the staging's own output buffer.
    std::vector<float> decodeScratch;
    /// A pre-1.5 host supplied no colour tag and took the compatibility fallback already; say it
    /// once per instance, not per frame.
    bool warnedLegacyFallback = false;
    /// The input has already been caught exceeding 1.0 under a display-referred label.
    bool warnedOverRange = false;
    /// A decoder has supplied NaN/inf and the repaired frame has already been reported.
    bool warnedNonFiniteInput = false;
    /// The first frame said which path its pixels took; the rest keep quiet.
    bool reportedFramePath = false;
    /// Likewise for which side of the boundary decoded them.
    bool reportedDecodePath = false;
    /// The render-status combination the host last announced, packed, or -1 before the first
    /// frame. Each new combination is reported once: which of these the host actually sets is
    /// the whole basis for developing a viewer frame differently from a delivered one, and
    /// otherwise nothing outside this plugin can see what the host said.
    int lastRenderStatus = -1;
    /// The host has opened a sequence render on this instance and not yet closed it, and the
    /// frame range it announced when it did. Diagnostic only, and deliberately not an input to
    /// any decision: measured against Resolve Studio 21, the bracket opens around a single viewer
    /// frame as readily as around a delivery, and the announced range is one frame in both cases
    /// (see the README). They are printed with the render-status line so that a host which does
    /// say something is on record, and nothing more.
    bool inSequenceRender = false;
    double sequenceRange[2] = {0, 0};
    /// The engine was not ready and this instance has already said so through the host; the
    /// frames after the first keep the failure to stderr.
    bool postedEngineError = false;
    /// The host handed over an unusable image and this instance has already said so through the
    /// host. Cleared the moment a fetch succeeds, so a clip that is fixed and broken again warns
    /// once more; kept otherwise, because a misconfigured thousand-frame delivery must not raise
    /// a thousand dialogs.
    bool postedFetchError = false;
    /// Said once for the same reason `postedEngineError` is.
    bool postedTextureRestart = false;
    /// What `reconcile` found beyond the end of a menu the host described: this project's choice
    /// is installed and will render, but the menu cannot be made to show it until a restart.
    /// Empty when every choice is inside its menu. Appended to the status line.
    std::string staleMenuNote;
    /// The device refused to decode a frame and the host's threads took over; said once.
    bool warnedHostDecodeFallback = false;

    /// Serialises this instance's render against a purge of it. The plugin declares
    /// `kOfxImageEffectRenderInstanceSafe`, which keeps two renders of the *same* instance from
    /// overlapping — but `kOfxActionPurgeCaches` carries no such promise, and a purge frees the
    /// decoded frame, the decode band and the engine's borrowed staging while a render in flight
    /// is holding raw pointers into all three. So the render holds this for its whole body and a
    /// purge takes it before freeing anything: a purge arriving mid-frame waits for the frame,
    /// which costs that purge a few milliseconds and costs the render nothing. Per instance, so
    /// two nodes still develop simultaneously.
    std::mutex renderLock;
};

Instance *instanceOf(OfxImageEffectHandle effect) {
    OfxPropertySetHandle properties = nullptr;
    if (gEffect->getPropertySet(effect, &properties) != kOfxStatOK) return nullptr;
    void *data = nullptr;
    gProperty->propGetPointer(properties, kOfxPropInstanceData, 0, &data);
    return static_cast<Instance *>(data);
}

/// Whether this node's panel is missing the per-stage texture toggles the engine offers.
///
/// The panel was built before the engine came up, so `describeInContext` had no stage to name and
/// defined no toggle: the texture selection then reads back as zero, which is indistinguishable
/// from the user having selected none — and none is the one selection that *is* the identity. So
/// the render and `isIdentity` have to be able to tell the two apart.
///
/// Asked here rather than recorded at creation, because the engine can come up between the two.
/// A node created while the engine was still refused holds no handles *and* saw an empty stage
/// list, so a comparison made then finds nothing wrong; the retry on a later node then fills the
/// list and leaves the first node reading a selection of zero from a panel that has no controls.
/// The lists are what they are at the moment the question is asked.
bool textureStagesMissing(const Instance *instance) {
    if (gTextureParams.empty()) return false;
    for (OfxParamHandle toggle : instance->textureStages) {
        if (toggle) return false;
    }
    return true;
}

/// The texture span's selection as of `time`: the OR of the per-stage booleans, each carrying the
/// bit the bridge handed out for its stage. The one thing `isIdentity` and the frame-varying
/// declaration need out of the parameter block, and cheap enough to ask for on its own.
int32_t textureSelection(Instance *instance, OfxTime time) {
    int32_t mask = 0;
    for (size_t i = 0; i < instance->textureStages.size() && i < gTextureMasks.size(); ++i) {
        if (!instance->textureStages[i]) continue;
        int selected = 0;
        gParameter->paramGetValueAtTime(instance->textureStages[i], time, &selected);
        if (selected) mask |= gTextureMasks[i];
    }
    return mask;
}

/// Reads a name out of the bridge, which writes into a caller buffer rather than handing back a
/// pointer it would then have to own.
std::string bridgeString(int32_t (*read)(int32_t, char *, int32_t), int32_t index) {
    char buffer[256];
    const int32_t length = read(index, buffer, static_cast<int32_t>(sizeof(buffer)));
    return length < 0 ? std::string() : std::string(buffer, static_cast<size_t>(length));
}

OfxStatus load() {
    if (gHost == nullptr) return kOfxStatErrMissingHostFeature;
    gEffect = static_cast<const OfxImageEffectSuiteV1 *>(
        gHost->fetchSuite(gHost->host, kOfxImageEffectSuite, 1));
    gProperty = static_cast<const OfxPropertySuiteV1 *>(
        gHost->fetchSuite(gHost->host, kOfxPropertySuite, 1));
    gParameter = static_cast<const OfxParameterSuiteV1 *>(
        gHost->fetchSuite(gHost->host, kOfxParameterSuite, 1));
    if (!gEffect || !gProperty || !gParameter) return kOfxStatErrMissingHostFeature;
    gMessage = static_cast<const OfxMessageSuiteV1 *>(
        gHost->fetchSuite(gHost->host, kOfxMessageSuite, 1));
    gThread = static_cast<const OfxMultiThreadSuiteV1 *>(
        gHost->fetchSuite(gHost->host, kOfxMultiThreadSuite, 1));

    Dl_info info;
    gResourcesPath.clear();
    if (dladdr(reinterpret_cast<const void *>(&load), &info) != 0 && info.dli_fname) {
        std::string path(info.dli_fname);
        for (int i = 0; i < 2; ++i) {
            const size_t slash = path.find_last_of('/');
            if (slash == std::string::npos) break;
            path.resize(slash);
        }
        gResourcesPath = path + "/Resources";
    }
    initializeEngine();
    return kOfxStatOK;
}

/// Opens the sealed packs and copies every menu the panel is built from out of the bridge. The
/// expensive half of coming up, and the half that must not be repeated under a running host: each
/// of these vectors is read by `isIdentity`, `getClipPreferences` and `reconcile` on the host's
/// own threads, and clearing one to refill it with the same contents is a race for no gain.
void openBridgeAndReadMenus() {
    gStockLabels.clear();
    gStockIDs.clear();
    gFormatLabels.clear();
    gFormatIDs.clear();
    gPaperLabels.clear();
    gPaperIDs.clear();
    gStageLabels.clear();
    gStageIDs.clear();
    gTextureLabels.clear();
    gTextureIDs.clear();
    gTextureParams.clear();
    gTextureMasks.clear();
    gLensFilterLabels.clear();
    gLensFilterIDs.clear();
    gMeteringLabels.clear();
    gDiffusionLabels.clear();
    gDiffusionIDs.clear();
    gDiffusionGradeLabels.clear();
    gNegativeViewingLabels.clear();
    const std::string &resources = gResourcesPath;

    const int32_t stocks = fotufilm_bridge_initialize(
        resources.empty() ? nullptr : resources.c_str());
    gInitializationError.clear();
    if (stocks >= 0) gBridgeInitialized = true;
    if (stocks < 0) {
        char message[512] = "";
        fotufilm_bridge_last_error(nullptr, message, sizeof(message));
        gInitializationError = message[0] ? message : "the engine could not initialise";
        report("could not initialise the engine from %s: %s",
             resources.c_str(), gInitializationError.c_str());
    }
    for (int32_t i = 0; i < fotufilm_bridge_stock_count(); ++i) {
        gStockLabels.push_back(bridgeString(fotufilm_bridge_stock_name, i));
        gStockIDs.push_back(bridgeString(fotufilm_bridge_stock_id, i));
    }
    for (int32_t i = 0; i < fotufilm_bridge_format_count(); ++i) {
        gFormatLabels.push_back(bridgeString(fotufilm_bridge_format_name, i));
        gFormatIDs.push_back(bridgeString(fotufilm_bridge_format_id, i));
    }
    // The menu appends Match Film after the bridge's gauges; the id list has to agree with the
    // menu, entry for entry, or the identity written for one choice names another.
    gFormatIDs.push_back(kMatchFilmFormatID);
    for (int32_t i = 0; i < fotufilm_bridge_paper_count(); ++i) {
        gPaperLabels.push_back(bridgeString(fotufilm_bridge_paper_name, i));
        gPaperIDs.push_back(bridgeString(fotufilm_bridge_paper_id, i));
    }
    // Silence should follow the stock's physical path: RA-4 for still negatives, the native
    // release print for motion negatives, and the direct positive for reversal film.
    gPaperLabels.push_back("Match Film");
    gPaperIDs.push_back(kMatchFilmPaperID);
    for (int32_t i = 0; i < fotufilm_bridge_stage_count(); ++i) {
        gStageLabels.push_back(bridgeString(fotufilm_bridge_stage_name, i));
        gStageIDs.push_back(bridgeString(fotufilm_bridge_stage_id, i));
    }
    for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
        gTextureLabels.push_back(bridgeString(fotufilm_bridge_texture_stage_name, i));
        gTextureIDs.push_back(bridgeString(fotufilm_bridge_texture_stage_id, i));
        gTextureMasks.push_back(fotufilm_bridge_texture_stage_mask(i));
        // An OFX parameter name is an identifier and the engine's ids are hyphenated, so the
        // name is derived rather than shared. It is the name a project file keeps, so the
        // derivation is fixed: prefix, then the id with each hyphen as an underscore.
        std::string name = "texture_" + gTextureIDs.back();
        for (char &c : name) { if (c == '-') c = '_'; }
        gTextureParams.push_back(name);
    }
    // The lens. The two menus that open with a "None" this side owns get that entry pushed on
    // the front of both their label and id lists, so a menu index and a list index are the same
    // number and the identity written for one choice cannot name another.
    gLensFilterLabels.push_back("None");
    gLensFilterIDs.push_back(FOTUFILM_BRIDGE_NO_FILTER_ID);
    for (int32_t i = 0; i < fotufilm_bridge_lens_filter_count(); ++i) {
        gLensFilterLabels.push_back(bridgeString(fotufilm_bridge_lens_filter_name, i));
        gLensFilterIDs.push_back(bridgeString(fotufilm_bridge_lens_filter_id, i));
    }
    for (int32_t i = 0; i < fotufilm_bridge_metering_count(); ++i) {
        gMeteringLabels.push_back(bridgeString(fotufilm_bridge_metering_name, i));
    }
    gDiffusionLabels.push_back("None");
    gDiffusionIDs.push_back(FOTUFILM_BRIDGE_NO_FILTER_ID);
    for (int32_t i = 0; i < fotufilm_bridge_diffusion_family_count(); ++i) {
        gDiffusionLabels.push_back(bridgeString(fotufilm_bridge_diffusion_family_name, i));
        gDiffusionIDs.push_back(bridgeString(fotufilm_bridge_diffusion_family_id, i));
    }
    for (int32_t i = 0; i < fotufilm_bridge_diffusion_grade_count(); ++i) {
        gDiffusionGradeLabels.push_back(bridgeString(fotufilm_bridge_diffusion_grade_name, i));
    }
    for (int32_t i = 0; i < fotufilm_bridge_negative_viewing_count(); ++i) {
        gNegativeViewingLabels.push_back(bridgeString(fotufilm_bridge_negative_viewing_name, i));
    }
}

/// Points the bridge at the plugin's resources and reads the menus out of it. Called at load,
/// and again by `createInstance` while the engine is not ready: the one failure a user can fix
/// without restarting the host is an inactive licence, and activating the app then adding a node
/// should render rather than wait for a relaunch. The menus a host has already described cannot
/// be rewritten by then — that part heals on restart, and the README says so.
///
/// A retry after the bridge has come up opens nothing and rebuilds nothing. It re-reads whether
/// the engine is usable, which is the only part of the answer that can have changed.
void initializeEngine() {
    gLastInitialization = std::chrono::steady_clock::now();
    gEverInitialized = true;
    gEngineReady = false;
    // Only the first time, or after a failure that left nothing open. Everything below this is a
    // fresh reading of state the bridge already holds, which is all a retry can usefully do.
    if (!gBridgeInitialized) openBridgeAndReadMenus();
    const std::string &resources = gResourcesPath;

    if (fotufilm_bridge_available() == 0) {
        // The licence, or the pack, said something more specific already. Keep it: "no Metal
        // device" sends a user who has not activated the app off to look at their hardware.
        if (gInitializationError.empty()) {
            gInitializationError = "no Metal device the Halide engine can use";
        }
        report("%s; renders will fail", gInitializationError.c_str());
    } else if (gStockLabels.empty()) {
        if (gInitializationError.empty()) {
            gInitializationError = "no film stocks found in " + resources;
        }
        report("%s", gInitializationError.c_str());
    } else {
        gEngineReady = true;
        gInitializationError.clear();
        report("ready, %zu stock(s) from %s (%s rendering)", gStockLabels.size(),
               resources.c_str(),
               fotufilm_bridge_realtime_enabled() ? "realtime" : "reference");
    }
}

OfxStatus unload() {
    gStockLabels.clear();
    gStockIDs.clear();
    gFormatLabels.clear();
    gFormatIDs.clear();
    gPaperLabels.clear();
    gPaperIDs.clear();
    gStageLabels.clear();
    gStageIDs.clear();
    gTextureLabels.clear();
    gTextureIDs.clear();
    gTextureParams.clear();
    gTextureMasks.clear();
    gLensFilterLabels.clear();
    gLensFilterIDs.clear();
    gMeteringLabels.clear();
    gDiffusionLabels.clear();
    gDiffusionIDs.clear();
    gDiffusionGradeLabels.clear();
    gNegativeViewingLabels.clear();
    gDescribedStages = gDescribedStocks = gDescribedFormats = gDescribedPapers = -1;
    gDescribedLensFilters = gDescribedDiffusions = -1;
    gEngineReady = false;
    // The vectors above are empty again, so the next load has to rebuild them, and the retry
    // clock starts over with it: an unload is the host putting the plugin down, not a node
    // failing to come up.
    gBridgeInitialized = false;
    gEverInitialized = false;
    gInitializationError.clear();
    gMessage = nullptr;
    gThread = nullptr;
    gCPUs = 0;
    return kOfxStatOK;
}

OfxStatus describe(OfxImageEffectHandle effect) {
    OfxPropertySetHandle properties = nullptr;
    if (gEffect->getPropertySet(effect, &properties) != kOfxStatOK) {
        return kOfxStatErrBadHandle;
    }
    gProperty->propSetString(properties, kOfxPropLabel, 0, "Fotufilm");
    gProperty->propSetString(properties, kOfxPropShortLabel, 0, "Fotufilm");
    gProperty->propSetString(properties, kOfxPropLongLabel, 0,
                             "Fotufilm — spectral film simulation");
    gProperty->propSetString(properties, kOfxPropPluginDescription, 0,
                             "A spectral film simulation: measured stocks, characteristic "
                             "curves, DIR couplers, grain, halation, and a print stage.\n\n"
                             "Colour: the model is scene-referred and works in linear "
                             "Rec.2020 — mid-grey at 0.18, specular highlights above 1.0. Set "
                             "Timeline Color Space to what the node is handed (or leave it on "
                             "Auto where the host tags clips). A display-referred timeline "
                             "(Rec.709, sRGB) clips at diffuse white, which leaves halation "
                             "nothing bright to scatter; a wide-gamut log or linear timeline "
                             "gives the film the range it was built for.");
    gProperty->propSetString(properties, kOfxImageEffectPluginPropGrouping, 0,
                             "Fotufilm");
    gProperty->propSetString(properties, kOfxImageEffectPropSupportedContexts, 0,
                             kOfxImageEffectContextFilter);
    gProperty->propSetString(properties, kOfxImageEffectPropSupportedContexts, 1,
                             kOfxImageEffectContextGeneral);
    gProperty->propSetString(properties, kOfxImageEffectPropSupportedPixelDepths, 0,
                             kOfxBitDepthFloat);

    gProperty->propSetInt(properties, kOfxImageEffectPropSupportsTiles, 0, 0);
    gProperty->propSetInt(properties, kOfxImageEffectPropSupportsMultiResolution, 0, 0);
    gProperty->propSetInt(properties, kOfxImageEffectPropTemporalClipAccess, 0, 0);
    gProperty->propSetInt(properties, kOfxImageEffectPluginPropSingleInstance, 0, 0);
    gProperty->propSetString(properties, kOfxImageEffectPluginRenderThreadSafety, 0,
                             kOfxImageEffectRenderInstanceSafe);
    // The clip preferences below depend on the span: a Print Only node asks for its input as
    // data and declares its output as data. Without this a host is entitled to ask once and
    // cache the answer, and a node moved from Full to Print Only would keep receiving colour.
    // Both the menu and the persisted id are named, since the span is resolved through the id.
    //
    // The frame-varying declaration moves with them too, and in Texture Only it is the texture
    // toggles that decide it: a selection that carries grain is seeded by the frame number, one
    // that does not is the same picture every time. The property is multi-valued, so each toggle
    // is appended after the two span parameters — a host told only about the span would keep the
    // first answer and freeze the grain field the moment a toggle moved.
    gProperty->propSetString(properties, kOfxImageEffectPropClipPreferencesSlaveParam, 0,
                             kStageParam);
    gProperty->propSetString(properties, kOfxImageEffectPropClipPreferencesSlaveParam, 1,
                             kStageIDParam);
    for (size_t i = 0; i < gTextureParams.size(); ++i) {
        gProperty->propSetString(properties, kOfxImageEffectPropClipPreferencesSlaveParam,
                                 static_cast<int>(2 + i), gTextureParams[i].c_str());
    }
    // OFX 1.5 colour management. Resolve exposes its timeline conversion in Full native mode;
    // ask for that mode, then request the exact linear Rec.2020 space the engine wants below.
    // The render still checks the selected tag instead of assuming the request was honoured.
    // The config declaration is mandatory on both sides of a native negotiation.
    gProperty->propSetString(properties, kOfxImageEffectPropColourManagementStyle, 0,
                             kOfxImageEffectColourManagementFull);
    gProperty->propSetString(properties,
                             kOfxImageEffectPropColourManagementAvailableConfigs, 0,
                             kOfxConfigIdentifier);
    return kOfxStatOK;
}

/// Defines one parameter and returns its property set, already labelled.
OfxPropertySetHandle define(OfxParamSetHandle set, const char *type,
                            const char *name, const char *label,
                            const char *hint, const char *parent) {
    OfxPropertySetHandle properties = nullptr;
    if (gParameter->paramDefine(set, type, name, &properties) != kOfxStatOK) {
        return nullptr;
    }
    gProperty->propSetString(properties, kOfxPropLabel, 0, label);
    if (hint) gProperty->propSetString(properties, kOfxParamPropHint, 0, hint);
    if (parent) gProperty->propSetString(properties, kOfxParamPropParent, 0, parent);
    return properties;
}

OfxPropertySetHandle defineDouble(OfxParamSetHandle set, const char *name,
                                  const char *label, const char *hint,
                                  const char *parent, double minimum,
                                  double maximum, double value) {
    OfxPropertySetHandle properties =
        define(set, kOfxParamTypeDouble, name, label, hint, parent);
    if (!properties) return nullptr;
    gProperty->propSetString(properties, kOfxParamPropDoubleType, 0,
                             kOfxParamDoubleTypeScale);
    gProperty->propSetDouble(properties, kOfxParamPropMin, 0, minimum);
    gProperty->propSetDouble(properties, kOfxParamPropMax, 0, maximum);
    gProperty->propSetDouble(properties, kOfxParamPropDisplayMin, 0, minimum);
    gProperty->propSetDouble(properties, kOfxParamPropDisplayMax, 0, maximum);
    gProperty->propSetDouble(properties, kOfxParamPropDefault, 0, value);
    return properties;
}

void defineChoice(OfxParamSetHandle set, const char *name, const char *label,
                  const char *hint, const char *parent,
                  const std::vector<std::string> &options, int value) {
    OfxPropertySetHandle properties =
        define(set, kOfxParamTypeChoice, name, label, hint, parent);
    if (!properties) return;
    for (size_t i = 0; i < options.size(); ++i) {
        gProperty->propSetString(properties, kOfxParamPropChoiceOption,
                                 static_cast<int>(i), options[i].c_str());
    }
    gProperty->propSetInt(properties, kOfxParamPropDefault, 0, value);
    gProperty->propSetInt(properties, kOfxParamPropAnimates, 0, 0);
}

void defineGroup(OfxParamSetHandle set, const char *name, const char *label) {
    define(set, kOfxParamTypeGroup, name, label, nullptr, nullptr);
}

/// A parameter the user never sees but the project file keeps.
void defineHiddenString(OfxParamSetHandle set, const char *name) {
    OfxPropertySetHandle properties =
        define(set, kOfxParamTypeString, name, name, nullptr, nullptr);
    if (!properties) return;
    gProperty->propSetString(properties, kOfxParamPropDefault, 0, "");
    gProperty->propSetInt(properties, kOfxParamPropSecret, 0, 1);
    gProperty->propSetInt(properties, kOfxParamPropAnimates, 0, 0);
}

/// A read-only line of text in the panel. Not persisted: its content is derived state, and a
/// saved copy would just go stale.
void defineLabel(OfxParamSetHandle set, const char *name, const char *label,
                 const char *parent, const char *text, const char *hint = nullptr) {
    OfxPropertySetHandle properties =
        define(set, kOfxParamTypeString, name, label, hint, parent);
    if (!properties) return;
    gProperty->propSetString(properties, kOfxParamPropStringMode, 0,
                             kOfxParamStringIsLabel);
    gProperty->propSetString(properties, kOfxParamPropDefault, 0, text);
    gProperty->propSetInt(properties, kOfxParamPropPersistant, 0, 0);
    gProperty->propSetInt(properties, kOfxParamPropAnimates, 0, 0);
}

OfxStatus describeInContext(OfxImageEffectHandle effect) {
    OfxPropertySetHandle clip = nullptr;
    gEffect->clipDefine(effect, kOfxImageEffectSimpleSourceClipName, &clip);
    gProperty->propSetString(clip, kOfxImageEffectPropSupportedComponents, 0,
                             kOfxImageComponentRGBA);
    gProperty->propSetInt(clip, kOfxImageEffectPropSupportsTiles, 0, 0);

    gEffect->clipDefine(effect, kOfxImageEffectOutputClipName, &clip);
    gProperty->propSetString(clip, kOfxImageEffectPropSupportedComponents, 0,
                             kOfxImageComponentRGBA);
    gProperty->propSetInt(clip, kOfxImageEffectPropSupportsTiles, 0, 0);

    OfxParamSetHandle set = nullptr;
    if (gEffect->getParamSet(effect, &set) != kOfxStatOK) return kOfxStatErrBadHandle;

    // The frozen menu layout `menuEncoding` decodes: original spaces, Auto at its shipped
    // index, spaces added since appended after it.
    std::vector<std::string> spaces;
    for (int i = 0; i < kColorSpaceAuto; ++i) {
        spaces.push_back(fotufilm::encodingLabel(static_cast<fotufilm::Encoding>(i)));
    }
    spaces.push_back("Auto (from host)");
    for (int i = kColorSpaceAuto; i < static_cast<int>(fotufilm::Encoding::Count); ++i) {
        spaces.push_back(fotufilm::encodingLabel(static_cast<fotufilm::Encoding>(i)));
    }
    std::vector<std::string> stocks = gStockLabels;
    // The placeholder is the reason, not a guess at it: an inactive licence reads as "not
    // activated", a broken pack as the pack's own error, and only a genuinely empty pack as
    // "no stocks installed". The menu is fixed once described, so it heals on restart; the
    // status line and the first render carry the same text until then.
    if (stocks.empty()) {
        stocks.push_back(gInitializationError.empty() ? "No stocks installed"
                                                      : gInitializationError);
    }

    defineGroup(set, "stageGroup", "Pipeline");
    std::vector<std::string> spans = gStageLabels;
    if (spans.empty()) spans.push_back("Full");
    gDescribedStages = static_cast<int>(spans.size());
    defineChoice(set, kStageParam, "Stage",
                 "Which span of the pipeline this node performs. Full is the whole "
                 "thing and is what every other setting here describes. Negative Only "
                 "stops at the developed negative and writes its per-layer densities "
                 "— data, not a picture — and Print Only takes exactly that back and "
                 "finishes it on the selected medium, so the two in series reproduce "
                 "Full. Texture Only lays "
                 "the film's spatial character over the frame it is handed and leaves "
                 "its colour alone.\n\n"
                 "A Negative Only node must feed a Print Only node directly, with the "
                 "same stock and lab settings and nothing in between: the densities "
                 "are not colour and anything that grades, resamples or transforms "
                 "them is not editing a picture.",
                 "stageGroup", spans, 0);
    defineLabel(set, kStageStatusParam, " ", "stageGroup",
                "Stage: Full — scene in, finished output out");
    defineHiddenString(set, kStageIDParam);
    // Nothing here when the engine has not come up: the bridge hands out the spatial stages, and
    // a toggle cannot be invented for one whose bit is unknown. `createInstance` records that the
    // panel has none, because a texture selection that cannot be read is not a selection of none.
    for (size_t i = 0; i < gTextureParams.size(); ++i) {
        OfxPropertySetHandle selected = define(
            set, kOfxParamTypeBoolean, gTextureParams[i].c_str(),
            gTextureLabels[i].c_str(),
            "Whether Texture Only carries this stage. Ignored by every other stage, "
            "where the strength controls below select what runs.",
            "stageGroup");
        if (selected) gProperty->propSetInt(selected, kOfxParamPropDefault, 0, 1);
    }

    defineGroup(set, "filmGroup", "Film");
    gDescribedStocks = static_cast<int>(stocks.size());
    defineChoice(set, kStockParam, "Stock",
                 "The emulsion. Each is a measured stock: its own spectral "
                 "sensitivity, characteristic curves, couplers, halation and "
                 "granularity.",
                 "filmGroup", stocks, 0);
    std::vector<std::string> formats = gFormatLabels.empty()
        ? std::vector<std::string>{"35mm still"} : gFormatLabels;
    const int matchFilm = static_cast<int>(formats.size());
    formats.push_back("Match Film");
    gDescribedFormats = static_cast<int>(formats.size());
    defineChoice(set, kFormatParam, "Format",
                 "The gauge the frame is exposed on. The image height maps onto "
                 "the gauge's frame height, so a smaller format is enlarged more "
                 "and shows coarser grain, wider halation and stronger adjacency "
                 "— the same emulsion at a different magnification. Match Film "
                 "takes the gauge the chosen stock is known on.",
                 "filmGroup", formats, matchFilm);
    defineChoice(set, kColorSpaceParam, "Timeline Color Space",
                 "What this node is being handed — the one control that is not "
                 "taste. The film model is scene-referred in linear Rec.2020: "
                 "mid-grey at 0.18, specular highlights above 1.0. The input is "
                 "decoded to that and the result encoded back, so a wrong "
                 "setting shows the emulsion the wrong light and lands the "
                 "characteristic curves whole stops off. Auto reads the space "
                 "the host tags the clip with, where the host says. A "
                 "display-referred space (Rec.709, sRGB) clips at diffuse "
                 "white, leaving halation nothing bright to scatter; a "
                 "wide-gamut log or linear timeline keeps the highlights the "
                 "model was built for.",
                 "filmGroup", spaces, kColorSpaceAuto);
    defineLabel(set, kColorSpaceStatusParam, "Decoded Input", "filmGroup",
                "Not yet examined",
                "The input encoding Fotufilm will decode. Host means Resolve supplied an "
                "exact OFX colour-space tag. Assumed means Resolve supplied Raw or no tag; "
                "select Timeline Color Space explicitly if that assumption does not match "
                "the image arriving at this node.");

    defineGroup(set, "outputGroup", "Output");
    std::vector<std::string> papers = gPaperLabels.empty()
        ? std::vector<std::string>{"Match Film"} : gPaperLabels;
    const int matchPaper = static_cast<int>(papers.size()) - 1;
    gDescribedPapers = static_cast<int>(papers.size());
    defineChoice(set, kPaperParam, "Output Medium",
                 "Choose where the finished image lives. Match Film uses RA-4 paper for a still "
                 "negative, the stock's native release print for a motion negative, and the "
                 "direct positive for reversal film. Digital Reference is the HDR path; paper, "
                 "projection, Lab Scan, Telecine and Negative are SDR. Negative is available "
                 "only for negative film.",
                 "outputGroup", papers, matchPaper);
    defineChoice(set, "printLight", "Viewing Illuminant",
                 "Choose the light used to judge a physical print. Medium Reference means D50 "
                 "for photo paper or calibrated 5400 K xenon for a projected release print. "
                 "Digital Reference, Lab Scan, Telecine and Negative ignore this control.",
                 "outputGroup",
                 {"Medium Reference · Auto", "Proofing Booth · D50",
                  "Tungsten · 2856 K", "Daylight · D65"}, 0);
    defineDouble(set, "printCorrection", "Channel Contrast Match",
                 "Balances how the film's colour layers print together. The medium's own "
                 "calibration is already applied; raise this only for a more neutral crossover.",
                 "outputGroup", 0, 1, 0.05);
    std::vector<std::string> viewings = gNegativeViewingLabels.empty()
        ? std::vector<std::string>{"Light Box"} : gNegativeViewingLabels;
    defineChoice(set, kNegativeViewingParam, "Negative Viewing",
                 "How the developed negative is read, when Output Medium is Negative. "
                 "Light Box normalises on the viewing light, so the film base keeps its own "
                 "orange. Scanner normalises on the film's own D-min, so the base reads white "
                 "and what is left is only the image's inversion. Every other medium ignores "
                 "this control, having a print or a scan of its own.",
                 "outputGroup", viewings, 0);

    // The identity behind each menu above; see the comment on kStockIDParam.
    defineHiddenString(set, kStockIDParam);
    defineHiddenString(set, kFormatIDParam);
    defineHiddenString(set, kPaperIDParam);

    defineGroup(set, "exposureGroup", "Exposure");
    defineDouble(set, "exposure", "Exposure", "Camera exposure, in stops.",
                 "exposureGroup", -5, 5, 0);
    defineDouble(set, "temperature", "Temperature",
                 "The illuminant the scene was lit by, in kelvin. Adapted to the "
                 "renderer's white before the emulsion sees the light, which is "
                 "where a camera does it too.",
                 "exposureGroup", 2000, 12000, 6504);
    defineDouble(set, "tint", "Tint", "Green/magenta balance of the illuminant.",
                 "exposureGroup", -100, 100, 0);

    // The lens. Everything here sits ahead of the emulsion, in the order the light meets it: the
    // absorbing glass, then how the exposure was set behind it, then the diffusion filter and the
    // focal length its scattering is imaged through.
    defineGroup(set, "lensGroup", "Lens");
    std::vector<std::string> filters = gLensFilterLabels.empty()
        ? std::vector<std::string>{"None"} : gLensFilterLabels;
    gDescribedLensFilters = static_cast<int>(filters.size());
    const char *const kFilterLabels[3] = {"Filter 1", "Filter 2", "Filter 3"};
    const char *const kFilterHints[3] = {
        "An absorbing filter on the front of the lens. It is integrated spectrally against the "
        "chosen film's own three layer sensitivities, which is why the same filter is a "
        "different filter on a different stock — an 85B is a correction on tungsten film and a "
        "heavy warm cast on daylight film. It also adds the veiling glare of two more air-glass "
        "faces, whatever the Lens Flare slider says — and that added glare is why this control "
        "is live only on the Full stage: no kernel this build carries can measure it in a span "
        "that ends at the developed negative.",
        "A second filter, behind the first. They stack in the order given: their transmittances "
        "multiply, and the gap between them makes a ghost of its own.",
        "A third filter, behind the second.",
    };
    for (int i = 0; i < 3; ++i) {
        defineChoice(set, kLensFilterParams[i], kFilterLabels[i], kFilterHints[i],
                     "lensGroup", filters, 0);
    }
    std::vector<std::string> meterings = gMeteringLabels.empty()
        ? std::vector<std::string>{"Metered through"} : gMeteringLabels;
    // The default is the engine's: through-the-lens metering, which is entry 1 of its own list.
    const int meteredThrough = gMeteringLabels.size() > 1 ? 1 : 0;
    defineChoice(set, "metering", "Metering",
                 "How the exposure was set with those filters fitted. Metered through is the "
                 "camera's own photopic cell reading the light that got past the glass, and is "
                 "the default; it can underexpose behind a narrow filter, because the meter does "
                 "not use the film's sensitivity. Filter factor is the published compensation, "
                 "worked out against the emulsion, which restores the luminance record without "
                 "cancelling the colour change. None is a fixed manual exposure, so the light "
                 "the filter took lands on the film as underexposure. Ignored with no filter "
                 "fitted, and live only on the Full stage, which is the only span a filter is "
                 "live in.",
                 "lensGroup", meterings, meteredThrough);
    std::vector<std::string> diffusions = gDiffusionLabels.empty()
        ? std::vector<std::string>{"None"} : gDiffusionLabels;
    gDescribedDiffusions = static_cast<int>(diffusions.size());
    defineChoice(set, kDiffusionParam, "Diffusion",
                 "A diffusion filter on the front of the lens. A share of the light meets a "
                 "particle and leaves in a new direction, and the lens images it somewhere else "
                 "on the frame; the share that missed every particle is untouched, which is why "
                 "a diffused picture keeps its edges instead of going soft. The black families "
                 "carry absorbing particles: the blacks still lift and the highlights bloom much "
                 "less.",
                 "lensGroup", diffusions, 0);
    std::vector<std::string> grades = gDiffusionGradeLabels.empty()
        ? std::vector<std::string>{"1/4"} : gDiffusionGradeLabels;
    const int32_t defaultGrade = fotufilm_bridge_diffusion_default_grade();
    defineChoice(set, "diffusionGrade", "Diffusion Grade",
                 "The particle loading a product line's 1/8, 1/4, 1/2, 1 and 2 name: one "
                 "formulation more heavily loaded, so the grade moves how much light takes part "
                 "and never how far it goes. Ignored with no diffusion filter fitted.",
                 "lensGroup", grades,
                 defaultGrade >= 0 && defaultGrade < static_cast<int32_t>(grades.size())
                     ? defaultGrade : 0);
    defineDouble(set, "focalLength", "Focal Length",
                 "The taking lens's focal length in millimetres, read only by the diffusion "
                 "filter: a ray deviated by an angle ahead of the lens lands focal length times "
                 "that angle off its unscattered position, so the same filter glows bigger on a "
                 "longer lens, exactly as it does in the world. 0 — the default — is the gauge's "
                 "own normal lens, which is what the grade numbering on a filter's ring is "
                 "calibrated around.",
                 "lensGroup", 0, 300, 0);
    for (int i = 0; i < 3; ++i) defineHiddenString(set, kLensFilterIDParams[i]);
    defineHiddenString(set, kDiffusionIDParam);

    defineGroup(set, "toneGroup", "Tone");
    defineDouble(set, "highlights", "Highlights",
                 "Scene-referred highlight recovery, applied before the film "
                 "model. Keyed to each pixel's regional brightness, so pulling a "
                 "sky down moves the sky as one piece.",
                 "toneGroup", -1, 1, 0);
    defineDouble(set, "shadows", "Shadows",
                 "The same shift, fading in below mid-grey.", "toneGroup", -1, 1, 0);
    OfxPropertySetHandle localTone =
        define(set, kOfxParamTypeBoolean, "localTone", "Regional Tone Mask",
               "Off, the highlight and shadow shifts key to each pixel's own "
               "luminance instead of to the region it sits in. Identical output "
               "when both rest at zero.",
               "toneGroup");
    if (localTone) gProperty->propSetInt(localTone, kOfxParamPropDefault, 0, 1);
    defineDouble(set, "saturation", "Saturation",
                 "Chroma multiplier applied to the scene before the film "
                 "responds. 1 leaves it untouched.",
                 "toneGroup", 0, 2, 1);
    defineDouble(set, "vibrance", "Vibrance",
                 "Chroma boost weighted toward the least colourful pixels; "
                 "already-vivid colours are left alone.",
                 "toneGroup", -1, 1, 0);

    defineGroup(set, "filmResponseGroup", "Film Response");
    defineDouble(set, "grain", "Grain",
                 "Multiplier on the stock's measured granularity. 0 disables it.",
                 "filmResponseGroup", 0, 2, 1);
    OfxPropertySetHandle halation = defineDouble(
                 set, "halation", "Halation",
                 "Multiplier on the fraction of light the base returns. On the "
                 "legacy model it scales the light going down rather than the "
                 "finished halo, so raising it widens the halo as well as "
                 "brightening it — the way a thinner antihalation layer would. "
                 "With Estimated Halation Shape on, the film's geometry is "
                 "pinned and this scales the amount alone. 1 is the stock's "
                 "authored look — the sheet's look scale times the measured "
                 "film, whose calibrated returns sit at the patent-floor "
                 "absorber densities and are all but invisible on their own. "
                 "The measured film survives at 1 over the look scale (0.025 "
                 "on a rem-jet stock). Typing past the slider reaches 100.",
                 "filmResponseGroup", 0, 10, 1);
    // The slider stays 0–10; the hard range admits typed values to 100 so a
    // pack's authored look can still be pushed well past itself without
    // touching the calibrated sheets.
    if (halation) gProperty->propSetDouble(halation, kOfxParamPropMax, 0, 100);
    OfxPropertySetHandle estimatedHalation =
        define(set, kOfxParamTypeBoolean, "estimatedHalation",
               "Estimated Halation Shape",
               "Renders halation through the stock's provisional annular "
               "profile — the reflex ring at the base's critical angle — where "
               "no independently calibrated profile exists. Off is the legacy "
               "Gaussian model and the render every existing project made; the "
               "annular road costs roughly half again as much frame time.",
               "filmResponseGroup");
    if (estimatedHalation) {
        gProperty->propSetInt(estimatedHalation, kOfxParamPropDefault, 0, 0);
    }
    defineDouble(set, "halationColour", "Halo Colour",
                 "How much the halo keeps the source's own colour instead of "
                 "the film's layered red. The returning light re-enters the "
                 "emulsion from below, so a colour film's ring is red whatever "
                 "the light was; raising this lifts the dimmer records to the "
                 "strongest record's return, and the ring brightens toward the "
                 "light's colour. 0 is the film.",
                 "filmResponseGroup", 0, 1, 0);
    defineDouble(set, "flare", "Lens Flare",
                 "Veiling glare from the taking lens, as a multiplier on the "
                 "stock's figure. It defaults to 0 because a photographed clip "
                 "already carries the glare of the lens that shot it, and this "
                 "stage would veil the shadows a second time. Raise it for light "
                 "that has met no glass — a render or a synthetic chart — or to "
                 "stand in for glass worse than the camera's.",
                 "filmResponseGroup", 0, 2, 0);
    defineDouble(set, "couplers", "DIR Couplers",
                 "Multiplier on inter-image inhibition, the mechanism behind the "
                 "stock's colour separation and its Mackie lines. 0 disables it.",
                 "filmResponseGroup", 0, 2, 1);
    OfxPropertySetHandle seed =
        define(set, kOfxParamTypeInteger, kSeedParam, "Grain Seed",
               "Same seed and same frame give the same grain. Grain also "
               "advances with the timeline, so a still frame is still, and a "
               "moving one is not.",
               "filmResponseGroup");
    if (seed) {
        gProperty->propSetInt(seed, kOfxParamPropDefault, 0, 0x46494C4D);
        gProperty->propSetInt(seed, kOfxParamPropAnimates, 0, 0);
    }

    defineGroup(set, "labGroup", "The Lab");
    OfxPropertySetHandle push = defineDouble(
        set, "push", "Push / Pull",
        "Measured push or pull conditions for this film's stated developer, "
        "dilution, temperature and agitation. The control is disabled when "
        "the stock pack has no measured response.",
        "labGroup", -2, 2, 0);
    // Interpolation between keyframes would be an unmeasured development condition. The instance
    // change handler also snaps typed and dragged values to the selected stock's measurements.
    if (push) gProperty->propSetInt(push, kOfxParamPropAnimates, 0, 0);
    defineDouble(set, "bleachBypass", "Bleach Bypass",
                 "How much of the developed silver the bleach leaves in the "
                 "negative. The retained silver is a black-and-white image "
                 "over the colour one: contrast up, chroma down, together.",
                 "labGroup", 0, 1, 0);
    defineDouble(set, "expired", "Expired",
                 "Years the roll sat past its process-by date. Speed falls a "
                 "stop a decade with the blue-sensitive layer going first, "
                 "base fog rises, and grain rises with the fog — the muddy, "
                 "crossed toe of an old roll.",
                 "labGroup", 0, 30, 0);
    return kOfxStatOK;
}

/// One menu with a persisted identity. `described` is how many entries the host was actually
/// given for this menu, and is not the same number as `ids->size()` on a node whose panel was
/// built before the engine came up.
struct ChoiceIdentity {
    OfxParamHandle choice;
    OfxParamHandle id;
    const std::vector<std::string> *ids;
    const std::vector<std::string> *labels;
    const char *what;
    const int *described;
    /// The menu this identity names, as the panel spells it.
    const char *menu;
    /// The id a brand-new node persists when the menu it was created against is a placeholder:
    /// the menu's index then names a position in a list the host never showed, so the only
    /// honest identity is the menu's own default. Null leaves the id empty until the user
    /// touches the menu.
    const char *defaultID;
};

std::vector<ChoiceIdentity> identities(Instance *instance) {
    return {
        {instance->stage, instance->stageID, &gStageIDs, &gStageLabels, "pipeline stage",
         &gDescribedStages, "Stage", "full"},
        {instance->stock, instance->stockID, &gStockIDs, &gStockLabels, "film stock",
         &gDescribedStocks, "Stock", nullptr},
        {instance->format, instance->formatID, &gFormatIDs, &gFormatLabels, "format",
         &gDescribedFormats, "Format", kMatchFilmFormatID},
        {instance->paper, instance->paperID, &gPaperIDs, &gPaperLabels, "print paper",
         &gDescribedPapers, "Output Medium", kMatchFilmPaperID},
        {instance->lensFilters[0], instance->lensFilterIDs[0], &gLensFilterIDs,
         &gLensFilterLabels, "lens filter", &gDescribedLensFilters, "Filter 1",
         FOTUFILM_BRIDGE_NO_FILTER_ID},
        {instance->lensFilters[1], instance->lensFilterIDs[1], &gLensFilterIDs,
         &gLensFilterLabels, "lens filter", &gDescribedLensFilters, "Filter 2",
         FOTUFILM_BRIDGE_NO_FILTER_ID},
        {instance->lensFilters[2], instance->lensFilterIDs[2], &gLensFilterIDs,
         &gLensFilterLabels, "lens filter", &gDescribedLensFilters, "Filter 3",
         FOTUFILM_BRIDGE_NO_FILTER_ID},
        {instance->diffusion, instance->diffusionID, &gDiffusionIDs, &gDiffusionLabels,
         "diffusion filter", &gDescribedDiffusions, "Diffusion",
         FOTUFILM_BRIDGE_NO_FILTER_ID},
    };
}

/// The index the persisted id names in this installation's menu, falling back to the menu index
/// when the id is empty, unknown, or was never written. The id is the authority: a project
/// restored against a rearranged pack renders the film it was graded with, whatever position that
/// film now occupies.
int effectiveChoice(OfxParamHandle idParam, const std::vector<std::string> &ids,
                    int menuIndex, OfxTime time) {
    if (!idParam) return menuIndex;
    char *saved = nullptr;
    if (gParameter->paramGetValueAtTime(idParam, time, &saved) != kOfxStatOK ||
        !saved || !*saved) {
        return menuIndex;
    }
    for (size_t i = 0; i < ids.size(); ++i) {
        if (ids[i] == saved) return static_cast<int>(i);
    }
    return menuIndex;
}

/// The span this node performs, resolved the way every other menu here is: through the id the
/// project persisted, with the menu index only as the fallback for a node that has not written
/// one yet.
int effectiveStage(Instance *instance, OfxTime time) {
    int menuIndex = 0;
    if (instance->stage) {
        gParameter->paramGetValueAtTime(instance->stage, time, &menuIndex);
    }
    const int resolved = effectiveChoice(instance->stageID, gStageIDs, menuIndex, time);
    return resolved >= 0 && resolved < static_cast<int>(gStageIDs.size())
        ? resolved : FOTUFILM_BRIDGE_STAGE_FULL;
}

/// The film this node renders, resolved through its persisted id the way the span is. The two
/// together are what the stage controls have to follow: which span is being performed, and which
/// emulsion is performing it.
int effectiveStockChoice(Instance *instance, OfxTime time) {
    int menuIndex = 0;
    if (instance->stock) {
        gParameter->paramGetValueAtTime(instance->stock, time, &menuIndex);
    }
    return effectiveChoice(instance->stockID, gStockIDs, menuIndex, time);
}

/// Turns a parameter's editability on or off, best effort: a host that refuses simply leaves the
/// control usable, and the render ignores it either way.
void enableParameter(OfxParamHandle parameter, bool enabled) {
    if (!parameter || !gParameter->paramGetPropertySet) return;
    OfxPropertySetHandle properties = nullptr;
    if (gParameter->paramGetPropertySet(parameter, &properties) != kOfxStatOK) return;
    gProperty->propSetInt(properties, kOfxParamPropEnabled, 0, enabled ? 1 : 0);
}

/// Greys out the controls the chosen span does not read, and says in the status line what the
/// node is now reading and writing.
///
/// Disabled rather than silently ignored, and the two lists below are the whole of what each span
/// does not reach. A control left live in a span that cannot act on it is the one failure mode a
/// stage menu invites: the user moves it, nothing happens, and nothing says why.
///
/// What stays live in every span is as deliberate as what does not. The lab controls — push,
/// bleach, expiry — and the gauge change the *stock as developed*, which both halves of a split
/// read: the print node needs the same curves the negative node exposed, so it needs the same
/// settings, and hiding them on one side would make the pair impossible to keep in step.
void updateStageControls(Instance *instance) {
    const int stage = effectiveStage(instance, 0);
    const bool scene = stage != FOTUFILM_BRIDGE_STAGE_PRINT;
    const bool print = stage == FOTUFILM_BRIDGE_STAGE_FULL ||
                       stage == FOTUFILM_BRIDGE_STAGE_PRINT;
    const bool texture = stage == FOTUFILM_BRIDGE_STAGE_TEXTURE;

    // The camera and the scene: nothing before the negative exists in the print span.
    for (int index : {FOTUFILM_BRIDGE_EXPOSURE_EV, FOTUFILM_BRIDGE_TEMPERATURE,
                      FOTUFILM_BRIDGE_TINT, FOTUFILM_BRIDGE_HIGHLIGHTS,
                      FOTUFILM_BRIDGE_SHADOWS, FOTUFILM_BRIDGE_LOCAL_TONE,
                      FOTUFILM_BRIDGE_SATURATION, FOTUFILM_BRIDGE_VIBRANCE,
                      FOTUFILM_BRIDGE_GRAIN_SCALE, FOTUFILM_BRIDGE_HALATION_SCALE,
                      FOTUFILM_BRIDGE_COUPLER_SCALE}) {
        enableParameter(instance->parameters[index], scene);
    }
    enableParameter(instance->seed, scene);
    // The print, which the two spans before it have not reached. The paper itself stays live in
    // the texture span: the enlarger's blur is one of the spatial stages that span can carry, and
    // it is a property of the medium.
    enableParameter(instance->paper, print || texture);
    enableParameter(instance->parameters[FOTUFILM_BRIDGE_PRINT_CORRECTION], print);
    enableParameter(instance->parameters[FOTUFILM_BRIDGE_PRINT_LIGHT], print);

    // The lens, which is camera-side: nothing screwed onto the front of it exists in a span that
    // starts at the developed negative, so Print Only greys the whole group exactly as it greys
    // the exposure.
    //
    // The scattering half survives into Texture Only, and that it does is measured rather than
    // reasoned. That span develops the frame twice — once with the spatial stages it was asked
    // for and once with none of them — and returns what the two densities differ by, so a lens
    // control reaches it only through what the spatial stages make of the light it changed. The
    // diffusion filter reaches it easily: the mist softens the light the halo, the adjacency and
    // the grain are then computed over, and the harness measures the frame moving by 1.2e-2 RMS
    // with a filter fitted and 9e-3 when the focal length changes its width. Diffusion is in
    // FOTUFILM_AOT_ALL_STAGES, which every span's variants are built from, so nothing about the
    // focal length or the mist depends on which span asks for it.
    //
    // The absorbing filters and the metering are live in Full and nowhere else, and not because
    // they are too small to see anywhere else: a filter is two more air-glass faces, so a fitted
    // one raises the veiling-glare feature bit (`FilmEngine.swift`, where
    // `lensFilters.addedVeilingGlare` enters the glare term whatever the Lens Flare slider says).
    // No compiled variant in FotufilmHalide.h pairs FOTUFILM_FRAME_FLARE with either of the two
    // spans that would need it — FOTUFILM_AOT_TEXTURE_SPAN has no flare, and neither does any
    // variant built on FOTUFILM_AOT_NEGATIVE_SPAN, which carries FOTUFILM_FRAME_DENSITY_OUT — and
    // `select_variant` matches the mask exactly rather than by superset. Left live in either
    // span, a filter would not be weak: it would fail every frame. Dimmed is the honest state
    // until those variants exist, and `readParameters` clears the slot as well, because a control
    // the user can no longer reach must not keep acting.
    const bool exposing = stage == FOTUFILM_BRIDGE_STAGE_FULL;
    for (int index : {FOTUFILM_BRIDGE_LENS_FILTER_1, FOTUFILM_BRIDGE_LENS_FILTER_2,
                      FOTUFILM_BRIDGE_LENS_FILTER_3, FOTUFILM_BRIDGE_LENS_METERING}) {
        enableParameter(instance->parameters[index], exposing);
    }
    for (int index : {FOTUFILM_BRIDGE_DIFFUSION_FAMILY, FOTUFILM_BRIDGE_DIFFUSION_GRADE,
                      FOTUFILM_BRIDGE_FOCAL_LENGTH}) {
        enableParameter(instance->parameters[index], scene);
    }

    // The negative viewing mode reads only where the negative *is* the output. Everything else
    // has a print or a scan of its own, and Match Film leaves the choice to the film.
    int paperIndex = 0;
    if (instance->paper) gParameter->paramGetValue(instance->paper, &paperIndex);
    paperIndex = effectiveChoice(instance->paperID, gPaperIDs, paperIndex, 0);
    enableParameter(instance->parameters[FOTUFILM_BRIDGE_NEGATIVE_VIEWING],
                    print && fotufilm_bridge_paper_is_negative(paperIndex) != 0);

    // The texture span's own selection, film by film. A stage is offered where the chosen stock's
    // measurements put something behind it and withheld where they do not: a remjet-backed stock
    // returns no light from its base, a coupler-free one has no adjacency, and a reversal stock
    // never meets an enlarger. Selecting one of those would be inert rather than wrong, which is
    // worse — the control moves and nothing happens. The engine is asked rather than this side
    // working it out: what a film has is the film's own data, and a second copy of that judgement
    // here would drift from it.
    const int stock = effectiveStockChoice(instance, 0);
    const bool pushes = fotufilm_bridge_stock_pushes(stock) != 0;
    enableParameter(instance->parameters[FOTUFILM_BRIDGE_PUSH_PULL], pushes);
    // Projects saved before development became measured can carry a generic value on any stock.
    // Once this row is disabled there is no UI with which to clear it, so retire that obsolete
    // request here. A host that refuses the write gets the bridge's explicit render error instead.
    if (instance->parameters[FOTUFILM_BRIDGE_PUSH_PULL]) {
        double requested = 0;
        gParameter->paramGetValue(instance->parameters[FOTUFILM_BRIDGE_PUSH_PULL], &requested);
        const double measured = fotufilm_bridge_stock_snap_push(
            stock, static_cast<float>(requested));
        if (std::abs(requested - measured) > 1e-4) {
            gParameter->paramSetValue(instance->parameters[FOTUFILM_BRIDGE_PUSH_PULL], measured);
        }
    }
    std::string withheld;
    int withheldCount = 0;
    for (size_t i = 0; i < instance->textureStages.size(); ++i) {
        const bool offered =
            fotufilm_bridge_texture_stage_available(stock, static_cast<int32_t>(i)) != 0;
        enableParameter(instance->textureStages[i], texture && offered);
        if (!offered && i < gTextureLabels.size()) {
            if (!withheld.empty()) withheld += ", ";
            withheld += gTextureLabels[i];
            ++withheldCount;
        }
    }

    if (!instance->stageStatus) return;
    std::string line;
    const char *text = "Stage: Full — scene in, finished output out";
    if (!gEngineReady) {
        // The top line of the panel is the one place a user looks before rendering; the reason
        // the node cannot render belongs there, not only in a menu entry that reads as a film.
        line = "Fotufilm cannot render: " + gInitializationError;
        gParameter->paramSetValue(instance->stageStatus, line.c_str());
        return;
    }
    switch (stage) {
    case FOTUFILM_BRIDGE_STAGE_NEGATIVE:
        text = "Negative Only: scene in, developed negative out — per-layer density, not a "
               "picture. Feed it straight into a Print Only node on the same stock and lab "
               "settings; do not grade, resize or convert in between.";
        break;
    case FOTUFILM_BRIDGE_STAGE_PRINT:
        // A reversal stock is its own positive. This is still the right span to put after a
        // Negative Only node — it is where the film's own read of the developed dyes happens —
        // but there is no enlarger and no paper in it, and saying so is better than leaving the
        // Output Medium menu to imply otherwise.
        line = fotufilm_bridge_stock_prints(stock) != 0
            ? "Print Only: developed negative in, finished output out. Its input carries no "
              "colour tag, so Timeline Color Space must name the space to encode into."
            : "Print Only: this film is its own positive and has no print, so this span "
              "performs the film's own read of the developed dyes and nothing else. It still "
              "belongs after a Negative Only node, and still needs Timeline Color Space named.";
        text = line.c_str();
        break;
    case FOTUFILM_BRIDGE_STAGE_TEXTURE:
        line = "Texture Only: the film's spatial character over the frame it is handed, in the "
               "same space it arrived in. No curve, no dyes, no print.";
        if (!withheld.empty()) {
            line += " This film has no " + withheld + " to give, so "
                + (withheldCount == 1 ? "that stage is" : "those stages are")
                + " not offered.";
        }
        text = line.c_str();
        break;
    default:
        break;
    }
    // A menu the host built before the engine came up cannot show what this project chose. The
    // node renders it anyway — the id is the authority — but the panel would otherwise say
    // nothing about why the menu disagrees with the picture.
    if (!instance->staleMenuNote.empty()) {
        line = std::string(text) + " " + instance->staleMenuNote;
        text = line.c_str();
    }
    gParameter->paramSetValue(instance->stageStatus, text);
}

/// Rewrites the read-only line under the colour space menu with what the plugin would actually do
/// right now. Derived state: refreshed at creation, when the choice moves, and when the clip
/// changes — never persisted.
void updateColourSpaceStatus(Instance *instance) {
    if (!instance->colorSpaceStatus) return;
    int choice = kColorSpaceAuto;
    if (instance->colorSpace) gParameter->paramGetValue(instance->colorSpace, &choice);

    char text[512];
    if (menuEncoding(choice) != fotufilm::Encoding::Count) {
        const auto encoding = menuEncoding(choice);
        const bool displayReferred = encoding == fotufilm::Encoding::Rec709Gamma24 ||
                                     encoding == fotufilm::Encoding::SRGB;
        std::snprintf(text, sizeof(text),
                      "%s (%s)", compactEncodingLabel(encoding),
                      displayReferred ? "display" : "scene");
    } else {
        char *name = nullptr;
        OfxPropertySetHandle clip = nullptr;
        if (instance->sourceClip &&
            gEffect->clipGetPropertySet(instance->sourceClip, &clip) == kOfxStatOK) {
            gProperty->propGetString(clip, kOfxImageClipPropColourspace, 0, &name);
        }
        const fotufilm::Encoding mapped = fotufilm::encodingForColourspace(name);
        if (mapped != fotufilm::Encoding::Count) {
            std::snprintf(text, sizeof(text),
                          "%s (host)", compactEncodingLabel(mapped));
        } else if (isRawColourspace(name)) {
            const auto fallback = rawFallback(name);
            std::snprintf(text, sizeof(text),
                          "%s (assumed)", compactEncodingLabel(fallback));
        } else if (name && *name) {
            std::snprintf(text, sizeof(text),
                          "Unsupported: %s", name);
        } else {
            std::snprintf(text, sizeof(text),
                          "%s (assumed)",
                          compactEncodingLabel(fotufilm::Encoding::Rec709Gamma24));
        }
    }
    gParameter->paramSetValue(instance->colorSpaceStatus, text);
}

/// Ask an OFX 1.5 host to do the cheapest exact conversion: hand Source to us in the engine's
/// linear Rec.2020 working space. The property name is clip-specific for this action.
///
/// Except on a Print Only node, where what arrives is not colour at all. Its Source is the
/// developed negative's densities, and the one thing a host must do with them is nothing — so it
/// is asked for Raw, the data space, and the link from the Negative Only node upstream carries
/// the numbers across untouched.
///
/// Whether the output varies from frame to frame on identical input is declared here too. The
/// grain field is seeded by the frame number, so a span that lays grain down — Full, Negative
/// Only, and Texture Only with grain selected — changes with the timeline even on a held frame,
/// and a host that cached one frame's answer for the next would show a frozen grain field. Print
/// Only is handed the grain already developed and adds none.
OfxStatus getClipPreferences(OfxImageEffectHandle effect, OfxPropertySetHandle outArgs) {
    if (!outArgs) return kOfxStatErrBadHandle;
    Instance *instance = instanceOf(effect);
    const int stage = instance ? effectiveStage(instance, 0) : FOTUFILM_BRIDGE_STAGE_FULL;
    const bool interchange = stage == FOTUFILM_BRIDGE_STAGE_PRINT;

    bool varying = stage != FOTUFILM_BRIDGE_STAGE_PRINT;
    if (instance && stage == FOTUFILM_BRIDGE_STAGE_TEXTURE) {
        varying = (textureSelection(instance, 0) & textureGrainMask()) != 0;
    }
    gProperty->propSetInt(outArgs, kOfxImageEffectFrameVarying, 0, varying ? 1 : 0);

    // Best effort, and the action succeeds either way: the property is OFX 1.5's, and a host
    // that predates it or refuses the clip-specific spelling has only declined a request. The
    // render reads the tag on every image rather than trusting this was honoured, so failing the
    // whole action here would take the frame-varying declaration above down with it for nothing.
    const std::string preferred =
        std::string(kOfxImageClipPropPreferredColourspaces) + "_" +
        kOfxImageEffectSimpleSourceClipName;
    const OfxStatus status = gProperty->propSetString(
        outArgs, preferred.c_str(), 0,
        interchange ? kOfxColourspaceRaw : kOfxColourspaceLinRec2020);
    if (status != kOfxStatOK) {
        report("the host declined the preferred input colourspace (%s, status %d); the "
               "render will read the tag on each image instead", preferred.c_str(),
               static_cast<int>(status));
    }
    return kOfxStatOK;
}

/// Declares output colourspace to the OFX host. Full and Texture cross-reference Source. Negative
/// and Print declare Raw so density interchange is not transformed and Print output is not encoded twice.
OfxStatus getOutputColourspace(OfxImageEffectHandle effect,
                               OfxPropertySetHandle outArgs) {
    if (!outArgs) return kOfxStatErrBadHandle;
    Instance *instance = instanceOf(effect);
    const int stage = instance ? effectiveStage(instance, 0) : FOTUFILM_BRIDGE_STAGE_FULL;
    const bool split = stage == FOTUFILM_BRIDGE_STAGE_NEGATIVE ||
                       stage == FOTUFILM_BRIDGE_STAGE_PRINT;
    return gProperty->propSetString(outArgs, kOfxImageClipPropColourspace, 0,
                                    split ? kOfxColourspaceRaw : "OfxColourspace_Source");
}

/// Brings a freshly created instance's menus and ids into agreement. A new node has empty ids and
/// adopts what the menus say; a node restored from a project has ids, and they win — the menu
/// index was only ever a position in whatever pack was installed on the machine that saved.
void reconcile(OfxImageEffectHandle effect, Instance *instance) {
    instance->staleMenuNote.clear();
    std::string stale;
    for (const ChoiceIdentity &entry : identities(instance)) {
        if (!entry.choice || !entry.id || entry.ids->empty()) continue;
        // How far into the id list a menu index is allowed to reach. A menu described before the
        // engine came up is shorter than the list behind it, and writing an index past its last
        // entry is writing a number the host cannot show — some hosts clamp it, some refuse it,
        // and the one that clamps has silently changed the node's film.
        const int described = entry.described && *entry.described >= 0
            ? *entry.described : static_cast<int>(entry.ids->size());

        int index = 0;
        gParameter->paramGetValue(entry.choice, &index);
        char *saved = nullptr;
        gParameter->paramGetValue(entry.id, &saved);

        if (!saved || !*saved) {
            // First creation: record the identity of the default the menu landed on. Best
            // effort — a host that refuses paramSetValue outside instanceChanged just leaves
            // the id empty until the user first touches the menu.
            //
            // Against a placeholder panel the index is not an identity at all: it is a
            // position in a menu the engine had not yet filled, and reading it into the full
            // list names whatever happens to sit there — the second gauge, say, where the
            // panel showed Match Film. Persist the menu's own default instead.
            const bool placeholder = described < static_cast<int>(entry.ids->size());
            if (placeholder) {
                if (entry.defaultID) gParameter->paramSetValue(entry.id, entry.defaultID);
            } else if (index >= 0 && index < static_cast<int>(entry.ids->size())) {
                gParameter->paramSetValue(entry.id, (*entry.ids)[index].c_str());
            }
            continue;
        }

        int found = -1;
        for (size_t i = 0; i < entry.ids->size(); ++i) {
            if ((*entry.ids)[i] == saved) { found = static_cast<int>(i); break; }
        }
        if (found < 0) {
            // Keep the stored id: reinstalling the missing pack heals the project.
            const bool labelled = index >= 0 && index < static_cast<int>(entry.labels->size());
            post(kOfxMessageError, effect,
                 "this project's %s \"%s\" is not installed; rendering \"%s\" until it is",
                 entry.what, saved,
                 labelled ? (*entry.labels)[index].c_str() : "the menu's current choice");
        } else if (found >= described) {
            // The id names something this installation has, but the menu the host built cannot
            // show it. The id is the authority and the render resolves through it, so the frame
            // is right; only the menu is stale, and only until the host is restarted.
            if (!stale.empty()) stale += ", ";
            stale += entry.menu;
        } else if (found != index) {
            // Synchronize the menu to the stable ID after pack ordering changes.
            gParameter->paramSetValue(entry.choice, found);
        }
    }
    if (!stale.empty()) {
        instance->staleMenuNote =
            "Fotufilm's engine started after Resolve built this node's panel, so the " + stale +
            " menu still holds a placeholder. The node renders what the project saved; restart "
            "Resolve to get the full menus.";
        report("%s", instance->staleMenuNote.c_str());
    }
}

/// What the host negotiated for colour management on this instance, on the record. The plugin
/// declared the native config in `describe` and looks colourspace names up against it; a host
/// that set a different config here has agreed to something the plugin does not speak, and the
/// names it will tag clips with may not be the ones `encodingForColourspace` knows. Said once
/// per instance rather than left to surface as an "unsupported tag" at render time.
void reportColourManagement(OfxImageEffectHandle effect) {
    OfxPropertySetHandle properties = nullptr;
    if (gEffect->getPropertySet(effect, &properties) != kOfxStatOK) return;
    char *style = nullptr, *config = nullptr;
    gProperty->propGetString(properties, kOfxImageEffectPropColourManagementStyle, 0, &style);
    gProperty->propGetString(properties, kOfxImageEffectPropColourManagementConfig, 0, &config);
    report("host colour management: style %s, config %s",
           style && *style ? style : "(none)", config && *config ? config : "(none)");
    if (config && *config && std::strcmp(config, kOfxConfigIdentifier) != 0) {
        post(kOfxMessageWarning, effect,
             "Fotufilm was given the colour management config \"%s\", but it only knows the "
             "native config %s. It will read the host's colourspace tags as native names; if "
             "a clip's tag is not recognised, set Timeline Color Space explicitly.",
             config, kOfxConfigIdentifier);
    }
}

OfxStatus createInstance(OfxImageEffectHandle effect) {
    // The engine may have been refused at load for a reason the user has since fixed — the
    // licence, most likely. One more attempt per node, so activating the app and adding a node
    // renders without a relaunch. The menus already described keep their placeholder until one.
    //
    // Throttled, because "per node" is not "per attempt": opening a project full of Fotufilm
    // nodes creates them in a burst, and a licence that was inactive a millisecond ago is
    // inactive still. The interval is the FxPlug side's, which throttles its own retry the same
    // way and for the same reason.
    if (!gEngineReady) {
        const std::chrono::duration<double> since =
            std::chrono::steady_clock::now() - gLastInitialization;
        if (!gEverInitialized || since.count() >= kEngineRetrySeconds) initializeEngine();
    }

    Instance *instance = new Instance();
    instance->bridge = fotufilm_bridge_context_create();
    if (!instance->bridge) {
        delete instance;
        post(kOfxMessageError, effect, "Fotufilm could not allocate its render context");
        return kOfxStatErrMemory;
    }

    gEffect->clipGetHandle(effect, kOfxImageEffectSimpleSourceClipName,
                           &instance->sourceClip, nullptr);
    gEffect->clipGetHandle(effect, kOfxImageEffectOutputClipName,
                           &instance->outputClip, nullptr);

    OfxParamSetHandle set = nullptr;
    gEffect->getParamSet(effect, &set);
    for (int i = 0; i < FOTUFILM_BRIDGE_PARAMETER_COUNT; ++i) {
        if (!kParameterNames[i]) continue;
        gParameter->paramGetHandle(set, kParameterNames[i],
                                   &instance->parameters[i], nullptr);
    }
    gParameter->paramGetHandle(set, kStageParam, &instance->stage, nullptr);
    gParameter->paramGetHandle(set, kStageIDParam, &instance->stageID, nullptr);
    // Whatever the engine names right now. A node created while the engine was still refused
    // gets an empty list here and no handles, and `textureStagesMissing` compares the two again
    // at every use rather than trusting this moment: the retry on a later node can fill the list
    // long after this one was built.
    instance->textureStages.assign(gTextureParams.size(), nullptr);
    for (size_t i = 0; i < gTextureParams.size(); ++i) {
        gParameter->paramGetHandle(set, gTextureParams[i].c_str(),
                                   &instance->textureStages[i], nullptr);
    }
    gParameter->paramGetHandle(set, kStageStatusParam, &instance->stageStatus, nullptr);
    gParameter->paramGetHandle(set, kStockParam, &instance->stock, nullptr);
    gParameter->paramGetHandle(set, kFormatParam, &instance->format, nullptr);
    gParameter->paramGetHandle(set, kPaperParam, &instance->paper, nullptr);
    gParameter->paramGetHandle(set, kColorSpaceParam, &instance->colorSpace, nullptr);
    gParameter->paramGetHandle(set, kSeedParam, &instance->seed, nullptr);
    gParameter->paramGetHandle(set, kStockIDParam, &instance->stockID, nullptr);
    gParameter->paramGetHandle(set, kFormatIDParam, &instance->formatID, nullptr);
    gParameter->paramGetHandle(set, kPaperIDParam, &instance->paperID, nullptr);
    for (int i = 0; i < 3; ++i) {
        gParameter->paramGetHandle(set, kLensFilterParams[i], &instance->lensFilters[i], nullptr);
        gParameter->paramGetHandle(set, kLensFilterIDParams[i], &instance->lensFilterIDs[i],
                                   nullptr);
    }
    gParameter->paramGetHandle(set, kDiffusionParam, &instance->diffusion, nullptr);
    gParameter->paramGetHandle(set, kDiffusionIDParam, &instance->diffusionID, nullptr);
    gParameter->paramGetHandle(set, kColorSpaceStatusParam,
                               &instance->colorSpaceStatus, nullptr);

    reconcile(effect, instance);
    updateColourSpaceStatus(instance);
    updateStageControls(instance);
    reportColourManagement(effect);

    OfxPropertySetHandle properties = nullptr;
    gEffect->getPropertySet(effect, &properties);
    gProperty->propSetPointer(properties, kOfxPropInstanceData, 0, instance);
    return kOfxStatOK;
}

/// Keeps the persisted identity in step with the menu the user just moved, and the colour space
/// status line in step with both the menu and the clip.
OfxStatus instanceChanged(OfxImageEffectHandle effect, OfxPropertySetHandle inArgs) {
    char *type = nullptr;
    gProperty->propGetString(inArgs, kOfxPropType, 0, &type);
    if (!type) return kOfxStatReplyDefault;

    Instance *instance = instanceOf(effect);
    if (!instance) return kOfxStatReplyDefault;

    if (std::strcmp(type, kOfxTypeClip) == 0) {
        // A different clip may carry a different colourspace tag.
        updateColourSpaceStatus(instance);
        return kOfxStatReplyDefault;
    }
    if (std::strcmp(type, kOfxTypeParameter) != 0) return kOfxStatReplyDefault;
    char *name = nullptr;
    gProperty->propGetString(inArgs, kOfxPropName, 0, &name);
    if (!name) return kOfxStatReplyDefault;

    if (std::strcmp(name, kColorSpaceParam) == 0) {
        updateColourSpaceStatus(instance);
        return kOfxStatOK;
    }

    if (std::strcmp(name, "push") == 0) {
        OfxParamHandle parameter =
            instance->parameters[FOTUFILM_BRIDGE_PUSH_PULL];
        if (!parameter) return kOfxStatReplyDefault;
        double requested = 0;
        gParameter->paramGetValue(parameter, &requested);
        const double measured = fotufilm_bridge_stock_snap_push(
            effectiveStockChoice(instance, 0), static_cast<float>(requested));
        if (std::abs(requested - measured) > 1e-4) {
            gParameter->paramSetValue(parameter, measured);
        }
        return kOfxStatOK;
    }

    for (const ChoiceIdentity &entry : identities(instance)) {
        bool ours =
            (entry.choice == instance->stage && std::strcmp(name, kStageParam) == 0) ||
            (entry.choice == instance->stock && std::strcmp(name, kStockParam) == 0) ||
            (entry.choice == instance->format && std::strcmp(name, kFormatParam) == 0) ||
            (entry.choice == instance->paper && std::strcmp(name, kPaperParam) == 0) ||
            (entry.choice == instance->diffusion && std::strcmp(name, kDiffusionParam) == 0);
        for (int i = 0; i < 3 && !ours; ++i) {
            ours = entry.choice == instance->lensFilters[i] &&
                   std::strcmp(name, kLensFilterParams[i]) == 0;
        }
        if (!ours || !entry.choice || !entry.id) continue;
        int index = 0;
        gParameter->paramGetValue(entry.choice, &index);
        if (index >= 0 && index < static_cast<int>(entry.ids->size())) {
            gParameter->paramSetValue(entry.id, (*entry.ids)[index].c_str());
        }
        // Which controls mean anything depends on the span, on the film — a stage the stock has
        // nothing behind is not offered — and on the output medium, since only the negative
        // medium reads a negative-viewing mode. So the panel follows any of the three. Done after
        // the id is written, because that is what the render, and this, resolve against.
        if (entry.choice == instance->stage || entry.choice == instance->stock ||
            entry.choice == instance->paper) {
            updateStageControls(instance);
        }
        return kOfxStatOK;
    }
    return kOfxStatReplyDefault;
}

OfxStatus destroyInstance(OfxImageEffectHandle effect) {
    Instance *instance = instanceOf(effect);
    if (instance) fotufilm_bridge_context_destroy(instance->bridge);
    delete instance;
    OfxPropertySetHandle properties = nullptr;
    if (gEffect->getPropertySet(effect, &properties) == kOfxStatOK) {
        gProperty->propSetPointer(properties, kOfxPropInstanceData, 0, nullptr);
    }
    return kOfxStatOK;
}

/// Host CPU image used by the render loop. The engine remains Metal-backed, but waiting on
/// Resolve's queue is incompatible with the OFX Metal extension.
struct Image {
    OfxPropertySetHandle handle = nullptr;
    float *data = nullptr;
    OfxRectI bounds = {0, 0, 0, 0};
    int rowBytes = 0;

    int width() const { return bounds.x2 - bounds.x1; }
    int height() const { return bounds.y2 - bounds.y1; }
    float *row(int y) const {
        return reinterpret_cast<float *>(reinterpret_cast<char *>(data) +
                                         static_cast<ptrdiff_t>(y - bounds.y1) * rowBytes);
    }
};

/// Fetches the clip's image at `time`, or says why it cannot be used. `reason` is for the user:
/// a host handing over the wrong depth, the wrong components or a row stride shorter than a row
/// is a host misconfiguration, and a bare failure status tells nobody which.
bool fetch(OfxImageClipHandle clip, OfxTime time, Image &image, std::string &reason) {
    if (gEffect->clipGetImage(clip, time, nullptr, &image.handle) != kOfxStatOK ||
        image.handle == nullptr) {
        reason = "the host supplied no image";
        return false;
    }
    void *data = nullptr;
    gProperty->propGetPointer(image.handle, kOfxImagePropData, 0, &data);
    gProperty->propGetIntN(image.handle, kOfxImagePropBounds, 4, &image.bounds.x1);
    gProperty->propGetInt(image.handle, kOfxImagePropRowBytes, 0, &image.rowBytes);

    char *depth = nullptr;
    gProperty->propGetString(image.handle, kOfxImageEffectPropPixelDepth, 0, &depth);
    char *components = nullptr;
    gProperty->propGetString(image.handle, kOfxImageEffectPropComponents, 0, &components);
    const long long minimumRow = static_cast<long long>(image.width()) * 4 * sizeof(float);
    const long long actualRow = std::llabs(static_cast<long long>(image.rowBytes));
    const bool usable = data != nullptr && image.width() > 0 && image.height() > 0 &&
                  actualRow >= minimumRow &&
                  !(depth && std::strcmp(depth, kOfxBitDepthFloat) != 0) &&
                  !(components && std::strcmp(components, kOfxImageComponentRGBA) != 0);
    if (usable) {
        image.data = static_cast<float *>(data);
    }

    if (!usable) {
        char text[512];
        if (data == nullptr) {
            std::snprintf(text, sizeof(text), "the host supplied an image with no pixel data");
        } else if (image.width() <= 0 || image.height() <= 0) {
            std::snprintf(text, sizeof(text), "the host supplied an empty image (%dx%d)",
                          image.width(), image.height());
        } else if (depth && std::strcmp(depth, kOfxBitDepthFloat) != 0) {
            std::snprintf(text, sizeof(text),
                          "the host supplied %s pixels, and Fotufilm declared it takes only "
                          "%s", depth, kOfxBitDepthFloat);
        } else if (components && std::strcmp(components, kOfxImageComponentRGBA) != 0) {
            std::snprintf(text, sizeof(text),
                          "the host supplied %s pixels, and Fotufilm declared it takes only "
                          "%s", components, kOfxImageComponentRGBA);
        } else {
            std::snprintf(text, sizeof(text),
                          "the host supplied a row stride of %d bytes for a %d-pixel RGBA "
                          "float row, which needs %lld", image.rowBytes, image.width(),
                          minimumRow);
        }
        reason = text;
        gEffect->clipReleaseImage(image.handle);
        image.handle = nullptr;
        return false;
    }
    return true;
}

double pixelAspectRatio(OfxImageClipHandle clip) {
    OfxPropertySetHandle properties = nullptr;
    double ratio = 1.0;
    if (gEffect->clipGetPropertySet(clip, &properties) == kOfxStatOK) {
        gProperty->propGetDouble(properties, kOfxImagePropPixelAspectRatio, 0, &ratio);
    }
    return std::isfinite(ratio) && ratio > 0 ? ratio : 1.0;
}

int squarePixelWidth(int width, double pixelAspect) {
    if (width <= 0 || !std::isfinite(pixelAspect) || pixelAspect <= 0) return 0;
    const double scaled = static_cast<double>(width) * pixelAspect;
    if (scaled < 1 || scaled > static_cast<double>(INT32_MAX)) return 0;
    return std::max(1, static_cast<int>(std::llround(scaled)));
}

bool isPremultiplied(OfxImageClipHandle clip) {
    OfxPropertySetHandle properties = nullptr;
    if (gEffect->clipGetPropertySet(clip, &properties) != kOfxStatOK) return false;
    char *value = nullptr;
    if (gProperty->propGetString(properties, kOfxImageEffectPropPreMultiplication, 0,
                                 &value) != kOfxStatOK || !value) {
        return false;
    }
    return std::strcmp(value, kOfxImagePreMultiplied) == 0;
}

/// Work shaped as a half-open row range, for spreading across the host's thread pool.
struct RowJob {
    void (*work)(int begin, int end, void *context);
    void *context;
    int begin, end;
};

void rowThunk(unsigned int index, unsigned int total, void *argument) {
    const RowJob &job = *static_cast<const RowJob *>(argument);
    const long long rows = job.end - job.begin;
    const int lo = job.begin + static_cast<int>(rows * index / total);
    const int hi = job.begin + static_cast<int>(rows * (index + 1) / total);
    if (hi > lo) job.work(lo, hi, job.context);
}

/// Runs `work` over [begin, end), split across the host's SMP suite when there is one and the
/// range is worth splitting. The per-pixel transcodes are embarrassingly parallel; on a host
/// without the suite nothing changes but the wall clock.
void forRows(int begin, int end, void (*work)(int begin, int end, void *context),
             void *context) {
    const int rows = end - begin;
    if (rows <= 0) return;
    if (gCPUs == 0) {
        unsigned int queried = 1;
        if (gThread && gThread->multiThread && gThread->multiThreadNumCPUs) {
            gThread->multiThreadNumCPUs(&queried);
        }
        gCPUs = queried > 0 ? queried : 1;
    }
    const unsigned int cpus = gCPUs;
    const unsigned int lanes =
        std::min<unsigned int>(cpus, static_cast<unsigned int>(rows));
    if (lanes <= 1 || rows < 64) {
        work(begin, end, context);
        return;
    }
    RowJob job{work, context, begin, end};
    if (gThread->multiThread(rowThunk, lanes, &job) != kOfxStatOK) {
        work(begin, end, context);
    }
}

/// Reads the float parameter block the bridge takes, as of `time`.
void readParameters(Instance *instance, OfxTime time,
                    float parameters[FOTUFILM_BRIDGE_PARAMETER_COUNT]) {
    for (int i = 0; i < FOTUFILM_BRIDGE_PARAMETER_COUNT; ++i) {
        parameters[i] = 0;
        if (!instance->parameters[i]) continue;
        // The Lens group's four catalogue menus are resolved out of the ids the project
        // persisted, after this loop. Reading the menu index here as well would only be reading
        // the number that id exists to outvote, so they are left at zero until then.
        if (i == FOTUFILM_BRIDGE_LENS_FILTER_1 || i == FOTUFILM_BRIDGE_LENS_FILTER_2 ||
            i == FOTUFILM_BRIDGE_LENS_FILTER_3 || i == FOTUFILM_BRIDGE_DIFFUSION_FAMILY) {
            continue;
        }
        if (i == FOTUFILM_BRIDGE_LOCAL_TONE || i == FOTUFILM_BRIDGE_ESTIMATED_HALATION) {
            int value = i == FOTUFILM_BRIDGE_LOCAL_TONE ? 1 : 0;
            gParameter->paramGetValueAtTime(instance->parameters[i], time, &value);
            parameters[i] = static_cast<float>(value);
        } else if (isOffsetChoice(i) || i == FOTUFILM_BRIDGE_DIFFUSION_GRADE) {
            // A choice param appears as an int, and the bridge wants a position in the engine's
            // own list: the menu's own for the grade, and one less than the menu's for the menus
            // that open with a None or a default this side owns. The offset is added back on the
            // way out, which is what makes a slot an older project never filled read as off.
            int value = 0;
            gParameter->paramGetValueAtTime(instance->parameters[i], time, &value);
            if (value < 0) value = 0;
            parameters[i] = static_cast<float>(value) + (isOffsetChoice(i) ? 1.0f : 0.0f);
        } else if (i == FOTUFILM_BRIDGE_PRINT_LIGHT) {
            // A choice param appears as an int, and the bridge wants kelvin.
            int value = 0;
            gParameter->paramGetValueAtTime(instance->parameters[i], time, &value);
            const int count =
                static_cast<int>(sizeof(kPrintLightKelvin) / sizeof(*kPrintLightKelvin));
            parameters[i] = kPrintLightKelvin[value >= 0 && value < count ? value : 0];
        } else {
            double value = 0;
            gParameter->paramGetValueAtTime(instance->parameters[i], time, &value);
            parameters[i] = static_cast<float>(value);
        }
    }
    // The two composed slots. The span comes from its persisted id rather than its menu index,
    // and the texture selection is the OR of the booleans, each carrying the bit the bridge
    // handed out for it.
    parameters[FOTUFILM_BRIDGE_STAGE] =
        static_cast<float>(effectiveStage(instance, time));
    parameters[FOTUFILM_BRIDGE_TEXTURE_STAGES] =
        static_cast<float>(textureSelection(instance, time));

    // The four catalogue menus in the Lens group, resolved through the id the project persisted
    // rather than through the position it happened to occupy. The filter drawer is the one menu
    // here that will certainly grow, and a drawer that gains a filter renumbers every entry after
    // it; a project graded through a #25 Red must keep rendering a #25 Red.
    const int lensSlots[3] = {FOTUFILM_BRIDGE_LENS_FILTER_1, FOTUFILM_BRIDGE_LENS_FILTER_2,
                              FOTUFILM_BRIDGE_LENS_FILTER_3};
    for (int i = 0; i < 3; ++i) {
        if (!instance->parameters[lensSlots[i]]) continue;
        int menuIndex = 0;
        gParameter->paramGetValueAtTime(instance->parameters[lensSlots[i]], time, &menuIndex);
        const int resolved =
            effectiveChoice(instance->lensFilterIDs[i], gLensFilterIDs, menuIndex, time);
        parameters[lensSlots[i]] = static_cast<float>(resolved < 0 ? 0 : resolved);
    }
    if (instance->parameters[FOTUFILM_BRIDGE_DIFFUSION_FAMILY]) {
        int menuIndex = 0;
        gParameter->paramGetValueAtTime(
            instance->parameters[FOTUFILM_BRIDGE_DIFFUSION_FAMILY], time, &menuIndex);
        const int resolved =
            effectiveChoice(instance->diffusionID, gDiffusionIDs, menuIndex, time);
        parameters[FOTUFILM_BRIDGE_DIFFUSION_FAMILY] =
            static_cast<float>(resolved < 0 ? 0 : resolved);
    }

    // The lens, cleared where `updateStageControls` dimmed it. A greyed control is by definition
    // not applied, and dimming one does not empty it: a filter chosen on the Full stage stays
    // chosen when the node is switched to a span that has no kernel for it, and the render would
    // then fail on a value the panel no longer offers any way to clear. So the value stops here
    // instead, and the span the user asked for renders.
    //
    // Which is which is the same division `updateStageControls` greys on, and for the same
    // reasons: the absorbing filters and the metering raise the veiling-glare feature bit, which
    // only Full's variants carry, and nothing on the front of the lens exists at all in a span
    // that begins at the developed negative.
    const int stage = static_cast<int>(parameters[FOTUFILM_BRIDGE_STAGE]);
    if (stage != FOTUFILM_BRIDGE_STAGE_FULL) {
        for (int slot : {FOTUFILM_BRIDGE_LENS_FILTER_1, FOTUFILM_BRIDGE_LENS_FILTER_2,
                         FOTUFILM_BRIDGE_LENS_FILTER_3, FOTUFILM_BRIDGE_LENS_METERING}) {
            parameters[slot] = 0;
        }
    }
    if (stage == FOTUFILM_BRIDGE_STAGE_PRINT) {
        for (int slot : {FOTUFILM_BRIDGE_DIFFUSION_FAMILY, FOTUFILM_BRIDGE_DIFFUSION_GRADE,
                         FOTUFILM_BRIDGE_FOCAL_LENGTH}) {
            parameters[slot] = 0;
        }
    }
}

/// The encoding a render should use: the menu's explicit choice, or on Auto whatever colourspace
/// the host tagged the frame with. A present but unknown tag is an error: guessing changes scene
/// exposure by stops. Only an absent tag takes the Rec.709 compatibility path for pre-1.5 hosts.
fotufilm::Encoding resolveEncoding(Instance *instance, OfxImageEffectHandle effect,
                                  OfxPropertySetHandle sourceImage, int choice) {
    if (menuEncoding(choice) != fotufilm::Encoding::Count) {
        return menuEncoding(choice);
    }
    char *name = nullptr;
    if (gProperty->propGetString(sourceImage, kOfxImageClipPropColourspace, 0,
                                 &name) != kOfxStatOK || !name || !*name) {
        name = nullptr;
        OfxPropertySetHandle clip = nullptr;
        if (gEffect->clipGetPropertySet(instance->sourceClip, &clip) == kOfxStatOK) {
            gProperty->propGetString(clip, kOfxImageClipPropColourspace, 0, &name);
        }
    }
    const fotufilm::Encoding mapped = fotufilm::encodingForColourspace(name);
    if (mapped != fotufilm::Encoding::Count) return mapped;

    if (name && *name && !isRawColourspace(name)) {
        post(kOfxMessageError, effect,
             "Timeline Color Space is Auto, but the host calls this clip \"%s\". "
             "Fotufilm cannot decode that tag directly. Choose one of the manually "
             "supported spaces: Rec.709 / Gamma 2.4, sRGB, DaVinci Wide Gamut / "
             "Intermediate, ACEScct, ACEScg, Linear Rec.709, Linear Display P3, or "
             "Linear Rec.2020; "
             "or configure the host to transform the source before this node.", name);
        return fotufilm::Encoding::Count;
    }

    const fotufilm::Encoding fallback = isRawColourspace(name)
        ? rawFallback(name)
        : fotufilm::Encoding::Rec709Gamma24;
    if (!instance->warnedLegacyFallback) {
        instance->warnedLegacyFallback = true;
        if (isRawColourspace(name)) {
            report("Timeline Color Space is Auto and Resolve labels this colour input Raw; "
                   "using the %s compatibility fallback",
                   fotufilm::encodingLabel(fallback));
        } else {
            report("Timeline Color Space is Auto and this host supplies no OFX colour tag; "
                   "using the legacy %s fallback", fotufilm::encodingLabel(fallback));
        }
    }
    return fallback;
}

/// Everything `writeDevelopedRows` needs to place engine rows into the host's image.
struct WriteState {
    const Image *source, *output;
    OfxRectI window;
    int processWidth;
    fotufilm::Encoding encoding;
    const fotufilm::Transform *transform;
    bool premultiplied;
    /// Copy rows without further conversion. Used when the kernel applied the output transform or
    /// when a stage returns density data. Disabled during resampling, which must average linear light.
    bool verbatim;
};

/// One strip of finished rows, as handed over by the bridge.
struct StripState {
    const WriteState *write;
    const float *rows;
    int32_t stripBegin;
};

/// Writes the part of each row in [begin, end) that the render window and both images agree on,
/// encoded back to the timeline's space. Runs on whatever threads forRows provides.
void writeStripRows(int begin, int end, void *context) {
    const StripState &strip = *static_cast<const StripState *>(context);
    const WriteState &state = *strip.write;
    const int sourceWidth = state.source->width();
    for (int r = begin; r < end; ++r) {
        const int y = state.source->bounds.y2 - 1 - r;
        if (y < state.window.y1 || y >= state.window.y2) continue;
        if (y < state.output->bounds.y1 || y >= state.output->bounds.y2) continue;
        const int x1 = std::max(state.window.x1,
                                std::max(state.source->bounds.x1, state.output->bounds.x1));
        const int x2 = std::min(state.window.x2,
                                std::min(state.source->bounds.x2, state.output->bounds.x2));
        if (x2 <= x1) continue;

        float *span = state.output->row(y) +
                      static_cast<ptrdiff_t>(x1 - state.output->bounds.x1) * 4;
        const float *processed = strip.rows +
            static_cast<size_t>(r - strip.stripBegin) * state.processWidth * 4;
        if (state.processWidth == sourceWidth) {
            const float *from =
                processed + static_cast<size_t>(x1 - state.source->bounds.x1) * 4;
            if (state.verbatim) {
                std::memcpy(span, from,
                            static_cast<size_t>(x2 - x1) * 4 * sizeof(float));
            } else {
                // Straight from the engine's rows into the host's image: the matrix, the transfer
                // encode and the re-premultiplication are one pass, where copying the span first
                // and then walking it three more times was four.
                fotufilm::encodePixels(state.encoding, *state.transform, from, span, x2 - x1,
                                      state.premultiplied);
            }
        } else {
            for (int x = x1; x < x2; ++x) {
                const int destination = x - x1;
                const int sourceX = x - state.source->bounds.x1;
                const float position =
                    (static_cast<float>(sourceX) + 0.5f) * state.processWidth /
                        sourceWidth -
                    0.5f;
                const int left = std::max(0, std::min(
                    state.processWidth - 1, static_cast<int>(std::floor(position))));
                const int right = std::min(left + 1, state.processWidth - 1);
                const float mix = std::max(0.0f, std::min(1.0f, position - left));
                for (int channel = 0; channel < 4; ++channel) {
                    const float a = processed[left * 4 + channel];
                    const float b = processed[right * 4 + channel];
                    span[destination * 4 + channel] = a + (b - a) * mix;
                }
            }
            // Resampled in place, then encoded in place over the same span.
            fotufilm::encodePixels(state.encoding, *state.transform, span, span, x2 - x1,
                                  state.premultiplied);
        }
    }
}

/// Receives finished rows from the bridge and fans the encode across the host's threads.
void writeDevelopedRows(void *context, int32_t begin, int32_t end, const float *rows) {
    StripState strip{static_cast<const WriteState *>(context), rows, begin};
    forRows(begin, end, writeStripRows, &strip);
}

int32_t hostWantsMore(void *context) {
    return gEffect->abort(static_cast<OfxImageEffectHandle>(context)) ? 0 : 1;
}

/// Everything the decode needs to turn host rows into scene-linear engine input.
struct DecodeState {
    const Image *source;
    float *frame;
    int sourceWidth;
    int processWidth;
    bool premultiplied;
    fotufilm::Encoding encoding;
    const fotufilm::Transform *transform;
    bool watchRange;
    std::atomic<float> *peak;
    std::atomic<bool> *repaired;
};

/// Decodes rows [begin, end) out of the host's image and into the engine's input, scanning for the
/// over-range peak on the way past. Runs on whatever threads forRows provides, so the peak merges
/// through a CAS.
void decodeRows(int begin, int end, void *context) {
    const DecodeState &state = *static_cast<const DecodeState *>(context);
    const bool resampling = state.processWidth != state.sourceWidth;
    // Non-square host pixels are normalized onto a square grid before any spatial film stage, and
    // the decode runs first so that transfer-encoded values are never averaged. One scratch row
    // for this whole slice of the frame holds that decode: every output pixel then reads already
    // decoded neighbours, where decoding them per output pixel decoded most of the row twice
    // over.
    std::vector<float> scratch;
    if (resampling) scratch.resize(static_cast<size_t>(state.sourceWidth) * 4);

    bool clean = true;
    float peak = 0.0f;
    for (int row = begin; row < end; ++row) {
        const float *in = state.source->row(state.source->bounds.y2 - 1 - row);
        float *out = state.frame + static_cast<size_t>(row) * state.processWidth * 4;
        float *decoded = resampling ? scratch.data() : out;
        const fotufilm::DecodeReport report = fotufilm::decodePixels(
            state.encoding, *state.transform, in, decoded, state.sourceWidth,
            state.premultiplied, state.watchRange);
        if (!report.clean) clean = false;
        peak = std::max(peak, report.peak);
        if (resampling && !fotufilm::resampleRow(decoded, state.sourceWidth, out,
                                                state.processWidth)) {
            clean = false;
        }
    }
    if (!clean) state.repaired->store(true, std::memory_order_relaxed);
    if (state.watchRange) {
        float seen = state.peak->load(std::memory_order_relaxed);
        while (peak > seen && !state.peak->compare_exchange_weak(
                                  seen, peak, std::memory_order_relaxed)) {
        }
    }
}

/// What the copy the device decode replaces the host walk with needs. `origin` is the frame row
/// `scratch` begins at, so a band lands at its own start rather than the frame's.
struct CopyState {
    const Image *source;
    float *scratch;
    int width;
    int origin;
};

/// Copies rows [begin, end) of the host's image into `scratch` in the layout the engine wants:
/// tightly packed, top row first, nothing else touched. The host's own rows are bottom-up and may
/// be strided, which is the whole of what this straightens out.
void copyRows(int begin, int end, void *context) {
    const CopyState &state = *static_cast<const CopyState *>(context);
    const size_t rowBytes = static_cast<size_t>(state.width) * 4 * sizeof(float);
    for (int row = begin; row < end; ++row) {
        std::memcpy(
            state.scratch + static_cast<size_t>(row - state.origin) * state.width * 4,
            state.source->row(state.source->bounds.y2 - 1 - row), rowBytes);
    }
}

/// Rows of a `width`-wide frame that a decode band may hold. Halide takes a band of host memory
/// across the device boundary and back, so the band is what the decode asks the device for, and a
/// frame with no staging to decode into is a frame on a machine with little to spare. Sixteen
/// megabytes is small enough not to matter on any machine that has a GPU at all, and large enough
/// that the per-call overhead disappears against the pixels.
///
/// `FOTUFILM_DECODE_BAND_BYTES` overrides it. Every frame small enough to check by hand is small
/// enough to decode in one band, so without this the multi-band path — and the row arithmetic that
/// puts each band where it belongs — could only be exercised on frames nothing could verify.
/// `FOTUFILM_STRIP_BUDGET` exists for the same reason one layer down.
int decodeBandRows(int width) {
    long long budget = 16 << 20;
    if (const char *override = std::getenv("FOTUFILM_DECODE_BAND_BYTES")) {
        const long long asked = std::atoll(override);
        if (asked > 0) budget = asked;
    }
    return static_cast<int>(std::max<long long>(1, budget / std::max(1, width * 16)));
}

/// Decodes a frame in device bands. Returns false without guaranteeing `scene` if any band fails.
/// `peak` and `repaired` aggregate results across all bands.
bool decodeThroughKernel(const Image &source, float *scene, int width, int height,
                         const FotufilmInputTransform &transform, std::vector<float> &scratch,
                         float &peak, bool &repaired) {
    const int bandRows = decodeBandRows(width);
    scratch.resize(static_cast<size_t>(bandRows) * width * 4);
    for (int begin = 0; begin < height; begin += bandRows) {
        const int end = std::min(height, begin + bandRows);
        CopyState copyState{&source, scratch.data(), width, begin};
        forRows(begin, end, copyRows, &copyState);
        float bandPeak = 0;
        int32_t bandRepaired = 0;
        if (fotufilm_bridge_decode_rows(
                scratch.data(), scene + static_cast<size_t>(begin) * width * 4, width,
                end - begin, &transform, &bandPeak, &bandRepaired) != 1) {
            return false;
        }
        peak = std::max(peak, bandPeak);
        if (bandRepaired) repaired = true;
    }
    return true;
}

OfxStatus render(OfxImageEffectHandle effect, OfxPropertySetHandle inArgs) {
    const auto renderBegan = Profile::now();
    Instance *instance = instanceOf(effect);
    if (!instance) return kOfxStatErrBadHandle;
    // Held for the whole body. `purgeCaches` frees the decoded frame, the decode band and the
    // engine's staging, and everything below holds raw pointers into them; see the lock's own
    // comment. Per instance, so it costs a second node nothing.
    std::lock_guard<std::mutex> renderHeld(instance->renderLock);

    OfxTime time = 0;
    gProperty->propGetDouble(inArgs, kOfxPropTime, 0, &time);
    OfxRectI renderWindow = {0, 0, 0, 0};
    gProperty->propGetIntN(inArgs, kOfxImageEffectPropRenderWindow, 4, &renderWindow.x1);

    Image source, output;
    std::string refused;
    // Once per node through the host, every frame to stderr, exactly as the engine-error path
    // does it: what makes a fetch fail is a property of the clip, not of the frame, so a
    // thousand-frame delivery of a misconfigured timeline would otherwise raise a thousand
    // dialogs. Cleared below when a fetch succeeds, so a later change warns once more.
    auto refuse = [&](const char *which) {
        if (instance->postedFetchError) {
            report("Fotufilm cannot render: %s for the %s clip", refused.c_str(), which);
        } else {
            instance->postedFetchError = true;
            post(kOfxMessageError, effect, "Fotufilm cannot render: %s for the %s clip",
                 refused.c_str(), which);
        }
        return kOfxStatFailed;
    };
    if (!fetch(instance->outputClip, time, output, refused)) {
        return refuse("output");
    }
    if (!fetch(instance->sourceClip, time, source, refused)) {
        gEffect->clipReleaseImage(output.handle);
        return refuse("source");
    }
    instance->postedFetchError = false;
    struct Release {
        Image &source, &output;
        ~Release() {
            gEffect->clipReleaseImage(source.handle);
            gEffect->clipReleaseImage(output.handle);
        }
    } release{source, output};

    if (!gEngineReady) {
        // Through the host once per node — the reason the panel already shows — and to stderr
        // every frame. A delivery of a thousand frames should not raise a thousand dialogs.
        const char *message = gInitializationError.empty()
            ? "the engine is not available" : gInitializationError.c_str();
        if (instance->postedEngineError) {
            report("Fotufilm cannot render: %s", message);
        } else {
            instance->postedEngineError = true;
            post(kOfxMessageError, effect, "Fotufilm cannot render: %s", message);
        }
        return kOfxStatFailed;
    }

    const int width = source.width();
    const int height = source.height();
    if (width <= 0 || height <= 0) return kOfxStatFailed;
    const double pixelAspect = pixelAspectRatio(instance->sourceClip);
    const int processWidth = squarePixelWidth(width, pixelAspect);
    if (processWidth <= 0) {
        post(kOfxMessageError, effect,
             "Fotufilm cannot normalize the source pixel aspect ratio %.6g", pixelAspect);
        return kOfxStatFailed;
    }

    float parameters[FOTUFILM_BRIDGE_PARAMETER_COUNT] = {};
    readParameters(instance, time, parameters);
    if (!std::isfinite(time)) {
        post(kOfxMessageError, effect, "Fotufilm received a non-finite frame time");
        return kOfxStatFailed;
    }
    for (float parameter : parameters) {
        if (!std::isfinite(parameter)) {
            post(kOfxMessageError, effect,
                 "Fotufilm received a non-finite parameter value");
            return kOfxStatFailed;
        }
    }
    int stock = 0, format = 0, paper = 0, space = 0, seed = 0;
    if (instance->stock) gParameter->paramGetValueAtTime(instance->stock, time, &stock);
    if (instance->format) gParameter->paramGetValueAtTime(instance->format, time, &format);
    if (instance->paper) gParameter->paramGetValueAtTime(instance->paper, time, &paper);
    if (instance->colorSpace) {
        gParameter->paramGetValueAtTime(instance->colorSpace, time, &space);
    }
    if (instance->seed) gParameter->paramGetValueAtTime(instance->seed, time, &seed);
    stock = effectiveChoice(instance->stockID, gStockIDs, stock, time);
    format = effectiveChoice(instance->formatID, gFormatIDs, format, time);
    paper = effectiveChoice(instance->paperID, gPaperIDs, paper, time);

    // Which span of the pipeline this node is. `readParameters` has already resolved it through
    // its persisted id and written it into the block the engine reads.
    const int stage = static_cast<int>(parameters[FOTUFILM_BRIDGE_STAGE]);
    const bool readsInterchange = stage == FOTUFILM_BRIDGE_STAGE_PRINT;
    const bool writesInterchange = stage == FOTUFILM_BRIDGE_STAGE_NEGATIVE;
    const bool deliversSceneBasis = stage == FOTUFILM_BRIDGE_STAGE_TEXTURE;
    const char *const stageLabel = stage >= 0 && stage < static_cast<int>(gStageLabels.size())
        ? gStageLabels[stage].c_str() : "this stage";
    // Texture Only on a node whose per-stage toggles were never described. The selection reads as
    // zero, and zero is the pass-through — so developing the frame here would quietly deliver the
    // input under a span the user asked to do something. Refuse it and say what to do instead.
    if (stage == FOTUFILM_BRIDGE_STAGE_TEXTURE && textureStagesMissing(instance)) {
        const char *const message =
            "Fotufilm's Texture Only stage cannot read which spatial stages it was asked for: "
            "the engine started after Resolve built this node's panel, so the per-stage toggles "
            "are not on it. Restart Resolve and the node will render.";
        if (instance->postedTextureRestart) {
            report("%s", message);
        } else {
            instance->postedTextureRestart = true;
            post(kOfxMessageError, effect, "%s", message);
        }
        return kOfxStatFailed;
    }
    // The interchange is per-layer density, and averaging densities is not averaging the light a
    // negative passes. So neither half of the split will normalise a non-square pixel: there is
    // nowhere in this span to do it that would be right.
    if ((readsInterchange || writesInterchange) && processWidth != width) {
        post(kOfxMessageError, effect,
             "Fotufilm's %s stage cannot normalise a pixel aspect ratio of %.6g. The "
             "developed negative it carries is density rather than light, and resampling "
             "it would not be resampling the picture. Unsqueeze before this node, or use "
             "the Full stage on an anamorphic clip.", stageLabel, pixelAspect);
        return kOfxStatFailed;
    }

    // Valid menu indices run 0..Count: the encodings around the Auto slot plus Auto itself.
    if (space < 0 || space > static_cast<int>(fotufilm::Encoding::Count)) {
        space = kColorSpaceAuto;
    }
    // Print Only receives density data, so Auto cannot infer the output colour space from the input.
    if (readsInterchange && menuEncoding(space) == fotufilm::Encoding::Count) {
        post(kOfxMessageError, effect,
             "Fotufilm's Print Only stage needs Timeline Color Space set explicitly. What "
             "arrives at this node is a developed negative — density, not colour — so there "
             "is no tag on it saying what space the finished print should be encoded into. "
             "Set it to the space this timeline works in.");
        return kOfxStatFailed;
    }
    const fotufilm::Encoding encoding =
        resolveEncoding(instance, effect, source.handle, space);
    if (encoding == fotufilm::Encoding::Count) return kOfxStatFailed;
    const fotufilm::Transform transform = fotufilm::transformFor(encoding);
    // Texture output remains in the scene working space, so invert the input basis for output.
    fotufilm::Transform outputBasis = transform;
    if (deliversSceneBasis) {
        std::memcpy(outputBasis.fromWorking, transform.fromScene,
                    sizeof(outputBasis.fromWorking));
    }
    const bool premultiplied = isPremultiplied(instance->sourceClip);

    // A display-referred space stops at 1.0; scene-referred data does not. Input well above
    // 1.0 under an sRGB or Rec.709 label is therefore a provable misconfiguration — the one
    // colour space mistake the plugin can catch rather than merely document. The 1.05
    // threshold leaves room for codec ringing, which overshoots white by a hair.
    const bool displayReferred = encoding == fotufilm::Encoding::Rec709Gamma24 ||
                                 encoding == fotufilm::Encoding::SRGB;
    // Only ever asked of scene light. A Print Only node is handed densities, which run well past
    // 1.0 by construction and would trip this on every frame.
    const bool watchRange = displayReferred && !readsInterchange
        && !instance->warnedOverRange;
    std::atomic<float> peak{0.0f};
    std::atomic<bool> repairedInput{false};

    // Resolve's render-status properties are useful diagnostics even though realtime arithmetic
    // is now uniform across viewer and delivery frames. The sequence bracket is deliberately not
    // part of this classification: Resolve opens one around viewer refreshes as well as delivery.
    int interactiveStatus = 0, sequentialStatus = 0, draftQuality = 0;
    gProperty->propGetInt(inArgs, kOfxImageEffectPropInteractiveRenderStatus, 0,
                          &interactiveStatus);
    gProperty->propGetInt(inArgs, kOfxImageEffectPropSequentialRenderStatus, 0,
                          &sequentialStatus);
    gProperty->propGetInt(inArgs, kOfxImageEffectPropRenderQualityDraft, 0, &draftQuality);
    const double announcedFrames =
        instance->inSequenceRender
            ? instance->sequenceRange[1] - instance->sequenceRange[0] + 1
            : 0;
    double renderScale[2] = {1, 1};
    gProperty->propGetDoubleN(inArgs, kOfxImageEffectPropRenderScale, 2, renderScale);
    // Positive evidence only; silence remains labelled as delivery in diagnostics.
    const bool viewerFrame =
        (interactiveStatus == 1 || draftQuality == 1) && sequentialStatus != 1;

    // The engine lends its own GPU-resident staging for a frame it can develop in one pass.
    // Decoding straight into that is the same traversal as decoding into a vector of our own, and
    // it saves the engine copying the whole frame onto the device and the whole result back off
    // it — at UHD, more time than the film model itself takes.
    float *stagedInput = nullptr, *stagedOutput = nullptr;
    const bool staged =
        fotufilm_bridge_frame_staging(instance->bridge, processWidth, height,
                                     &stagedInput, &stagedOutput) == 1;
    // The developed staging remains borrowed until the host has copied it below. It must also be
    // returned on every early exit after decode, including an abort before the engine runs.
    struct StagingRelease {
        FotufilmBridgeContext context;
        bool active;
        ~StagingRelease() {
            if (active) fotufilm_bridge_release_staging(context);
        }
    } releaseStaging{instance->bridge, staged};
    float *scene = stagedInput;
    if (!staged) {
        instance->frame.resize(static_cast<size_t>(processWidth) * height * 4);
        scene = instance->frame.data();
    }

    // Once per instance, name the path the host and the engine actually chose — the only way
    // anyone outside this function can know whether either handshake happened.
    if (!instance->reportedFramePath) {
        instance->reportedFramePath = true;
        report("CPU host frames, %s%s", staged ? "developed in engine staging"
                                               : "streamed through the engine",
               processWidth == width ? "" : ", square-pixel normalized");
    }
    const int renderStatus = interactiveStatus * 8 + sequentialStatus * 4 +
                             draftQuality * 2 + (instance->inSequenceRender ? 1 : 0);
    if (renderStatus != instance->lastRenderStatus) {
        instance->lastRenderStatus = renderStatus;
        report("host says sequence=%d span=%.0f scale=%.4g size=%dx%d interactive=%d "
               "sequential=%d draft=%d -> %s frame",
               instance->inSequenceRender ? 1 : 0, announcedFrames, renderScale[0],
               processWidth, height, interactiveStatus, sequentialStatus, draftQuality,
               viewerFrame ? "viewer" : "delivered");
    }

    // Run pointwise decoding in the kernel for both staged and striped paths so memory-dependent
    // path selection cannot change output. Resampling decodes on the host because it must average
    // linear light. GPU and host transcendental implementations may differ by a few parts in 10^7.
    const fotufilm::InputTransform inputCurve = fotufilm::inputTransformFor(encoding);
    FotufilmInputTransform inputTransform{};
    inputTransform.transfer = inputCurve.shape;
    inputTransform.premultiplied = premultiplied ? 1 : 0;
    std::memcpy(inputTransform.matrix, transform.toWorking, sizeof(inputTransform.matrix));
    std::memcpy(inputTransform.coefficients, inputCurve.coefficients,
                sizeof(inputTransform.coefficients));

    const auto decodeBegan = Profile::now();
    bool decodedOnDevice = false;
    if (readsInterchange) {
        // Nothing to decode: what arrived is the developed negative's densities, and the only
        // thing between the host's image and the engine is the layout — the host's rows are
        // bottom-up and may be strided. Alpha rides along with them, as it did on the way in to
        // the node that made them.
        CopyState copyState{&source, scene, width, 0};
        forRows(0, height, copyRows, &copyState);
    } else if (processWidth == width) {
        float devicePeak = 0;
        bool deviceRepaired = false;
        if (staged) {
            // The staging's output is the scratch: frame-sized, idle until the render fills it,
            // and overwritten by the render regardless. Decoding the input buffer over itself
            // instead would leave the peak depending on whether the kernel writing the scene ran
            // before the kernel reading the host's own numbers.
            CopyState copyState{&source, stagedOutput, width, 0};
            forRows(0, height, copyRows, &copyState);
            int32_t reportedRepair = 0;
            decodedOnDevice = fotufilm_bridge_decode_staged(
                instance->bridge, processWidth, height, &inputTransform,
                &devicePeak, &reportedRepair) == 1;
            deviceRepaired = reportedRepair != 0;
        } else {
            decodedOnDevice = decodeThroughKernel(source, scene, width, height, inputTransform,
                                                  instance->decodeScratch, devicePeak,
                                                  deviceRepaired);
        }
        if (decodedOnDevice) {
            if (watchRange) peak.store(devicePeak, std::memory_order_relaxed);
            if (deviceRepaired) repairedInput.store(true, std::memory_order_relaxed);
        }
    }
    if (!decodedOnDevice && !readsInterchange) {
        // The device was asked and refused — as distinct from the resampling path, which never
        // asks. The host's threads decode the same arithmetic, so the frame is right, but its
        // transcendentals are libm's rather than Metal's and the frame is a few parts in ten
        // million from the one the device would have made. Worth one message: a node that has
        // silently changed decoders is not the same node it was.
        if (processWidth == width && !instance->warnedHostDecodeFallback) {
            instance->warnedHostDecodeFallback = true;
            char message[512] = "";
            fotufilm_bridge_last_error(instance->bridge, message, sizeof(message));
            post(kOfxMessageWarning, effect,
                 "Fotufilm's engine could not decode this frame on the GPU%s%s; the host's "
                 "threads are decoding it instead. The picture is correct, but a few parts in "
                 "ten million from the GPU's.", message[0] ? ": " : "", message);
        }
        DecodeState decodeState{&source,      scene,       width,      processWidth,
                                premultiplied, encoding,   &transform, watchRange,
                                &peak,        &repairedInput};
        forRows(0, height, decodeRows, &decodeState);
    }
    const auto decodeEnded = Profile::now();
    if (!instance->reportedDecodePath) {
        instance->reportedDecodePath = true;
        report("decode %s", readsInterchange ? "not needed — the input is a developed negative"
                            : decodedOnDevice ? "in the engine's kernel"
                                              : "on the host's threads");
    }
    if (repairedInput.load(std::memory_order_relaxed) &&
        !instance->warnedNonFiniteInput) {
        instance->warnedNonFiniteInput = true;
        report("Resolve supplied NaN or infinity; Fotufilm repaired invalid RGB to black "
               "and invalid alpha to opaque. Check source decoding, proxies/cache, or "
               "upstream nodes; changing Fotufilm's colour-space setting will not repair "
               "non-finite pixels");
    }
    if (watchRange && peak.load(std::memory_order_relaxed) > 1.05f) {
        instance->warnedOverRange = true;
        post(kOfxMessageWarning, effect,
             "The input reaches %.2f, but it is being decoded as %s — a display-referred "
             "space that ends at 1.0. The colour space setting is probably wrong for this "
             "timeline; set it to the space actually arriving at the node.",
             peak.load(std::memory_order_relaxed), fotufilm::encodingLabel(encoding));
    }

    if (gEffect->abort(effect)) return kOfxStatOK;

    // Apply output basis, transfer, and premultiplication in the kernel when possible. Resampling
    // must instead average linear light, and density output cannot use a transfer curve. Query
    // before rendering because striped rows are written as soon as they are developed.
    //
    // Asked for the road this frame is actually taking. The viewer flag changes which kernel a
    // staged render asks for — the one that measures its own glare — and a striped render never
    // measures that way, so a striped frame is asked about as a delivered one whatever the host
    // said about the session. The bridge checks the same thing against the staging it holds, so
    // the two cannot be asked different questions.
    const bool encodeInKernel =
        !writesInterchange && processWidth == source.width()
        && fotufilm_bridge_encodes_output(instance->bridge, stock, format, paper,
                                         parameters, processWidth, height,
                                         (staged && viewerFrame) ? 1 : 0) != 0;
    const fotufilm::OutputTransform curve = fotufilm::outputTransformFor(encoding);
    FotufilmOutputTransform outputTransform{};
    outputTransform.transfer = curve.shape;
    outputTransform.premultiplied = premultiplied ? 1 : 0;
    std::memcpy(outputTransform.matrix, outputBasis.fromWorking,
                sizeof(outputTransform.matrix));
    std::memcpy(outputTransform.coefficients, curve.coefficients,
                sizeof(outputTransform.coefficients));

    WriteState state{&source, &output, renderWindow, processWidth, encoding,
                     &outputBasis, premultiplied,
                     encodeInKernel || writesInterchange};

    // FOTUFILM_TRACE_BRIDGE: everything this plugin is about to hand the engine, in one line per
    // frame. The Final Cut plugin prints the same line in the same format, so two hosts developing
    // the same picture differently can be diffed as text rather than guessed at.
    if (std::getenv("FOTUFILM_TRACE_BRIDGE")) {
        std::string trace = "TRACE stock=" + std::to_string(stock) +
            " format=" + std::to_string(format) + " paper=" + std::to_string(paper) +
            " seed=" + std::to_string(static_cast<uint32_t>(seed)) +
            " frame=" + std::to_string(static_cast<uint64_t>(std::llround(time))) +
            " size=" + std::to_string(processWidth) + "x" + std::to_string(height) +
            " interactive=" + std::to_string(viewerFrame ? 1 : 0) +
            " staged=" + std::to_string(staged ? 1 : 0) +
            " encode=" + std::to_string(encodeInKernel ? 1 : 0);
        char number[64];
        trace += " params=";
        for (int i = 0; i < FOTUFILM_BRIDGE_PARAMETER_COUNT; ++i) {
            std::snprintf(number, sizeof(number), "%.9g,", parameters[i]);
            trace += number;
        }
        trace += " in.transfer=" + std::to_string(inputTransform.transfer) +
                 " in.premul=" + std::to_string(inputTransform.premultiplied) + " in.m=";
        for (float v : inputTransform.matrix) {
            std::snprintf(number, sizeof(number), "%.9g,", v); trace += number;
        }
        trace += " in.c=";
        for (float v : inputTransform.coefficients) {
            std::snprintf(number, sizeof(number), "%.9g,", v); trace += number;
        }
        trace += " out.transfer=" + std::to_string(outputTransform.transfer) +
                 " out.premul=" + std::to_string(outputTransform.premultiplied) + " out.m=";
        for (float v : outputTransform.matrix) {
            std::snprintf(number, sizeof(number), "%.9g,", v); trace += number;
        }
        trace += " out.c=";
        for (float v : outputTransform.coefficients) {
            std::snprintf(number, sizeof(number), "%.9g,", v); trace += number;
        }
        std::fprintf(stderr, "%s\n", trace.c_str());
    }
    int32_t developed = 0;
    const auto engineBegan = Profile::now();
    auto engineEnded = engineBegan;
    if (staged) {
        developed = fotufilm_bridge_render_staged(
            instance->bridge, stock, format, paper, parameters,
            static_cast<uint32_t>(seed), processWidth, height,
            static_cast<uint64_t>(std::llround(time)), viewerFrame ? 1 : 0,
            encodeInKernel ? &outputTransform : nullptr,
            hostWantsMore, effect);
        engineEnded = Profile::now();
        // A staged frame arrives whole rather than in strips, so it is written as one strip.
        if (developed > 0) writeDevelopedRows(&state, 0, height, stagedOutput);
    } else {
        developed = fotufilm_bridge_render(
            instance->bridge, stock, format, paper, parameters, static_cast<uint32_t>(seed),
            instance->frame.data(), processWidth, height,
            static_cast<uint64_t>(std::llround(time)),
            writeDevelopedRows, &state,
            encodeInKernel ? &outputTransform : nullptr, hostWantsMore, effect);
        // Streaming interleaves the encode with the develop, so the two cannot be told apart.
        engineEnded = Profile::now();
    }
    Profile::frame(renderBegan, decodeBegan, decodeEnded, engineBegan, engineEnded,
                   Profile::now(),
                   processWidth, height, staged, viewerFrame);
    if (developed < 0) return kOfxStatOK;  // The host aborted; it discards the frame.
    if (developed == 0) {
        char message[512] = "";
        fotufilm_bridge_last_error(instance->bridge, message, sizeof(message));
        post(kOfxMessageError, effect, "Fotufilm render failed: %s", message);
        return kOfxStatFailed;
    }
    return kOfxStatOK;
}

/// A delivery render announces itself here; compiling the schedule and uploading the stock's
/// spectral tables now moves that cost out of the first frame. Best effort in every direction —
/// a failure surfaces on the frame itself, with its error intact.
OfxStatus beginSequenceRender(OfxImageEffectHandle effect, OfxPropertySetHandle inArgs) {
    Instance *instance = instanceOf(effect);
    if (!instance) return kOfxStatOK;

    double range[2] = {0, 0};
    gProperty->propGetDoubleN(inArgs, kOfxImageEffectPropFrameRange, 2, range);
    // Recorded even when the engine is not ready, so the bracket cannot be left half-open.
    instance->inSequenceRender = true;
    instance->sequenceRange[0] = range[0];
    instance->sequenceRange[1] = range[1];
    instance->lastRenderStatus = -1;
    if (!gEngineReady) return kOfxStatOK;

    const OfxTime time = range[0];

    OfxRectD definition = {0, 0, 0, 0};
    if (gEffect->clipGetRegionOfDefinition(instance->sourceClip, time, &definition) !=
        kOfxStatOK) {
        return kOfxStatOK;
    }
    double renderScale[2] = {1, 1};
    gProperty->propGetDoubleN(inArgs, kOfxImageEffectPropRenderScale, 2, renderScale);
    if (!std::isfinite(renderScale[0]) || renderScale[0] <= 0) renderScale[0] = 1;
    if (!std::isfinite(renderScale[1]) || renderScale[1] <= 0) renderScale[1] = 1;
    // RoD is canonical. Convert to the square-pixel dimensions the engine will actually process:
    // canonical x already includes PAR, while y does not.
    const int width = static_cast<int>(std::llround(
        (definition.x2 - definition.x1) * renderScale[0]));
    const int height = static_cast<int>(std::llround(
        (definition.y2 - definition.y1) * renderScale[1]));
    if (width <= 0 || height <= 0) return kOfxStatOK;

    float parameters[FOTUFILM_BRIDGE_PARAMETER_COUNT] = {};
    readParameters(instance, time, parameters);
    int stock = 0, format = 0, paper = 0;
    if (instance->stock) gParameter->paramGetValueAtTime(instance->stock, time, &stock);
    if (instance->format) gParameter->paramGetValueAtTime(instance->format, time, &format);
    if (instance->paper) gParameter->paramGetValueAtTime(instance->paper, time, &paper);
    stock = effectiveChoice(instance->stockID, gStockIDs, stock, time);
    format = effectiveChoice(instance->formatID, gFormatIDs, format, time);
    paper = effectiveChoice(instance->paperID, gPaperIDs, paper, time);

    fotufilm_bridge_prepare(instance->bridge, stock, format, paper, parameters, width, height);
    return kOfxStatOK;
}

/// The one configuration that is a copy by construction: Texture Only with no stage selected
/// develops the frame twice with nothing between the two developments and applies their ratio,
/// which is one. Declared as the identity so the host passes the source through and skips the
/// decode, the two developments and the encode — and skips the round trip through the working
/// space, which on a display-referred timeline was the only thing the copy moved at all. Every
/// other span and selection changes the picture and answers the default.
OfxStatus isIdentity(OfxImageEffectHandle effect, OfxPropertySetHandle inArgs,
                     OfxPropertySetHandle outArgs) {
    Instance *instance = instanceOf(effect);
    if (!instance || !outArgs) return kOfxStatReplyDefault;
    // Except where the selection could not be read at all: a panel described before the engine
    // came up has no toggles on it, and the zero that reads back is not the user asking for
    // nothing. Answering the default sends the host to the render, which refuses and says so.
    if (textureStagesMissing(instance)) return kOfxStatReplyDefault;
    OfxTime time = 0;
    if (inArgs) gProperty->propGetDouble(inArgs, kOfxPropTime, 0, &time);

    // Two values, read for themselves. The host asks this of every node on every frame it is
    // about to render, and reading the whole parameter block for it is twenty-nine round trips
    // through the host's suite plus four id lookups, none of which changes the answer to "is
    // this a texture span with nothing selected".
    if (effectiveStage(instance, time) != FOTUFILM_BRIDGE_STAGE_TEXTURE ||
        textureSelection(instance, time) != 0) {
        return kOfxStatReplyDefault;
    }
    gProperty->propSetString(outArgs, kOfxPropName, 0, kOfxImageEffectSimpleSourceClipName);
    gProperty->propSetDouble(outArgs, kOfxPropTime, 0, time);
    return kOfxStatOK;
}

/// Hands back what the instance was keeping between frames: the decoded frame and decode band
/// of a striped render, and the engine's staging if a frame left it borrowed. All of it is
/// reclaimed on the next render, so a purge costs that frame an allocation and nothing else.
OfxStatus purgeCaches(OfxImageEffectHandle effect) {
    Instance *instance = instanceOf(effect);
    if (!instance) return kOfxStatOK;
    // A render of this instance may be in flight on another thread with raw pointers into all
    // three of these. Wait for it: the frame costs milliseconds, and freeing under it costs the
    // host a crash.
    std::lock_guard<std::mutex> held(instance->renderLock);
    std::vector<float>().swap(instance->frame);
    std::vector<float>().swap(instance->decodeScratch);
    fotufilm_bridge_release_staging(instance->bridge);
    return kOfxStatOK;
}

OfxStatus mainEntry(const char *action, const void *handle,
                    OfxPropertySetHandle inArgs, OfxPropertySetHandle outArgs) {
    auto effect = reinterpret_cast<OfxImageEffectHandle>(const_cast<void *>(handle));
    if (std::strcmp(action, kOfxActionLoad) == 0) return load();
    if (std::strcmp(action, kOfxActionUnload) == 0) return unload();
    if (std::strcmp(action, kOfxActionDescribe) == 0) return describe(effect);
    if (std::strcmp(action, kOfxImageEffectActionDescribeInContext) == 0) {
        return describeInContext(effect);
    }
    if (std::strcmp(action, kOfxActionCreateInstance) == 0) return createInstance(effect);
    if (std::strcmp(action, kOfxActionDestroyInstance) == 0) return destroyInstance(effect);
    if (std::strcmp(action, kOfxActionInstanceChanged) == 0) {
        return instanceChanged(effect, inArgs);
    }
    if (std::strcmp(action, kOfxImageEffectActionGetClipPreferences) == 0) {
        return getClipPreferences(effect, outArgs);
    }
    if (std::strcmp(action, kOfxImageEffectActionGetOutputColourspace) == 0) {
        return getOutputColourspace(effect, outArgs);
    }
    if (std::strcmp(action, kOfxImageEffectActionBeginSequenceRender) == 0) {
        return beginSequenceRender(effect, inArgs);
    }
    if (std::strcmp(action, kOfxImageEffectActionEndSequenceRender) == 0) {
        if (Instance *instance = instanceOf(effect)) {
            instance->inSequenceRender = false;
            instance->lastRenderStatus = -1;
        }
        return kOfxStatOK;
    }
    if (std::strcmp(action, kOfxImageEffectActionRender) == 0) {
        return render(effect, inArgs);
    }
    if (std::strcmp(action, kOfxImageEffectActionIsIdentity) == 0) {
        return isIdentity(effect, inArgs, outArgs);
    }
    if (std::strcmp(action, kOfxActionPurgeCaches) == 0) return purgeCaches(effect);
    return kOfxStatReplyDefault;
}

void setHost(OfxHost *host) { gHost = host; }

OfxPlugin gPlugin = {
    kOfxImageEffectPluginApi,
    1,
    // Stable project identity: changing this makes existing Resolve timelines lose the effect.
    "com.fotufilm",
    // From project.yml's MARKETING_VERSION, by way of build.sh; see the defines at the top.
    // Parameter identity is unchanged since 1.1, and the major must stay 1 while it is.
    FOTUFILM_VERSION_MAJOR,
    FOTUFILM_VERSION_MINOR,
    setHost,
    mainEntry,
};

}

extern "C" {

OfxExport int OfxGetNumberOfPlugins(void) { return 1; }

OfxExport OfxPlugin *OfxGetPlugin(int nth) {
    return nth == 0 ? &gPlugin : nullptr;
}

}
