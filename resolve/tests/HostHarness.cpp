
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <dlfcn.h>
#include <stdlib.h>

#include "openfx/ofxImageEffect.h"
#include "openfx/ofxColour.h"
#include "openfx/ofxMessage.h"
#include "openfx/ofxMultiThread.h"
#include "FotufilmBridge.h"
#include "WorkingSpace.h"
#include "tests/ParityFrame.h"
#include "tests/TranscodeParity.h"

extern "C" {
int OfxGetNumberOfPlugins(void);
OfxPlugin *OfxGetPlugin(int nth);
}

namespace {
int (*gGetNumberOfPlugins)(void) = OfxGetNumberOfPlugins;
OfxPlugin *(*gGetPlugin)(int) = OfxGetPlugin;

bool gLinkedIn = true;

bool openBundle(const char *path) {
    void *handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    if (!handle) {
        std::printf("  FAIL dlopen(%s): %s\n", path, dlerror());
        return false;
    }
    auto count = reinterpret_cast<int (*)(void)>(dlsym(handle, "OfxGetNumberOfPlugins"));
    auto get = reinterpret_cast<OfxPlugin *(*)(int)>(dlsym(handle, "OfxGetPlugin"));
    if (!count || !get) {
        std::printf("  FAIL %s does not export OfxGetNumberOfPlugins/OfxGetPlugin\n",
                    path);
        return false;
    }
    gGetNumberOfPlugins = count;
    gGetPlugin = get;
    gLinkedIn = false;
    std::printf("  ok   dlopen(%s)\n", path);
    return true;
}
}

namespace {

int gFailures = 0;

void check(bool condition, const char *what) {
    std::printf("%s %s\n", condition ? "  ok  " : "  FAIL", what);
    if (!condition) ++gFailures;
}

struct PropertySet {
    std::map<std::string, std::vector<std::string>> strings;
    std::map<std::string, std::vector<double>> doubles;
    std::map<std::string, std::vector<int>> ints;
    std::map<std::string, std::vector<void *>> pointers;
};

std::vector<std::unique_ptr<PropertySet>> gPropertySets;

PropertySet *newPropertySet() {
    gPropertySets.push_back(std::make_unique<PropertySet>());
    return gPropertySets.back().get();
}

PropertySet *setOf(OfxPropertySetHandle handle) {
    return reinterpret_cast<PropertySet *>(handle);
}
OfxPropertySetHandle handleOf(PropertySet *set) {
    return reinterpret_cast<OfxPropertySetHandle>(set);
}

template <typename T>
void store(std::map<std::string, std::vector<T>> &into, const char *name,
           int index, const T &value) {
    auto &slot = into[name];
    if (static_cast<int>(slot.size()) <= index) slot.resize(index + 1);
    slot[index] = value;
}

/// A host that predates OFX 1.5, or does not know the clip-specific spelling of the preferred
/// colourspace property, refuses the write. The plugin has to take that as a declined request
/// rather than a failed action.
bool gRefusePreferredColourspace = false;
OfxStatus propSetString(OfxPropertySetHandle p, const char *n, int i, const char *v) {
    if (gRefusePreferredColourspace &&
        std::strncmp(n, kOfxImageClipPropPreferredColourspaces,
                     std::strlen(kOfxImageClipPropPreferredColourspaces)) == 0) {
        return kOfxStatErrUnsupported;
    }
    store(setOf(p)->strings, n, i, std::string(v));
    return kOfxStatOK;
}
OfxStatus propSetDouble(OfxPropertySetHandle p, const char *n, int i, double v) {
    store(setOf(p)->doubles, n, i, v);
    return kOfxStatOK;
}
OfxStatus propSetInt(OfxPropertySetHandle p, const char *n, int i, int v) {
    store(setOf(p)->ints, n, i, v);
    return kOfxStatOK;
}
OfxStatus propSetPointer(OfxPropertySetHandle p, const char *n, int i, void *v) {
    store(setOf(p)->pointers, n, i, v);
    return kOfxStatOK;
}

OfxStatus propGetString(OfxPropertySetHandle p, const char *n, int i, char **v) {
    auto found = setOf(p)->strings.find(n);
    if (found == setOf(p)->strings.end() || i >= static_cast<int>(found->second.size())) {
        return kOfxStatErrUnknown;
    }
    *v = const_cast<char *>(found->second[i].c_str());
    return kOfxStatOK;
}
OfxStatus propGetDouble(OfxPropertySetHandle p, const char *n, int i, double *v) {
    auto found = setOf(p)->doubles.find(n);
    if (found == setOf(p)->doubles.end() || i >= static_cast<int>(found->second.size())) {
        return kOfxStatErrUnknown;
    }
    *v = found->second[i];
    return kOfxStatOK;
}
OfxStatus propGetInt(OfxPropertySetHandle p, const char *n, int i, int *v) {
    auto found = setOf(p)->ints.find(n);
    if (found == setOf(p)->ints.end() || i >= static_cast<int>(found->second.size())) {
        return kOfxStatErrUnknown;
    }
    *v = found->second[i];
    return kOfxStatOK;
}
OfxStatus propGetPointer(OfxPropertySetHandle p, const char *n, int i, void **v) {
    auto found = setOf(p)->pointers.find(n);
    if (found == setOf(p)->pointers.end() || i >= static_cast<int>(found->second.size())) {
        *v = nullptr;
        return kOfxStatErrUnknown;
    }
    *v = found->second[i];
    return kOfxStatOK;
}
OfxStatus propGetIntN(OfxPropertySetHandle p, const char *n, int count, int *v) {
    for (int i = 0; i < count; ++i) {
        if (propGetInt(p, n, i, v + i) != kOfxStatOK) return kOfxStatErrUnknown;
    }
    return kOfxStatOK;
}
OfxStatus propGetDoubleN(OfxPropertySetHandle p, const char *n, int count, double *v) {
    for (int i = 0; i < count; ++i) {
        if (propGetDouble(p, n, i, v + i) != kOfxStatOK) return kOfxStatErrUnknown;
    }
    return kOfxStatOK;
}
OfxStatus propSetIntN(OfxPropertySetHandle p, const char *n, int count, const int *v) {
    for (int i = 0; i < count; ++i) store(setOf(p)->ints, n, i, v[i]);
    return kOfxStatOK;
}

OfxPropertySuiteV1 gPropertySuite = {};

struct Param {
    std::string type;
    PropertySet *properties = nullptr;
    double doubleValue = 0;
    int intValue = 0;
    std::string stringValue;
};

struct ParamSet {
    std::map<std::string, std::unique_ptr<Param>> params;
};

OfxStatus paramDefine(OfxParamSetHandle set, const char *type, const char *name,
                      OfxPropertySetHandle *properties) {
    auto *owner = reinterpret_cast<ParamSet *>(set);
    auto param = std::make_unique<Param>();
    param->type = type;
    param->properties = newPropertySet();
    if (properties) *properties = handleOf(param->properties);
    owner->params[name] = std::move(param);
    return kOfxStatOK;
}

/// Set only where a parameter is *meant* to be missing — a panel the host described before the
/// engine came up has no texture toggles on it, and asking for one is then the correct thing for
/// the plugin to do. Everywhere else an undefined parameter is a mistake and fails the run.
bool gAllowUndefinedParams = false;

OfxStatus paramGetHandle(OfxParamSetHandle set, const char *name,
                         OfxParamHandle *param, OfxPropertySetHandle *properties) {
    auto *owner = reinterpret_cast<ParamSet *>(set);
    auto found = owner->params.find(name);
    if (found == owner->params.end()) {
        if (!gAllowUndefinedParams) {
            std::printf("  FAIL the plugin asked for an undefined parameter: %s\n", name);
            ++gFailures;
        }
        *param = nullptr;
        return kOfxStatErrUnknown;
    }
    *param = reinterpret_cast<OfxParamHandle>(found->second.get());
    if (properties) *properties = handleOf(found->second->properties);
    return kOfxStatOK;
}

void readValue(Param *param, va_list arguments) {
    if (param->type == kOfxParamTypeDouble) {
        *va_arg(arguments, double *) = param->doubleValue;
    } else if (param->type == kOfxParamTypeString) {
        *va_arg(arguments, char **) = const_cast<char *>(param->stringValue.c_str());
    } else {
        *va_arg(arguments, int *) = param->intValue;
    }
}

void writeValue(Param *param, va_list arguments) {
    if (param->type == kOfxParamTypeDouble) {
        param->doubleValue = va_arg(arguments, double);
    } else if (param->type == kOfxParamTypeString) {
        const char *value = va_arg(arguments, char *);
        param->stringValue = value ? value : "";
    } else {
        param->intValue = va_arg(arguments, int);
    }
}

OfxStatus paramGetValue(OfxParamHandle handle, ...) {
    va_list arguments;
    va_start(arguments, handle);
    readValue(reinterpret_cast<Param *>(handle), arguments);
    va_end(arguments);
    return kOfxStatOK;
}

OfxStatus paramGetValueAtTime(OfxParamHandle handle, OfxTime time, ...) {
    va_list arguments;
    va_start(arguments, time);
    readValue(reinterpret_cast<Param *>(handle), arguments);
    va_end(arguments);
    return kOfxStatOK;
}

OfxStatus paramGetPropertySet(OfxParamHandle handle, OfxPropertySetHandle *out) {
    if (!handle || !out) return kOfxStatErrBadHandle;
    *out = handleOf(reinterpret_cast<Param *>(handle)->properties);
    return kOfxStatOK;
}

OfxStatus paramSetValue(OfxParamHandle handle, ...) {
    va_list arguments;
    va_start(arguments, handle);
    writeValue(reinterpret_cast<Param *>(handle), arguments);
    va_end(arguments);
    return kOfxStatOK;
}

OfxStatus propReset(OfxPropertySetHandle handle, const char *name) {
    auto *properties = setOf(handle);
    properties->strings.erase(name);
    properties->ints.erase(name);
    properties->doubles.erase(name);
    properties->pointers.erase(name);
    return kOfxStatOK;
}

OfxParameterSuiteV1 gParameterSuite = {};

struct Clip {
    PropertySet *properties = nullptr;
    PropertySet *image = nullptr;
    std::vector<float> pixels;
};

struct Effect {
    PropertySet *properties = nullptr;
    ParamSet params;
    std::map<std::string, std::unique_ptr<Clip>> clips;
};

OfxStatus getPropertySet(OfxImageEffectHandle effect, OfxPropertySetHandle *out) {
    *out = handleOf(reinterpret_cast<Effect *>(effect)->properties);
    return kOfxStatOK;
}

OfxStatus getParamSet(OfxImageEffectHandle effect, OfxParamSetHandle *out) {
    *out = reinterpret_cast<OfxParamSetHandle>(&reinterpret_cast<Effect *>(effect)->params);
    return kOfxStatOK;
}

OfxStatus clipDefine(OfxImageEffectHandle effect, const char *name,
                     OfxPropertySetHandle *properties) {
    auto *owner = reinterpret_cast<Effect *>(effect);
    auto clip = std::make_unique<Clip>();
    clip->properties = newPropertySet();
    if (properties) *properties = handleOf(clip->properties);
    owner->clips[name] = std::move(clip);
    return kOfxStatOK;
}

OfxStatus clipGetHandle(OfxImageEffectHandle effect, const char *name,
                        OfxImageClipHandle *clip, OfxPropertySetHandle *properties) {
    auto *owner = reinterpret_cast<Effect *>(effect);
    auto found = owner->clips.find(name);
    if (found == owner->clips.end()) return kOfxStatErrUnknown;
    *clip = reinterpret_cast<OfxImageClipHandle>(found->second.get());
    if (properties) *properties = handleOf(found->second->properties);
    return kOfxStatOK;
}

OfxStatus clipGetPropertySet(OfxImageClipHandle clip, OfxPropertySetHandle *out) {
    *out = handleOf(reinterpret_cast<Clip *>(clip)->properties);
    return kOfxStatOK;
}

OfxStatus clipGetImage(OfxImageClipHandle clip, OfxTime, const OfxRectD *,
                       OfxPropertySetHandle *image) {
    *image = handleOf(reinterpret_cast<Clip *>(clip)->image);
    return kOfxStatOK;
}

OfxStatus clipReleaseImage(OfxPropertySetHandle) { return kOfxStatOK; }

OfxStatus clipGetRegionOfDefinition(OfxImageClipHandle clip, OfxTime, OfxRectD *bounds) {
    Clip *owner = reinterpret_cast<Clip *>(clip);
    if (!owner->image || !bounds) return kOfxStatErrBadHandle;
    int stored[4] = {0, 0, 0, 0};
    if (propGetIntN(handleOf(owner->image), kOfxImagePropBounds, 4, stored) != kOfxStatOK) {
        return kOfxStatErrUnknown;
    }
    bounds->x1 = stored[0];
    bounds->y1 = stored[1];
    bounds->x2 = stored[2];
    bounds->y2 = stored[3];
    return kOfxStatOK;
}

int gAbortAfter = -1;
int gAbortCalls = 0;
/// Run once, on the render thread, the first time the plugin asks the host whether to keep going
/// — which is to say from inside `render`, with whatever the render is holding still live. It is
/// the only place the harness can stand while a render is genuinely in flight.
void (*gAbortHook)() = nullptr;
int effectAbort(OfxImageEffectHandle) {
    ++gAbortCalls;
    if (gAbortHook) {
        void (*hook)() = gAbortHook;
        gAbortHook = nullptr;
        hook();
    }
    return gAbortAfter >= 0 && gAbortCalls > gAbortAfter ? 1 : 0;
}

int gMessagesPosted = 0;
std::string gLastMessageType;
std::string gLastMessageText;
OfxStatus postMessage(void *, const char *type, const char *, const char *format, ...) {
    ++gMessagesPosted;
    gLastMessageType = type ? type : "";
    char text[2048];
    va_list arguments;
    va_start(arguments, format);
    std::vsnprintf(text, sizeof(text), format, arguments);
    va_end(arguments);
    gLastMessageText = text;
    return kOfxStatOK;
}

int gThreadFanOuts = 0;
OfxStatus hostMultiThread(OfxThreadFunctionV1 func, unsigned int count, void *argument) {
    if (!func || count == 0) return kOfxStatFailed;
    ++gThreadFanOuts;
    std::vector<std::thread> pool;
    for (unsigned int i = 0; i < count; ++i) {
        pool.emplace_back([func, i, count, argument] { func(i, count, argument); });
    }
    for (std::thread &worker : pool) worker.join();
    return kOfxStatOK;
}
OfxStatus hostMultiThreadNumCPUs(unsigned int *count) {
    const unsigned int cores = std::thread::hardware_concurrency();
    *count = cores > 1 ? cores : 2;
    return kOfxStatOK;
}
OfxStatus hostMultiThreadIndex(unsigned int *index) {
    *index = 0;
    return kOfxStatOK;
}
int hostMultiThreadIsSpawnedThread(void) { return 0; }
OfxStatus hostMutexCreate(OfxMutexHandle *mutex, int lockCount) {
    auto *created = new std::recursive_mutex;
    while (lockCount-- > 0) created->lock();
    *mutex = reinterpret_cast<OfxMutexHandle>(created);
    return kOfxStatOK;
}
OfxStatus hostMutexDestroy(const OfxMutexHandle mutex) {
    delete reinterpret_cast<std::recursive_mutex *>(mutex);
    return kOfxStatOK;
}
OfxStatus hostMutexLock(const OfxMutexHandle mutex) {
    reinterpret_cast<std::recursive_mutex *>(mutex)->lock();
    return kOfxStatOK;
}
OfxStatus hostMutexUnLock(const OfxMutexHandle mutex) {
    reinterpret_cast<std::recursive_mutex *>(mutex)->unlock();
    return kOfxStatOK;
}
OfxStatus hostMutexTryLock(const OfxMutexHandle mutex) {
    return reinterpret_cast<std::recursive_mutex *>(mutex)->try_lock() ? kOfxStatOK
                                                                       : kOfxStatFailed;
}

OfxImageEffectSuiteV1 gEffectSuite = {};
OfxMessageSuiteV1 gMessageSuite = {};
OfxMultiThreadSuiteV1 gThreadSuite = {};
bool gOfferMessageSuite = true;
bool gOfferThreadSuite = true;

const void *fetchSuite(OfxPropertySetHandle, const char *name, int) {
    if (std::strcmp(name, kOfxImageEffectSuite) == 0) return &gEffectSuite;
    if (std::strcmp(name, kOfxPropertySuite) == 0) return &gPropertySuite;
    if (std::strcmp(name, kOfxParameterSuite) == 0) return &gParameterSuite;
    if (std::strcmp(name, kOfxMessageSuite) == 0) {
        return gOfferMessageSuite ? &gMessageSuite : nullptr;
    }
    if (std::strcmp(name, kOfxMultiThreadSuite) == 0) {
        return gOfferThreadSuite ? &gThreadSuite : nullptr;
    }
    return nullptr;
}

void buildSuites() {
    gPropertySuite.propReset = propReset;
    gPropertySuite.propSetPointer = propSetPointer;
    gPropertySuite.propSetString = propSetString;
    gPropertySuite.propSetDouble = propSetDouble;
    gPropertySuite.propSetInt = propSetInt;
    gPropertySuite.propSetIntN = propSetIntN;
    gPropertySuite.propGetPointer = propGetPointer;
    gPropertySuite.propGetString = propGetString;
    gPropertySuite.propGetDouble = propGetDouble;
    gPropertySuite.propGetInt = propGetInt;
    gPropertySuite.propGetIntN = propGetIntN;
    gPropertySuite.propGetDoubleN = propGetDoubleN;

    gParameterSuite.paramDefine = paramDefine;
    gParameterSuite.paramGetHandle = paramGetHandle;
    gParameterSuite.paramGetValue = paramGetValue;
    gParameterSuite.paramGetValueAtTime = paramGetValueAtTime;
    gParameterSuite.paramSetValue = paramSetValue;
    gParameterSuite.paramGetPropertySet = paramGetPropertySet;

    gEffectSuite.getPropertySet = getPropertySet;
    gEffectSuite.getParamSet = getParamSet;
    gEffectSuite.clipDefine = clipDefine;
    gEffectSuite.clipGetHandle = clipGetHandle;
    gEffectSuite.clipGetPropertySet = clipGetPropertySet;
    gEffectSuite.clipGetImage = clipGetImage;
    gEffectSuite.clipReleaseImage = clipReleaseImage;
    gEffectSuite.clipGetRegionOfDefinition = clipGetRegionOfDefinition;
    gEffectSuite.abort = effectAbort;

    gMessageSuite.message = postMessage;

    gThreadSuite.multiThread = hostMultiThread;
    gThreadSuite.multiThreadNumCPUs = hostMultiThreadNumCPUs;
    gThreadSuite.multiThreadIndex = hostMultiThreadIndex;
    gThreadSuite.multiThreadIsSpawnedThread = hostMultiThreadIsSpawnedThread;
    gThreadSuite.mutexCreate = hostMutexCreate;
    gThreadSuite.mutexDestroy = hostMutexDestroy;
    gThreadSuite.mutexLock = hostMutexLock;
    gThreadSuite.mutexUnLock = hostMutexUnLock;
    gThreadSuite.mutexTryLock = hostMutexTryLock;
}

void applyDefaults(ParamSet &set) {
    for (auto &entry : set.params) {
        Param *param = entry.second.get();
        if (param->type == kOfxParamTypeDouble) {
            propGetDouble(handleOf(param->properties), kOfxParamPropDefault, 0,
                          &param->doubleValue);
        } else if (param->type == kOfxParamTypeString) {
            char *value = nullptr;
            if (propGetString(handleOf(param->properties), kOfxParamPropDefault, 0,
                              &value) == kOfxStatOK && value) {
                param->stringValue = value;
            }
        } else {
            propGetInt(handleOf(param->properties), kOfxParamPropDefault, 0,
                       &param->intValue);
        }
    }
}

void setParam(ParamSet &set, const char *name, double value) {
    auto found = set.params.find(name);
    if (found == set.params.end()) return;
    found->second->doubleValue = value;
    found->second->intValue = static_cast<int>(value);
}

void setString(ParamSet &set, const char *name, const std::string &value) {
    auto found = set.params.find(name);
    if (found != set.params.end()) found->second->stringValue = value;
}

std::string getString(ParamSet &set, const char *name) {
    auto found = set.params.find(name);
    return found == set.params.end() ? std::string() : found->second->stringValue;
}

int getInt(ParamSet &set, const char *name) {
    auto found = set.params.find(name);
    return found == set.params.end() ? 0 : found->second->intValue;
}

void setChoice(OfxPlugin *plugin, OfxImageEffectHandle instance, ParamSet &set,
               const char *name, int value) {
    setParam(set, name, value);
    PropertySet *arguments = newPropertySet();
    propSetString(handleOf(arguments), kOfxPropType, 0, kOfxTypeParameter);
    propSetString(handleOf(arguments), kOfxPropName, 0, name);
    plugin->mainEntry(kOfxActionInstanceChanged, instance, handleOf(arguments), nullptr);
}

int spaceMenuIndex(fotufilm::Encoding encoding) {
    const int value = static_cast<int>(encoding);
    return value < 7 ? value : value + 1;
}

size_t optionCount(ParamSet &set, const char *name) {
    auto found = set.params.find(name);
    if (found == set.params.end()) return 0;
    auto &strings = found->second->properties->strings;
    auto options = strings.find(kOfxParamPropChoiceOption);
    return options == strings.end() ? 0 : options->second.size();
}

/// The gamut fit: the step that keeps a print the paper can make from leaving the container the
/// timeline hands it. Every claim here is one the fix would be worthless without.
void testGamutFit() {
    // Only Rec.709's primaries are narrower than the Display P3 the print is delivered in.
    check(fotufilm::deliveryLeavesGamut(fotufilm::Encoding::Rec709Gamma24) &&
          fotufilm::deliveryLeavesGamut(fotufilm::Encoding::SRGB) &&
          fotufilm::deliveryLeavesGamut(fotufilm::Encoding::LinearRec709),
          "Rec.709 primaries are named as unable to hold the print's gamut");
    check(!fotufilm::deliveryLeavesGamut(fotufilm::Encoding::LinearDisplayP3) &&
          !fotufilm::deliveryLeavesGamut(fotufilm::Encoding::LinearRec2020) &&
          !fotufilm::deliveryLeavesGamut(fotufilm::Encoding::ACEScg) &&
          !fotufilm::deliveryLeavesGamut(fotufilm::Encoding::ACEScct) &&
          !fotufilm::deliveryLeavesGamut(fotufilm::Encoding::DaVinciIntermediate),
          "every space that encloses Display P3 is left alone");

    const fotufilm::Transform rec709 =
        fotufilm::transformFor(fotufilm::Encoding::LinearRec709);
    const float *luma = rec709.luminance;
    check(std::fabs(luma[0] - 0.2126f) < 2e-3f &&
          std::fabs(luma[1] - 0.7152f) < 2e-3f &&
          std::fabs(luma[2] - 0.0722f) < 2e-3f,
          "the fit weighs luminance by the destination's own primaries");

    // In gamut is the identity, and bit-identical rather than merely close: anything else would
    // move every pixel of every frame to fix the few that are outside.
    bool untouched = true;
    for (float value : {0.0f, 0.02f, 0.18f, 0.5f, 0.9f, 0.999f, 1.0f}) {
        float pixel[4] = {value, value * 0.7f, value * 0.4f, 1.0f};
        const float before[3] = {pixel[0], pixel[1], pixel[2]};
        fotufilm::fitToGamut(luma, pixel);
        for (int c = 0; c < 3; ++c) untouched = untouched && pixel[c] == before[c];
    }
    check(untouched, "an in-gamut pixel comes back bit-identical");

    // The measured defect: a warm print highlight, inside the paper's own range, that lands
    // above 1.0 in red once it is written in Rec.709 primaries.
    {
        float pixel[4] = {1.018f, 0.921f, 0.704f, 1.0f};
        const float y = luma[0] * pixel[0] + luma[1] * pixel[1] + luma[2] * pixel[2];
        fotufilm::fitToGamut(luma, pixel);
        const float after = luma[0] * pixel[0] + luma[1] * pixel[1] + luma[2] * pixel[2];
        check(pixel[0] <= 1.0f + 1e-6f && pixel[1] <= 1.0f + 1e-6f &&
              pixel[2] <= 1.0f + 1e-6f,
              "the measured overshoot lands inside the container");
        check(std::fabs(after - y) < 1e-5f, "the fit holds luminance");
        check(pixel[0] > pixel[1] && pixel[1] > pixel[2],
              "the fit keeps the highlight warm rather than flattening its channel order");
    }

    // A transparency above white is the print working as intended. The fit must not read it as
    // an excursion and pull it down — its own level is the ceiling.
    {
        float pixel[4] = {1.5f, 1.5f, 1.5f, 1.0f};
        fotufilm::fitToGamut(luma, pixel);
        check(pixel[0] == 1.5f && pixel[1] == 1.5f && pixel[2] == 1.5f,
              "a neutral highlight above white is left alone");
    }
    {
        // A coloured highlight above white keeps its colour as well as its level. Flattening it
        // to neutral would hold luminance and stay inside every bound the checks above name,
        // which is exactly why this one asks for the channels themselves.
        float pixel[4] = {1.9f, 1.2f, 1.1f, 1.0f};
        fotufilm::fitToGamut(luma, pixel);
        check(pixel[0] == 1.9f && pixel[1] == 1.2f && pixel[2] == 1.1f,
              "a coloured highlight above white is left as the print made it");
    }
    {
        // The pinch: just under white the cube has almost no room off the neutral axis, so a
        // colour there is nearly white by the cube's own geometry, not by choice.
        float pixel[4] = {1.10f, 0.97f, 0.90f, 1.0f};
        const float y = luma[0] * pixel[0] + luma[1] * pixel[1] + luma[2] * pixel[2];
        fotufilm::fitToGamut(luma, pixel);
        const float after = luma[0] * pixel[0] + luma[1] * pixel[1] + luma[2] * pixel[2];
        check(std::fabs(after - y) < 1e-5f && pixel[0] <= 1.0f + 1e-6f,
              "a pixel just under white is fitted without moving its luminance");
    }

    // Negatives are the other side of the same excursion and clip just as hard.
    {
        float pixel[4] = {0.6f, 0.5f, -0.08f, 1.0f};
        fotufilm::fitToGamut(luma, pixel);
        check(pixel[2] >= -1e-6f, "a negative channel is brought back to the gamut floor");
    }

    // End to end through the encode, which is where the plugin actually takes it: the same pixel
    // with and without the fit, in the encoding the defect was measured in.
    {
        const fotufilm::Transform t =
            fotufilm::transformFor(fotufilm::Encoding::Rec709Gamma24);
        float bare[4] = {1.018f, 0.921f, 0.704f, 1.0f};
        float fitted[4] = {1.018f, 0.921f, 0.704f, 1.0f};
        fotufilm::encodeRow(fotufilm::Encoding::Rec709Gamma24, t, bare, 1, false);
        fotufilm::encodeRow(fotufilm::Encoding::Rec709Gamma24, t, fitted, 1, true);
        check(bare[0] > 1.0f, "without the fit the encode still hands the host a value over 1.0");
        check(fitted[0] <= 1.0f + 1e-6f, "with the fit the encoded print fits the container");
    }
}

void testWorkingSpace() {
    std::printf("working space\n");
    // A Transform's two matrices are inverses of two different paths: toWorking carries
    // the source into the Rec.2020 scene basis, fromWorking carries the Display P3 print
    // back to the source. Identity therefore holds only around the whole pipeline — decode,
    // deliver the print, encode — so the round-trip inserts the delivery step the engine's
    // paper tables perform. Its matrix comes from the plugin's own transforms rather than
    // fresh literals: fromWorking of Linear Rec.2020 is the delivery's exact inverse.
    float delivery[9];
    {
        // Bound to a named Transform rather than read straight off the returned temporary: the
        // pointer would outlive the value it points into by the end of the initialiser.
        const fotufilm::Transform rec2020 =
            fotufilm::transformFor(fotufilm::Encoding::LinearRec2020);
        const float *m = rec2020.fromWorking;
        const float det = m[0] * (m[4] * m[8] - m[5] * m[7])
                        - m[1] * (m[3] * m[8] - m[5] * m[6])
                        + m[2] * (m[3] * m[7] - m[4] * m[6]);
        const float inv = 1.0f / det;
        delivery[0] = (m[4] * m[8] - m[5] * m[7]) * inv;
        delivery[1] = (m[2] * m[7] - m[1] * m[8]) * inv;
        delivery[2] = (m[1] * m[5] - m[2] * m[4]) * inv;
        delivery[3] = (m[5] * m[6] - m[3] * m[8]) * inv;
        delivery[4] = (m[0] * m[8] - m[2] * m[6]) * inv;
        delivery[5] = (m[2] * m[3] - m[0] * m[5]) * inv;
        delivery[6] = (m[3] * m[7] - m[4] * m[6]) * inv;
        delivery[7] = (m[1] * m[6] - m[0] * m[7]) * inv;
        delivery[8] = (m[0] * m[4] - m[1] * m[3]) * inv;
    }
    for (int i = 0; i < static_cast<int>(fotufilm::Encoding::Count); ++i) {
        const auto encoding = static_cast<fotufilm::Encoding>(i);
        const fotufilm::Transform transform = fotufilm::transformFor(encoding);

        float worst = 0;
        for (float value : {-0.5f, -0.05f, 0.0f, 0.02f, 0.18f, 0.5f, 1.0f,
                            4.0f}) {
            // A working-space scene colour, delivered as the identity print in P3 — the
            // stand-in for the develop — then encoded to the source and decoded back.
            const float original[3] = {value, value * 0.7f, value * 0.4f};
            float pixel[4] = {0, 0, 0, 1.0f};
            for (int row = 0; row < 3; ++row) {
                pixel[row] = delivery[row * 3] * original[0]
                           + delivery[row * 3 + 1] * original[1]
                           + delivery[row * 3 + 2] * original[2];
            }
            fotufilm::encodeRow(encoding, transform, pixel, 1);
            fotufilm::decodeRow(encoding, transform, pixel, 1);
            for (int c = 0; c < 3; ++c) {
                const float scale = std::fmax(1.0f, std::fabs(original[c]));
                worst = std::fmax(worst, std::fabs(pixel[c] - original[c]) / scale);
            }
        }
        char label[128];
        std::snprintf(label, sizeof(label), "%s round-trips (worst %.2e)",
                      fotufilm::encodingLabel(encoding), worst);
        check(worst < 1e-4f, label);

        const float encoded = fotufilm::fromLinear(encoding, 1.0f);
        float white[4] = {encoded, encoded, encoded, 1.0f};
        fotufilm::decodeRow(encoding, transform, white, 1);
        const float spread = std::fmax(std::fmax(white[0], white[1]), white[2]) -
                             std::fmin(std::fmin(white[0], white[1]), white[2]);
        std::snprintf(label, sizeof(label), "%s white stays neutral (spread %.2e)",
                      fotufilm::encodingLabel(encoding), spread);
        check(spread < 1e-3f, label);
    }

    testGamutFit();

    // Blackmagic's DI curve branches on the signed value. These negative references catch the
    // tempting but incorrect implementation that takes abs(), runs the positive log branch, and
    // restores the sign.
    constexpr float diM = 10.44426855f;
    check(std::fabs(fotufilm::toLinear(fotufilm::Encoding::DaVinciIntermediate,
                                     -0.5f) - (-0.5f / diM)) < 1e-7f,
          "DaVinci Intermediate negative code values use the published linear toe");
    check(std::fabs(fotufilm::fromLinear(fotufilm::Encoding::DaVinciIntermediate,
                                       -0.05f) - (-0.05f * diM)) < 1e-7f,
          "DaVinci Intermediate negative linear values encode on the signed branch");

    // The OFX colourspace tags Auto reads: core 1.5 names, display spellings of the same spaces,
    // and — just as load-bearing — the refusals. A camera log the plugin cannot decode must come
    // back unknown, not close-enough.
    const struct { const char *tag; fotufilm::Encoding expected; } tags[] = {
        {"ACEScct", fotufilm::Encoding::ACEScct},
        {"ACEScg", fotufilm::Encoding::ACEScg},
        {"lin_ap1", fotufilm::Encoding::ACEScg},
        {"davinci_intermediate_widegamut", fotufilm::Encoding::DaVinciIntermediate},
        {"DaVinci Intermediate / Wide Gamut", fotufilm::Encoding::DaVinciIntermediate},
        {"srgb_tx", fotufilm::Encoding::SRGB},
        {"sRGB", fotufilm::Encoding::SRGB},
        {"Rec.709 Gamma 2.4", fotufilm::Encoding::Rec709Gamma24},
        {"rec1886_rec709_display", fotufilm::Encoding::Count},
        {"g24_rec709_tx", fotufilm::Encoding::Rec709Gamma24},
        {"lin_rec709_srgb", fotufilm::Encoding::LinearRec709},
        {"Linear Rec.709", fotufilm::Encoding::LinearRec709},
        {"lin_p3d65", fotufilm::Encoding::LinearDisplayP3},
        {"Linear Display P3", fotufilm::Encoding::LinearDisplayP3},
        {"lin_rec2020", fotufilm::Encoding::LinearRec2020},
        {"Linear Rec.2020", fotufilm::Encoding::LinearRec2020},
        {"Raw", fotufilm::Encoding::Count},
        {"ofx_raw", fotufilm::Encoding::Count},
        {"slog3_sgamut3", fotufilm::Encoding::Count},
        {"arri_logc4", fotufilm::Encoding::Count},
        {"ofx_scene_linear", fotufilm::Encoding::Count},
        {"g22_rec709_tx", fotufilm::Encoding::Count},
        {"srgb_display", fotufilm::Encoding::Count},
        {"", fotufilm::Encoding::Count},
    };
    bool tagsAgree = true;
    for (const auto &entry : tags) {
        if (fotufilm::encodingForColourspace(entry.tag) != entry.expected) {
            std::printf("       colourspace tag \"%s\" mismapped\n", entry.tag);
            tagsAgree = false;
        }
    }
    if (fotufilm::encodingForColourspace(nullptr) != fotufilm::Encoding::Count) {
        std::printf("       null colourspace tag mismapped\n");
        tagsAgree = false;
    }
    check(tagsAgree, "colourspace tags map to encodings, and only the honest ones");
}

int testPlugin() {
    buildSuites();

    PropertySet *hostProperties = newPropertySet();
    OfxHost host = {handleOf(hostProperties), fetchSuite};

    std::printf("plugin\n");
    check(gGetNumberOfPlugins() == 1, "exports exactly one plugin");
    OfxPlugin *plugin = gGetPlugin(0);
    check(plugin != nullptr, "OfxGetPlugin(0) returns a plugin");
    if (!plugin) return 1;
    check(std::strcmp(plugin->pluginApi, kOfxImageEffectPluginApi) == 0,
          "declares the image effect API");

    plugin->setHost(&host);
    check(plugin->mainEntry(kOfxActionLoad, nullptr, nullptr, nullptr) == kOfxStatOK,
          "loads");
    const char *realtimeFlag = std::getenv("FOTUFILM_REALTIME");
    const bool expectedRealtime = !realtimeFlag || std::strcmp(realtimeFlag, "0") != 0;
    check(fotufilm_bridge_realtime_enabled() == (expectedRealtime ? 1 : 0),
          expectedRealtime ? "defaults to realtime rendering"
                           : "honours the reference-rendering flag");

    Effect describer;
    describer.properties = newPropertySet();
    auto describerHandle = reinterpret_cast<OfxImageEffectHandle>(&describer);
    check(plugin->mainEntry(kOfxActionDescribe, describerHandle, nullptr, nullptr) ==
              kOfxStatOK, "describes");

    char *label = nullptr;
    propGetString(handleOf(describer.properties), kOfxPropLabel, 0, &label);
    check(label && std::strcmp(label, "Fotufilm") == 0, "labels itself Fotufilm");
    int tiles = 1;
    propGetInt(handleOf(describer.properties), kOfxImageEffectPropSupportsTiles, 0, &tiles);
    check(tiles == 0, "refuses tiles, as a whole-frame model must");
    char *renderSafety = nullptr;
    propGetString(handleOf(describer.properties), kOfxImageEffectPluginRenderThreadSafety, 0,
                  &renderSafety);
    check(renderSafety && std::strcmp(renderSafety, kOfxImageEffectRenderInstanceSafe) == 0,
          "allows separate effect instances to render concurrently");
    char *style = nullptr, *config = nullptr;
    propGetString(handleOf(describer.properties),
                  kOfxImageEffectPropColourManagementStyle, 0, &style);
    propGetString(handleOf(describer.properties),
                  kOfxImageEffectPropColourManagementAvailableConfigs, 0, &config);
    check(style && std::strcmp(style, kOfxImageEffectColourManagementFull) == 0,
          "negotiates Resolve's OFX 1.5 full colour management");
    check(config && std::strcmp(config, kOfxConfigIdentifier) == 0,
          "declares the required native colour config");
    check(describer.properties->strings.count("OfxImageEffectPropMetalRenderSupported") == 0,
          "does not advertise a host-Metal path that would block Resolve's queue");
    {
        // The clip preferences follow the span, so the host has to be told which parameters
        // move them, or it is entitled to ask once and never again.
        bool slavedToStage = false;
        std::vector<std::string> declared;
        auto slaved = describer.properties->strings.find(
            kOfxImageEffectPropClipPreferencesSlaveParam);
        if (slaved != describer.properties->strings.end()) {
            declared = slaved->second;
            for (const std::string &name : declared) {
                if (name == "stage") slavedToStage = true;
            }
        }
        check(slavedToStage, "slaves its clip preferences to the stage parameter");

        // And to every texture toggle. In Texture Only the frame-varying answer is decided by
        // which spatial stages were selected — grain is seeded by the frame number and nothing
        // else in that span is — so a host told only about the span is entitled to ask once and
        // keep the answer, and the grain field freezes on the timeline.
        std::vector<std::string> togglesMissing;
        for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
            char id[128] = "";
            if (fotufilm_bridge_texture_stage_id(i, id, sizeof(id)) < 0) continue;
            std::string name = std::string("texture_") + id;
            for (char &c : name) { if (c == '-') c = '_'; }
            if (std::find(declared.begin(), declared.end(), name) == declared.end()) {
                togglesMissing.push_back(name);
            }
        }
        for (const std::string &name : togglesMissing) {
            std::printf("  FAIL %s moves the frame-varying answer but is not a slave "
                        "parameter\n", name.c_str());
            ++gFailures;
        }
        check(fotufilm_bridge_texture_stage_count() > 0 && togglesMissing.empty(),
              "and to every texture stage toggle, which decides the frame-varying answer");
    }
#if defined(FOTUFILM_VERSION_MAJOR) && defined(FOTUFILM_VERSION_MINOR)
    check(plugin->pluginVersionMajor == FOTUFILM_VERSION_MAJOR &&
              plugin->pluginVersionMinor == FOTUFILM_VERSION_MINOR,
          "carries the version version.env names");
#endif

    Effect instance;
    instance.properties = newPropertySet();
    auto instanceHandle = reinterpret_cast<OfxImageEffectHandle>(&instance);
    check(plugin->mainEntry(kOfxImageEffectActionDescribeInContext, instanceHandle,
                            nullptr, nullptr) == kOfxStatOK,
          "describes in context");
    check(instance.clips.count(kOfxImageEffectSimpleSourceClipName) == 1 &&
              instance.clips.count(kOfxImageEffectOutputClipName) == 1,
          "defines a source and an output clip");
    check(instance.params.params.size() >= 16, "defines the full parameter set");
    check(instance.params.params.count("stockID") == 1 &&
              instance.params.params.count("formatID") == 1 &&
              instance.params.params.count("paperID") == 1,
          "defines the hidden identity parameters");
    {
        PropertySet *preferences = newPropertySet();
        check(plugin->mainEntry(kOfxImageEffectActionGetClipPreferences, instanceHandle,
                                nullptr, handleOf(preferences)) == kOfxStatOK,
              "answers the OFX colour clip-preferences action");
        char *preferred = nullptr;
        propGetString(handleOf(preferences),
                      "OfxImageClipPropPreferredColourspaces_Source", 0, &preferred);
        check(preferred && std::strcmp(preferred, kOfxColourspaceLinRec2020) == 0,
              "asks Resolve for the engine's exact linear Rec.2020 input");
        int varying = 0;
        propGetInt(handleOf(preferences), kOfxImageEffectFrameVarying, 0, &varying);
        check(varying == 1, "declares that its output varies with the frame, as seeded grain does");

        // The 1.5 property may be refused by a host that does not have it. The preferences
        // action still succeeds — the render reads the tag on each image regardless.
        PropertySet *refused = newPropertySet();
        gRefusePreferredColourspace = true;
        const OfxStatus declined = plugin->mainEntry(
            kOfxImageEffectActionGetClipPreferences, instanceHandle, nullptr,
            handleOf(refused));
        gRefusePreferredColourspace = false;
        check(declined == kOfxStatOK,
              "and a host that declines the colourspace request does not fail the action");
        int varyingAnyway = 0;
        propGetInt(handleOf(refused), kOfxImageEffectFrameVarying, 0, &varyingAnyway);
        check(varyingAnyway == 1, "which still carries the frame-varying declaration");

        PropertySet *outputColour = newPropertySet();
        check(plugin->mainEntry(kOfxImageEffectActionGetOutputColourspace, instanceHandle,
                                nullptr, handleOf(outputColour)) == kOfxStatOK,
              "answers the OFX output-colourspace action");
        char *selected = nullptr;
        propGetString(handleOf(outputColour), kOfxImageClipPropColourspace, 0, &selected);
        check(selected && std::strcmp(selected, "OfxColourspace_Source") == 0,
              "declares that output returns to the negotiated source space");
    }
    {
        bool labelled = false, named = false, explained = false;
        auto found = instance.params.params.find("colorSpaceStatus");
        if (found != instance.params.params.end()) {
            char *mode = nullptr, *label = nullptr, *hint = nullptr;
            propGetString(handleOf(found->second->properties),
                          kOfxParamPropStringMode, 0, &mode);
            propGetString(handleOf(found->second->properties), kOfxPropLabel, 0, &label);
            propGetString(handleOf(found->second->properties),
                          kOfxParamPropHint, 0, &hint);
            labelled = mode && std::strcmp(mode, kOfxParamStringIsLabel) == 0;
            named = label && std::strcmp(label, "Decoded Input") == 0;
            explained = hint && std::strstr(hint, "Assumed") != nullptr;
        }
        check(labelled, "defines a read-only colour space status line");
        check(named, "gives the colour space status a visible inspector label");
        check(explained, "explains assumed Auto values in the status tooltip");
    }

    {
        const std::pair<const char *, const char *> groups[] = {
            {"inputGroup", "Input"}, {"filmGroup", "Film"},
            {"exposureGroup", "Light & Colour"}, {"lensGroup", "Lens & Filters"},
            {"labGroup", "Development"}, {"filmResponseGroup", "Grain"},
            {"halationGroup", "Halation"}, {"couplerGroup", "Colour Separation"},
            {"outputGroup", "Output"}, {"stageGroup", "Pipeline"},
        };
        bool grouped = true;
        for (const auto &group : groups) {
            auto found = instance.params.params.find(group.first);
            if (found == instance.params.params.end()) { grouped = false; continue; }
            char *label = nullptr;
            propGetString(handleOf(found->second->properties), kOfxPropLabel, 0, &label);
            int open = -1;
            propGetInt(handleOf(found->second->properties), kOfxParamPropGroupOpen, 0, &open);
            const bool initiallyOpen = std::strcmp(group.first, "inputGroup") == 0 ||
                std::strcmp(group.first, "filmGroup") == 0 || std::strcmp(group.first, "outputGroup") == 0;
            grouped &= label && std::strcmp(label, group.second) == 0 && open == (initiallyOpen ? 1 : 0);
        }
        check(grouped, "defines ten workflow groups with Input, Film and Output initially open");
        auto parentIs = [&](const char *name, const char *wanted) {
            char *parent = nullptr;
            propGetString(handleOf(instance.params.params.at(name)->properties), kOfxParamPropParent, 0, &parent);
            return parent && std::strcmp(parent, wanted) == 0;
        };
        check(parentIs("flare", "lensGroup") && parentIs("halation", "halationGroup") &&
              parentIs("couplers", "couplerGroup") && parentIs("colorSpace", "inputGroup") &&
              parentIs("stage", "stageGroup") && parentIs("flare", "lensGroup"),
              "moves existing parameter identities into their intended groups");
        int hidden = 0, persistent = 1;
        propGetInt(handleOf(instance.params.params.at("push")->properties), kOfxParamPropSecret, 0, &hidden);
        propGetInt(handleOf(instance.params.params.at("pushCondition")->properties), kOfxParamPropPersistant, 0, &persistent);
        check(hidden == 1 && persistent == 0,
              "the measured menu is derived while legacy numeric development remains saved");
    }
    applyDefaults(instance.params);
    check(getInt(instance.params, "paper") >= fotufilm_bridge_paper_count(),
          "the output medium defaults to Match Film");
    {
        // The plugin declared the native config; a host that set another has agreed to names
        // the plugin does not speak, and says so once at creation rather than per unknown tag.
        const int before = gMessagesPosted;
        propSetString(handleOf(instance.properties),
                      kOfxImageEffectPropColourManagementStyle, 0,
                      kOfxImageEffectColourManagementOCIO);
        propSetString(handleOf(instance.properties),
                      kOfxImageEffectPropColourManagementConfig, 0,
                      "studio-config-v1.0.0_aces-v1.3_ocio-v2.1");
        check(plugin->mainEntry(kOfxActionCreateInstance, instanceHandle, nullptr,
                                nullptr) == kOfxStatOK,
              "creates an instance under a foreign colour management config");
        check(gMessagesPosted == before + 1 && gLastMessageType == kOfxMessageWarning &&
                  gLastMessageText.find("studio-config") != std::string::npos &&
                  gLastMessageText.find(kOfxConfigIdentifier) != std::string::npos,
              "and warns that it will read the tags as native names");
        propSetString(handleOf(instance.properties),
                      kOfxImageEffectPropColourManagementStyle, 0,
                      kOfxImageEffectColourManagementFull);
        propSetString(handleOf(instance.properties),
                      kOfxImageEffectPropColourManagementConfig, 0, kOfxConfigIdentifier);
        const int under = gMessagesPosted;
        plugin->mainEntry(kOfxActionCreateInstance, instanceHandle, nullptr, nullptr);
        check(gMessagesPosted == under, "and says nothing under the native config");
    }
    check(plugin->mainEntry(kOfxActionCreateInstance, instanceHandle, nullptr,
                            nullptr) == kOfxStatOK, "creates an instance");

    const int width = 240, height = 135;
    Clip *source = instance.clips[kOfxImageEffectSimpleSourceClipName].get();
    Clip *output = instance.clips[kOfxImageEffectOutputClipName].get();
    for (Clip *clip : {source, output}) {
        clip->pixels.assign(static_cast<size_t>(width) * height * 4, 0.0f);
        clip->image = newPropertySet();
        propSetPointer(handleOf(clip->image), kOfxImagePropData, 0, clip->pixels.data());
        const int bounds[4] = {0, 0, width, height};
        propSetIntN(handleOf(clip->image), kOfxImagePropBounds, 4, bounds);
        propSetInt(handleOf(clip->image), kOfxImagePropRowBytes, 0,
                   width * 4 * static_cast<int>(sizeof(float)));
        propSetString(handleOf(clip->image), kOfxImageEffectPropPixelDepth, 0,
                      kOfxBitDepthFloat);
        propSetString(handleOf(clip->image), kOfxImageEffectPropComponents, 0,
                      kOfxImageComponentRGBA);
        propSetString(handleOf(clip->properties),
                      kOfxImageEffectPropPreMultiplication, 0, kOfxImageOpaque);
    }
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const float ramp = static_cast<float>(x) / (width - 1);
            float *pixel = source->pixels.data() +
                           (static_cast<size_t>(y) * width + x) * 4;
            pixel[0] = ramp;
            pixel[1] = ramp * 0.85f;
            pixel[2] = ramp * 0.7f;
            pixel[3] = 1.0f;
        }
    }

    setParam(instance.params, "colorSpace",
             static_cast<double>(fotufilm::Encoding::LinearDisplayP3));
    setParam(instance.params, "grain", 0);

    PropertySet *renderArgs = newPropertySet();
    propSetDouble(handleOf(renderArgs), kOfxPropTime, 0, 0);
    const int window[4] = {0, 0, width, height};
    propSetIntN(handleOf(renderArgs), kOfxImageEffectPropRenderWindow, 4, window);

    gThreadFanOuts = 0;
    const OfxStatus rendered = plugin->mainEntry(
        kOfxImageEffectActionRender, instanceHandle, handleOf(renderArgs), nullptr);
    check(rendered == kOfxStatOK, "renders");
    check(gThreadFanOuts > 0, "and fans the transcode across the host's threads");

    if (rendered == kOfxStatOK) {
        bool wrote = false, finite = true, monotonic = true;
        float previous = -1;
        for (size_t i = 0; i < output->pixels.size(); ++i) {
            if (output->pixels[i] != 0) wrote = true;
            if (!std::isfinite(output->pixels[i])) finite = false;
        }
        const int middle = height / 2;
        for (int x = 0; x < width; ++x) {
            const float value =
                output->pixels[(static_cast<size_t>(middle) * width + x) * 4];
            if (value + 1e-3f < previous) monotonic = false;
            previous = value;
        }
        check(wrote, "writes the output clip");
        check(finite, "produces no NaNs or infinities");
        check(monotonic, "keeps the exposure ramp monotonic");

        const float *left = output->pixels.data() +
                            (static_cast<size_t>(middle) * width + 4) * 4;
        const float *right = output->pixels.data() +
                             (static_cast<size_t>(middle) * width + width - 5) * 4;
        std::printf("       ramp: %.4f -> %.4f (alpha %.2f)\n",
                    left[0], right[0], right[3]);
        check(right[0] > left[0], "develops a brighter highlight than shadow");
        check(right[3] == 1.0f, "passes alpha through");

        const std::vector<float> smooth = output->pixels;
        setParam(instance.params, "grain", 1);
        if (plugin->mainEntry(kOfxImageEffectActionRender, instanceHandle,
                              handleOf(renderArgs), nullptr) == kOfxStatOK) {
            double energy = 0;
            for (size_t i = 0; i < smooth.size(); ++i) {
                const double difference = output->pixels[i] - smooth[i];
                energy += difference * difference;
            }
            const double rms = std::sqrt(energy / smooth.size());
            std::printf("       grain RMS: %.5f\n", rms);
            check(rms > 1e-4, "the grain control reaches the engine");
        } else {
            check(false, "renders again with grain on");
        }

        // The output medium. Grain off, so the only thing moving between the two renders is the
        // medium. A reversal stock is viewed directly and has no print, so it is *correct* for one
        // to ignore the choice — walk the stocks until one has a print to change rather than
        // assuming whichever stock sorts first is a negative.
        setParam(instance.params, "grain", 0);
        const size_t papers = static_cast<size_t>(fotufilm_bridge_paper_count());
        const size_t paperChoices = optionCount(instance.params, "paper");
        const size_t stocks = optionCount(instance.params, "stock");
        check(papers >= 2, "offers more than one concrete output medium");
        check(paperChoices == papers + 1,
              "appends Match Film after the concrete output media");

        auto renderNow = [&] {
            return plugin->mainEntry(kOfxImageEffectActionRender, instanceHandle,
                                     handleOf(renderArgs), nullptr) == kOfxStatOK;
        };

        // Counted over every stock, because which papers a stock can tell apart depends on the
        // stock: a reversal one has no print at all, and a monochrome negative carries no colour
        // for two similar colour papers to disagree about. A paper that no stock distinguishes,
        // though, is a paper that is not being read.
        std::vector<int> distinguishing(papers, 0);
        std::vector<double> largest(papers, 0.0);
        for (size_t s = 0; s < stocks; ++s) {
            setChoice(plugin, instanceHandle, instance.params, "stock", static_cast<int>(s));
            setChoice(plugin, instanceHandle, instance.params, "paper", 0);
            if (!renderNow()) continue;
            const std::vector<float> onFirst = output->pixels;
            for (size_t p = 1; p < papers; ++p) {
                setChoice(plugin, instanceHandle, instance.params, "paper",
                          static_cast<int>(p));
                if (!renderNow()) continue;
                double energy = 0;
                for (size_t i = 0; i < onFirst.size(); ++i) {
                    const double difference = output->pixels[i] - onFirst[i];
                    energy += difference * difference;
                }
                const double rms = std::sqrt(energy / onFirst.size());
                if (rms > largest[p]) largest[p] = rms;
                if (rms > 1e-4) ++distinguishing[p];
            }
        }
        bool everyPaperRead = true;
        for (size_t p = 1; p < papers; ++p) {
            std::printf("       paper %zu: %d/%zu stocks differ from paper 0, "
                        "largest RMS %.5f\n",
                        p, distinguishing[p], stocks, largest[p]);
            if (distinguishing[p] == 0) everyPaperRead = false;
        }
        check(everyPaperRead, "every paper reaches the engine");

        // The lab levers, one moved at a time against the same developed frame.
        // Counted over every stock like the papers, because some are right to
        // ignore one — a transparency has no bleach to skip and no print light
        // to change. A lever no stock answers is a slider wired to nothing.
        const char *const levers[] = {"push", "bleachBypass", "expired",
                                      "printLight"};
        const double moved[] = {2.0, 1.0, 10.0, 2.0};
        const size_t leverCount = sizeof(levers) / sizeof(*levers);
        std::vector<int> answering(leverCount, 0);
        std::vector<int> offered(leverCount, 0);
        std::vector<double> leverLargest(leverCount, 0.0);
        setChoice(plugin, instanceHandle, instance.params, "paper", 0);
        for (size_t s = 0; s < stocks; ++s) {
            setChoice(plugin, instanceHandle, instance.params, "stock", static_cast<int>(s));
            for (size_t l = 0; l < leverCount; ++l) {
                setParam(instance.params, levers[l], 0);
            }
            if (!renderNow()) continue;
            const std::vector<float> rested = output->pixels;
            for (size_t l = 0; l < leverCount; ++l) {
                if (l == 0 && fotufilm_bridge_stock_pushes(static_cast<int32_t>(s)) == 0) {
                    continue;
                }
                ++offered[l];
                setParam(instance.params, levers[l], moved[l]);
                const bool ok = renderNow();
                setParam(instance.params, levers[l], 0);
                if (!ok) continue;
                double energy = 0;
                for (size_t i = 0; i < rested.size(); ++i) {
                    const double difference = output->pixels[i] - rested[i];
                    energy += difference * difference;
                }
                const double rms = std::sqrt(energy / rested.size());
                if (rms > leverLargest[l]) leverLargest[l] = rms;
                if (rms > 1e-4) ++answering[l];
            }
        }
        bool everyLeverRead = true;
        for (size_t l = 0; l < leverCount; ++l) {
            std::printf("       %s: %d/%d offered stocks answer, largest RMS %.5f\n",
                        levers[l], answering[l], offered[l], leverLargest[l]);
            if (offered[l] > 0 && answering[l] == 0) everyLeverRead = false;
        }
        check(everyLeverRead, "every lab lever reaches the engine");

        // Identity. A project stores a menu index and the id behind it; the id is what a
        // render trusts, so a pack rearranged underneath a saved project keeps its look.
        std::printf("identity\n");
        if (stocks >= 2) {
            setChoice(plugin, instanceHandle, instance.params, "stock", 1);
            const std::string idOfSecond = getString(instance.params, "stockID");
            check(!idOfSecond.empty(), "choosing a stock records its id");
            if (renderNow()) {
                const std::vector<float> asChosen = output->pixels;
                // A stale project: the menu says 0, the id still names the second stock —
                // the host restored both without firing instanceChanged.
                setParam(instance.params, "stock", 0);
                check(renderNow(), "renders with a stale menu index");
                check(output->pixels == asChosen,
                      "the persisted id outvotes a stale menu index");
            } else {
                check(false, "renders the second stock");
            }

            // The same project opened on this machine: createInstance moves the menu to
            // wherever the id's stock now sits.
            setParam(instance.params, "stock", 0);
            setString(instance.params, "stockID", idOfSecond);
            check(plugin->mainEntry(kOfxActionCreateInstance, instanceHandle, nullptr,
                                    nullptr) == kOfxStatOK,
                  "re-creates the instance over restored parameters");
            check(getInt(instance.params, "stock") == 1,
                  "createInstance moves the menu to the id's new position");
            check(getString(instance.params, "stockID") == idOfSecond,
                  "reconciling does not rewrite the id");

            // A project whose stock is not installed here: the user is told, the menu keeps
            // its position, and the id survives so reinstalling the pack heals the project.
            const int messagesBefore = gMessagesPosted;
            setString(instance.params, "stockID", "not-installed-stock");
            setParam(instance.params, "stock", 0);
            plugin->mainEntry(kOfxActionCreateInstance, instanceHandle, nullptr, nullptr);
            check(gMessagesPosted > messagesBefore,
                  "a missing stock is reported to the host");
            check(getString(instance.params, "stockID") == "not-installed-stock",
                  "the missing id is kept so a reinstall heals the project");
            check(renderNow(), "and the menu's stock renders meanwhile");
            setChoice(plugin, instanceHandle, instance.params, "stock", 0);
        }

        // Auto colour space: the host tags the clip, the plugin reads the tag.
        std::printf("colour space\n");
        // Auto's *menu index*, frozen at 7 by the plugin's persistence ABI. Encoding::Count
        // no longer names it: encodings added since (Linear Rec.2020) append after Auto in
        // the menu while growing the enum before Count, exactly so saved projects keep
        // meaning what they meant.
        const int autoChoice = 7;
        std::vector<float> explicitDaVinciIntermediate;
        setParam(instance.params, "colorSpace",
                 static_cast<double>(fotufilm::Encoding::DaVinciIntermediate));
        const bool renderedDaVinciIntermediate = renderNow();
        if (renderedDaVinciIntermediate) {
            explicitDaVinciIntermediate = output->pixels;
            setParam(instance.params, "colorSpace", autoChoice);
            propSetString(handleOf(source->image), kOfxImageClipPropColourspace, 0,
                          "davinci_intermediate_widegamut");
            check(renderNow() && output->pixels == explicitDaVinciIntermediate,
                  "Auto reads Resolve's full-mode DaVinci Intermediate tag");
        } else {
            check(false, "renders DaVinci Intermediate explicitly");
        }

        setParam(instance.params, "colorSpace",
                 static_cast<double>(fotufilm::Encoding::ACEScct));
        if (renderNow()) {
            const std::vector<float> explicitACES = output->pixels;
            setParam(instance.params, "colorSpace", autoChoice);
            propSetString(handleOf(source->image), kOfxImageClipPropColourspace, 0,
                          "ACEScct");
            check(renderNow() && output->pixels == explicitACES,
                  "Auto reads the host's colourspace tag");

            setParam(instance.params, "colorSpace",
                     static_cast<double>(fotufilm::Encoding::Rec709Gamma24));
            check(renderNow(), "renders Rec.709 explicitly");
            const std::vector<float> explicitRec709 = output->pixels;
            const int rawMessagesBefore = gMessagesPosted;
            setParam(instance.params, "colorSpace", autoChoice);
            propSetString(handleOf(source->image), kOfxImageClipPropColourspace, 0,
                          kOfxColourspaceRaw);
            check(renderNow() && renderedDaVinciIntermediate &&
                      output->pixels == explicitDaVinciIntermediate,
                  "Resolve Raw uses the DaVinci Intermediate compatibility fallback");
            propSetString(handleOf(source->image), kOfxImageClipPropColourspace, 0,
                          kOfxColourspaceOfxRaw);
            check(renderNow() && output->pixels == explicitRec709,
                  "generic OFX Raw keeps the Rec.709 compatibility fallback");
            check(gMessagesPosted == rawMessagesBefore,
                  "and neither Raw sentinel posts a host error");

            const int messagesBefore = gMessagesPosted;
            propSetString(handleOf(source->image), kOfxImageClipPropColourspace, 0,
                          "slog3_sgamut3");
            check(!renderNow(), "an undecodable host tag fails instead of guessing");
            check(gMessagesPosted > messagesBefore &&
                      gLastMessageType == kOfxMessageError,
                  "and tells the user to choose the actual space");
            check(gLastMessageText.find("Rec.709 / Gamma 2.4") != std::string::npos &&
                      gLastMessageText.find("Linear Display P3") != std::string::npos &&
                      gLastMessageText.find("transform the source") != std::string::npos,
                  "and lists the supported inputs and upstream-transform remedy");

            // A host with no OFX 1.5 tag at all keeps the pre-extension project behaviour.
            source->image->strings.erase(kOfxImageClipPropColourspace);
            check(renderNow() && output->pixels == explicitRec709,
                  "an untagged legacy host keeps the Rec.709 compatibility fallback");
        } else {
            check(false, "renders ACEScct explicitly");
        }

        // The status line under the menu: it follows the explicit choice, and on Auto it
        // follows the clip's tag when the clip changes under the node.
        setChoice(plugin, instanceHandle, instance.params, "colorSpace",
                  static_cast<int>(fotufilm::Encoding::SRGB));
        check(getString(instance.params, "colorSpaceStatus").find("sRGB") !=
                  std::string::npos,
              "the status line names the explicit choice");
        setChoice(plugin, instanceHandle, instance.params, "colorSpace", autoChoice);
        propSetString(handleOf(source->properties), kOfxImageClipPropColourspace, 0,
                      "ACEScct");
        PropertySet *clipChange = newPropertySet();
        propSetString(handleOf(clipChange), kOfxPropType, 0, kOfxTypeClip);
        propSetString(handleOf(clipChange), kOfxPropName, 0,
                      kOfxImageEffectSimpleSourceClipName);
        plugin->mainEntry(kOfxActionInstanceChanged, instanceHandle,
                          handleOf(clipChange), nullptr);
        check(getString(instance.params, "colorSpaceStatus").find("ACEScct") !=
                  std::string::npos,
              "on Auto the status line reads the clip's tag");
        propSetString(handleOf(source->properties), kOfxImageClipPropColourspace, 0,
                      kOfxColourspaceRaw);
        plugin->mainEntry(kOfxActionInstanceChanged, instanceHandle,
                          handleOf(clipChange), nullptr);
        const std::string rawStatus = getString(instance.params, "colorSpaceStatus");
        check(rawStatus == "DWG / Intermediate (assumed)",
              "on Raw the status line concisely names the compatibility fallback");
        setChoice(plugin, instanceHandle, instance.params, "colorSpace",
                  static_cast<int>(fotufilm::Encoding::LinearDisplayP3));

        // Abort. A host that no longer wants the frame gets a clean return and an
        // untouched output, whether it changed its mind before or during the engine.
        std::printf("abort\n");
        std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
        gAbortCalls = 0;
        gAbortAfter = 0;
        check(plugin->mainEntry(kOfxImageEffectActionRender, instanceHandle,
                                handleOf(renderArgs), nullptr) == kOfxStatOK,
              "an abort before the engine returns cleanly");
        bool untouched = true;
        for (float value : output->pixels) {
            if (value != -7.0f) untouched = false;
        }
        check(untouched, "and writes nothing");

        gAbortCalls = 0;
        gAbortAfter = 1;  // The plugin's own pre-check passes; the engine's polling stops it.
        check(plugin->mainEntry(kOfxImageEffectActionRender, instanceHandle,
                                handleOf(renderArgs), nullptr) == kOfxStatOK,
              "an abort during the engine returns cleanly");
        untouched = true;
        for (float value : output->pixels) {
            if (value != -7.0f) untouched = false;
        }
        check(untouched, "and had written nothing yet");
        gAbortAfter = -1;
        gAbortCalls = 0;

        // Geometry a real host throws: offset bounds, a strict subwindow, frames small
        // enough to make every off-by-one show itself.
        std::printf("geometry\n");
        // `tilt` varies the frame down as well as across. Off by default, because most of what is
        // checked here is an engine invariant this would drag a separate question into: staged and
        // striped renders of a vertically varying frame are not bit-identical, by about six tenths
        // of a 16-bit LSB, and that is the engine's business rather than the plugin's. On means a
        // row of the frame can be told from any other, which is the only way a band, a strip or a
        // flipped copy that landed at the wrong row shows up at all.
        auto provision = [&](int w, int h, int ox, int oy, bool tilt = false) {
            for (Clip *clip : {source, output}) {
                clip->pixels.assign(static_cast<size_t>(w) * h * 4, 0.0f);
                propSetPointer(handleOf(clip->image), kOfxImagePropData, 0,
                               clip->pixels.data());
                const int bounds[4] = {ox, oy, ox + w, oy + h};
                propSetIntN(handleOf(clip->image), kOfxImagePropBounds, 4, bounds);
                propSetInt(handleOf(clip->image), kOfxImagePropRowBytes, 0,
                           w * 4 * static_cast<int>(sizeof(float)));
            }
            for (int y = 0; y < h; ++y) {
                const float down =
                    tilt && h > 1 ? static_cast<float>(y) / (h - 1) : 1.0f;
                for (int x = 0; x < w; ++x) {
                    const float ramp =
                        w > 1 ? static_cast<float>(x) / (w - 1) : 0.5f;
                    const float level = ramp * (tilt ? 0.35f + 0.65f * down : 1.0f);
                    float *pixel = source->pixels.data() +
                                   (static_cast<size_t>(y) * w + x) * 4;
                    pixel[0] = level;
                    pixel[1] = level * 0.85f + (tilt ? 0.1f * down : 0.0f);
                    pixel[2] = level * 0.7f + (tilt ? 0.2f * (1.0f - down) : 0.0f);
                    pixel[3] = 1.0f;
                }
            }
            const int fullWindow[4] = {ox, oy, ox + w, oy + h};
            propSetIntN(handleOf(renderArgs), kOfxImageEffectPropRenderWindow, 4,
                        fullWindow);
        };

        provision(64, 48, -7, 5);
        const int subwindow[4] = {0, 10, 30, 40};
        propSetIntN(handleOf(renderArgs), kOfxImageEffectPropRenderWindow, 4, subwindow);
        std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
        check(renderNow(), "renders an offset frame through a subwindow");
        bool outsideUntouched = true, insideFinite = true;
        int insideChanged = 0;
        for (int y = 5; y < 53; ++y) {
            for (int x = -7; x < 57; ++x) {
                const float *pixel = output->pixels.data() +
                    (static_cast<size_t>(y - 5) * 64 + (x + 7)) * 4;
                const bool inside = x >= 0 && x < 30 && y >= 10 && y < 40;
                for (int c = 0; c < 4; ++c) {
                    if (!inside) {
                        if (pixel[c] != -7.0f) outsideUntouched = false;
                    } else {
                        if (!std::isfinite(pixel[c])) insideFinite = false;
                        if (pixel[c] != -7.0f) ++insideChanged;
                    }
                }
            }
        }
        check(outsideUntouched, "leaves everything outside the window alone");
        check(insideFinite && insideChanged > 0, "fills the window with finite pixels");

        for (const auto &size : {std::make_pair(17, 9), std::make_pair(16, 16),
                                 std::make_pair(1, 1)}) {
            provision(size.first, size.second, 0, 0);
            char label[64];
            std::snprintf(label, sizeof(label), "renders %dx%d",
                          size.first, size.second);
            const bool ok = renderNow();
            bool finite = true;
            for (float value : output->pixels) {
                if (!std::isfinite(value)) finite = false;
            }
            check(ok && finite, label);
        }

        // Anamorphic pixels are resampled to a square grid for the isotropic grain/halation
        // kernels, then returned at the host's original dimensions.
        provision(24, 16, 0, 0);
        propSetDouble(handleOf(source->properties), kOfxImagePropPixelAspectRatio, 0, 2.0);
        check(renderNow() && output->pixels.size() == 24u * 16u * 4u,
              "normalizes non-square pixels without changing host geometry");
        bool anamorphicFinite = true;
        for (float value : output->pixels) {
            if (!std::isfinite(value)) anamorphicFinite = false;
        }
        check(anamorphicFinite, "produces finite output after square-pixel processing");
        propSetDouble(handleOf(source->properties), kOfxImagePropPixelAspectRatio, 0, 1.0);

        // A malformed host row stride must be rejected before a row copy can overrun it.
        provision(16, 16, 0, 0);
        propSetInt(handleOf(source->image), kOfxImagePropRowBytes, 0,
                   4 * static_cast<int>(sizeof(float)));
        const int strideBefore = gMessagesPosted;
        check(!renderNow(), "rejects a row stride shorter than one RGBA float row");
        check(gMessagesPosted == strideBefore + 1 && gLastMessageType == kOfxMessageError &&
                  gLastMessageText.find("row stride") != std::string::npos &&
                  gLastMessageText.find("16 bytes") != std::string::npos,
              "and tells the host which stride it was handed");
        // What makes a fetch fail is a property of the clip, not of the frame, so every frame of
        // a misconfigured delivery fails the same way. Said once through the host, like the
        // engine-error path: a thousand frames must not be a thousand dialogs.
        check(!renderNow() && gMessagesPosted == strideBefore + 1,
              "and the next frame refused for the same reason says nothing more");
        propSetInt(handleOf(source->image), kOfxImagePropRowBytes, 0,
                   16 * 4 * static_cast<int>(sizeof(float)));
        // Until it is fixed and broken again: the user has changed something in between, and
        // silence would leave the second mistake unreported.
        check(renderNow(), "renders once the stride is a row again");
        propSetInt(handleOf(source->image), kOfxImagePropRowBytes, 0,
                   4 * static_cast<int>(sizeof(float)));
        check(!renderNow() && gMessagesPosted == strideBefore + 2,
              "and a clip broken a second time is reported a second time");
        propSetInt(handleOf(source->image), kOfxImagePropRowBytes, 0,
                   16 * 4 * static_cast<int>(sizeof(float)));

        // A failed decoder or an upstream effect may hand an OFX host NaN/inf. Repair the bad
        // channels before invoking the engine without turning a recoverable frame into a host
        // render warning or error.
        std::printf("input\n");
        const int invalidBefore = gMessagesPosted;
        source->pixels[(4 * 16 + 3) * 4] = std::numeric_limits<float>::quiet_NaN();
        check(renderNow(), "repairs a NaN source channel without failing the render");
        source->pixels[(4 * 16 + 3) * 4] = 0.25f;
        source->pixels[(7 * 16 + 9) * 4 + 1] = std::numeric_limits<float>::infinity();
        check(renderNow(), "repairs an infinite source channel without failing the render");
        source->pixels[(7 * 16 + 9) * 4 + 1] = 0.2f;
        bool repairedFinite = true;
        for (float value : output->pixels) {
            if (!std::isfinite(value)) repairedFinite = false;
        }
        check(repairedFinite, "keeps repaired output finite");
        check(gMessagesPosted == invalidBefore,
              "without posting a render warning for repaired source frames");
        setParam(instance.params, "exposure",
                 std::numeric_limits<double>::quiet_NaN());
        check(!renderNow(), "rejects a non-finite parameter without reaching the engine");
        setParam(instance.params, "exposure", 0);
        check(gMessagesPosted == invalidBefore + 1 &&
                  gLastMessageType == kOfxMessageError,
              "and reports the corrupt parameter to the host");

        // Premultiplied input: the engine develops straight colour; the matte comes back
        // exactly as it went in, and a zero-alpha pixel must not divide its way to a NaN.
        std::printf("alpha\n");
        provision(32, 24, 0, 0);
        propSetString(handleOf(source->properties),
                      kOfxImageEffectPropPreMultiplication, 0, kOfxImagePreMultiplied);
        for (int y = 0; y < 24; ++y) {
            for (int x = 0; x < 32; ++x) {
                float *pixel = source->pixels.data() +
                               (static_cast<size_t>(y) * 32 + x) * 4;
                const float alpha = x >= 16 ? 0.5f : 1.0f;
                for (int c = 0; c < 3; ++c) pixel[c] *= alpha;
                pixel[3] = alpha;
            }
        }
        source->pixels[0] = source->pixels[1] = source->pixels[2] = 0;
        source->pixels[3] = 0;
        check(renderNow(), "renders premultiplied input");
        bool alphaKept = true, alphaFinite = true;
        for (int y = 0; y < 24; ++y) {
            for (int x = 0; x < 32; ++x) {
                const size_t at = (static_cast<size_t>(y) * 32 + x) * 4;
                for (int c = 0; c < 4; ++c) {
                    if (!std::isfinite(output->pixels[at + c])) alphaFinite = false;
                }
                if (output->pixels[at + 3] != source->pixels[at + 3]) alphaKept = false;
            }
        }
        check(alphaFinite, "with finite output everywhere, zero alpha included");
        check(alphaKept, "and the matte passes through unchanged");
        propSetString(handleOf(source->properties),
                      kOfxImageEffectPropPreMultiplication, 0, kOfxImageOpaque);

        // A display-referred label on data that provably is not: input above 1.05 under an
        // sRGB label earns one warning — the frame still renders, and a second frame says
        // nothing more.
        std::printf("range\n");
        provision(32, 24, 0, 0);
        source->pixels[(5 * 32 + 7) * 4 + 0] = 3.0f;  // one scene-referred highlight
        setParam(instance.params, "colorSpace",
                 static_cast<double>(fotufilm::Encoding::SRGB));
        const int rangeBefore = gMessagesPosted;
        check(renderNow(), "renders over-range input labelled sRGB");
        check(gMessagesPosted == rangeBefore + 1 &&
                  gLastMessageType == kOfxMessageWarning,
              "and warns that the label must be wrong");
        check(renderNow() && gMessagesPosted == rangeBefore + 1, "but says it only once");
        setParam(instance.params, "colorSpace",
                 static_cast<double>(fotufilm::Encoding::LinearDisplayP3));

        // Staging: the plugin decodes into the engine's own GPU buffers and reads the developed
        // frame straight back out of them, which is the purpose — the frame never crosses the
        // host/device boundary. A frame too large to develop in one pass still has to be striped
        // through host memory, and that path has to produce the very same picture. Striping only
        // happens on frames far too large to check by hand, so the budget is lowered instead.
        // Bracketed the way a delivery is, because that is what the parity is about: the frame
        // being kept has to be the same frame whichever path develops it. An unbracketed render
        // is a viewer frame, and a viewer frame is allowed to differ between the two paths.
        // A span, not a single frame: Resolve opens a sequence around one viewer frame too, so
        // the announced range is what separates a delivery from a scrub.
        PropertySet *deliveryArgs = newPropertySet();
        propSetDouble(handleOf(deliveryArgs), kOfxImageEffectPropFrameRange, 0, 0);
        propSetDouble(handleOf(deliveryArgs), kOfxImageEffectPropFrameRange, 1, 23);
        auto beginDelivery = [&] {
            return plugin->mainEntry(kOfxImageEffectActionBeginSequenceRender, instanceHandle,
                                     handleOf(deliveryArgs), nullptr) == kOfxStatOK;
        };
        auto endDelivery = [&] {
            return plugin->mainEntry(kOfxImageEffectActionEndSequenceRender, instanceHandle,
                                     handleOf(deliveryArgs), nullptr) == kOfxStatOK;
        };

        std::printf("staging\n");
        provision(48, 32, 0, 0);
        // With grain on, so the comparison covers the seeded, frame-coordinate-keyed stages: a
        // strip is developed with its own row origin, and grain that did not agree with the
        // whole-frame dispatch about where it sits would show up here and nowhere else.
        setParam(instance.params, "grain", 1);
        check(renderNow(), "renders a frame the engine stages");
        const std::vector<float> stagedFrame = output->pixels;
        if (gLinkedIn) {
            FotufilmBridgeContext first = fotufilm_bridge_context_create();
            FotufilmBridgeContext second = fotufilm_bridge_context_create();
            float *firstIn = nullptr, *firstOut = nullptr;
            float *secondIn = nullptr, *secondOut = nullptr;
            const bool firstStaged = fotufilm_bridge_frame_staging(
                first, 48, 32, &firstIn, &firstOut) == 1;
            const bool secondStaged = fotufilm_bridge_frame_staging(
                second, 48, 32, &secondIn, &secondOut) == 1;
            check(firstStaged && secondStaged && firstIn && firstOut && secondIn && secondOut &&
                      firstIn != firstOut && secondIn != secondOut &&
                      firstIn != secondIn && firstOut != secondOut,
                  "and concurrent contexts borrow distinct frame staging");

            float parameters[FOTUFILM_BRIDGE_PARAMETER_COUNT] = {};
            for (int pixel = 0; firstStaged && secondStaged && pixel < 48 * 32; ++pixel) {
                for (int channel = 0; channel < 3; ++channel) {
                    firstIn[pixel * 4 + channel] = 0.18f;
                    secondIn[pixel * 4 + channel] = 0.5f;
                }
                firstIn[pixel * 4 + 3] = 1.0f;
                secondIn[pixel * 4 + 3] = 1.0f;
            }
            float firstReference = 0, secondReference = 0;
            bool concurrentResultsAreStable = true;
            for (int round = 0; round < 8; ++round) {
                std::atomic<int> ready{0};
                std::atomic<bool> go{false};
                int firstResult = 0, secondResult = 0;
                auto develop = [&](FotufilmBridgeContext context, int *result) {
                    ++ready;
                    while (!go.load(std::memory_order_acquire)) std::this_thread::yield();
                    *result = fotufilm_bridge_render_staged(
                        context, 0, 0, 0, parameters, 0, 48, 32, 0, 0, nullptr,
                        nullptr, nullptr);
                };
                std::thread firstRender(develop, first, &firstResult);
                std::thread secondRender(develop, second, &secondResult);
                while (ready.load(std::memory_order_acquire) != 2) std::this_thread::yield();
                go.store(true, std::memory_order_release);
                firstRender.join();
                secondRender.join();
                concurrentResultsAreStable = concurrentResultsAreStable &&
                    firstResult == 1 && secondResult == 1 &&
                    std::isfinite(firstOut[0]) && std::isfinite(secondOut[0]) &&
                    firstOut[0] != secondOut[0];
                if (round == 0) {
                    firstReference = firstOut[0];
                    secondReference = secondOut[0];
                } else {
                    concurrentResultsAreStable = concurrentResultsAreStable &&
                        firstOut[0] == firstReference && secondOut[0] == secondReference;
                }
            }
            check(concurrentResultsAreStable,
                  "and repeatedly develop simultaneously without crossing outputs");
            fotufilm_bridge_release_staging(first);
            fotufilm_bridge_release_staging(second);
            fotufilm_bridge_context_destroy(first);
            fotufilm_bridge_context_destroy(second);
        }

        setenv("FOTUFILM_STRIP_BUDGET", "98304", 1);
        if (gLinkedIn) {
            FotufilmBridgeContext context = fotufilm_bridge_context_create();
            float *stagedIn = nullptr, *stagedOut = nullptr;
            check(fotufilm_bridge_frame_staging(
                      context, 48, 32, &stagedIn, &stagedOut) == 0,
                  "a budget too small for one pass refuses the staging");
            fotufilm_bridge_context_destroy(context);
        }
        std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
        check(renderNow(), "renders the same frame striped through host memory");
        check(output->pixels == stagedFrame,
              "bit for bit the frame the staged path developed");

        // A purge hands back the striped path's frame and band and any borrowed staging; the
        // next frame reclaims them and develops the same picture.
        check(plugin->mainEntry(kOfxActionPurgeCaches, instanceHandle, nullptr, nullptr) ==
                  kOfxStatOK, "purges its caches on request");
        std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
        check(renderNow() && output->pixels == stagedFrame,
              "and the next striped frame is the same frame");

        // A striped frame cannot measure its glare in the kernel, whatever the host says about
        // the session, so a striped viewer frame is the striped delivered frame — and the encode
        // question the plugin asks for it must be the striped road's, not the staged road's.
        propSetInt(handleOf(renderArgs), kOfxImageEffectPropInteractiveRenderStatus, 0, 1);
        std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
        check(renderNow() && output->pixels == stagedFrame,
              "a striped viewer frame is bit for bit the striped delivered frame");
        propSetInt(handleOf(renderArgs), kOfxImageEffectPropInteractiveRenderStatus, 0, 0);
        if (gLinkedIn) {
            FotufilmBridgeContext striped = fotufilm_bridge_context_create();
            float *in = nullptr, *out = nullptr;
            float parameters[FOTUFILM_BRIDGE_PARAMETER_COUNT] = {};
            const bool refused = fotufilm_bridge_frame_staging(striped, 48, 32, &in, &out) == 0;
            const int32_t delivered = fotufilm_bridge_encodes_output(
                striped, 0, 0, 0, parameters, 48, 32, 0);
            const int32_t viewer = fotufilm_bridge_encodes_output(
                striped, 0, 0, 0, parameters, 48, 32, 1);
            // Honest about what this can and cannot prove. It pins the contract the header
            // states — with no staging held the flag is not part of the question — but it
            // cannot fail on the kernels shipped today, and that was checked rather than
            // assumed: asking the bridge with the flag on while it holds no staging still
            // answers 1 on both schedules. `carriesOutputTransform` adopts the
            // glare-measuring variant only after finding it exists, so the flag can only ever
            // turn a *no* into a *yes* — and only if the plain encode variant were withdrawn
            // while its flare-measuring twin stayed. That is the frame this guards: a promise
            // the striped render would then be unable to keep, which fails the render.
            check(refused && delivered == 1 && viewer == delivered,
                  "and with no staging held the encode query ignores the viewer flag");
            fotufilm_bridge_context_destroy(striped);
        }

        // A striped frame with no staging to decode into is decoded a band at a time, and the
        // bands are cut on free memory rather than on anything about the picture — so the frame
        // must not depend on where they fell. Held striped against striped, and on a frame that
        // varies down as well as across, because a horizontal ramp lets any row stand in for any
        // other and a band that landed at the wrong one would go unseen. Not held against the
        // staged frame: that comparison is the engine's strip parity, which is a separate question
        // and, on a vertically varying frame, a separate answer.
        provision(48, 32, 0, 0, true);
        std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
        check(renderNow(), "renders a frame that varies down the frame as well as across");
        const std::vector<float> wholeBand = output->pixels;
        // Seven rows to a band, so the frame is decoded in four of them and a short one.
        setenv("FOTUFILM_DECODE_BAND_BYTES", "5376", 1);
        std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
        check(renderNow(), "and decodes it again in bands of seven rows");
        check(output->pixels == wholeBand,
              "bit for bit the frame one band reached");
        unsetenv("FOTUFILM_DECODE_BAND_BYTES");
        provision(48, 32, 0, 0);

        unsetenv("FOTUFILM_STRIP_BUDGET");
        std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
        check(renderNow() && output->pixels == stagedFrame,
              "and staging resumes when the budget does");

        // A purge arriving while a render of the same node is in flight. The host is entitled to
        // send one from any thread — nothing in `kOfxActionPurgeCaches` promises otherwise, and
        // `kOfxImageEffectRenderInstanceSafe` says nothing about it — and what it frees is the
        // decoded frame, the decode band and the engine's borrowed staging, all of which the
        // render in flight is holding raw pointers into.
        //
        // Driven from the plugin's own abort poll, which runs on the render thread from inside
        // the engine: it is the one moment the harness can be certain a render is genuinely
        // mid-frame. The purge is fired onto a second thread and not waited for, because the
        // whole point is that it blocks until the frame is finished. After it returns it claims
        // the freed memory back and writes over it, which is what any host doing anything at all
        // would do — so a purge that did not wait leaves the engine reading poison rather than
        // reading memory that merely happens to still be intact.
        {
            std::printf("purge during a render\n");
            // The purger is started before the render and parked, so that firing it costs a
            // store rather than a thread creation — a render this size finishes in less time
            // than `std::thread` takes to come up, and a purge that arrives after the frame
            // proves nothing. Once released it purges, then claims the freed blocks back and
            // writes over them, which is what a host that allocates anything at all would do.
            // The render thread waits inside the abort poll — still mid-frame, still holding
            // every pointer — until the purger says it is through or the wait times out. With
            // the lock in place the purge cannot get through, so the wait always times out and
            // the frame is untouched; without it the purge completes, the poison lands, and the
            // engine reads it.
            static OfxPlugin *purgePlugin = nullptr;
            static OfxImageEffectHandle purgeHandle = nullptr;
            static std::atomic<bool> purgeGo{false};
            static std::atomic<bool> purgeDone{false};
            static std::atomic<int> purgeStatus{-1};
            static std::atomic<int> purgesFired{0};
            static std::atomic<bool> purgeSawFrame{false};
            purgePlugin = plugin;
            purgeHandle = instanceHandle;

            std::thread purgeThread([] {
                while (!purgeGo.load(std::memory_order_acquire)) std::this_thread::yield();
                purgeStatus.store(purgePlugin->mainEntry(kOfxActionPurgeCaches, purgeHandle,
                                                         nullptr, nullptr));
                // The decoded frame and the decode band are both this many bytes at 96x64, so
                // the free list hands them straight back.
                std::vector<std::vector<float>> claimed;
                for (int i = 0; i < 128; ++i) claimed.emplace_back(96 * 64 * 4, -98765.0f);
                purgeDone.store(true, std::memory_order_release);
            });

            auto fire = [] {
                ++purgesFired;
                purgeGo.store(true, std::memory_order_release);
                const auto until = std::chrono::steady_clock::now() +
                                   std::chrono::milliseconds(50);
                while (!purgeDone.load(std::memory_order_acquire) &&
                       std::chrono::steady_clock::now() < until) {
                    std::this_thread::yield();
                }
                purgeSawFrame.store(!purgeDone.load(std::memory_order_acquire));
            };

            auto raceOnce = [&](const char *what) {
                std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
                check(renderNow(), what);
                purgeThread.join();
            };

            // Striped first: the frame it is reading is the instance's own vector, which is
            // exactly what the purge hands back.
            setenv("FOTUFILM_STRIP_BUDGET", "98304", 1);
            provision(96, 64, 0, 0, true);
            setParam(instance.params, "grain", 1);
            std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
            check(renderNow(), "renders a striped frame with nothing else happening");
            const std::vector<float> unpurgedStripe = output->pixels;
            gAbortHook = fire;
            raceOnce("renders the same striped frame while a purge is fired mid-frame");
            check(purgesFired.load() == 1 && purgeStatus.load() == kOfxStatOK,
                  "the purge arrived during the frame and was accepted");
            check(purgeSawFrame.load(),
                  "and was made to wait for the frame rather than freeing under it");
            check(output->pixels == unpurgedStripe,
                  "so the frame is bit for bit the one no purge interrupted");

            // Then staged, where what the render holds is the engine's own device-backed staging
            // and the purge hands *that* back.
            unsetenv("FOTUFILM_STRIP_BUDGET");
            std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
            check(renderNow(), "renders a staged frame with nothing else happening");
            const std::vector<float> unpurgedStaged = output->pixels;
            purgesFired.store(0);
            purgeStatus.store(-1);
            purgeGo.store(false);
            purgeDone.store(false);
            purgeSawFrame.store(false);
            std::thread stagedPurgeThread([] {
                while (!purgeGo.load(std::memory_order_acquire)) std::this_thread::yield();
                purgeStatus.store(purgePlugin->mainEntry(kOfxActionPurgeCaches, purgeHandle,
                                                         nullptr, nullptr));
                purgeDone.store(true, std::memory_order_release);
            });
            gAbortHook = fire;
            std::fill(output->pixels.begin(), output->pixels.end(), -7.0f);
            check(renderNow(),
                  "renders the same staged frame while a purge is fired mid-frame");
            stagedPurgeThread.join();
            check(purgesFired.load() == 1 && purgeStatus.load() == kOfxStatOK,
                  "the purge arrived during that frame too");
            check(purgeSawFrame.load(),
                  "and waited for it rather than handing the staging back under the engine");
            check(output->pixels == unpurgedStaged,
                  "so that frame is bit for bit the one no purge interrupted");
            gAbortHook = nullptr;
            provision(48, 32, 0, 0);
        }

        setParam(instance.params, "grain", 0);

        // The kernel's own encode against libm's, on developed pixels. Everything above holds the
        // engine to itself; TranscodeParity holds the coefficient form of each curve to the
        // closed form, but on the host, where both are libm. This is the only place the two
        // arithmetics meet: Metal's `pow` and `log` are not the system's, and the frame the host
        // writes out now comes from Metal's.
        //
        // Driven through the bridge rather than through the plugin because the plugin has no way
        // to be asked for the same frame twice, once each way — the colour space chooses the
        // decode as well as the encode, so two renders through it are two different pictures. The
        // bridge takes the transform as its own argument, so the same developed light can be
        // encoded both ways and subtracted.
        if (gLinkedIn) {
            std::printf("kernel encode\n");
            const int width = 48, height = 32;
            const int count = width * height;
            float parameters[FOTUFILM_BRIDGE_PARAMETER_COUNT] = {};
            FotufilmBridgeContext bridgeContext = fotufilm_bridge_context_create();
            float *scenePixels = nullptr, *developedPixels = nullptr;
            const bool staged = fotufilm_bridge_frame_staging(
                bridgeContext, width, height, &scenePixels, &developedPixels) == 1;
            check(staged, "stages a frame to develop both ways");

            // Scene-linear Rec.2020, opaque: a diagonal ramp two and a half stops over white
            // crossed with three saturated primaries, so the print reaches both ends of every
            // curve and the matrix has something off-axis to carry.
            std::vector<float> scene(static_cast<size_t>(count) * 4, 0.0f);
            for (int y = 0; staged && y < height; ++y) {
                for (int x = 0; x < width; ++x) {
                    float *pixel = scene.data() + (static_cast<size_t>(y) * width + x) * 4;
                    const float ramp = 5.5f * (x + y) / (width + height);
                    const int wedge = (3 * x) / width;
                    for (int c = 0; c < 3; ++c) pixel[c] = ramp * (c == wedge ? 1.0f : 0.25f);
                    pixel[3] = (x % 3) * 0.5f;
                }
            }

            auto develop = [&](FotufilmOutputTransform *transform) {
                std::memcpy(scenePixels, scene.data(), scene.size() * sizeof(float));
                return fotufilm_bridge_render_staged(
                           bridgeContext, 0, 0, 0, parameters, 0, width, height, 0,
                           0, transform, nullptr, nullptr) == 1;
            };

            std::vector<float> light;
            const bool developed = staged && develop(nullptr);
            check(developed, "develops it once into display-linear light");
            if (developed) light.assign(developedPixels, developedPixels + scene.size());

            bool everyCurveCarried = true, everyCurveAgrees = true;
            double worstEncode = 0;
            const char *worstEncodeWhere = "none";
            for (bool fit : {false, true}) {
            for (bool premultiplied : {false, true}) {
            for (int e = 0; !light.empty() && e < static_cast<int>(fotufilm::Encoding::Count);
                 ++e) {
                const auto encoding = static_cast<fotufilm::Encoding>(e);
                const fotufilm::Transform transform = fotufilm::transformFor(encoding);
                const fotufilm::OutputTransform curve = fotufilm::outputTransformFor(encoding);
                FotufilmOutputTransform wanted{};
                wanted.transfer = curve.shape;
                wanted.premultiplied = premultiplied ? 1 : 0;
                std::memcpy(wanted.matrix, transform.fromWorking, sizeof(wanted.matrix));
                std::memcpy(wanted.coefficients, curve.coefficients,
                            sizeof(wanted.coefficients));

                if (fit) {
                    std::memcpy(wanted.gamutLuminance, transform.luminance,
                                sizeof(wanted.gamutLuminance));
                }

                if (fotufilm_bridge_encodes_output(
                        bridgeContext, 0, 0, 0, parameters, width, height, 0) != 1) {
                    everyCurveCarried = false;
                    continue;
                }
                if (!develop(&wanted)) {
                    everyCurveAgrees = false;
                    continue;
                }

                // The host's answer for the very same light. The plain float path floors the
                // developed pixel at zero and so does the encoding one, so no clamp belongs here
                // — `light` is already what the host would have been handed.
                std::vector<float> reference(light.size());
                fotufilm::encodePixels(encoding, transform, light.data(), reference.data(),
                                      count, premultiplied, fit);
                for (size_t i = 0; i < reference.size(); ++i) {
                    const double gap = std::fabs(
                        static_cast<double>(reference[i]) - developedPixels[i]);
                    if (gap > worstEncode) {
                        worstEncode = gap;
                        worstEncodeWhere = fotufilm::encodingLabel(encoding);
                    }
                }
            }
            }
            }
            check(everyCurveCarried, "carries every curve with and without gamut fitting and alpha");
            check(everyCurveAgrees, "and develops a frame through each");
            std::printf("       kernel vs libm: max |d| %.3e (16-bit LSB %.3e, worst %s)\n",
                        worstEncode, 1.0 / 65535.0, worstEncodeWhere);
            check(!light.empty() && worstEncode < 0.25 / 65535.0,
                  "and lands within a quarter of a 16-bit LSB of the host's own encode");
            fotufilm_bridge_release_staging(bridgeContext);
            fotufilm_bridge_context_destroy(bridgeContext);
        }

        // Realtime arithmetic is uniform across viewer and delivery frames. The opt-out restores
        // the reference renderer's earlier split: a disposable viewer may measure glare on the
        // device, while a delivery uses the host reduction for striped-path parity.
        std::printf("viewer frames\n");
        check(renderNow(), "renders a delivered frame");
        const std::vector<float> deliveredFrame = output->pixels;

        check(beginDelivery() && renderNow() && endDelivery(),
              "a bracketed frame renders");
        check(output->pixels == deliveredFrame,
              "and a sequence bracket alone does not make a frame a viewer frame");

        propSetInt(handleOf(renderArgs), kOfxImageEffectPropInteractiveRenderStatus, 0, 1);
        check(renderNow(), "renders a frame the host says is for an interactive session");
        double viewerDrift = 0;
        for (size_t i = 0; i < deliveredFrame.size(); ++i) {
            const double difference =
                std::fabs(output->pixels[i] - deliveredFrame[i]);
            if (difference > viewerDrift) viewerDrift = difference;
        }
        std::printf("       viewer vs delivered: max |d| %.3e (16-bit LSB %.3e)\n",
                    viewerDrift, 1.0 / 65535.0);
        if (expectedRealtime) {
            check(viewerDrift == 0,
                  "a realtime viewer frame is identical to the delivered one");
        } else {
            check(viewerDrift < 1.0 / 65535.0,
                  "a reference viewer frame stays within a 16-bit LSB of delivery");
        }

        // A host walking the timeline in order is delivering, whatever else it says about the
        // session — that is the flag that has to win, because it is the one that means "kept".
        propSetInt(handleOf(renderArgs), kOfxImageEffectPropSequentialRenderStatus, 0, 1);
        check(renderNow() && output->pixels == deliveredFrame,
              "a sequential render is delivery even while the session is interactive");
        propSetInt(handleOf(renderArgs), kOfxImageEffectPropSequentialRenderStatus, 0, 0);

        propSetInt(handleOf(renderArgs), kOfxImageEffectPropInteractiveRenderStatus, 0, 0);
        propSetInt(handleOf(renderArgs), kOfxImageEffectPropRenderQualityDraft, 0, 1);
        check(renderNow(), "renders a draft-quality frame");
        propSetInt(handleOf(renderArgs), kOfxImageEffectPropRenderQualityDraft, 0, 0);
        check(renderNow() && output->pixels == deliveredFrame,
              "and the interactive choice never leaks into the next delivered frame");

        // Opt-in end-to-end benchmark of the actual OFX path: host float rows through decode,
        // Metal develop, and encode back into the host output. Kept out of the normal harness so
        // correctness checks stay quick; performance work can set the frame count explicitly.
        if (const char *requested = std::getenv("FOTUFILM_BENCHMARK_4K")) {
            const int frames = std::max(1, std::min(120, std::atoi(requested)));
            std::printf("4K benchmark\n");
            double savedTime = 0;
            propGetDouble(handleOf(renderArgs), kOfxPropTime, 0, &savedTime);
            const char *budgetSetting = std::getenv("FOTUFILM_BENCHMARK_BUDGET_MS");
            const double budgetMs = budgetSetting ? std::atof(budgetSetting) : 15.0;
            std::vector<double> timings;
            provision(3840, 2160, 0, 0, true);
            setChoice(plugin, instanceHandle, instance.params, "stock", 0);
            // Match the plugin's normal 35 mm default. Smaller gauges deliberately render
            // larger film structures and remain useful stress cases, but are not the playback
            // target this benchmark names.
            setChoice(plugin, instanceHandle, instance.params, "format", 3);
            setChoice(plugin, instanceHandle, instance.params, "paper", 0);
            setParam(instance.params, "grain", 1);
            setParam(instance.params, "colorSpace",
                     static_cast<double>(fotufilm::Encoding::DaVinciIntermediate));
            check(renderNow(), "warms the 4K render path");

            double total = 0;
            double best = std::numeric_limits<double>::infinity();
            bool complete = true;
            for (int frame = 0; frame < frames; ++frame) {
                propSetDouble(handleOf(renderArgs), kOfxPropTime, 0, frame);
                const auto began = std::chrono::steady_clock::now();
                complete = renderNow() && complete;
                const double elapsed = std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - began).count();
                total += elapsed;
                best = std::min(best, elapsed);
                timings.push_back(elapsed * 1000.0);
            }
            propSetDouble(handleOf(renderArgs), kOfxPropTime, 0, savedTime);
            std::sort(timings.begin(), timings.end());
            const double medianMs = (timings[(frames - 1) / 2] + timings[frames / 2]) * 0.5;
            const double p95Ms = timings[static_cast<size_t>(std::ceil(frames * 0.95)) - 1];
            const int overBudget = static_cast<int>(std::count_if(timings.begin(), timings.end(),
                [&](double ms) { return ms >= budgetMs; }));
            const double averageMs = 1000.0 * total / frames;
            std::printf("       %d frames: %.2f ms average, %.2f ms median, %.2f ms p95, "
                        "%.2f ms best; %d at/over %.2f ms budget\n",
                        frames, averageMs, medianMs, p95Ms, best * 1000.0,
                        overBudget, budgetMs);
            if (const char *dumpPath = std::getenv("FOTUFILM_BENCHMARK_DUMP")) {
                FILE *dump = std::fopen(dumpPath, "wb");
                const bool written = dump && std::fwrite(output->pixels.data(), sizeof(float),
                    output->pixels.size(), dump) == output->pixels.size();
                if (dump) std::fclose(dump);
                check(written, "writes the last measured 4K frame");
            }
            check(complete, "renders every 4K benchmark frame");
            check(std::isfinite(budgetMs) && budgetMs > 0 && overBudget == 0,
                  "keeps every measured 4K frame under the requested budget");
        }

        // The pipeline spans. The claim worth checking here is not that each renders, but that
        // Negative Only followed by Print Only reproduces Full — through the plugin, over the
        // host's own images, with the interchange crossing as the host would carry it.
        std::printf("pipeline stages\n");
        setChoice(plugin, instanceHandle, instance.params, "stock", 0);
        setParam(instance.params, "grain", 1);
        setParam(instance.params, "colorSpace",
                 spaceMenuIndex(fotufilm::Encoding::LinearRec2020));
        provision(96, 64, 0, 0, true);

        const int stages = static_cast<int>(optionCount(instance.params, "stage"));
        check(stages == 4, "offers the four pipeline spans");
        check(instance.params.params.count("stageID") == 1,
              "persists the span by a durable id, not a menu position");
        {
            auto found = instance.params.params.find("stage");
            int animates = 1;
            if (found != instance.params.params.end()) {
                propGetInt(handleOf(found->second->properties),
                           kOfxParamPropAnimates, 0, &animates);
            }
            check(animates == 0,
                  "and refuses to animate: a span changes what the frames mean");
        }
        check(instance.params.params.count("texture_grain") == 1 &&
                  instance.params.params.count("texture_halation") == 1,
              "defines the texture span's stage selection");

        // Moving the menu writes the identity, which is what a reopened project resolves against.
        setChoice(plugin, instanceHandle, instance.params, "stage", 1);
        check(getString(instance.params, "stageID") == "negative",
              "moving the menu records the span's id");

        setChoice(plugin, instanceHandle, instance.params, "stage", 0);
        check(renderNow(), "renders the full span");
        const std::vector<float> full = output->pixels;

        setChoice(plugin, instanceHandle, instance.params, "stage", 1);
        check(renderNow(), "renders the negative span");
        std::vector<float> negative = output->pixels;
        float peakDensity = 0;
        bool insideInterchange = true;
        for (size_t i = 0; i < negative.size(); ++i) {
            if (i % 4 == 3) continue;
            peakDensity = std::max(peakDensity, negative[i]);
            if (!(negative[i] > -0.5f && negative[i] < 8.0f)) insideInterchange = false;
        }
        check(insideInterchange, "and its densities stay inside the stated interchange range");
        check(peakDensity > 1.0f,
              "and reach past display white, as a developed negative does");

        // The host carries the interchange from one node to the next; here that is the copy
        // Resolve would make along the link, with nothing applied to it.
        std::copy(negative.begin(), negative.end(), source->pixels.begin());
        setChoice(plugin, instanceHandle, instance.params, "stage", 2);
        check(renderNow(), "renders the print span from the negative span's output");
        double worst = 0;
        size_t worstAt = 0;
        for (size_t i = 0; i < full.size(); ++i) {
            const double difference = std::abs(
                static_cast<double>(output->pixels[i]) - full[i]);
            if (difference > worst) { worst = difference; worstAt = i; }
        }
        size_t overLSB = 0;
        double total = 0;
        for (size_t i = 0; i < full.size(); ++i) {
            const double difference = std::abs(
                static_cast<double>(output->pixels[i]) - full[i]);
            if (difference > 1.0 / 65535.0) ++overLSB;
            total += difference;
        }
        std::printf("       negative -> print vs full: %.3g worst component "
                    "(pixel %zu channel %zu: %.6f vs %.6f), %.3g mean, "
                    "%zu/%zu over a 16-bit LSB\n",
                    worst, worstAt / 4, worstAt % 4,
                    static_cast<double>(output->pixels[worstAt]), full[worstAt],
                    total / full.size(), overLSB, full.size());
        // Measured on this frame, 2026-09-01: the reference schedule lands 1.19e-7 worst and
        // 8.3e-9 mean — one float ulp at unity, the interchange's own rounding — and the
        // realtime schedule 1.37e-6 worst and 1.8e-7 mean, its half-float intermediates against
        // the float32 the split writes. Held at roughly twice that, so a seam that starts
        // developing a different negative on one side shows up long before a sixteen-bit step.
        const bool realtimeSplit = fotufilm_bridge_realtime_enabled() != 0;
        const double worstAllowed = realtimeSplit ? 3.0e-6 : 2.5e-7;
        const double meanAllowed = realtimeSplit ? 4.0e-7 : 2.0e-8;
        check(worst < worstAllowed,
              realtimeSplit ? "the split reproduces Full within 3e-6 on the realtime schedule"
                            : "the split reproduces Full within 2.5e-7 on the reference schedule");
        check(total / full.size() < meanAllowed,
              realtimeSplit ? "and within 4e-7 on average"
                            : "and within 2e-8 on average");
        check(overLSB == 0, "and nothing over a sixteen-bit step");
        // Each span tells the host what it is handing over. The two halves of the split carry
        // data — densities in one direction, an already-encoded print in the other — and the host
        // must apply nothing to either.
        {
            PropertySet *preferences = newPropertySet();
            plugin->mainEntry(kOfxImageEffectActionGetClipPreferences, instanceHandle,
                              nullptr, handleOf(preferences));
            char *preferred = nullptr;
            propGetString(handleOf(preferences),
                          "OfxImageClipPropPreferredColourspaces_Source", 0, &preferred);
            check(preferred && std::strcmp(preferred, kOfxColourspaceRaw) == 0,
                  "the print span asks the host not to touch its input");
            int printVarying = 1;
            propGetInt(handleOf(preferences), kOfxImageEffectFrameVarying, 0, &printVarying);
            check(printVarying == 0,
                  "and does not claim to vary with the frame, adding no grain of its own");
            PropertySet *outputColour = newPropertySet();
            plugin->mainEntry(kOfxImageEffectActionGetOutputColourspace, instanceHandle,
                              nullptr, handleOf(outputColour));
            char *selected = nullptr;
            propGetString(handleOf(outputColour), kOfxImageClipPropColourspace, 0, &selected);
            check(selected && std::strcmp(selected, kOfxColourspaceRaw) == 0,
                  "and not to encode its output a second time");
        }

        // Auto has nothing to read on a print node: what arrives is data, and the space the print
        // is encoded into has to be named. Refused rather than guessed.
        {
            const int before = gMessagesPosted;
            setChoice(plugin, instanceHandle, instance.params, "colorSpace", 7);
            check(getString(instance.params, "colorSpaceStatus").find("Required:") == 0,
                  "Print Only Auto shows the missing output-space requirement in the panel");
            check(plugin->mainEntry(kOfxImageEffectActionRender, instanceHandle,
                                    handleOf(renderArgs), nullptr) == kOfxStatFailed,
                  "the print span refuses to guess its output space");
            check(gMessagesPosted > before && gLastMessageType == kOfxMessageError,
                  "and says so through the host");
            setParam(instance.params, "colorSpace",
                     spaceMenuIndex(fotufilm::Encoding::LinearRec2020));
        }

        // The texture selection follows the film. A control the chosen stock has nothing behind
        // is disabled rather than left live to do nothing, and the panel has to follow the stock
        // menu as well as the span menu — the two together are what decides it.
        {
            setChoice(plugin, instanceHandle, instance.params, "stage", 3);
            // Derived from the bridge's own ids exactly as the plugin derives them, so the two
            // cannot name different controls.
            std::vector<std::string> textureNames;
            for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
                char id[128] = "";
                if (fotufilm_bridge_texture_stage_id(i, id, sizeof(id)) < 0) continue;
                std::string name = std::string("texture_") + id;
                for (char &c : name) { if (c == '-') c = '_'; }
                textureNames.push_back(name);
            }
            const size_t textureCount = textureNames.size();
            check(textureCount > 0, "the bridge names the texture span's stages");
            int stocksSeen = 0, everWithheld = 0, everOffered = 0;
            for (size_t st = 0; st < stocks; ++st) {
                setChoice(plugin, instanceHandle, instance.params, "stock",
                          static_cast<int>(st));
                ++stocksSeen;
                for (size_t i = 0; i < textureCount; ++i) {
                    auto found = instance.params.params.find(textureNames[i]);
                    if (found == instance.params.params.end()) continue;
                    int enabled = 1;
                    propGetInt(handleOf(found->second->properties),
                               kOfxParamPropEnabled, 0, &enabled);
                    const bool offered = fotufilm_bridge_texture_stage_available(
                        static_cast<int32_t>(st), static_cast<int32_t>(i)) != 0;
                    if (enabled != (offered ? 1 : 0)) {
                        check(false, "a texture stage's control follows the film");
                    }
                    offered ? ++everOffered : ++everWithheld;
                }
            }
            check(stocksSeen > 0 && everOffered > 0,
                  "every stock's texture selection follows what that film offers");
            std::printf("       %d texture controls offered, %d withheld across %d stocks\n",
                        everOffered, everWithheld, stocksSeen);
            setChoice(plugin, instanceHandle, instance.params, "stock", 0);
            setChoice(plugin, instanceHandle, instance.params, "stage", 0);
        }

        // Reopened projects must resolve the stable ID instead of the saved menu index.
        setParam(instance.params, "stage", 0);
        setString(instance.params, "stageID", "print");
        check(plugin->mainEntry(kOfxActionCreateInstance, instanceHandle, nullptr,
                                nullptr) == kOfxStatOK,
              "re-creates the instance over a restored span");
        check(getInt(instance.params, "stage") == FOTUFILM_BRIDGE_STAGE_PRINT,
              "createInstance moves the span menu to the id it was saved with");

        // And a span this build does not have: reported, kept, and rendered around — the same
        // contract a stock from an uninstalled pack gets, for the same reason.
        {
            const int before = gMessagesPosted;
            setString(instance.params, "stageID", "not-a-stage");
            setParam(instance.params, "stage", 0);
            plugin->mainEntry(kOfxActionCreateInstance, instanceHandle, nullptr, nullptr);
            check(gMessagesPosted > before, "an unknown span is reported to the host");
            check(getString(instance.params, "stageID") == "not-a-stage",
                  "and its id is kept, so a newer build heals the project");
        }
        setChoice(plugin, instanceHandle, instance.params, "stage", 0);

        // Texture Only with nothing selected is a copy, in whatever space the frame arrived in.
        provision(96, 64, 0, 0, true);
        const std::vector<float> beforeTexture = source->pixels;
        setChoice(plugin, instanceHandle, instance.params, "stage", 3);
        for (const char *name : {"texture_emulsion_mtf", "texture_halation",
                                 "texture_adjacency", "texture_grain",
                                 "texture_enlarger"}) {
            setParam(instance.params, name, 0);
        }
        {
            // Declared as such, so a host can pass the source straight through rather than
            // develop it twice to multiply by one.
            PropertySet *identityArgs = newPropertySet();
            propSetDouble(handleOf(identityArgs), kOfxPropTime, 0, 3);
            PropertySet *identityAnswer = newPropertySet();
            const OfxStatus answered = plugin->mainEntry(
                kOfxImageEffectActionIsIdentity, instanceHandle, handleOf(identityArgs),
                handleOf(identityAnswer));
            char *passThrough = nullptr;
            propGetString(handleOf(identityAnswer), kOfxPropName, 0, &passThrough);
            double identityTime = -1;
            propGetDouble(handleOf(identityAnswer), kOfxPropTime, 0, &identityTime);
            check(answered == kOfxStatOK && passThrough &&
                      std::strcmp(passThrough, kOfxImageEffectSimpleSourceClipName) == 0 &&
                      identityTime == 3,
                  "an unselected texture span declares itself the identity on the source");
            PropertySet *unvarying = newPropertySet();
            plugin->mainEntry(kOfxImageEffectActionGetClipPreferences, instanceHandle,
                              nullptr, handleOf(unvarying));
            int textureVarying = 1;
            propGetInt(handleOf(unvarying), kOfxImageEffectFrameVarying, 0, &textureVarying);
            check(textureVarying == 0, "and does not vary with the frame");

            setParam(instance.params, "texture_grain", 1);
            PropertySet *grainAnswer = newPropertySet();
            check(plugin->mainEntry(kOfxImageEffectActionIsIdentity, instanceHandle,
                                    handleOf(identityArgs), handleOf(grainAnswer)) ==
                          kOfxStatReplyDefault &&
                      grainAnswer->strings.count(kOfxPropName) == 0,
                  "selecting grain makes it a render again");
            PropertySet *varying = newPropertySet();
            plugin->mainEntry(kOfxImageEffectActionGetClipPreferences, instanceHandle,
                              nullptr, handleOf(varying));
            int grainVarying = 0;
            propGetInt(handleOf(varying), kOfxImageEffectFrameVarying, 0, &grainVarying);
            check(grainVarying == 1, "and one that varies with the frame");
            setParam(instance.params, "texture_grain", 0);

            setChoice(plugin, instanceHandle, instance.params, "stage", 0);
            PropertySet *fullAnswer = newPropertySet();
            check(plugin->mainEntry(kOfxImageEffectActionIsIdentity, instanceHandle,
                                    handleOf(identityArgs), handleOf(fullAnswer)) ==
                          kOfxStatReplyDefault &&
                      fullAnswer->strings.count(kOfxPropName) == 0,
                  "the full span is never the identity");
            setChoice(plugin, instanceHandle, instance.params, "stage", 3);
        }
        for (int index = 0; index < static_cast<int>(fotufilm::Encoding::Count); ++index) {
            const auto space = static_cast<fotufilm::Encoding>(index);
            setParam(instance.params, "colorSpace", spaceMenuIndex(space));
            if (!renderNow()) { check(false, "renders the texture span"); continue; }
            double moved = 0;
            for (size_t i = 0; i < beforeTexture.size(); ++i) {
                moved = std::max(moved, std::abs(
                    static_cast<double>(output->pixels[i]) - beforeTexture[i]));
            }
            std::printf("       texture no-op in %s: %.3g\n",
                        fotufilm::encodingLabel(space), moved);
            // Not exactly zero, and what is left is the round trip out to the working space and
            // back rather than anything the span did: on every scene-referred space it stays
            // under 1e-6, and the one display-referred power law reaches 8.7e-5 because the
            // decode runs on the device's own `pow` and the encode on libm's. The span itself
            // contributes nothing measurable — on Linear Rec.2020, where the round trip is the
            // identity, the frame comes back bit for bit.
            check(moved < 1e-4, "an unselected texture span leaves the frame where it was");
        }
        setParam(instance.params, "colorSpace",
                 spaceMenuIndex(fotufilm::Encoding::LinearRec2020));
        setChoice(plugin, instanceHandle, instance.params, "stage", 0);
        setParam(instance.params, "grain", 0);

        // Output Medium: Negative on a colour negative. Checks that the light-box and scanner
        // readings are finite, stay at or below the lamp level, invert the print, keep the base
        // orange at the engine's lamp level on the light box, and read the base as white on the
        // scanner. The raw negative span is rendered alongside for the preview dump only.
        std::printf("negative medium\n");
        {
            int colourNegative = -1;
            for (size_t st = 0; st < stocks && colourNegative < 0; ++st) {
                const auto index = static_cast<int32_t>(st);
                if ((fotufilm_bridge_control_capabilities(index, 0) &
                     FOTUFILM_CONTROL_COLOUR_NEGATIVE) != 0) {
                    colourNegative = index;
                }
            }
            int negativeMedium = -1;
            for (int32_t i = 0; i < fotufilm_bridge_paper_count() && negativeMedium < 0; ++i) {
                if (fotufilm_bridge_paper_is_negative(i) != 0) negativeMedium = i;
            }
            check(colourNegative >= 0 && negativeMedium >= 0,
                  "a colour negative and the negative medium are installed");
            if (colourNegative >= 0 && negativeMedium >= 0) {
                applyDefaults(instance.params);
                setChoice(plugin, instanceHandle, instance.params, "stock", colourNegative);
                setChoice(plugin, instanceHandle, instance.params, "format",
                          static_cast<int>(fotufilm_bridge_format_count()));
                setChoice(plugin, instanceHandle, instance.params, "stage", 0);
                // Linear Display P3 is the delivery basis, so the levels read back are the
                // engine's own rather than a matrix's rendering of them.
                setParam(instance.params, "colorSpace",
                         spaceMenuIndex(fotufilm::Encoding::LinearDisplayP3));
                setParam(instance.params, "grain", 0);
                const int width = 320, height = 180;
                provision(width, height, 0, 0, true);
                // The left margin is unexposed film (no scene light), where the two readings of
                // the base can be measured. The ramp's own left edge carries the tilt's blue and
                // green, about a stop under mid-grey, so it is not the base.
                const int margin = std::max(1, width / 20);
                for (int y = 0; y < height; ++y) {
                    for (int x = 0; x < margin; ++x) {
                        float *pixel =
                            source->pixels.data() + (static_cast<size_t>(y) * width + x) * 4;
                        pixel[0] = pixel[1] = pixel[2] = 0.0f;
                        pixel[3] = 1.0f;
                    }
                }

                setChoice(plugin, instanceHandle, instance.params, "paper",
                          static_cast<int>(fotufilm_bridge_paper_count()));
                check(renderNow(), "renders the print the negative medium is measured against");
                const std::vector<float> printed = output->pixels;
                setChoice(plugin, instanceHandle, instance.params, "paper", negativeMedium);
                setChoice(plugin, instanceHandle, instance.params, "negativeViewing", 0);
                check(renderNow(), "renders the negative on the light box");
                const std::vector<float> lightBox = output->pixels;
                setChoice(plugin, instanceHandle, instance.params, "negativeViewing", 1);
                check(renderNow(), "and on the scanner");
                const std::vector<float> scanned = output->pixels;
                setChoice(plugin, instanceHandle, instance.params, "negativeViewing", 0);
                setChoice(plugin, instanceHandle, instance.params, "stage", 1);
                check(renderNow(), "and the raw negative span beside them");
                const std::vector<float> densities = output->pixels;
                setChoice(plugin, instanceHandle, instance.params, "stage", 0);

                struct Stats { float low[3], high[3]; double mean[3]; bool finite; };
                auto statsOf = [&](const std::vector<float> &frame) {
                    Stats s{{1e9f, 1e9f, 1e9f}, {-1e9f, -1e9f, -1e9f}, {0, 0, 0}, true};
                    const size_t pixels = frame.size() / 4;
                    for (size_t p = 0; p < pixels; ++p) {
                        for (int c = 0; c < 3; ++c) {
                            const float v = frame[p * 4 + c];
                            if (!std::isfinite(v)) { s.finite = false; continue; }
                            s.low[c] = std::min(s.low[c], v);
                            s.high[c] = std::max(s.high[c], v);
                            s.mean[c] += v;
                        }
                    }
                    for (int c = 0; c < 3; ++c) s.mean[c] /= static_cast<double>(pixels);
                    return s;
                };
                auto report = [&](const char *name, const std::vector<float> &frame) {
                    const Stats s = statsOf(frame);
                    std::printf("       %-18s min %.4f %.4f %.4f  max %.4f %.4f %.4f  "
                                "mean %.4f %.4f %.4f%s\n", name,
                                s.low[0], s.low[1], s.low[2], s.high[0], s.high[1], s.high[2],
                                s.mean[0], s.mean[1], s.mean[2],
                                s.finite ? "" : "  NON-FINITE");
                    return s;
                };
                report("print", printed);
                const Stats box = report("negative/light box", lightBox);
                const Stats scan = report("negative/scanner", scanned);
                report("negative span", densities);

                // Nothing on the film transmits more than the lamp, so neither reading exceeds
                // its own white.
                check(box.finite && scan.finite, "the viewed negative is finite everywhere");
                float peak = 0;
                for (const std::vector<float> *frame : {&lightBox, &scanned}) {
                    for (size_t i = 0; i < frame->size(); ++i) {
                        if (i % 4 != 3) peak = std::max(peak, (*frame)[i]);
                    }
                }
                check(peak <= 1.0f + 1e-3f,
                      "and stays at or below white, unlike the raw densities");

                // Inversion: the unexposed left margin is the negative's clear base and reads
                // bright; the bright right edge is dense and reads dark. The print reads the
                // other way.
                auto edgeMean = [&](const std::vector<float> &frame, bool left, int channel) {
                    double total = 0;
                    int counted = 0;
                    for (int y = 0; y < height; ++y) {
                        for (int x = left ? 0 : width - margin;
                             x < (left ? margin : width); ++x) {
                            total += frame[(static_cast<size_t>(y) * width + x) * 4 + channel];
                            ++counted;
                        }
                    }
                    return total / counted;
                };
                auto edgeLuminance = [&](const std::vector<float> &frame, bool left) {
                    return 0.2627 * edgeMean(frame, left, 0) + 0.6780 * edgeMean(frame, left, 1)
                        + 0.0593 * edgeMean(frame, left, 2);
                };
                check(edgeLuminance(printed, true) < edgeLuminance(printed, false),
                      "the print keeps the scene's polarity");
                check(edgeLuminance(lightBox, true) > edgeLuminance(lightBox, false),
                      "the light box shows the negative's, inverted");
                check(edgeLuminance(scanned, true) > edgeLuminance(scanned, false),
                      "and so does the scanner");
                // The base: orange on the light box, and read out to white by the scanner.
                check(edgeMean(lightBox, true, 0) > edgeMean(lightBox, true, 1) &&
                          edgeMean(lightBox, true, 1) > edgeMean(lightBox, true, 2),
                      "the light box keeps the film base's orange");
                // The engine's `SpectralRuntime.lightBoxBaseLevel`, 0.9, in the base's brightest
                // channel. Measured over the unexposed margin, so only spill from the ramp
                // separates the reading from the constant.
                const double brightestBase = std::max({edgeMean(lightBox, true, 0),
                                                       edgeMean(lightBox, true, 1),
                                                       edgeMean(lightBox, true, 2)});
                check(std::abs(brightestBase - 0.9) < 0.02,
                      "and puts the base just under white");
                bool baseWhite = true;
                for (int c = 0; c < 3; ++c) {
                    if (std::abs(edgeMean(scanned, true, c) - 1.0) > 0.05) baseWhite = false;
                }
                check(baseWhite, "the scanner reads the film base as white");
                std::printf("       base on the light box: %.4f %.4f %.4f; scanned: "
                            "%.4f %.4f %.4f\n",
                            edgeMean(lightBox, true, 0), edgeMean(lightBox, true, 1),
                            edgeMean(lightBox, true, 2), edgeMean(scanned, true, 0),
                            edgeMean(scanned, true, 1), edgeMean(scanned, true, 2));

                if (const char *directory = std::getenv("FOTUFILM_CONTROL_PREVIEW_DIR")) {
                    const std::string base = std::string(directory) + "/";
                    check(parity::writeDump((base + "print.bin").c_str(), printed.data(),
                                            width, height) &&
                              parity::writeDump((base + "negativeLightBox.bin").c_str(),
                                                lightBox.data(), width, height) &&
                              parity::writeDump((base + "negativeScanner.bin").c_str(),
                                                scanned.data(), width, height) &&
                              parity::writeDump((base + "negativeSpan.bin").c_str(),
                                                densities.data(), width, height),
                          "writes the negative medium previews");
                }
            }
            applyDefaults(instance.params);
            setChoice(plugin, instanceHandle, instance.params, "stock", 0);
            setChoice(plugin, instanceHandle, instance.params, "paper", 0);
            setChoice(plugin, instanceHandle, instance.params, "stage", 0);
            setParam(instance.params, "colorSpace",
                     spaceMenuIndex(fotufilm::Encoding::LinearRec2020));
            setParam(instance.params, "grain", 0);
        }

        // Every control, moved from its default, has to change the developed frame — a slider
        // wired to nothing is the one failure a panel cannot show. Judged on a frame with
        // something for each to act on: a ramp that varies both ways, and a patch three stops
        // over white for the halation, the flare and the highlight recovery to find. Tried first
        // on a colour negative that has halation and couplers to scale, then on the other films
        // installed, and reported with the film that answered.
        std::printf("every control\n");
        {
            auto textureIndex = [](const char *wanted) {
                for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
                    char id[64] = "";
                    if (fotufilm_bridge_texture_stage_id(i, id, sizeof(id)) >= 0 &&
                        std::strcmp(id, wanted) == 0) {
                        return i;
                    }
                }
                return int32_t(-1);
            };
            const int32_t halationStage = textureIndex("halation");
            const int32_t adjacencyStage = textureIndex("adjacency");
            // A filter's *menu* index, which is one past its place in the engine's catalogue
            // because the plugin's menu opens with a None of its own. Looked up by id rather
            // than written down: the drawer will gain filters, and a position typed in here
            // would then name a different piece of glass than the comment claims.
            auto filterMenuIndex = [](const char *wanted) {
                for (int32_t i = 0; i < fotufilm_bridge_lens_filter_count(); ++i) {
                    char id[64] = "";
                    if (fotufilm_bridge_lens_filter_id(i, id, sizeof(id)) >= 0 &&
                        std::strcmp(id, wanted) == 0) {
                        return static_cast<int>(i) + 1;
                    }
                }
                return 0;
            };
            const int deepRed = filterMenuIndex("w25");
            const int warming = filterMenuIndex("w81a");
            check(deepRed > 0 && warming > 0,
                  "the filter drawer carries the two filters this sweep fits");
            std::vector<int> order;
            for (size_t st = 0; st < stocks; ++st) {
                const auto index = static_cast<int32_t>(st);
                if ((fotufilm_bridge_control_capabilities(index, 0) &
                     FOTUFILM_CONTROL_COLOUR_NEGATIVE) != 0 &&
                    fotufilm_bridge_texture_stage_available(index, halationStage) != 0 &&
                    fotufilm_bridge_texture_stage_available(index, adjacencyStage) != 0) {
                    order.push_back(static_cast<int>(st));
                }
            }
            check(!order.empty(), "a colour negative with halation and couplers is installed");
            for (size_t st = 0; st < stocks; ++st) {
                if (std::find(order.begin(), order.end(), static_cast<int>(st)) == order.end()) {
                    order.push_back(static_cast<int>(st));
                }
            }

            // The frame the sweep judges on: the tilted ramp, with a patch three stops over
            // white in the middle of it for the halation, the flare and the highlight recovery
            // to find. Sized as a fraction of the frame so the same picture is posed at every
            // size below.
            auto layOut = [&](int w, int h) {
                provision(w, h, 0, 0, true);
                for (int y = h * 7 / 16; y < h * 9 / 16; ++y) {
                    for (int x = w * 7 / 16; x < w * 9 / 16; ++x) {
                        float *pixel =
                            source->pixels.data() + (static_cast<size_t>(y) * w + x) * 4;
                        pixel[0] = 8.0f; pixel[1] = 7.0f; pixel[2] = 6.0f; pixel[3] = 1.0f;
                    }
                }
            };
            // The spatial stages are sized in millimetres of emulsion, so how much of one a
            // pixel covers decides whether a stage exists at all. On a 64-pixel-tall frame of
            // 35 mm the film's halo is a fraction of a pixel across and the halation stage is
            // correctly left out — `FilmEngine.halationBoxRadius` returns a zero radius below
            // about 1.4 pixels of sigma, and a zero radius is not a small blur, it is no stage.
            // So a lever that has said nothing is retried on a frame with more emulsion in it
            // before it is called unwired, and the size that answered is printed. Silent at
            // every size is a slider wired to nothing. The larger size is the measured one: the
            // three halation controls say nothing at 96x64 and all three answer at 384x256.
            const std::pair<int, int> sizes[] = {{96, 64}, {384, 256}};
            // Every parameter at its described default, then the menus a sweep has to pin: the
            // film, a physical paper for the print light to change, the gauge left on Match
            // Film, the full span, and the engine's own space so nothing is lost either way.
            auto rest = [&](int stock) {
                applyDefaults(instance.params);
                setChoice(plugin, instanceHandle, instance.params, "stock", stock);
                setChoice(plugin, instanceHandle, instance.params, "paper", 0);
                setChoice(plugin, instanceHandle, instance.params, "format",
                          static_cast<int>(fotufilm_bridge_format_count()));
                setChoice(plugin, instanceHandle, instance.params, "stage", 0);
                setParam(instance.params, "colorSpace",
                         spaceMenuIndex(fotufilm::Encoding::LinearRec2020));
            };
            auto rmsAgainst = [&](const std::vector<float> &reference) {
                double energy = 0;
                for (size_t i = 0; i < reference.size(); ++i) {
                    const double difference = output->pixels[i] - reference[i];
                    energy += difference * difference;
                }
                return std::sqrt(energy / reference.size());
            };
            // The convention the paper and lab sweeps above use: a change the engine made shows
            // as more than 1e-4 RMS over the frame, and float noise as orders less.
            const double moved = 1e-4;

            struct Lever {
                const char *name;
                double value;
                /// A second control that has to be off its default for this one to have
                /// anything to do; null where the lever stands alone.
                const char *companion;
                double companionValue;
            };
            const Lever levers[] = {
                {"exposure", 1.0, nullptr, 0},
                {"temperature", 3200, nullptr, 0},
                {"tint", 60, nullptr, 0},
                {"highlights", -0.75, nullptr, 0},
                {"shadows", 0.75, nullptr, 0},
                // Identical output when both shifts rest at zero, by design.
                {"localTone", 0, "highlights", -0.75},
                {"saturation", 0.25, nullptr, 0},
                {"vibrance", 1.0, nullptr, 0},
                {"grain", 0, nullptr, 0},
                {"halation", 0, nullptr, 0},
                {"couplers", 0, nullptr, 0},
                {"flare", 2.0, nullptr, 0},
                {"estimatedHalation", 1, nullptr, 0},
                {"halationColour", 1.0, nullptr, 0},
                {"printCorrection", 1.0, nullptr, 0},
                // The push is snapped to a measured condition per film below.
                {"push", 2.0, nullptr, 0},
                {"bleachBypass", 1.0, nullptr, 0},
                {"expired", 10, nullptr, 0},
                {"printLight", 2, nullptr, 0},
                {"seed", 1234, nullptr, 0},
                // The lens. A deep red filter is a colour change the through-the-lens metering
                // cannot compensate away, which is the point of integrating a filter against the
                // film's own three sensitivities rather than against a meter.
                {"lensFilter1", static_cast<double>(deepRed), nullptr, 0},
                // The second thread only means anything with the first one fitted: they stack in
                // order, and their transmittances multiply.
                {"lensFilter2", static_cast<double>(warming), "lensFilter1",
                 static_cast<double>(deepRed)},
                // Metering is a scalar on the exposure the emulsion integrates, so it needs
                // something in front of the lens to compensate for. Moved from the default,
                // Metered through, to None: the light the red filter took then lands on the film.
                {"metering", 0, "lensFilter1", static_cast<double>(deepRed)},
                // The first diffusion family, at the grade the menu opens on.
                {"diffusion", 1, nullptr, 0},
                // Focal length is read by the diffusion filter and by nothing else: the halo is
                // focal length times scattering angle.
                {"focalLength", 200, "diffusion", 1},
                {"mottleShare", 80, "mottleOverride", 1},
                {"mottleOverride", 1, "mottleShare", 80},
                {"couplerReach", 0, nullptr, 0},
                {"couplerSelf", 3, "couplers", 2},
                {"couplerRedGreen", 0, nullptr, 0},
                {"couplerGreenBlue", 0, nullptr, 0},
                {"sceneLight", 3, nullptr, 0},
                {"sceneLightKelvin", 2856, "sceneLight", 5},
                {"halation550", 6, "halation", 10},
                {"halation650", 6, "halation", 10},
                {"filterCoating", 2, "lensFilter1", static_cast<double>(deepRed)},
                {"frameCoverage", 25, nullptr, 0},
                {"shutterSeconds", 3600, nullptr, 0},
            };
            bool everyControlRead = true;
            const size_t sizeCount = sizeof(sizes) / sizeof(*sizes);
            for (const Lever &lever : levers) {
                const bool isPush = std::strcmp(lever.name, "push") == 0;
                double best = 0;
                int answeredBy = -1, offered = 0;
                std::pair<int, int> answeredAt{0, 0};
                // The first size is enough to learn that no film offers the control at all —
                // a push condition no installed film has is not a frame-size question.
                for (size_t s = 0; s < sizeCount && answeredBy < 0 && (s == 0 || offered > 0);
                     ++s) {
                    layOut(sizes[s].first, sizes[s].second);
                    double atThisSize = 0;
                    for (int stock : order) {
                        // A film with no measured push condition is right to ignore the
                        // control, exactly as the lab sweep above treats it.
                        if (isPush && fotufilm_bridge_stock_pushes(stock) == 0) continue;
                        if (std::strcmp(lever.name, "shutterSeconds") == 0 &&
                            !(fotufilm_bridge_control_capabilities(stock, 0) & FOTUFILM_CONTROL_RECIPROCITY)) continue;
                        rest(stock);
                        if (lever.companion) {
                            setParam(instance.params, lever.companion, lever.companionValue);
                        }
                        if (!renderNow()) continue;
                        const std::vector<float> reference = output->pixels;
                        double value = lever.value;
                        if (isPush) {
                            value = fotufilm_bridge_stock_snap_push(stock,
                                                                   static_cast<float>(value));
                            if (value == 0) continue;
                        }
                        ++offered;
                        setParam(instance.params, lever.name, value);
                        if (!renderNow()) continue;
                        const double rms = rmsAgainst(reference);
                        if (rms > atThisSize) atThisSize = rms;
                        if (rms > best) best = rms;
                        if (rms > moved) { answeredBy = stock; answeredAt = sizes[s]; break; }
                    }
                    if (answeredBy < 0 && offered > 0 && s + 1 < sizeCount) {
                        std::printf("       %s: RMS %.5f at %dx%d — retrying on more "
                                    "emulsion\n", lever.name, atThisSize, sizes[s].first,
                                    sizes[s].second);
                    }
                }
                if (offered == 0) {
                    std::printf("       %s: no installed film offers it\n", lever.name);
                } else if (answeredBy >= 0) {
                    std::printf("       %s: RMS %.5f on stock %d at %dx%d\n", lever.name, best,
                                answeredBy, answeredAt.first, answeredAt.second);
                } else {
                    std::printf("       %s: RMS %.5f — no installed film answered\n",
                                lever.name, best);
                    everyControlRead = false;
                }
            }
            check(everyControlRead, "every control reaches the engine");

            // The gauge: two named gauges differ from each other, and Match Film is one film's
            // own gauge, so at least one of the two differs from it. Back on the small frame,
            // whatever size the levers above ended on — the gauge changes how much emulsion the
            // frame spans, which every stage reads, so it needs no room to show itself.
            layOut(sizes[0].first, sizes[0].second);
            rest(order[0]);
            check(renderNow(), "renders on Match Film");
            const std::vector<float> matched = output->pixels;
            setChoice(plugin, instanceHandle, instance.params, "format", 0);
            check(renderNow(), "renders on the first gauge");
            const std::vector<float> firstGauge = output->pixels;
            const double firstFromMatch = rmsAgainst(matched);
            setChoice(plugin, instanceHandle, instance.params, "format", 1);
            check(renderNow(), "renders on the second gauge");
            const double secondFromMatch = rmsAgainst(matched);
            const double secondFromFirst = rmsAgainst(firstGauge);
            std::printf("       format: RMS %.5f and %.5f from Match Film, %.5f apart\n",
                        firstFromMatch, secondFromMatch, secondFromFirst);
            check(secondFromFirst > moved && std::max(firstFromMatch, secondFromMatch) > moved,
                  "the gauge reaches the engine");

            // Grain advances with the timeline: the next frame is a different frame, and the
            // same frame asked for again is the same frame.
            rest(order[0]);
            check(renderNow(), "renders frame 0");
            const std::vector<float> frameZero = output->pixels;
            propSetDouble(handleOf(renderArgs), kOfxPropTime, 0, 1);
            check(renderNow(), "renders frame 1");
            const double advanced = rmsAgainst(frameZero);
            propSetDouble(handleOf(renderArgs), kOfxPropTime, 0, 0);
            check(renderNow(), "renders frame 0 again");
            std::printf("       grain from frame 0 to 1: RMS %.5f\n", advanced);
            check(advanced > moved, "grain advances with the frame");
            check(output->pixels == frameZero, "and the same frame is the same grain");

            // The negative viewing mode, which is the one Lens-adjacent control that is not on
            // the front of the lens: it says how a developed negative is read, and it is read
            // only where the negative *is* the output. Every other medium has a print or a scan
            // of its own, and a viewing mode carried into one of those would replace the print
            // with the film.
            std::printf("lens\n");
            int negativeMedium = -1;
            for (int32_t i = 0; i < fotufilm_bridge_paper_count(); ++i) {
                if (fotufilm_bridge_paper_is_negative(i) != 0) {
                    negativeMedium = static_cast<int>(i);
                    break;
                }
            }
            check(negativeMedium >= 0, "the engine offers the negative as an output medium");
            auto enabledOf = [&](const char *name) {
                auto found = instance.params.params.find(name);
                if (found == instance.params.params.end()) return -1;
                int enabled = 1;
                propGetInt(handleOf(found->second->properties), kOfxParamPropEnabled, 0,
                           &enabled);
                return enabled;
            };
            if (negativeMedium >= 0) {
                layOut(sizes[0].first, sizes[0].second);
                rest(order[0]);
                setChoice(plugin, instanceHandle, instance.params, "paper", negativeMedium);
                check(enabledOf("negativeViewing") == 1,
                      "Negative Viewing is live once the output medium is the negative");
                check(renderNow(), "renders the developed negative on a light box");
                const std::vector<float> lightBox = output->pixels;
                setChoice(plugin, instanceHandle, instance.params, "negativeViewing", 1);
                const bool scanned = renderNow();
                const double divided = scanned ? rmsAgainst(lightBox) : 0;
                std::printf("       negativeViewing: RMS %.5f from the light box\n", divided);
                check(scanned && divided > moved,
                      "dividing the base out reaches the engine");

                // And on a print, where it has nothing to say: the control is dimmed, and the
                // frame is the print rather than the negative. The second half is the one that
                // matters — a viewing mode *is* the engine's instruction to show the negative,
                // so a plugin that passed it through unconditionally would print nothing at all.
                setChoice(plugin, instanceHandle, instance.params, "paper", 0);
                check(enabledOf("negativeViewing") == 0,
                      "and dimmed again on a medium that prints");
                check(renderNow(), "renders the print with a viewing mode still selected");
                const std::vector<float> printed = output->pixels;
                setChoice(plugin, instanceHandle, instance.params, "negativeViewing", 0);
                check(renderNow() && output->pixels == printed,
                      "and the print is the same frame whichever mode is selected");
            }

            // The lens divides in two, and neither half divides by span the way the group's
            // position on the panel suggests. The scattering half — the mist and the focal length
            // it is imaged through — is live wherever the scene still exists, which is every span
            // but Print Only. The absorbing half — the three filter threads and the metering
            // behind them — is live in Full alone, because a fitted filter raises the
            // veiling-glare feature bit and no compiled kernel pairs that bit with a span that
            // ends at, or begins from, the developed negative. Measured below rather than argued.
            rest(order[0]);
            setChoice(plugin, instanceHandle, instance.params, "lensFilter1", deepRed);
            setChoice(plugin, instanceHandle, instance.params, "diffusion", 1);
            const char *const absorbing[] = {"lensFilter1", "lensFilter2", "lensFilter3",
                                             "metering"};
            const char *const scattering[] = {"diffusion", "diffusionGrade", "focalLength"};
            bool greyedRight = true;
            for (int stage : {FOTUFILM_BRIDGE_STAGE_FULL, FOTUFILM_BRIDGE_STAGE_NEGATIVE,
                              FOTUFILM_BRIDGE_STAGE_PRINT, FOTUFILM_BRIDGE_STAGE_TEXTURE}) {
                setChoice(plugin, instanceHandle, instance.params, "stage", stage);
                const bool exposing = stage == FOTUFILM_BRIDGE_STAGE_FULL;
                const bool scatters = stage != FOTUFILM_BRIDGE_STAGE_PRINT;
                for (const char *name : absorbing) {
                    if (enabledOf(name) != (exposing ? 1 : 0)) greyedRight = false;
                }
                for (const char *name : scattering) {
                    if (enabledOf(name) != (scatters ? 1 : 0)) greyedRight = false;
                }
            }
            check(greyedRight,
                  "the absorbing half of the lens is live only in the span that exposes film "
                  "through it, and the scattering half wherever the scene still exists");

            if (const char *directory = std::getenv("FOTUFILM_CONTROL_PREVIEW_DIR")) {
                layOut(384, 256);
                const Lever previews[] = {
                    {"baseline", 0, nullptr, 0},
                    {"mottleShare", 80, "mottleOverride", 1},
                    {"halation650", 6, "halation", 10},
                    {"couplerReach", 0, nullptr, 0},
                    {"sceneLight", 3, nullptr, 0},
                    {"filterCoating", 2, "lensFilter1", static_cast<double>(deepRed)},
                };
                for (const auto &preview : previews) {
                    rest(order[0]);
                    setParam(instance.params, "format", 0);
                    setString(instance.params, "formatID", "super8");
                    if (preview.companion) setParam(instance.params, preview.companion, preview.companionValue);
                    if (std::strcmp(preview.name, "baseline") != 0) setParam(instance.params, preview.name, preview.value);
                    const std::string path = std::string(directory) + "/" + preview.name + ".bin";
                    check(renderNow() && parity::writeDump(path.c_str(), output->pixels.data(), 384, 256),
                          "writes a representative control render for visual inspection");
                }
                layOut(sizes[0].first, sizes[0].second);
            }

            std::printf("contextual controls and saved state\n");
            rest(order[0]);
            check(enabledOf("diffusionGrade") == 0 && enabledOf("focalLength") == 0 &&
                  enabledOf("metering") == 0 && enabledOf("filterCoating") == 0,
                  "empty lens accessories disable their dependent controls");
            setChoice(plugin, instanceHandle, instance.params, "diffusion", 1);
            check(enabledOf("diffusionGrade") == 1 && enabledOf("focalLength") == 1 &&
                  enabledOf("filterCoating") == 1, "fitting diffusion enables its controls");
            setChoice(plugin, instanceHandle, instance.params, "highlights", -1);
            check(enabledOf("localTone") == 1, "regional tone becomes available when shaping light");
            setChoice(plugin, instanceHandle, instance.params, "highlights", 0);
            check(enabledOf("localTone") == 0, "neutral tone disables its regional mask");
            setChoice(plugin, instanceHandle, instance.params, "grain", 0);
            check(enabledOf("seed") == 0 && enabledOf("newSeed") == 0 &&
                  enabledOf("mottleOverride") == 0, "zero grain disables grain dependencies");
            setChoice(plugin, instanceHandle, instance.params, "grain", 1);
            setChoice(plugin, instanceHandle, instance.params, "mottleOverride", 1);
            check(enabledOf("mottleShare") == 1, "custom mottle enables its amount in Full");
            setChoice(plugin, instanceHandle, instance.params, "stage", FOTUFILM_BRIDGE_STAGE_TEXTURE);
            check(enabledOf("mottleOverride") == 0 && enabledOf("mottleShare") == 0,
                  "Texture Only does not offer unsupported mottle");
            int secret = 1;
            auto textureProperties = handleOf(instance.params.params.at("texture_grain")->properties);
            propGetInt(textureProperties, kOfxParamPropSecret, 0, &secret);
            check(secret == 0, "texture selectors are visible in Texture Only");
            setChoice(plugin, instanceHandle, instance.params, "texture_grain", 0);
            check(enabledOf("grain") == 0, "a deselected texture stage disables its strength");
            setChoice(plugin, instanceHandle, instance.params, "stage", FOTUFILM_BRIDGE_STAGE_FULL);
            propGetInt(textureProperties, kOfxParamPropSecret, 0, &secret);
            check(secret == 1, "texture selectors are hidden in Full");
            setChoice(plugin, instanceHandle, instance.params, "stage", FOTUFILM_BRIDGE_STAGE_PRINT);
            check(enabledOf("estimatedHalation") == 0 && enabledOf("halationColour") == 0 &&
                  enabledOf("flare") == 0 && enabledOf("halation650") == 0,
                  "Print Only disables every camera-side halation and glare control");
            rest(order[0]);
            check(!getString(instance.params, "resolvedFormat").empty() &&
                  !getString(instance.params, "resolvedPaper").empty(),
                  "Match Film reports the resolved format and output medium");
            int digital = -1;
            for (int i = 0; i < fotufilm_bridge_paper_count(); ++i) {
                char id[80]; fotufilm_bridge_paper_id(i, id, sizeof(id));
                if (std::strcmp(id, "screen") == 0) digital = i;
            }
            check(digital >= 0, "finds Digital Reference by identity");
            if (digital >= 0) setChoice(plugin, instanceHandle, instance.params, "paper", digital);
            check(enabledOf("printLight") == 0, "Digital Reference disables the viewing lamp");
            int measuredStocks = 0, silverStock = -1;
            for (int st : order) {
                setChoice(plugin, instanceHandle, instance.params, "stock", st);
                const int flags = fotufilm_bridge_control_capabilities(st, digital);
                if ((flags & FOTUFILM_CONTROL_DISC_GRAIN) && silverStock < 0) silverStock = st;
                check(enabledOf("bleachBypass") == ((flags & FOTUFILM_CONTROL_COLOUR_NEGATIVE) ? 1 : 0),
                      "bleach availability follows the film's material");
                if (!(flags & FOTUFILM_CONTROL_DISC_GRAIN))
                    check(enabledOf("grainModel") == 0, "dye-cloud stocks do not offer silver disc grain");
                if (fotufilm_bridge_stock_pushes(st)) {
                    ++measuredStocks;
                    auto &menu = instance.params.params.at("pushCondition")->properties->strings[kOfxParamPropChoiceOption];
                    const int count = fotufilm_bridge_development_count(st);
                    check(static_cast<int>(menu.size()) == count, "development menu contains exactly the measured conditions");
                    setChoice(plugin, instanceHandle, instance.params, "pushCondition", count - 1);
                    check(std::abs(instance.params.params.at("push")->doubleValue -
                                   fotufilm_bridge_development_stop(st, count - 1)) < 1e-4,
                          "selecting a condition updates the durable stop value");
                    setChoice(plugin, instanceHandle, instance.params, "push", 0);
                    check(getInt(instance.params, "pushCondition") >= 0 &&
                          getString(instance.params, "developmentStatus").find("stops") != std::string::npos,
                          "legacy stop edits synchronize the measured menu and status");
                }
            }
            if (std::getenv("FOTUFILM_REQUIRE_ADVANCED_STOCKS")) {
                check(measuredStocks > 0, "exercises at least one measured development menu");
                check(silverStock >= 0, "finds a silver-image stock for the disc render test");
            }
            if (silverStock >= 0) {
                layOut(384, 256);
                rest(silverStock);
                setChoice(plugin, instanceHandle, instance.params, "format", 0);
                setChoice(plugin, instanceHandle, instance.params, "frameCoverage", 5);
                setChoice(plugin, instanceHandle, instance.params, "halation", 0);
                setChoice(plugin, instanceHandle, instance.params, "couplers", 0);
                if (digital >= 0) setChoice(plugin, instanceHandle, instance.params, "paper", digital);
                setChoice(plugin, instanceHandle, instance.params, "renderMode", 2);
                check(enabledOf("grainModel") == 1 && renderNow(), "renders clump-field silver grain on Reference");
                const auto silverClumps = output->pixels;
                setChoice(plugin, instanceHandle, instance.params, "grainModel", 1);
                check(renderNow() && rmsAgainst(silverClumps) > moved,
                      "resolved silver discs change the actual grain, not just the renderer selection");
                if (const char *directory = std::getenv("FOTUFILM_CONTROL_PREVIEW_DIR")) {
                    const std::string base = std::string(directory) + "/";
                    check(parity::writeDump((base + "silverClumps.bin").c_str(), silverClumps.data(), 384, 256) &&
                          parity::writeDump((base + "silverDiscs.bin").c_str(), output->pixels.data(), 384, 256),
                          "writes silver grain model previews");
                }
                layOut(sizes[0].first, sizes[0].second);
            }
            rest(order[0]);
            setChoice(plugin, instanceHandle, instance.params, "renderMode", 2);
            check(getString(instance.params, "renderStatus") == "Reference", "Reference is an explicit node setting");
            check(renderNow(), "renders Reference from the node control");
            const auto referenceMode = output->pixels;
            setChoice(plugin, instanceHandle, instance.params, "renderMode", 1);
            check(getString(instance.params, "renderStatus") == "Realtime", "Realtime overrides the launch default");
            check(renderNow(), "renders Realtime from the node control");
            setChoice(plugin, instanceHandle, instance.params, "renderMode", 2);
            check(renderNow() && output->pixels == referenceMode,
                  "switching back to Reference restores the same frame, including cached tables");
            setChoice(plugin, instanceHandle, instance.params, "grainModel", 1);
            check(getInt(instance.params, "renderMode") == 2, "selecting discs selects Reference rendering");
            setChoice(plugin, instanceHandle, instance.params, "renderMode", 1);
            check(getInt(instance.params, "grainModel") == 0, "selecting Realtime restores supported clump grain");
            rest(order[0]);
            setChoice(plugin, instanceHandle, instance.params, "grainAnimation", 1);
            PropertySet *frozenPreferences = newPropertySet();
            plugin->mainEntry(kOfxImageEffectActionGetClipPreferences, instanceHandle, nullptr, handleOf(frozenPreferences));
            int varying = 1;
            propGetInt(handleOf(frozenPreferences), kOfxImageEffectFrameVarying, 0, &varying);
            check(varying == 0, "frozen grain clears the frame-varying cache declaration");
            double savedTime = 0;
            propGetDouble(handleOf(renderArgs), kOfxPropTime, 0, &savedTime);
            propSetDouble(handleOf(renderArgs), kOfxPropTime, 0, 10);
            check(renderNow(), "renders frozen grain at frame 10");
            const auto frozenFrame = output->pixels;
            propSetDouble(handleOf(renderArgs), kOfxPropTime, 0, 11);
            check(renderNow() && output->pixels == frozenFrame, "frozen grain is identical across timeline frames");
            const int oldSeed = getInt(instance.params, "seed");
            setChoice(plugin, instanceHandle, instance.params, "newSeed", 0);
            check(getInt(instance.params, "seed") != oldSeed, "New Seed changes the saved grain field");
            check(renderNow() && output->pixels != frozenFrame, "New Seed reaches the frozen render");
            setChoice(plugin, instanceHandle, instance.params, "seed", oldSeed);
            check(renderNow() && output->pixels == frozenFrame, "restoring the seed restores identical grain");
            setChoice(plugin, instanceHandle, instance.params, "grainAnimation", 0);
            propSetDouble(handleOf(renderArgs), kOfxPropTime, 0, savedTime);
            rest(order[0]);

            // The scattering half's side of that, measured. Texture Only develops the frame twice
            // — once with the spatial stages it was asked for and once with none of them — and
            // returns what the two densities differ by, so a lens control reaches it only through
            // what the spatial stages make of the light it changed. A mist filter reaches it
            // easily: the halo, the adjacency and the grain are all computed over softened light.
            layOut(sizes[1].first, sizes[1].second);
            struct TextureProbe {
                const char *name;
                double value;
                const char *companion;
                double companionValue;
                bool active = true;
            };
            const TextureProbe probes[] = {
                {"diffusion", 1, nullptr, 0},
                {"focalLength", 200, "diffusion", 1},
                {"mottleShare", 80, "mottleOverride", 1, false},
                {"mottleOverride", 1, "mottleShare", 80, false},
                {"couplerReach", 0, nullptr, 0},
                {"couplerSelf", 3, "couplers", 2},
                {"couplerRedGreen", 0, nullptr, 0},
                {"couplerGreenBlue", 0, nullptr, 0},
                {"sceneLight", 3, nullptr, 0},
                {"sceneLightKelvin", 2856, "sceneLight", 5},
                {"halation550", 6, "halation", 10},
                {"halation650", 6, "halation", 10},
                {"filterCoating", 2, "lensFilter1", static_cast<double>(deepRed), false},
                {"frameCoverage", 25, nullptr, 0},
                {"shutterSeconds", 3600, nullptr, 0},
            };
            for (const TextureProbe &probe : probes) {
                double best = 0;
                bool renderedAll = true;
                int offered = 0;
                // Test the control on a film that offers it. Short diffusion reaches
                // need more pixels per millimetre to produce a measurable texture.
                for (double coverage : {100.0, 25.0, 5.0}) {
                  if (coverage != 100 && (!probe.active ||
                      std::strcmp(probe.name, "frameCoverage") == 0)) continue;
                  for (int stock : order) {
                    if (std::strcmp(probe.name, "shutterSeconds") == 0 &&
                        !(fotufilm_bridge_control_capabilities(stock, 0) & FOTUFILM_CONTROL_RECIPROCITY)) continue;
                    rest(stock);
                    setParam(instance.params, "frameCoverage", coverage);
                    setChoice(plugin, instanceHandle, instance.params, "stage",
                              FOTUFILM_BRIDGE_STAGE_TEXTURE);
                    if (probe.companion) {
                        setParam(instance.params, probe.companion, probe.companionValue);
                    }
                    ++offered;
                    if (!renderNow()) { renderedAll = false; break; }
                    const std::vector<float> reference = output->pixels;
                    setParam(instance.params, probe.name, probe.value);
                    if (!renderNow()) { renderedAll = false; break; }
                    best = std::max(best, rmsAgainst(reference));
                    if (probe.active && best > moved) break;
                  }
                  if (!renderedAll || (probe.active && best > moved)) break;
                }
                std::printf("       %s through the texture span: RMS %.6f\n",
                            probe.name, best);
                check(offered > 0 && renderedAll && (probe.active ? best > moved : best == 0),
                      probe.active ? "supported controls reach the texture span"
                                   : "Full-only controls leave texture output unchanged");
            }
            layOut(sizes[0].first, sizes[0].second);

            // The absorbing half, both ways round.
            //
            // First through the plugin: a filter chosen in Full and carried into a span that
            // cannot expose through it is *cleared*, not merely greyed. Greying a control does
            // not empty it, and once it is greyed there is no UI left with which to empty it —
            // so a value still reaching the engine from behind one is a value the user cannot
            // take back. The frame those spans render has to be the frame with no filter fitted,
            // bit for bit, and the filter has to start moving the picture again the moment the
            // node is Full once more.
            //
            // Then through the bridge, which is where the reason for all of it lives. A fitted
            // filter is two more air-glass faces, so it raises the veiling-glare feature bit;
            // FOTUFILM_AOT_TEXTURE_SPAN carries no FOTUFILM_FRAME_FLARE and neither does any
            // variant built on FOTUFILM_AOT_NEGATIVE_SPAN, and `select_variant` matches a mask
            // exactly rather than by superset. So the engine refuses those frames outright. That
            // refusal is asked of the engine directly, because the plugin now clears the slot
            // before the engine ever sees it: were the check left on the plugin's own render it
            // would pass for the wrong reason. The day a flare-carrying negative or texture
            // variant is compiled, this fails — and the answer then is to make the controls live
            // again, not to relax the check.
            std::vector<std::string> offeredToggles;
            int32_t offeredStages = 0;
            for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
                char id[128] = "";
                if (fotufilm_bridge_texture_stage_id(i, id, sizeof(id)) < 0) continue;
                if (fotufilm_bridge_texture_stage_available(
                        static_cast<int32_t>(order[0]), i) == 0) {
                    continue;
                }
                std::string name = std::string("texture_") + id;
                for (char &c : name) { if (c == '-') c = '_'; }
                offeredToggles.push_back(name);
                offeredStages |= fotufilm_bridge_texture_stage_mask(i);
            }
            check(offeredStages != 0,
                  "the film this probe develops on offers a spatial stage to select");

            struct CarriedFilter {
                int stage;
                const char *what;
            };
            const CarriedFilter carriedInto[] = {
                {FOTUFILM_BRIDGE_STAGE_TEXTURE, "Texture Only"},
                {FOTUFILM_BRIDGE_STAGE_NEGATIVE, "Negative Only"},
            };
            for (const CarriedFilter &into : carriedInto) {
                rest(order[0]);
                setChoice(plugin, instanceHandle, instance.params, "stage", into.stage);
                if (into.stage == FOTUFILM_BRIDGE_STAGE_TEXTURE) {
                    for (const std::string &name : offeredToggles) {
                        setParam(instance.params, name.c_str(), 1);
                    }
                }
                if (!renderNow()) {
                    check(false, "renders that span with no filter fitted");
                    continue;
                }
                const std::vector<float> bare = output->pixels;
                setParam(instance.params, "lensFilter1", deepRed);
                const bool rendered = renderNow();
                std::printf("       a filter carried into %s: %s\n", into.what,
                            !rendered ? "failed the frame"
                                      : (output->pixels == bare ? "cleared"
                                                                : "applied anyway"));
                check(rendered && output->pixels == bare,
                      "a filter carried into a span that cannot expose through it is cleared "
                      "rather than left behind a dimmed control to fail the frame");
            }
            // And it is a real filter, not one this sweep has quietly broken: back in Full the
            // same value moves the frame.
            rest(order[0]);
            check(renderNow(), "renders Full with no filter fitted");
            const std::vector<float> unfiltered = output->pixels;
            setParam(instance.params, "lensFilter1", deepRed);
            const bool refiltered = renderNow();
            const double throughGlass = refiltered ? rmsAgainst(unfiltered) : 0;
            std::printf("       the same filter back in Full: RMS %.6f\n", throughGlass);
            check(refiltered && throughGlass > moved,
                  "and the filter the other spans cleared still moves the frame in Full");

            // The engine's own answer, with nothing between it and the parameter block. The
            // three physical scales are set to the values the panel opens on and Lens Flare is
            // left at its own default of zero, so the only veiling glare anywhere in the frame is
            // the filter's, and the spatial stages the texture span differences are really there
            // — a span with nothing but couplers left in it would be served by the flat variant,
            // which does carry flare, and the probe would be measuring the wrong kernel.
            if (gLinkedIn) {
                auto discardRows = +[](void *, int32_t, int32_t, const float *) {};
                auto engineDevelops = [&](int32_t stage, int32_t textureStages, int filter) {
                    FotufilmBridgeContext probe = fotufilm_bridge_context_create();
                    if (!probe) return false;
                    const int probeWidth = 96, probeHeight = 64;
                    std::vector<float> scene(
                        static_cast<size_t>(probeWidth) * probeHeight * 4, 0.25f);
                    float parameters[FOTUFILM_BRIDGE_PARAMETER_COUNT] = {};
                    parameters[FOTUFILM_BRIDGE_GRAIN_SCALE] = 1;
                    parameters[FOTUFILM_BRIDGE_HALATION_SCALE] = 1;
                    parameters[FOTUFILM_BRIDGE_COUPLER_SCALE] = 1;
                    parameters[FOTUFILM_BRIDGE_STAGE] = static_cast<float>(stage);
                    parameters[FOTUFILM_BRIDGE_TEXTURE_STAGES] =
                        static_cast<float>(textureStages);
                    parameters[FOTUFILM_BRIDGE_LENS_FILTER_1] = static_cast<float>(filter);
                    const int32_t status = fotufilm_bridge_render(
                        probe, static_cast<int32_t>(order[0]),
                        fotufilm_bridge_format_count(), 0, parameters, 0, scene.data(),
                        probeWidth, probeHeight, 0, discardRows, nullptr, nullptr, nullptr,
                        nullptr);
                    fotufilm_bridge_context_destroy(probe);
                    return status == 1;
                };
                struct SpanProbe {
                    int32_t stage;
                    int32_t textureStages;
                    const char *what;
                };
                const SpanProbe spans[] = {
                    {FOTUFILM_BRIDGE_STAGE_TEXTURE, offeredStages, "the texture span"},
                    {FOTUFILM_BRIDGE_STAGE_NEGATIVE, 0, "the negative span"},
                };
                for (const SpanProbe &span : spans) {
                    const bool bare = engineDevelops(span.stage, span.textureStages, 0);
                    const bool filtered =
                        engineDevelops(span.stage, span.textureStages, deepRed);
                    std::printf("       %s: %s with no filter, %s with one\n", span.what,
                                bare ? "develops" : "refuses",
                                filtered ? "develops" : "no kernel for it");
                    check(bare && !filtered,
                          "the engine has no kernel for an absorbing filter in that span, "
                          "which is why its control is dimmed and its value cleared");
                }
            }
            rest(order[0]);
            setChoice(plugin, instanceHandle, instance.params, "stage", 0);

            // A project graded through a named filter must keep that filter when the drawer is
            // renumbered under it. The id is what was saved; the menu index is only a position.
            {
                rest(order[0]);
                setChoice(plugin, instanceHandle, instance.params, "lensFilter1", deepRed);
                char id[64] = "";
                fotufilm_bridge_lens_filter_id(static_cast<int32_t>(deepRed - 1), id, sizeof(id));
                check(getString(instance.params, "lensFilter1ID") == id,
                      "choosing a filter writes its id beside the menu");
                check(renderNow(), "renders through the named filter");
                const std::vector<float> throughIt = output->pixels;

                // The same project on a machine whose drawer numbers that filter differently.
                setParam(instance.params, "lensFilter1", 0);
                check(renderNow() && output->pixels == throughIt,
                      "the persisted filter id outvotes a stale menu index");
                check(plugin->mainEntry(kOfxActionCreateInstance, instanceHandle, nullptr,
                                        nullptr) == kOfxStatOK,
                      "re-creates the instance over the restored filter");
                check(getInt(instance.params, "lensFilter1") == deepRed,
                      "createInstance moves the filter menu back to the id's position");

                const int messagesBefore = gMessagesPosted;
                setString(instance.params, "lensFilter1ID", "not-a-filter");
                setParam(instance.params, "lensFilter1", 0);
                plugin->mainEntry(kOfxActionCreateInstance, instanceHandle, nullptr, nullptr);
                check(gMessagesPosted > messagesBefore,
                      "a filter this install does not have is reported to the host");
                check(getString(instance.params, "lensFilter1ID") == "not-a-filter",
                      "and the missing id is kept, so a later build heals the project");
                check(renderNow(), "and the menu's filter renders meanwhile");
                setChoice(plugin, instanceHandle, instance.params, "lensFilter1", 0);
                setString(instance.params, "lensFilter1ID", "");
            }

            // The whole point of every one of these slots being zero-off: a project saved before
            // the Lens group existed carries an array that stops at the halo colour, and the host
            // zero-fills the rest. That frame must not move by one bit.
            //
            // Driven through the bridge, because the plugin has no way to be asked for a
            // twenty-one-slot render: its menus always compose the full block. The two arrays
            // below are exactly what an old host and a new one at its defaults would each send.
            if (gLinkedIn) {
                const int w = 64, h = 48;
                FotufilmBridgeContext bridge = fotufilm_bridge_context_create();
                float *sceneIn = nullptr, *developedOut = nullptr;
                const bool staged =
                    fotufilm_bridge_frame_staging(bridge, w, h, &sceneIn, &developedOut) == 1;
                check(staged, "stages a frame to develop with an old parameter block");
                std::vector<float> scene(static_cast<size_t>(w) * h * 4, 0.0f);
                for (int y = 0; y < h; ++y) {
                    for (int x = 0; x < w; ++x) {
                        float *pixel = scene.data() + (static_cast<size_t>(y) * w + x) * 4;
                        const float ramp = 4.0f * (x + y) / (w + h);
                        pixel[0] = ramp; pixel[1] = ramp * 0.8f; pixel[2] = ramp * 0.6f;
                        pixel[3] = 1.0f;
                    }
                }
                float legacy[FOTUFILM_BRIDGE_PARAMETER_COUNT] = {};
                legacy[FOTUFILM_BRIDGE_TEMPERATURE] = 6504;
                legacy[FOTUFILM_BRIDGE_SATURATION] = 1;
                legacy[FOTUFILM_BRIDGE_LOCAL_TONE] = 1;
                legacy[FOTUFILM_BRIDGE_GRAIN_SCALE] = 1;
                legacy[FOTUFILM_BRIDGE_HALATION_SCALE] = 1;
                legacy[FOTUFILM_BRIDGE_COUPLER_SCALE] = 1;
                legacy[FOTUFILM_BRIDGE_PRINT_CORRECTION] = 0.05f;
                legacy[FOTUFILM_BRIDGE_TEXTURE_STAGES] = 0;
                // Everything from FOTUFILM_BRIDGE_LENS_FILTER_1 up is left at zero: that is the
                // whole of what an older project supplies.
                float fresh[FOTUFILM_BRIDGE_PARAMETER_COUNT] = {};
                std::memcpy(fresh, legacy, sizeof(fresh));
                // What the plugin's own defaults compose: three empty threads, the engine's own
                // metering, no mist, the grade menu resting on its default, the gauge's normal
                // lens, and the light box.
                fresh[FOTUFILM_BRIDGE_LENS_METERING] = 2;
                fresh[FOTUFILM_BRIDGE_DIFFUSION_GRADE] =
                    static_cast<float>(fotufilm_bridge_diffusion_default_grade());
                fresh[FOTUFILM_BRIDGE_NEGATIVE_VIEWING] = 1;

                auto developWith = [&](const float *block, std::vector<float> &into) {
                    std::memcpy(sceneIn, scene.data(), scene.size() * sizeof(float));
                    const bool ok = fotufilm_bridge_render_staged(
                        bridge, order[0], fotufilm_bridge_format_count(), 0, block, 0x46494C4D,
                        w, h, 0, 0, nullptr, nullptr, nullptr) == 1;
                    if (ok) into.assign(developedOut, developedOut + scene.size());
                    return ok;
                };
                std::vector<float> before, after;
                const bool both = staged && developWith(legacy, before) &&
                                  developWith(fresh, after);
                check(both, "develops the same frame from an old block and a new one");
                check(both && before == after,
                      "a project saved before the Lens group existed renders bit-identically");
                fotufilm_bridge_release_staging(bridge);
                fotufilm_bridge_context_destroy(bridge);
            }

            rest(0);
            setParam(instance.params, "grain", 0);
        }

        // An out-of-range menu index without a stable ID must fail without crashing the host.
        std::printf("failure\n");
        provision(32, 24, 0, 0);
        const int failuresBefore = gMessagesPosted;
        setString(instance.params, "stockID", "");
        setParam(instance.params, "stock", 9999);
        check(plugin->mainEntry(kOfxImageEffectActionRender, instanceHandle,
                                handleOf(renderArgs), nullptr) == kOfxStatFailed,
              "an out-of-range stock fails the render instead of crashing");
        check(gMessagesPosted > failuresBefore && gLastMessageType == kOfxMessageError,
              "and posts the error to the host");
        setChoice(plugin, instanceHandle, instance.params, "stock", 0);

        // A sequence render warms the engine before its first frame.
        PropertySet *sequenceArgs = newPropertySet();
        propSetDouble(handleOf(sequenceArgs), kOfxImageEffectPropFrameRange, 0, 0);
        propSetDouble(handleOf(sequenceArgs), kOfxImageEffectPropFrameRange, 1, 24);
        check(plugin->mainEntry(kOfxImageEffectActionBeginSequenceRender, instanceHandle,
                                handleOf(sequenceArgs), nullptr) == kOfxStatOK,
              "a sequence render can warm the engine first");
        check(renderNow(), "and the first frame still renders");
    }

    check(plugin->mainEntry(kOfxActionDestroyInstance, instanceHandle, nullptr,
                            nullptr) == kOfxStatOK, "destroys the instance");
    check(plugin->mainEntry(kOfxActionUnload, nullptr, nullptr, nullptr) == kOfxStatOK,
          "unloads");

    // A host that predates the message suite and has no SMP suite either: everything still
    // works — the errors keep to stderr and the transcodes run on one core.
    std::printf("without a message suite\n");
    gOfferMessageSuite = false;
    gOfferThreadSuite = false;
    gThreadFanOuts = 0;
    check(plugin->mainEntry(kOfxActionLoad, nullptr, nullptr, nullptr) == kOfxStatOK,
          "loads");
    Effect quietDescriber;
    quietDescriber.properties = newPropertySet();
    plugin->mainEntry(kOfxActionDescribe,
                      reinterpret_cast<OfxImageEffectHandle>(&quietDescriber),
                      nullptr, nullptr);
    Effect quiet;
    quiet.properties = newPropertySet();
    auto quietHandle = reinterpret_cast<OfxImageEffectHandle>(&quiet);
    check(plugin->mainEntry(kOfxImageEffectActionDescribeInContext, quietHandle, nullptr,
                            nullptr) == kOfxStatOK, "describes in context");
    applyDefaults(quiet.params);
    check(plugin->mainEntry(kOfxActionCreateInstance, quietHandle, nullptr, nullptr) ==
              kOfxStatOK, "creates an instance");

    const int quietWidth = 32, quietHeight = 24;
    Clip *quietSource = quiet.clips[kOfxImageEffectSimpleSourceClipName].get();
    Clip *quietOutput = quiet.clips[kOfxImageEffectOutputClipName].get();
    for (Clip *clip : {quietSource, quietOutput}) {
        clip->pixels.assign(static_cast<size_t>(quietWidth) * quietHeight * 4, 0.25f);
        clip->image = newPropertySet();
        propSetPointer(handleOf(clip->image), kOfxImagePropData, 0, clip->pixels.data());
        const int bounds[4] = {0, 0, quietWidth, quietHeight};
        propSetIntN(handleOf(clip->image), kOfxImagePropBounds, 4, bounds);
        propSetInt(handleOf(clip->image), kOfxImagePropRowBytes, 0,
                   quietWidth * 4 * static_cast<int>(sizeof(float)));
        propSetString(handleOf(clip->image), kOfxImageEffectPropPixelDepth, 0,
                      kOfxBitDepthFloat);
        propSetString(handleOf(clip->image), kOfxImageEffectPropComponents, 0,
                      kOfxImageComponentRGBA);
        propSetString(handleOf(clip->properties),
                      kOfxImageEffectPropPreMultiplication, 0, kOfxImageOpaque);
    }
    PropertySet *quietArgs = newPropertySet();
    propSetDouble(handleOf(quietArgs), kOfxPropTime, 0, 0);
    const int quietWindow[4] = {0, 0, quietWidth, quietHeight};
    propSetIntN(handleOf(quietArgs), kOfxImageEffectPropRenderWindow, 4, quietWindow);

    setParam(quiet.params, "colorSpace",
             static_cast<double>(fotufilm::Encoding::LinearDisplayP3));
    setParam(quiet.params, "grain", 0);
    check(plugin->mainEntry(kOfxImageEffectActionRender, quietHandle,
                            handleOf(quietArgs), nullptr) == kOfxStatOK, "renders");
    check(gThreadFanOuts == 0, "serially, there being no SMP suite to fan out on");
    const int posted = gMessagesPosted;
    setString(quiet.params, "stockID", "");
    setParam(quiet.params, "stock", 9999);
    check(plugin->mainEntry(kOfxImageEffectActionRender, quietHandle,
                            handleOf(quietArgs), nullptr) == kOfxStatFailed,
          "fails an out-of-range stock without a suite to tell");
    check(gMessagesPosted == posted, "and posted nothing anywhere");
    check(plugin->mainEntry(kOfxActionDestroyInstance, quietHandle, nullptr,
                            nullptr) == kOfxStatOK, "destroys the instance");
    check(plugin->mainEntry(kOfxActionUnload, nullptr, nullptr, nullptr) == kOfxStatOK,
          "unloads");
    gOfferMessageSuite = true;

    // A node the host built before the engine came up. The
    // retry heals the engine, but a menu is fixed the moment `describeInContext` returns, so the
    // panel keeps its one-entry placeholder while the id lists behind it fill. An unloaded plugin
    // is exactly that state — no engine, no menus — so the sequence is described here rather than
    // simulated: describe against nothing, start, then hand the node over.
    std::printf("menus described before the engine came up\n");
    {
        plugin->mainEntry(kOfxActionUnload, nullptr, nullptr, nullptr);
        Effect blindDescriber;
        blindDescriber.properties = newPropertySet();
        check(plugin->mainEntry(kOfxActionDescribe,
                                reinterpret_cast<OfxImageEffectHandle>(&blindDescriber),
                                nullptr, nullptr) == kOfxStatOK,
              "describes itself with no engine behind it");
        Effect blind;
        blind.properties = newPropertySet();
        auto blindHandle = reinterpret_cast<OfxImageEffectHandle>(&blind);
        check(plugin->mainEntry(kOfxImageEffectActionDescribeInContext, blindHandle, nullptr,
                                nullptr) == kOfxStatOK,
              "and describes a panel from menus it does not have");
        check(optionCount(blind.params, "stock") == 1,
              "whose stock menu is the one-entry placeholder");
        size_t togglesDescribed = 0;
        for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
            char id[128] = "";
            if (fotufilm_bridge_texture_stage_id(i, id, sizeof(id)) < 0) continue;
            std::string name = std::string("texture_") + id;
            for (char &c : name) { if (c == '-') c = '_'; }
            togglesDescribed += blind.params.params.count(name);
        }
        check(togglesDescribed == 0,
              "and which carries no texture toggle at all, the engine having named none");

        // The engine comes up. Whether it was this or the retry inside `createInstance` makes no
        // difference to what follows: the lists are full and the panel is not.
        check(plugin->mainEntry(kOfxActionLoad, nullptr, nullptr, nullptr) == kOfxStatOK,
              "starts the engine afterwards");
        applyDefaults(blind.params);

        char secondStock[256] = "";
        const bool second = fotufilm_bridge_stock_count() > 1 &&
                            fotufilm_bridge_stock_id(1, secondStock, sizeof(secondStock)) > 0;
        check(second, "the pack holds a second film for the project to have been saved on");
        setString(blind.params, "stockID", secondStock);

        // The panel has no texture toggles, so `createInstance` asks for parameters this host
        // never defined — which is the correct thing for it to do, and the only place in the run
        // where that is true.
        gAllowUndefinedParams = true;
        check(plugin->mainEntry(kOfxActionCreateInstance, blindHandle, nullptr, nullptr) ==
                  kOfxStatOK, "creates a node against the placeholder panel");
        gAllowUndefinedParams = false;

        check(getInt(blind.params, "stock") == 0,
              "leaves the stock menu alone rather than writing an index past its last entry");
        check(getString(blind.params, "stockID") == secondStock,
              "keeps the id the project saved, which is what the render resolves through");
        check(getString(blind.params, "stageStatus").find("restart Resolve") !=
                  std::string::npos,
              "and says on the status line that a restart is what fills the menus");
        // The ids this node never had are the other half. The placeholder Format menu put its
        // Match Film default at index 1, which in the full list is the second real gauge; a node
        // that persisted *that* would be pinned to a gauge nobody chose.
        check(getString(blind.params, "formatID") == "match-film",
              "a new node persists Match Film rather than the gauge at the placeholder's index");
        check(getString(blind.params, "paperID") == "match-film-output",
              "and the paper's Match Film likewise");
        check(getString(blind.params, "lensFilter1ID") == "none",
              "and no lens filter");

        const int blindWidth = 32, blindHeight = 24;
        Clip *blindSource = blind.clips[kOfxImageEffectSimpleSourceClipName].get();
        Clip *blindOutput = blind.clips[kOfxImageEffectOutputClipName].get();
        for (Clip *clip : {blindSource, blindOutput}) {
            clip->pixels.assign(static_cast<size_t>(blindWidth) * blindHeight * 4, 0.25f);
            clip->image = newPropertySet();
            propSetPointer(handleOf(clip->image), kOfxImagePropData, 0, clip->pixels.data());
            const int bounds[4] = {0, 0, blindWidth, blindHeight};
            propSetIntN(handleOf(clip->image), kOfxImagePropBounds, 4, bounds);
            propSetInt(handleOf(clip->image), kOfxImagePropRowBytes, 0,
                       blindWidth * 4 * static_cast<int>(sizeof(float)));
            propSetString(handleOf(clip->image), kOfxImageEffectPropPixelDepth, 0,
                          kOfxBitDepthFloat);
            propSetString(handleOf(clip->image), kOfxImageEffectPropComponents, 0,
                          kOfxImageComponentRGBA);
            propSetString(handleOf(clip->properties), kOfxImageEffectPropPreMultiplication, 0,
                          kOfxImageOpaque);
        }
        PropertySet *blindArgs = newPropertySet();
        propSetDouble(handleOf(blindArgs), kOfxPropTime, 0, 0);
        const int blindWindow[4] = {0, 0, blindWidth, blindHeight};
        propSetIntN(handleOf(blindArgs), kOfxImageEffectPropRenderWindow, 4, blindWindow);
        setParam(blind.params, "colorSpace",
                 static_cast<double>(fotufilm::Encoding::LinearDisplayP3));

        check(plugin->mainEntry(kOfxImageEffectActionRender, blindHandle, handleOf(blindArgs),
                                nullptr) == kOfxStatOK,
              "the Full span renders the film the id names, stale menu and all");

        // Texture Only is the span the missing toggles break. Its selection reads back as zero,
        // and zero is the one selection that *is* the identity — so the honest answer is neither
        // "no stages" nor a developed frame, but a refusal that says what to do.
        char textureStage[256] = "";
        const bool named = fotufilm_bridge_stage_id(FOTUFILM_BRIDGE_STAGE_TEXTURE, textureStage,
                                                   sizeof(textureStage)) > 0;
        check(named, "the bridge names the texture span");
        setString(blind.params, "stageID", textureStage);
        PropertySet *blindAnswer = newPropertySet();
        check(plugin->mainEntry(kOfxImageEffectActionIsIdentity, blindHandle,
                                handleOf(blindArgs), handleOf(blindAnswer)) ==
                      kOfxStatReplyDefault &&
                  blindAnswer->strings.count(kOfxPropName) == 0,
              "a texture span whose toggles were never described is not declared the identity");
        const int blindBefore = gMessagesPosted;
        std::fill(blindOutput->pixels.begin(), blindOutput->pixels.end(), -7.0f);
        check(plugin->mainEntry(kOfxImageEffectActionRender, blindHandle, handleOf(blindArgs),
                                nullptr) == kOfxStatFailed,
              "and fails the frame instead of passing the input through");
        bool blindUntouched = true;
        for (float value : blindOutput->pixels) {
            if (value != -7.0f) blindUntouched = false;
        }
        check(blindUntouched, "having written nothing");
        check(gMessagesPosted == blindBefore + 1 && gLastMessageType == kOfxMessageError &&
                  gLastMessageText.find("Restart Resolve") != std::string::npos,
              "telling the host, in words, that restarting Resolve is the fix");
        check(plugin->mainEntry(kOfxImageEffectActionRender, blindHandle, handleOf(blindArgs),
                                nullptr) == kOfxStatFailed &&
                  gMessagesPosted == blindBefore + 1,
              "once per node, not once per frame");

        plugin->mainEntry(kOfxActionDestroyInstance, blindHandle, nullptr, nullptr);
        check(plugin->mainEntry(kOfxActionUnload, nullptr, nullptr, nullptr) == kOfxStatOK,
              "unloads");
    }
    return 0;
}

int dumpParityFrame(const char *path) {
    auto fail = [](const char *what) {
        std::fprintf(stderr, "parity dump: %s\n", what);
        return 1;
    };

    buildSuites();
    PropertySet *hostProperties = newPropertySet();
    OfxHost host = {handleOf(hostProperties), fetchSuite};

    if (gGetNumberOfPlugins() < 1) return fail("the plugin exports nothing");
    OfxPlugin *plugin = gGetPlugin(0);
    if (!plugin) return fail("OfxGetPlugin(0) returned nothing");
    plugin->setHost(&host);
    if (plugin->mainEntry(kOfxActionLoad, nullptr, nullptr, nullptr) != kOfxStatOK) {
        return fail("the plugin refused to load");
    }

    Effect describer;
    describer.properties = newPropertySet();
    if (plugin->mainEntry(kOfxActionDescribe,
                          reinterpret_cast<OfxImageEffectHandle>(&describer), nullptr,
                          nullptr) != kOfxStatOK) {
        return fail("the plugin refused to describe itself");
    }

    Effect instance;
    instance.properties = newPropertySet();
    auto instanceHandle = reinterpret_cast<OfxImageEffectHandle>(&instance);
    if (plugin->mainEntry(kOfxImageEffectActionDescribeInContext, instanceHandle, nullptr,
                          nullptr) != kOfxStatOK) {
        return fail("the plugin refused to describe itself in context");
    }
    applyDefaults(instance.params);
    if (plugin->mainEntry(kOfxActionCreateInstance, instanceHandle, nullptr, nullptr) !=
        kOfxStatOK) {
        return fail("the plugin refused to create an instance");
    }

    Clip *source = instance.clips.count(kOfxImageEffectSimpleSourceClipName)
        ? instance.clips[kOfxImageEffectSimpleSourceClipName].get() : nullptr;
    Clip *output = instance.clips.count(kOfxImageEffectOutputClipName)
        ? instance.clips[kOfxImageEffectOutputClipName].get() : nullptr;
    if (!source || !output) return fail("the plugin defined no source or output clip");

    // Whole-frame bounds, whole-frame render window, square pixels. The plugin normalises a
    // non-square pixel aspect ratio by resampling, and a resampled frame is a different question
    // from the one being asked; 1.0 is written rather than left absent so that it is a stated
    // condition of the comparison and not the default of whichever host is answering.
    const int width = parity::kWidth, height = parity::kHeight;
    for (Clip *clip : {source, output}) {
        clip->pixels.assign(static_cast<size_t>(width) * height * 4, 0.0f);
        clip->image = newPropertySet();
        propSetPointer(handleOf(clip->image), kOfxImagePropData, 0, clip->pixels.data());
        const int bounds[4] = {0, 0, width, height};
        propSetIntN(handleOf(clip->image), kOfxImagePropBounds, 4, bounds);
        propSetInt(handleOf(clip->image), kOfxImagePropRowBytes, 0,
                   width * 4 * static_cast<int>(sizeof(float)));
        propSetString(handleOf(clip->image), kOfxImageEffectPropPixelDepth, 0,
                      kOfxBitDepthFloat);
        propSetString(handleOf(clip->image), kOfxImageEffectPropComponents, 0,
                      kOfxImageComponentRGBA);
        propSetString(handleOf(clip->image), kOfxImageClipPropColourspace, 0,
                      kOfxColourspaceLinRec709Srgb);
        propSetDouble(handleOf(clip->properties), kOfxImagePropPixelAspectRatio, 0, 1.0);
        // Straight alpha, so the plugin neither divides on the way in nor multiplies on the way
        // out. The frame is opaque throughout, so this changes no pixel — it removes a step, and
        // a step the two hosts do not agree about taking.
        propSetString(handleOf(clip->properties), kOfxImageEffectPropPreMultiplication, 0,
                      kOfxImageUnPreMultiplied);
        propSetString(handleOf(clip->properties), kOfxImageClipPropColourspace, 0,
                      kOfxColourspaceLinRec709Srgb);
    }
    // Bottom-up, because that is what an OFX image is. The plugin flips on the way in and out, so
    // filling this in natural row order would look right in the dump and be upside down where it
    // matters — inside the engine, where the grain field is generated. Colour and tone would agree
    // and the grain would be a vertical mirror, which is a difference that appears as the two
    // plugins disagreeing when it is really this harness not speaking OFX.
    {
        std::vector<float> upright((size_t)parity::kWidth * parity::kHeight * 4);
        parity::fillFrame(upright.data());
        for (int y = 0; y < parity::kHeight; ++y) {
            std::memcpy(source->pixels.data() + (size_t)y * parity::kWidth * 4,
                        upright.data() + (size_t)(parity::kHeight - 1 - y) * parity::kWidth * 4,
                        (size_t)parity::kWidth * 4 * sizeof(float));
        }
    }

    // The menus, moved the way a user moves them so that each one's persisted id follows the
    // index. Setting the index alone would leave the id the instance adopted at creation in
    // place, and the render resolves through the id.
    setChoice(plugin, instanceHandle, instance.params, "stage", FOTUFILM_BRIDGE_STAGE_FULL);
    setChoice(plugin, instanceHandle, instance.params, "stock", 0);
    setChoice(plugin, instanceHandle, instance.params, "paper", 0);
    // One past the bridge's gauges is the plugin's own appended "Match Film" entry.
    setChoice(plugin, instanceHandle, instance.params, "format",
              static_cast<int>(fotufilm_bridge_format_count()));
    // Explicit, never Auto: Auto would read the host's tag, and the point is to name the space
    // rather than to test two hosts' tagging.
    setChoice(plugin, instanceHandle, instance.params, "colorSpace",
              spaceMenuIndex(fotufilm::Encoding::LinearRec709));
    setParam(instance.params, "seed", 0x46494C4D);

    // Every texture-stage toggle on. The names are derived from the engine's stage ids, so they
    // are found by their prefix rather than listed here — a stage added to the engine joins this
    // frame without anyone remembering to add it.
    for (auto &entry : instance.params.params) {
        if (entry.first.rfind("texture_", 0) == 0) {
            setParam(instance.params, entry.first.c_str(), 1);
        }
    }

    // The float block the bridge reads, in its own order.
    const struct { const char *name; double value; } settings[] = {
        {"exposure", 0},        {"temperature", 6504}, {"tint", 0},
        {"highlights", 0},      {"shadows", 0},        {"saturation", 1},
        {"vibrance", 0},        {"grain", 1},          {"halation", 1},
        {"couplers", 1},        {"printCorrection", 0.05}, {"localTone", 1},
        {"push", 0},            {"bleachBypass", 0},   {"expired", 0},
        // The viewing-illuminant menu's first entry, which uses the medium reference.
        {"printLight", 0},      {"flare", 0},          {"estimatedHalation", 0},
        {"halationColour", 0},
    };
    for (const auto &setting : settings) {
        if (instance.params.params.count(setting.name) == 0) {
            std::fprintf(stderr, "parity dump: the plugin defines no \"%s\" parameter\n",
                         setting.name);
            return 1;
        }
        setParam(instance.params, setting.name, setting.value);
    }

    // Read labels from the plugin menus because index 0 may identify different stocks in different
    // catalogues. Printing labels prevents accidental comparison of dumps from different films.
    auto option = [&](const char *name) {
        auto found = instance.params.params.find(name);
        if (found == instance.params.params.end()) return std::string("?");
        auto &strings = found->second->properties->strings;
        auto options = strings.find(kOfxParamPropChoiceOption);
        const int index = found->second->intValue;
        if (options == strings.end() || index < 0 ||
            index >= static_cast<int>(options->second.size())) {
            return std::string("?");
        }
        return options->second[index];
    };
    std::printf("stage \"%s\", stock \"%s\" of %zu, format \"%s\", paper \"%s\", space \"%s\"\n",
                option("stage").c_str(), option("stock").c_str(),
                optionCount(instance.params, "stock"), option("format").c_str(),
                option("paper").c_str(), option("colorSpace").c_str());

    PropertySet *renderArgs = newPropertySet();
    propSetDouble(handleOf(renderArgs), kOfxPropTime, 0, 0);
    const int window[4] = {0, 0, width, height};
    propSetIntN(handleOf(renderArgs), kOfxImageEffectPropRenderWindow, 4, window);
    propSetDouble(handleOf(renderArgs), kOfxImageEffectPropRenderScale, 0, 1);
    propSetDouble(handleOf(renderArgs), kOfxImageEffectPropRenderScale, 1, 1);

    const OfxStatus rendered = plugin->mainEntry(kOfxImageEffectActionRender, instanceHandle,
                                                 handleOf(renderArgs), nullptr);
    if (rendered != kOfxStatOK) {
        if (!gLastMessageText.empty()) {
            std::fprintf(stderr, "parity dump: the plugin said: %s\n",
                         gLastMessageText.c_str());
        }
        return fail("the render failed");
    }
    // And back the other way, so the dump is the picture rather than the clip's own row order.
    std::vector<float> upright((size_t)width * height * 4);
    for (int y = 0; y < height; ++y) {
        std::memcpy(upright.data() + (size_t)y * width * 4,
                    output->pixels.data() + (size_t)(height - 1 - y) * width * 4,
                    (size_t)width * 4 * sizeof(float));
    }
    if (!parity::writeDump(path, upright.data(), width, height)) {
        return fail("could not write the dump");
    }
    std::printf("wrote %s (%dx%d RGBA float32)\n", path, width, height);

    plugin->mainEntry(kOfxActionDestroyInstance, instanceHandle, nullptr, nullptr);
    plugin->mainEntry(kOfxActionUnload, nullptr, nullptr, nullptr);
    return 0;
}

}

int main(int argc, char **argv) {
    // `argv[1]` remains the optional bundle to open instead of the linked-in plugin; the parity
    // dump is a flag, so the two combine — a dump can be taken from a built bundle as easily as
    // from this binary's own copy.
    const char *bundle = nullptr;
    const char *parityDump = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--parity-dump") == 0) {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "--parity-dump needs a path to write\n");
                return 2;
            }
            parityDump = argv[++i];
        } else if (!bundle && argv[i][0] != '-') {
            bundle = argv[i];
        } else {
            std::fprintf(stderr, "usage: host-harness [bundle] [--parity-dump <path>]\n");
            return 2;
        }
    }

    if (bundle && !openBundle(bundle)) return 1;
    // The dump is the whole run: the self-test suite renders hundreds of frames through this same
    // instance machinery, and a mode meant to produce one named frame should not also be a test.
    if (parityDump) return dumpParityFrame(parityDump);

    testWorkingSpace();
    fotufilm_test::testTranscodeParity(check);
    testPlugin();
    std::printf("\n%s\n", gFailures == 0 ? "all checks passed"
                                         : "THERE WERE FAILURES");
    return gFailures == 0 ? 0 : 1;
}
