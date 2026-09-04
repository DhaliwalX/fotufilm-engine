// A minimal host for the Final Cut plugin.
//
// It stands in for Final Cut Pro the way `resolve/tests/HostHarness.cpp` stands in for Resolve:
// it makes the parameter APIs, makes real IOSurfaces, and drives the effect through real renders,
// so the plugin's engine-facing half can be checked without the application — and, because the
// FxPlug SDK is a separate download from Apple, without the SDK.
//
// What it checks is the plugin, against the real engine. What it cannot check is `FxPlugStub.h`;
// see the note at the top of that file.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Accelerate/Accelerate.h>

#import "FxPlugStub.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <unistd.h>

#include "FotufilmBridge.h"
#include "ParityFrame.h"
#include "FotufilmEffect.h"

@implementation FxImageTile
@end

/// The SDK declares this and the framework defines it. Nothing links the framework here, so the
/// harness is what gives it an address — and the value is the SDK's own string, so an error this
/// plugin makes reads the same way in the harness as it does in Final Cut.
NSString *FxPlugErrorDomain = @"FxPlugErrorDomain";

static int gFailures = 0;

static void expect(bool condition, const char *what) {
    printf("%s %s\n", condition ? "  ok  " : "  FAIL", what);
    if (!condition) ++gFailures;
}

// MARK: - the host

@interface FakeHost : NSObject <PROAPIAccessing, FxParameterCreationAPI_v5,
                                FxParameterRetrievalAPI_v6, FxParameterSettingAPI_v5,
                                FxCustomParameterActionAPI_v4>
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id> *values;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *names;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *order;
/// The flags each control was created with, and then whatever the plugin last set them to. A
/// dimmed control is the plugin's only way of saying "this film has nothing behind this", so the
/// host has to remember them for that to be checkable.
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *flags;
@property(nonatomic, assign) NSInteger openGroups;
@property(nonatomic, assign) NSInteger balancedGroups;
/// startAction:/endAction: bracket every write the plugin makes; a write outside one is a write
/// Final Cut would not fold into a single undo.
@property(nonatomic, assign) NSInteger openActions;
@property(nonatomic, assign) NSInteger unbracketedWrites;
/// Writes made through `setFloatValue:toParameter:atTime:`. On an animatable parameter that call
/// is not a correction, it is a keyframe at whatever time was passed — so counting them is how
/// the harness sees a plugin quietly editing a project the user has only opened.
@property(nonatomic, assign) NSInteger timedFloatWrites;
@property(nonatomic, assign) CMTime now;
@end

@implementation FakeHost

- (instancetype)init {
    self = [super init];
    _values = [NSMutableDictionary dictionary];
    _names = [NSMutableDictionary dictionary];
    _order = [NSMutableArray array];
    _flags = [NSMutableDictionary dictionary];
    _now = kCMTimeZero;
    return self;
}

- (id)apiForProtocol:(Protocol *)protocol {
    return [self conformsToProtocol:protocol] ? self : nil;
}

- (void)define:(UInt32)parmId name:(NSString *)name value:(id)value
         flags:(FxParameterFlags)flags {
    if (self.values[@(parmId)]) {
        printf("  FAIL parameter id %u is defined twice (%s and %s)\n", parmId,
               self.names[@(parmId)].UTF8String, name.UTF8String);
        ++gFailures;
    }
    self.values[@(parmId)] = value;
    self.names[@(parmId)] = name;
    self.flags[@(parmId)] = @(flags);
    [self.order addObject:@(parmId)];
}

/// Every write the plugin makes goes through here, so that one place counts the ones it made
/// outside a startAction:/endAction: bracket.
- (void)wrote:(UInt32)parmId {
    if (self.openActions <= 0) ++self.unbracketedWrites;
}

- (BOOL)addFloatSliderWithName:(NSString *)name parameterID:(UInt32)parmId defaultValue:(double)v
                  parameterMin:(double)a parameterMax:(double)b sliderMin:(double)c
                     sliderMax:(double)d delta:(double)e parameterFlags:(FxParameterFlags)f {
    expect(v >= a && v <= b, [NSString stringWithFormat:@"%@ default is inside its hard range",
                                                        name].UTF8String);
    [self define:parmId name:name value:@(v) flags:f];
    return YES;
}

- (BOOL)addIntSliderWithName:(NSString *)name parameterID:(UInt32)parmId defaultValue:(int)v
                parameterMin:(int)a parameterMax:(int)b sliderMin:(int)c sliderMax:(int)d
                       delta:(int)e parameterFlags:(FxParameterFlags)f {
    [self define:parmId name:name value:@(v) flags:f];
    return YES;
}

- (BOOL)addToggleButtonWithName:(NSString *)name parameterID:(UInt32)parmId defaultValue:(BOOL)v
                      parameterFlags:(FxParameterFlags)f {
    [self define:parmId name:name value:@(v) flags:f];
    return YES;
}

- (BOOL)addPopupMenuWithName:(NSString *)name parameterID:(UInt32)parmId defaultValue:(UInt32)v
                 menuEntries:(NSArray *)entries parameterFlags:(FxParameterFlags)f {
    expect(entries.count > 0,
           [NSString stringWithFormat:@"%@ menu is not empty", name].UTF8String);
    [self define:parmId name:name value:@(v) flags:f];
    return YES;
}

- (BOOL)addStringParameterWithName:(NSString *)name parameterID:(UInt32)parmId
                      defaultValue:(NSString *)v parameterFlags:(FxParameterFlags)f {
    [self define:parmId name:name value:v flags:f];
    return YES;
}

- (BOOL)startParameterSubGroup:(NSString *)name parameterID:(UInt32)parmId
                     parameterFlags:(FxParameterFlags)f {
    [self define:parmId name:name value:@0 flags:f];
    ++self.openGroups;
    return YES;
}

- (BOOL)endParameterSubGroup {
    --self.openGroups;
    ++self.balancedGroups;
    return YES;
}

- (BOOL)getFloatValue:(double *)value fromParameter:(UInt32)parmId atTime:(CMTime)time {
    id stored = self.values[@(parmId)];
    if (!stored) return NO;
    *value = [stored doubleValue];
    return YES;
}

- (BOOL)getIntValue:(int *)value fromParameter:(UInt32)parmId atTime:(CMTime)time {
    id stored = self.values[@(parmId)];
    if (!stored) return NO;
    *value = [stored intValue];
    return YES;
}

- (BOOL)getBoolValue:(BOOL *)value fromParameter:(UInt32)parmId atTime:(CMTime)time {
    id stored = self.values[@(parmId)];
    if (!stored) return NO;
    *value = [stored boolValue];
    return YES;
}

- (BOOL)getStringParameterValue:(NSString **)value fromParameter:(UInt32)parmId {
    id stored = self.values[@(parmId)];
    if (![stored isKindOfClass:NSString.class]) return NO;
    *value = stored;
    return YES;
}

- (BOOL)getParameterFlags:(FxParameterFlags *)flags fromParameter:(UInt32)parmId {
    NSNumber *stored = self.flags[@(parmId)];
    if (!stored) return NO;
    *flags = (FxParameterFlags)stored.unsignedIntValue;
    return YES;
}

- (BOOL)setStringParameterValue:(NSString *)value toParameter:(UInt32)parmId {
    [self wrote:parmId];
    self.values[@(parmId)] = value;
    return YES;
}

- (BOOL)setFloatValue:(double)value toParameter:(UInt32)parmId atTime:(CMTime)time {
    [self wrote:parmId];
    ++self.timedFloatWrites;
    self.values[@(parmId)] = @(value);
    return YES;
}

- (BOOL)setIntValue:(int)value toParameter:(UInt32)parmId atTime:(CMTime)time {
    [self wrote:parmId];
    self.values[@(parmId)] = @(value);
    return YES;
}

- (BOOL)setParameterFlags:(FxParameterFlags)flags toParameter:(UInt32)parmId {
    [self wrote:parmId];
    self.flags[@(parmId)] = @(flags);
    return YES;
}

// void, as the SDK declares them. A host that answered these with a value would be a stub that
// had drifted from FxCustomParameterActionAPI.h.
- (void)startAction:(id)effect { ++self.openActions; }
- (void)endAction:(id)effect { --self.openActions; }
- (CMTime)currentTime { return self.now; }
@end

// MARK: - surfaces

static IOSurfaceRef makeSurface(int width, int height, OSType format = kCVPixelFormatType_64RGBAHalf) {
    const int bytesPerElement = format == kCVPixelFormatType_128RGBAFloat ? 16
                              : format == kCVPixelFormatType_32BGRA ? 4 : 8;
    NSDictionary *properties = @{
        (id)kIOSurfaceWidth : @(width),
        (id)kIOSurfaceHeight : @(height),
        (id)kIOSurfaceBytesPerElement : @(bytesPerElement),
        (id)kIOSurfacePixelFormat : @(format),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)properties);
}

static FxImageTile *makeTile(IOSurfaceRef surface, FxRect image, FxRect tile) {
    FxImageTile *out = [[FxImageTile alloc] init];
    out.ioSurface = (__bridge IOSurface *)surface;
    out.imagePixelBounds = image;
    out.tilePixelBounds = tile;
    // Linear sRGB is linear light on Rec.709 primaries, which is what a standard-gamut host hands
    // over once the plugin has asked for linear — so it is what Auto has to resolve here.
    out.colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);
    out.imageOrigin = kFxImageOrigin_TOP_LEFT;
    return out;
}

/// `takeLock` is what separates a write this machine's CPU made from a write anything else made.
/// `IOSurfaceRef.h` increments the buffer's seed "as the unlock is performed" on a buffer locked
/// for writing, and says nothing about a GPU or other hardware write — so a surface rewritten
/// without the lock keeps the seed it had, which is exactly what a Metal stage upstream writing
/// into a pooled surface looks like from in here.
static void fillInto(IOSurfaceRef surface, int width, int height, bool takeLock,
                     void (^generator)(int x, int y, float *rgba)) {
    if (takeLock) IOSurfaceLock(surface, 0, nullptr);
    uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(surface);
    const size_t stride = IOSurfaceGetBytesPerRow(surface);
    const bool wide =
        (OSType)IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_128RGBAFloat;
    std::vector<float> row((size_t)width * 4);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) generator(x, y, &row[(size_t)x * 4]);
        if (wide) {
            std::memcpy(base + (size_t)y * stride, row.data(),
                        (size_t)width * 4 * sizeof(float));
        } else {
            vImage_Buffer source{row.data(), 1, (vImagePixelCount)width * 4, 0};
            vImage_Buffer destination{base + (size_t)y * stride, 1, (vImagePixelCount)width * 4, 0};
            vImageConvert_PlanarFtoPlanar16F(&source, &destination, kvImageNoFlags);
        }
    }
    if (takeLock) IOSurfaceUnlock(surface, 0, nullptr);
}

static void fill(IOSurfaceRef surface, int width, int height,
                 void (^generator)(int x, int y, float *rgba)) {
    fillInto(surface, width, height, true, generator);
}

static void fillWithoutLocking(IOSurfaceRef surface, int width, int height,
                               void (^generator)(int x, int y, float *rgba)) {
    fillInto(surface, width, height, false, generator);
}

static std::vector<float> readback(IOSurfaceRef surface, int width, int height) {
    std::vector<float> out((size_t)width * height * 4);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
    const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(surface);
    const size_t stride = IOSurfaceGetBytesPerRow(surface);
    if ((OSType)IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_128RGBAFloat) {
        for (int y = 0; y < height; ++y) {
            std::memcpy(out.data() + (size_t)y * width * 4, base + (size_t)y * stride,
                        (size_t)width * 4 * sizeof(float));
        }
    } else {
        vImage_Buffer source{(void *)base, (vImagePixelCount)height, (vImagePixelCount)width * 4,
                             stride};
        vImage_Buffer destination{out.data(), (vImagePixelCount)height,
                                  (vImagePixelCount)width * 4, (size_t)width * 4 * sizeof(float)};
        vImageConvert_Planar16FtoPlanarF(&source, &destination, kvImageNoFlags);
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
    return out;
}

// MARK: - the runs

static id<FxTileableEffect> makeEffect(FakeHost *host) {
    Class effectClass = NSClassFromString(@"FotufilmEffect");
    if (!effectClass) {
        printf("  FAIL the class named in Info.plist (FotufilmEffect) is not in the binary\n");
        ++gFailures;
        return nil;
    }
    id<FxTileableEffect> effect = [[effectClass alloc] initWithAPIManager:host];
    NSError *error = nil;
    if (![effect addParametersWithError:&error]) {
        printf("  FAIL addParameters: %s\n", error.localizedDescription.UTF8String);
        ++gFailures;
    }
    return effect;
}

static bool develop(id<FxTileableEffect> effect, FakeHost *host, int width, int height,
                    void (^generator)(int x, int y, float *rgba), std::vector<float> *out) {
    IOSurfaceRef sourceSurface = makeSurface(width, height);
    IOSurfaceRef destinationSurface = makeSurface(width, height);
    fill(sourceSurface, width, height, generator);

    const FxRect bounds{0, 0, width, height};
    FxImageTile *source = makeTile(sourceSurface, bounds, bounds);
    FxImageTile *destination = makeTile(destinationSurface, bounds, bounds);

    NSError *error = nil;
    NSData *state = nil;
    if (![effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error]) {
        printf("  FAIL pluginState: %s\n", error.localizedDescription.UTF8String);
        ++gFailures;
        CFRelease(sourceSurface); CFRelease(destinationSurface);
        return false;
    }
    if (![effect renderDestinationImage:destination
                           sourceImages:@[ source ]
                            pluginState:state
                                 atTime:kCMTimeZero
                                  error:&error]) {
        printf("  FAIL render: %s\n", error.localizedDescription.UTF8String);
        ++gFailures;
        CFRelease(sourceSurface); CFRelease(destinationSurface);
        return false;
    }
    *out = readback(destinationSurface, width, height);
    CFRelease(sourceSurface);
    CFRelease(destinationSurface);
    return true;
}

/// One render, whose failure is the answer rather than a fault: the checks on the engine that
/// will not start, and on the destination that is too small to write, are checks that the plugin
/// says no.
static BOOL tryDevelop(id<FxTileableEffect> effect, int width, int height, NSError **error) {
    IOSurfaceRef sourceSurface = makeSurface(width, height);
    IOSurfaceRef destinationSurface = makeSurface(width, height);
    fill(sourceSurface, width, height, ^(int x, int y, float *rgba) {
        rgba[0] = rgba[1] = rgba[2] = 0.18f;
        rgba[3] = 1.0f;
    });
    const FxRect bounds{0, 0, width, height};
    FxImageTile *source = makeTile(sourceSurface, bounds, bounds);
    FxImageTile *destination = makeTile(destinationSurface, bounds, bounds);

    NSData *state = nil;
    BOOL rendered = [effect pluginState:&state atTime:kCMTimeZero quality:2 error:error] &&
                    [effect renderDestinationImage:destination
                                      sourceImages:@[ source ]
                                       pluginState:state
                                            atTime:kCMTimeZero
                                             error:error];
    CFRelease(sourceSurface);
    CFRelease(destinationSurface);
    return rendered;
}

// MARK: - reading the inspector back

static FxParameterFlags flagsOf(FakeHost *host, UInt32 parmId) {
    return (FxParameterFlags)[host.flags[@(parmId)] unsignedIntValue];
}

static BOOL dimmed(FakeHost *host, UInt32 parmId) {
    return (flagsOf(host, parmId) & kFxParameterFlag_DISABLED) != 0;
}

static NSString *statusLine(FakeHost *host) {
    id line = host.values[@(kFotufilmParam_Status)];
    return [line isKindOfClass:NSString.class] ? line : @"";
}

static BOOL saysThat(FakeHost *host, NSString *fragment) {
    return [statusLine(host) containsString:fragment];
}

/// The first stock the engine has for which `wanted` holds, or -1. The films these checks need —
/// one measured at more than one development, one that never meets a print — are properties of
/// the pack rather than names to hardcode: a pack that renamed them would leave a check asserting
/// nothing about a stock that no longer exists.
static int32_t firstStock(BOOL (^wanted)(int32_t)) {
    for (int32_t i = 0; i < fotufilm_bridge_stock_count(); ++i) {
        if (wanted(i)) return i;
    }
    return -1;
}

static NSString *stockName(int32_t stock) {
    char buffer[256];
    const int32_t length = fotufilm_bridge_stock_name(stock, buffer, (int32_t)sizeof(buffer));
    return [[NSString alloc] initWithBytes:buffer
                                    length:(NSUInteger)MAX(length, 0)
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

/// A filter's *menu* index, which is one past its place in the engine's catalogue because the
/// menu opens with a None of the plugin's own. Looked up by id: the drawer will gain filters, and
/// a position written down here would then name a different piece of glass than the caller means.
static int filterMenuIndex(const char *wanted) {
    for (int32_t i = 0; i < fotufilm_bridge_lens_filter_count(); ++i) {
        char id[64] = "";
        if (fotufilm_bridge_lens_filter_id(i, id, (int32_t)sizeof(id)) >= 0 &&
            strcmp(id, wanted) == 0) {
            return (int)i + 1;
        }
    }
    return 0;
}

/// The durable id of a pipeline span, asked of the engine rather than spelled here: it is what a
/// project saves, and a harness that wrote its own copy of the string would still pass on a build
/// that had renamed the engine's.
static NSString *stageID(int32_t stage) {
    char buffer[64];
    const int32_t length = fotufilm_bridge_stage_id(stage, buffer, (int32_t)sizeof(buffer));
    return [[NSString alloc] initWithBytes:buffer
                                    length:(NSUInteger)MAX(length, 0)
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

/// Puts a film in the menu the way a user does, and lets the plugin react to it.
static void chooseStock(id<FxTileableEffect> effect, FakeHost *host, int32_t stock) {
    host.values[@(kFotufilmParam_Stock)] = @(stock);
    host.values[@(kFotufilmParam_StockID)] = @"";
    NSError *error = nil;
    [effect parameterChanged:kFotufilmParam_Stock atTime:kCMTimeZero error:&error];
}

static int parityDump(const char *path) {
    FakeHost *host = [[FakeHost alloc] init];
    id<FxTileableEffect> effect = makeEffect(host);
    if (!effect) return 1;

    host.values[@(kFotufilmParam_Stock)] = @0;
    host.values[@(kFotufilmParam_Paper)] = @0;
    host.values[@(kFotufilmParam_Format)] = @(fotufilm_bridge_format_count());
    host.values[@(kFotufilmParam_Stage)] = @(FOTUFILM_BRIDGE_STAGE_FULL);
    for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
        host.values[@(kFotufilmParam_TextureStageFirst + i)] = @YES;
    }
    // Named, not Auto: the two plugins must be asked about the same light, and Auto resolves
    // against a host tag that the OFX side does not have here.
    host.values[@(kFotufilmParam_ColorSpace)] = @((int)fotufilm::Encoding::LinearRec709);
    host.values[@(kFotufilmParam_Seed)] = @0x46494C4D;

    host.values[@(kFotufilmParam_Exposure)] = @0.0;
    host.values[@(kFotufilmParam_Temperature)] = @6504.0;
    host.values[@(kFotufilmParam_Tint)] = @0.0;
    host.values[@(kFotufilmParam_Highlights)] = @0.0;
    host.values[@(kFotufilmParam_Shadows)] = @0.0;
    host.values[@(kFotufilmParam_Saturation)] = @1.0;
    host.values[@(kFotufilmParam_Vibrance)] = @0.0;
    host.values[@(kFotufilmParam_Grain)] = @1.0;
    host.values[@(kFotufilmParam_Halation)] = @1.0;
    host.values[@(kFotufilmParam_Couplers)] = @1.0;
    host.values[@(kFotufilmParam_PrintCorrection)] = @0.05;
    host.values[@(kFotufilmParam_LocalTone)] = @YES;
    host.values[@(kFotufilmParam_Push)] = @0.0;
    host.values[@(kFotufilmParam_BleachBypass)] = @0.0;
    host.values[@(kFotufilmParam_Expired)] = @0.0;
    host.values[@(kFotufilmParam_PrintLight)] = @0;
    host.values[@(kFotufilmParam_Flare)] = @0.0;
    host.values[@(kFotufilmParam_EstimatedHalation)] = @NO;
    host.values[@(kFotufilmParam_HalationColour)] = @0.0;

    std::vector<float> scene((size_t)parity::kWidth * parity::kHeight * 4);
    parity::fillFrame(scene.data());

    IOSurfaceRef sourceSurface =
        makeSurface(parity::kWidth, parity::kHeight, kCVPixelFormatType_128RGBAFloat);
    IOSurfaceRef destinationSurface =
        makeSurface(parity::kWidth, parity::kHeight, kCVPixelFormatType_128RGBAFloat);
    __block const float *source = scene.data();
    fill(sourceSurface, parity::kWidth, parity::kHeight, ^(int x, int y, float *rgba) {
        const float *from = source + ((size_t)y * parity::kWidth + x) * 4;
        rgba[0] = from[0]; rgba[1] = from[1]; rgba[2] = from[2]; rgba[3] = from[3];
    });

    const FxRect bounds{0, 0, parity::kWidth, parity::kHeight};
    FxImageTile *in = makeTile(sourceSurface, bounds, bounds);
    FxImageTile *out = makeTile(destinationSurface, bounds, bounds);

    NSError *error = nil;
    NSData *state = nil;
    // kFxQuality_HIGH: a frame being kept, developed the exact way rather than the viewer's.
    if (![effect pluginState:&state atTime:kCMTimeZero quality:kFxQuality_HIGH error:&error]) {
        printf("pluginState failed: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }
    if (![effect renderDestinationImage:out sourceImages:@[ in ] pluginState:state
                                 atTime:kCMTimeZero error:&error]) {
        printf("render failed: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }
    std::vector<float> developed = readback(destinationSurface, parity::kWidth, parity::kHeight);
    CFRelease(sourceSurface);
    CFRelease(destinationSurface);

    if (!parity::writeDump(path, developed.data(), parity::kWidth, parity::kHeight)) {
        printf("could not write %s\n", path);
        return 1;
    }
    printf("wrote %s (%dx%d)\n", path, parity::kWidth, parity::kHeight);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i + 1 < argc; ++i) {
            if (strcmp(argv[i], "--parity-dump") == 0) return parityDump(argv[i + 1]);
        }
        const int width = 320;
        const int height = 180;

        printf("engine start\n");
        {
            // The engine is started once per XPC process, and the failure a user actually meets —
            // the Mac app not yet activated — is one they fix with Final Cut still open. A latched
            // failure would make them quit the application to find out that activating worked. So
            // the first attempt here is made to fail, and the checks are that the plugin says so,
            // that it does not ask again immediately, and that it does ask again after the
            // throttle and then works.
            //
            // The failure is injected rather than arranged: a licence that is really inactive
            // cannot be produced in-process on a Mac that holds a certificate.
            setenv("FOTUFILM_TEST_ENGINE_FAILURE", "the harness asked for a failed start", 1);

            FakeHost *broken = [[FakeHost alloc] init];
            id<FxTileableEffect> stalled = makeEffect(broken);
            if (!stalled) return 1;

            NSError *error = nil;
            expect(!tryDevelop(stalled, width, height, &error),
                   "an engine that did not start refuses to render");
            expect([error.domain isEqualToString:FxPlugErrorDomain] &&
                       error.code >= kFxError_ThirdPartyDeveloperStart,
                   "the refusal is an FxPlugErrorDomain error in the third-party block");
            expect([error.localizedDescription containsString:@"the harness asked for a failed "
                                                               "start"],
                   "the refusal quotes what the engine said");
            expect(saysThat(broken, @"the harness asked for a failed start") &&
                       saysThat(broken, @"try again"),
                   "the status line says the engine did not start and will be asked again");

            // Cleared, but inside the throttle: a clip full of instances must not turn one failed
            // start into one licence check per instance per frame.
            unsetenv("FOTUFILM_TEST_ENGINE_FAILURE");
            expect(!tryDevelop(stalled, width, height, nullptr),
                   "a failed start is not retried again inside the throttle window");

            // Nothing has reached the bridge yet: that failure is injected ahead of it, the way
            // an inactive licence fails before the packs are opened.
            expect(FotufilmTestBridgeInitializeCount == 0,
                   "a start that failed before the bridge did not initialise it");

            // The other kind of failure: the bridge initialises, and one of the checks after it
            // refuses anyway — no Metal device, an empty pack, more texture stages than the
            // reserved id block holds. `fotufilm_bridge_initialize` opens the sealed stock packs
            // and sets the engine's environment, and none of those three is fixed by doing it
            // again; a retry that re-ran it would reload the process-wide stock registry every
            // few seconds for the rest of the session.
            auto waitOutThrottle = [] {
                usleep((useconds_t)(((double)kFotufilmEngineRetrySeconds + 0.25) * 1e6));
            };
            setenv("FOTUFILM_TEST_ENGINE_POST_FAILURE",
                   "the harness asked for a failure after initialising", 1);
            waitOutThrottle();
            expect(!tryDevelop(stalled, width, height, &error),
                   "a failure raised after the bridge initialised still refuses to render");
            expect(FotufilmTestBridgeInitializeCount == 1,
                   "and the bridge was initialised exactly once to get there");
            expect([error.localizedDescription containsString:@"after initialising"],
                   "and the refusal quotes the post-initialise reason");

            waitOutThrottle();
            expect(!tryDevelop(stalled, width, height, &error),
                   "the retry past the throttle re-checks it and refuses again");
            expect(FotufilmTestBridgeInitializeCount == 1,
                   "without opening the stock packs a second time");

            // Past it, with nothing left to refuse. Nothing was quit and nothing was reloaded;
            // the same effect instance now develops, which is what activating the Mac app
            // mid-session has to look like.
            unsetenv("FOTUFILM_TEST_ENGINE_POST_FAILURE");
            waitOutThrottle();
            expect(tryDevelop(stalled, width, height, &error),
                   "the next use past the throttle starts the engine and develops");
            expect(FotufilmTestBridgeInitializeCount == 1,
                   "on the one initialise it has ever made");

            // What that effect is left holding, which is the other half of a late start and the
            // only place it can be checked: the engine is a process singleton, so once it is up
            // no later instance can have a panel built against a dead one. `stalled`'s inspector
            // was built from stand-ins — one entry in each menu, and not one texture toggle —
            // and Final Cut cannot go back and fill them in.
            //
            // The menus first. A stand-in menu's index is a position in a list the host never
            // showed: read into the engine's own list, the zero behind "Match Film" names the
            // first real gauge, and every frame develops on a format the inspector never
            // offered. The menu's own default identity is the only honest reading.
            expect(fotufilm_bridge_format_count() > 0,
                   "the engine offers at least one gauge for a placeholder to be confused with");
            {
                NSData *state = nil;
                FotufilmState unpacked{};
                expect([stalled pluginState:&state atTime:kCMTimeZero quality:2 error:&error],
                       "an effect whose panel was built without the engine still packs a state");
                [state getBytes:&unpacked length:sizeof(unpacked)];
                expect(unpacked.format == fotufilm_bridge_format_count(),
                       "a placeholder Format menu renders Match Film, not the first real gauge");

                // And the same identity is written down when the instance joins its document, so
                // the project keeps what the inspector showed rather than resolving it afresh
                // against whatever pack is installed next time.
                [stalled pluginInstanceAddedToDocument];
                expect([broken.values[@(kFotufilmParam_FormatID)]
                           isEqualToString:@kFotufilmMatchFilmFormatID],
                       "joining a document persists the placeholder menu's own default id");
                expect(saysThat(broken, @"placeholders") && saysThat(broken, @"Restart Final Cut"),
                       "the status line says the menus are placeholders until Final Cut restarts");
            }

            // Then the toggles. `addParametersWithError:` makes one per spatial stage the engine
            // hands out, and it had none to hand out; the controls that do not exist read back as
            // off, so the texture mask packs as zero — which is indistinguishable from the user
            // switching every stage off, and would hand the source straight back under a span
            // they asked to do something.
            expect(fotufilm_bridge_texture_stage_count() > 0,
                   "the engine offers spatial stages for the panel to be missing");
            //
            // The span arrives by name, not by menu index: a one-entry Stage menu has no index
            // that means Texture Only, and a project saved with it carries the id. Joining the
            // document again is the path that restore actually takes, and it refreshes the
            // status line without writing the placeholder menu's index back over the id.
            broken.values[@(kFotufilmParam_StageID)] = stageID(FOTUFILM_BRIDGE_STAGE_TEXTURE);
            [stalled pluginInstanceAddedToDocument];
            error = nil;
            expect(!tryDevelop(stalled, width, height, &error),
                   "Texture Only on a panel with no texture toggles is refused, not passed "
                   "through");
            expect([error.domain isEqualToString:FxPlugErrorDomain] &&
                       error.code >= kFxError_ThirdPartyDeveloperStart &&
                       [error.localizedDescription containsString:@"Restart Final Cut Pro"],
                   "and the refusal names the restart that is the only fix");
            expect(saysThat(broken, @"Texture Only cannot be rendered"),
                   "the status line says the same thing before the render is attempted");
            broken.values[@(kFotufilmParam_StageID)] = stageID(FOTUFILM_BRIDGE_STAGE_FULL);
            expect(tryDevelop(stalled, width, height, &error),
                   "and every other span on that panel still develops");
        }

        printf("parameters\n");
        FakeHost *host = [[FakeHost alloc] init];
        id<FxTileableEffect> effect = makeEffect(host);
        if (!effect) return 1;

        expect(host.openGroups == 0, "every parameter group is closed");
        expect(host.balancedGroups == 8, "eight groups were opened and closed");
        expect(host.values[@(kFotufilmParam_Stock)] != nil, "the stock menu exists");
        expect(host.values[@(kFotufilmParam_Halation)] != nil, "the halation slider exists");
        expect([host.values[@(kFotufilmParam_Status)] isKindOfClass:NSString.class],
               "the status line exists and is a string");
        expect(dimmed(host, kFotufilmParam_Status),
               "the status line is dimmed: it is read, never typed into");
        // Match Film is one past the engine's own gauges: passing it as `format` is how the
        // plugin says "the gauge this stock is known on".
        expect([host.values[@(kFotufilmParam_Format)] intValue] >= fotufilm_bridge_format_count(),
               "the gauge defaults to Match Film");
        expect([host.values[@(kFotufilmParam_Paper)] intValue] >= fotufilm_bridge_paper_count(),
               "the output medium defaults to Match Film");
        for (NSNumber *parmId in host.order) {
            if (parmId.intValue < 1 || parmId.intValue > 9998) {
                printf("  FAIL parameter id %d is outside the range FxPlug reserves\n",
                       parmId.intValue);
                ++gFailures;
            }
        }
        expect(true, "every parameter id is inside FxPlug's range");

        NSDictionary *properties = nil;
        NSError *error = nil;
        expect([effect properties:&properties error:&error], "properties are declared");
        expect([properties[kFxPropertyKey_NeedsFullBuffer] boolValue],
               "the plugin asks not to be tiled");
        expect([properties[kFxPropertyKey_DesiredProcessingColorInfo] unsignedIntegerValue] ==
                   kFxImageColorInfo_RGB_LINEAR,
               "the plugin asks for linear light");
        expect([properties[kFxPropertyKey_VariesWhenParamsAreStatic] boolValue],
               "the plugin declares that a static frame still moves");
        // One frame in, the same frame out. The SDK's default is YES, which makes the host hold
        // more of the clip than this needs.
        expect(properties[kFxPropertyKey_MayRemapTime] != nil &&
                   ![properties[kFxPropertyKey_MayRemapTime] boolValue],
               "the plugin declares that it does not remap time");
        expect(![effect properties:nil error:&error] &&
                   [error.domain isEqualToString:FxPlugErrorDomain],
               "properties: with nowhere to put them is refused rather than crashed on");

        printf("identity\n");
        {
            // A project saved by name must survive a menu that renumbered underneath it: the id
            // is what the render trusts, and the index is only a hint.
            char buffer[256];
            const int32_t length = fotufilm_bridge_stock_id(1, buffer, (int32_t)sizeof(buffer));
            NSString *second = [[NSString alloc] initWithBytes:buffer
                                                        length:(NSUInteger)MAX(length, 0)
                                                      encoding:NSUTF8StringEncoding];
            host.values[@(kFotufilmParam_Stock)] = @0;
            host.values[@(kFotufilmParam_StockID)] = second;
            NSData *state = nil;
            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
            FotufilmState unpacked{};
            [state getBytes:&unpacked length:sizeof(unpacked)];
            expect(unpacked.stock == 1, "the persisted id wins over the menu index");

            host.values[@(kFotufilmParam_StockID)] = @"a-stock-that-was-uninstalled";
            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
            [state getBytes:&unpacked length:sizeof(unpacked)];
            expect(unpacked.stock == 0, "an id this install does not have falls back to the menu");
            host.values[@(kFotufilmParam_StockID)] = @"";
        }

        printf("parameter slots\n");
        {
            // Twenty-one slots, filled by hand, and a slot filled from the wrong control is a
            // lever that silently does nothing — or worse, does something else. Each one is moved
            // off its default and read back out of the packed block.
            struct Slot {
                UInt32 parameter;
                int slot;
                id value;
                float expected;
                const char *what;
            };
            const Slot slots[] = {
                {kFotufilmParam_Exposure, FOTUFILM_BRIDGE_EXPOSURE_EV, @1.5, 1.5f, "exposure"},
                {kFotufilmParam_Temperature, FOTUFILM_BRIDGE_TEMPERATURE, @3200.0, 3200.0f,
                 "temperature"},
                {kFotufilmParam_Tint, FOTUFILM_BRIDGE_TINT, @12.0, 12.0f, "tint"},
                {kFotufilmParam_Highlights, FOTUFILM_BRIDGE_HIGHLIGHTS, @-0.4, -0.4f, "highlights"},
                {kFotufilmParam_Shadows, FOTUFILM_BRIDGE_SHADOWS, @0.3, 0.3f, "shadows"},
                {kFotufilmParam_Saturation, FOTUFILM_BRIDGE_SATURATION, @1.4, 1.4f, "saturation"},
                {kFotufilmParam_Vibrance, FOTUFILM_BRIDGE_VIBRANCE, @0.5, 0.5f, "vibrance"},
                {kFotufilmParam_Grain, FOTUFILM_BRIDGE_GRAIN_SCALE, @0.25, 0.25f, "grain"},
                {kFotufilmParam_Halation, FOTUFILM_BRIDGE_HALATION_SCALE, @4.0, 4.0f, "halation"},
                {kFotufilmParam_HalationColour, FOTUFILM_BRIDGE_HALATION_COLOUR, @0.7, 0.7f,
                 "halo colour"},
                {kFotufilmParam_Flare, FOTUFILM_BRIDGE_FLARE_SCALE, @1.25, 1.25f, "lens flare"},
                {kFotufilmParam_Couplers, FOTUFILM_BRIDGE_COUPLER_SCALE, @0.6, 0.6f, "DIR couplers"},
                {kFotufilmParam_PrintCorrection, FOTUFILM_BRIDGE_PRINT_CORRECTION, @0.4, 0.4f,
                 "print correction"},
                // Push is not in this table: it is the one control the state call does not pass
                // through, because the engine carries a film's response only at the developments
                // it was measured at. It gets its own section below, where the value asked for
                // and the value packed are both checked against the film's own measurements.
                {kFotufilmParam_BleachBypass, FOTUFILM_BRIDGE_BLEACH_BYPASS, @0.8, 0.8f,
                 "bleach bypass"},
                {kFotufilmParam_Expired, FOTUFILM_BRIDGE_EXPIRED_YEARS, @7.0, 7.0f, "expired years"},
                {kFotufilmParam_LocalTone, FOTUFILM_BRIDGE_LOCAL_TONE, @NO, 0.0f, "regional tone"},
                {kFotufilmParam_EstimatedHalation, FOTUFILM_BRIDGE_ESTIMATED_HALATION, @YES, 1.0f,
                 "estimated halation"},
                // A menu index, and the engine wants the lamp in kelvin. Entry 2 is 2856 K.
                {kFotufilmParam_PrintLight, FOTUFILM_BRIDGE_PRINT_LIGHT, @2, 2856.0f,
                 "viewing light, in kelvin"},
                // The lens. The filter and diffusion menus open with a "None" the plugin owns,
                // so a menu index already is the engine index plus one the bridge wants; the
                // metering and negative-viewing menus come straight out of an engine enum and
                // have the one added. The grade is a bare index.
                {kFotufilmParam_LensFilter1, FOTUFILM_BRIDGE_LENS_FILTER_1, @3, 3.0f,
                 "the first filter thread"},
                {kFotufilmParam_LensFilter2, FOTUFILM_BRIDGE_LENS_FILTER_2, @5, 5.0f,
                 "the second filter thread"},
                {kFotufilmParam_LensFilter3, FOTUFILM_BRIDGE_LENS_FILTER_3, @7, 7.0f,
                 "the third filter thread"},
                {kFotufilmParam_Metering, FOTUFILM_BRIDGE_LENS_METERING, @0, 1.0f,
                 "metering, offset past its off position"},
                {kFotufilmParam_Diffusion, FOTUFILM_BRIDGE_DIFFUSION_FAMILY, @2, 2.0f,
                 "the diffusion family"},
                {kFotufilmParam_DiffusionGrade, FOTUFILM_BRIDGE_DIFFUSION_GRADE, @3, 3.0f,
                 "the diffusion grade, as a bare index"},
                {kFotufilmParam_FocalLength, FOTUFILM_BRIDGE_FOCAL_LENGTH, @135.0, 135.0f,
                 "focal length, in millimetres"},
                {kFotufilmParam_NegativeViewing, FOTUFILM_BRIDGE_NEGATIVE_VIEWING, @1, 2.0f,
                 "negative viewing, offset past its off position"},
            };
            for (const Slot &slot : slots) {
                id saved = host.values[@(slot.parameter)];
                host.values[@(slot.parameter)] = slot.value;
                NSData *state = nil;
                [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
                FotufilmState unpacked{};
                [state getBytes:&unpacked length:sizeof(unpacked)];
                expect(std::fabs(unpacked.parameters[slot.slot] - slot.expected) < 1e-4f,
                       [NSString stringWithFormat:@"%s reaches its engine slot", slot.what]
                           .UTF8String);
                host.values[@(slot.parameter)] = saved;
            }

            // The seed is not in the block; it is its own argument, and grain is seeded on it.
            host.values[@(kFotufilmParam_Seed)] = @12345;
            NSData *state = nil;
            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
            FotufilmState unpacked{};
            [state getBytes:&unpacked length:sizeof(unpacked)];
            expect(unpacked.seed == 12345, "the grain seed reaches the engine");
            host.values[@(kFotufilmParam_Seed)] = @0x46494C4D;

            // The texture toggles are one bit each, and the bit is the engine's to hand out. Turn
            // them all off and the mask must be empty; a hardcoded bit would survive that.
            const int32_t stage = FOTUFILM_BRIDGE_STAGE_TEXTURE;
            host.values[@(kFotufilmParam_Stage)] = @(stage);
            for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
                host.values[@(kFotufilmParam_TextureStageFirst + i)] = @NO;
            }
            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
            [state getBytes:&unpacked length:sizeof(unpacked)];
            expect(unpacked.parameters[FOTUFILM_BRIDGE_TEXTURE_STAGES] == 0.0f,
                   "no texture stage selected is an empty mask");
            int32_t everything = 0;
            for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
                host.values[@(kFotufilmParam_TextureStageFirst + i)] = @YES;
                everything |= fotufilm_bridge_texture_stage_mask(i);
            }
            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
            [state getBytes:&unpacked length:sizeof(unpacked)];
            expect((int32_t)unpacked.parameters[FOTUFILM_BRIDGE_TEXTURE_STAGES] == everything,
                   "every texture stage carries the bit the engine handed out");
            expect(unpacked.parameters[FOTUFILM_BRIDGE_STAGE] == (float)stage,
                   "the span reaches its engine slot");
            host.values[@(kFotufilmParam_Stage)] = @0;
        }

        // The films these sections need, chosen by what the engine says they are rather than by
        // name. A pack that renames or reorders its stocks must not leave a check asserting
        // something about a film that is no longer there.
        const int32_t pushed = firstStock(^(int32_t stock) {
            return (BOOL)(fotufilm_bridge_stock_pushes(stock) != 0);
        });
        const int32_t unpushed = firstStock(^(int32_t stock) {
            return (BOOL)(fotufilm_bridge_stock_pushes(stock) == 0);
        });
        const int32_t printed = firstStock(^(int32_t stock) {
            return (BOOL)(fotufilm_bridge_stock_prints(stock) != 0);
        });
        const int32_t reversal = firstStock(^(int32_t stock) {
            return (BOOL)(fotufilm_bridge_stock_prints(stock) == 0);
        });

        printf("push snapping\n");
        {
            // Push / Pull is a continuous slider over a set of measured conditions. The engine
            // carries a film's response only at the developments it was measured at and throws on
            // anything between them, so every value the slider can land on that is not one of them
            // is a frame that does not render. The plugin snaps instead: when the control moves,
            // when the film changes, and again in the state call, because a restored project and
            // an interpolated keyframe reach the render without passing through either.
            NSError *error = nil;
            NSData *state = nil;
            FotufilmState unpacked{};

            // A film that carries measured developments if the pack has one, and otherwise any
            // film at all: a film with none is measured at reference development only, which is
            // still a grid, and still one the slider can fall off.
            const int32_t stock = pushed >= 0 ? pushed : 0;
            chooseStock(effect, host, stock);
            expect(dimmed(host, kFotufilmParam_Push) == (pushed < 0),
                   "the Push / Pull slider is live exactly on a film with measured developments");

            // A value the film was not measured at, found by asking rather than assumed: what a
            // pack carries is the pack's business, and a hardcoded stop would assert nothing on a
            // pack that happened to carry it.
            double asked = 0;
            for (double candidate = -1; candidate <= 3.0001; candidate += 0.05) {
                if (std::fabs(fotufilm_bridge_stock_snap_push(stock, (float)candidate) - candidate)
                        > 1e-4) {
                    asked = candidate;
                    break;
                }
            }
            const double onto = fotufilm_bridge_stock_snap_push(stock, (float)asked);
            expect(std::fabs(asked - onto) > 1e-4,
                   [NSString stringWithFormat:@"%@ has a development it was not measured at for "
                                               "the slider to land on", stockName(stock)]
                       .UTF8String);

            // The control is left exactly where the user put it. Push / Pull animates, so
            // writing the snapped value back would not correct the control — it would lay a
            // keyframe, at whatever time the playhead was on, in a project that may have been
            // open for two seconds. The snap belongs on the way to the engine, where the state
            // call does it, and on the status line, where the user can read it.
            host.values[@(kFotufilmParam_Push)] = @(asked);
            const NSInteger keyframesBefore = host.timedFloatWrites;
            [effect parameterChanged:kFotufilmParam_Push atTime:kCMTimeZero error:&error];
            const double landed = [host.values[@(kFotufilmParam_Push)] doubleValue];
            expect(std::fabs(landed - asked) < 1e-4,
                   "moving the slider off the measured grid leaves the control where it was put");
            expect(host.timedFloatWrites == keyframesBefore,
                   "and keyframes nothing, so opening a project cannot change it");
            expect(saysThat(host, pushed >= 0 ? @"is not a development"
                                              : @"has no measured push or pull"),
                   "the status line says what happened to the value that was asked for");
            expect(pushed < 0 || saysThat(host, @"snapped to"),
                   "and where it will actually be developed");

            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
            [state getBytes:&unpacked length:sizeof(unpacked)];
            expect(std::fabs(unpacked.parameters[FOTUFILM_BRIDGE_PUSH_PULL] - onto) < 1e-4 &&
                       std::fabs(unpacked.parameters[FOTUFILM_BRIDGE_PUSH_PULL] - asked) > 1e-4,
                   "the state carries the snapped push, not the one on the control");

            // The project saved under another film, and the keyframe interpolated between two
            // measured stops: neither passes through parameterChanged:, and the state call is the
            // last place to catch them before the engine refuses the frame.
            host.values[@(kFotufilmParam_Push)] = @(asked);
            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
            [state getBytes:&unpacked length:sizeof(unpacked)];
            expect(std::fabs(unpacked.parameters[FOTUFILM_BRIDGE_PUSH_PULL] - asked) > 1e-4 &&
                       std::fabs(unpacked.parameters[FOTUFILM_BRIDGE_PUSH_PULL] - onto) < 1e-4,
                   "a value that never passed through the control is snapped in the state");
            host.values[@(kFotufilmParam_Push)] = @(asked);
            expect(tryDevelop(effect, width, height, &error),
                   "an off-grid push renders instead of being thrown out by the engine");

            if (unpushed >= 0) {
                host.values[@(kFotufilmParam_Push)] = @2.0;
                chooseStock(effect, host, unpushed);
                expect(dimmed(host, kFotufilmParam_Push),
                       [NSString stringWithFormat:@"%@ has no measured push, so the slider is "
                                                   "dimmed", stockName(unpushed)].UTF8String);
                expect(saysThat(host, @"has no measured push or pull"),
                       "the status line says why the Push / Pull slider is dimmed");
                [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
                [state getBytes:&unpacked length:sizeof(unpacked)];
                expect(unpacked.parameters[FOTUFILM_BRIDGE_PUSH_PULL] == 0.0f,
                       "a film with no measured development renders at reference development");
            } else {
                printf("  note  every film in this pack carries a measured push; the "
                       "no-profile path was not exercised\n");
            }
            if (pushed < 0) {
                printf("  note  no film in this pack carries a measured push or pull, so the "
                       "snap onto a non-zero measured stop was not exercised; run with "
                       "FOTUFILM_STOCKS pointed at a pack that has one\n");
            }
            host.values[@(kFotufilmParam_Push)] = @0.0;
        }

        printf("per-stock gating\n");
        {
            // What a film has is the film's own data. A control the chosen stock cannot back is
            // dimmed rather than left live: a live control that does nothing is worse than an
            // absent one, because the user moves it and waits for a change that never comes.
            expect(printed >= 0 && reversal >= 0,
                   "the pack has both a film that is printed and one that is its own positive");
            NSError *error = nil;

            if (printed >= 0) {
                chooseStock(effect, host, printed);
                expect(!dimmed(host, kFotufilmParam_Paper) &&
                           !dimmed(host, kFotufilmParam_PrintLight) &&
                           !dimmed(host, kFotufilmParam_PrintCorrection),
                       [NSString stringWithFormat:@"%@ is printed, so the print controls stay "
                                                   "live", stockName(printed)].UTF8String);
                expect(!saysThat(host, @"has no print"),
                       "the status line does not claim a printed film has no print");
            }
            if (reversal >= 0) {
                chooseStock(effect, host, reversal);
                expect(dimmed(host, kFotufilmParam_Paper) &&
                           dimmed(host, kFotufilmParam_PrintLight) &&
                           dimmed(host, kFotufilmParam_PrintCorrection),
                       [NSString stringWithFormat:@"%@ is its own positive, so Output Medium, "
                                                   "Viewing Illuminant and Channel Contrast Match "
                                                   "are dimmed", stockName(reversal)].UTF8String);
                expect(saysThat(host, @"is its own positive and has no print"),
                       "the status line says why the print controls are dimmed");
            }

            // The texture stages, film by film: a remjet-backed stock returns no light from its
            // base, a coupler-free one has no adjacency, and a reversal never meets an enlarger.
            bool gatedRight = true;
            bool sawWithheld = false;
            for (int32_t stock : {printed, reversal}) {
                if (stock < 0) continue;
                chooseStock(effect, host, stock);
                for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
                    const bool offered =
                        fotufilm_bridge_texture_stage_available(stock, i) != 0;
                    if (!offered) sawWithheld = true;
                    if (dimmed(host, (UInt32)(kFotufilmParam_TextureStageFirst + i)) == offered) {
                        gatedRight = false;
                    }
                }
            }
            expect(gatedRight,
                   "each texture toggle is live exactly where the film has that stage to give");
            expect(sawWithheld, "at least one of the two films withholds a texture stage");
            if (sawWithheld) {
                expect(saysThat(host, @"not offered"),
                       "the status line names the stages the film has no ability to give");
            }

            // A project restored rather than built: the menus already hold the film when the
            // instance joins the document, and nothing was ever "changed". The gating done when
            // the controls were created knows only about the defaults, so this is the other place
            // it has to happen.
            if (reversal >= 0 && printed >= 0) {
                chooseStock(effect, host, printed);
                host.values[@(kFotufilmParam_Stock)] = @(reversal);
                host.values[@(kFotufilmParam_StockID)] = @"";
                expect(!dimmed(host, kFotufilmParam_Paper),
                       "a film put in the menu without a change notice is not gated yet");
                host.now = CMTimeMake(7, 30);
                [effect pluginInstanceAddedToDocument];
                expect(dimmed(host, kFotufilmParam_Paper) &&
                           saysThat(host, @"is its own positive and has no print"),
                       "an instance joining a document is gated against what the project saved");
                host.now = kCMTimeZero;
            }

            // Back to where the rest of the run expects to find things.
            chooseStock(effect, host, 0);
            expect(host.unbracketedWrites == 0,
                   "every write the plugin made was inside a startAction:/endAction: pair");
            expect(host.openActions == 0, "every action the plugin opened was closed");
            (void)error;
        }

        printf("colour space\n");
        {
            // The plugin asks Final Cut for kFxImageColorInfo_RGB_LINEAR, so what it is handed is
            // linear light whatever the library's transfer curve is. Four menu entries name a
            // curved library — Rec.709 Gamma 2.4, sRGB, DaVinci Intermediate, ACEScct — and
            // decoding light that is already linear with their curves would bend it twice. Their
            // indices are frozen, because the choice persists as one; what they mean is not.
            bool allLinear = true;
            for (int choice = 0; choice <= (int)fotufilm::Encoding::Count; ++choice) {
                if (choice == kFotufilmColorSpaceAuto) continue;
                const fotufilm::Encoding transfer = FotufilmMenuTransfer(choice);
                if (FotufilmMenuPrimaries(choice) == fotufilm::Encoding::Count) continue;
                if (fotufilm::inputTransformFor(transfer).shape != 0 ||
                    fotufilm::outputTransformFor(transfer).shape != 0) {
                    printf("       menu entry %d decodes with a transfer curve\n", choice);
                    allLinear = false;
                }
            }
            expect(allLinear, "every colour space choice decodes with a linear transfer");

            // DaVinci Wide Gamut has no linear twin in fotufilm::Encoding, so that entry keeps its
            // own matrices and borrows an identity transfer from one that does. Its published
            // curve is emphatically not identity, which is what makes this worth asserting.
            expect(FotufilmMenuPrimaries(2) == fotufilm::Encoding::DaVinciIntermediate &&
                       fotufilm::inputTransformFor(fotufilm::Encoding::DaVinciIntermediate).shape != 0,
                   "DaVinci Intermediate keeps its own primaries and drops its own curve");

            // End to end, on a linear ramp: entries that share primaries must develop to exactly
            // the same frame, whatever library they were named for. Applying the Rec.709 gamma
            // 2.4 decode to entry 0 would move every pixel.
            struct Group { const char *what; int choices[4]; int count; };
            const Group groups[] = {
                {"Rec.709 Gamma 2.4, sRGB, Linear Rec.709 and Auto develop identically",
                 {(int)fotufilm::Encoding::Rec709Gamma24, (int)fotufilm::Encoding::SRGB,
                  (int)fotufilm::Encoding::LinearRec709, kFotufilmColorSpaceAuto}, 4},
                {"ACEScct and ACEScg develop identically",
                 {(int)fotufilm::Encoding::ACEScct, (int)fotufilm::Encoding::ACEScg, 0, 0}, 2},
            };
            void (^greyRamp)(int, int, float *) = ^(int x, int y, float *rgba) {
                const float t = (float)x / (float)(width - 1);
                rgba[0] = rgba[1] = rgba[2] = 0.02f + t * 1.4f;
                rgba[3] = 1.0f;
            };
            id saved = host.values[@(kFotufilmParam_ColorSpace)];
            for (const Group &group : groups) {
                std::vector<float> reference;
                bool same = true;
                for (int i = 0; i < group.count; ++i) {
                    host.values[@(kFotufilmParam_ColorSpace)] = @(group.choices[i]);
                    std::vector<float> developed;
                    if (!develop(effect, host, width, height, greyRamp, &developed)) {
                        same = false;
                        break;
                    }
                    if (i == 0) reference = developed;
                    else if (developed != reference) same = false;
                }
                expect(same, group.what);
            }

            // ...and entries that do not share primaries must not. Otherwise the check above
            // would pass on a plugin that had thrown the colour space away entirely.
            std::vector<float> rec709, wide;
            host.values[@(kFotufilmParam_ColorSpace)] = @((int)fotufilm::Encoding::LinearRec709);
            develop(effect, host, width, height, greyRamp, &rec709);
            host.values[@(kFotufilmParam_ColorSpace)] =
                @((int)fotufilm::Encoding::DaVinciIntermediate);
            develop(effect, host, width, height, greyRamp, &wide);
            expect(rec709 != wide,
                   "a choice on other primaries develops to a different frame");

            // What the status line says the choice decodes as.
            NSError *error = nil;
            host.values[@(kFotufilmParam_ColorSpace)] = @((int)fotufilm::Encoding::SRGB);
            [effect parameterChanged:kFotufilmParam_ColorSpace atTime:kCMTimeZero error:&error];
            expect(saysThat(host, @"decoded as linear Rec.709") &&
                       saysThat(host, @"no transfer curve is applied"),
                   "the status line says what the sRGB entry decodes as");
            host.values[@(kFotufilmParam_ColorSpace)] =
                @((int)fotufilm::Encoding::DaVinciIntermediate);
            [effect parameterChanged:kFotufilmParam_ColorSpace atTime:kCMTimeZero error:&error];
            expect(saysThat(host, @"decoded as linear DaVinci Wide Gamut"),
                   "the status line says what the DaVinci Intermediate entry decodes as");

            // A clip whose colour space does not name itself. Auto reads it as Rec.709, which is
            // what a standard-gamut library almost always is — but it is a guess, and a guess the
            // user can only correct if they are told it was made.
            {
                IOSurfaceRef untaggedSurface = makeSurface(width, height);
                fill(untaggedSurface, width, height, greyRamp);
                IOSurfaceRef out = makeSurface(width, height);
                const FxRect bounds{0, 0, width, height};
                FxImageTile *untagged = makeTile(untaggedSurface, bounds, bounds);
                untagged.colorSpace = NULL;
                FxImageTile *into = makeTile(out, bounds, bounds);

                host.values[@(kFotufilmParam_ColorSpace)] = @(kFotufilmColorSpaceAuto);
                NSError *renderError = nil;
                NSData *autoState = nil;
                [effect pluginState:&autoState atTime:kCMTimeZero quality:2 error:&renderError];
                expect([effect renderDestinationImage:into
                                         sourceImages:@[ untagged ]
                                          pluginState:autoState
                                               atTime:kCMTimeZero
                                                error:&renderError],
                       "a clip whose colour space has no name still develops");
                [effect parameterChanged:kFotufilmParam_ColorSpace
                                  atTime:kCMTimeZero
                                   error:&renderError];
                expect(saysThat(host, @"has no name"),
                       "the status line says the clip's colour space was guessed at");
                CFRelease(untaggedSurface);
                CFRelease(out);
            }

            // Auto on the Print Only span: its input is per-layer optical density, which carries
            // no colour space at all. Guessing one would be worse than refusing.
            host.values[@(kFotufilmParam_ColorSpace)] = @(kFotufilmColorSpaceAuto);
            host.values[@(kFotufilmParam_Stage)] = @(FOTUFILM_BRIDGE_STAGE_PRINT);
            [effect parameterChanged:kFotufilmParam_Stage atTime:kCMTimeZero error:&error];
            expect(saysThat(host, @"Print Only needs Timeline Color Space named"),
                   "the status line says Print Only cannot use Auto");
            expect(!tryDevelop(effect, width, height, &error) &&
                       [error.domain isEqualToString:FxPlugErrorDomain],
                   "Print Only with Auto is refused rather than guessed at");
            host.values[@(kFotufilmParam_Stage)] = @0;
            [effect parameterChanged:kFotufilmParam_Stage atTime:kCMTimeZero error:&error];
            host.values[@(kFotufilmParam_ColorSpace)] = saved;
        }

        printf("lens\n");
        {
            // Everything in the Lens group sits ahead of the emulsion, and every one of its
            // slots is zero-off. Both halves are checked here: that each control reaches the
            // engine and moves the developed frame, and that a project saved before the group
            // existed — whose blob stops at the halo colour — develops the same frame it always
            // did, to the bit.
            NSError *error = nil;

            const int deepRed = filterMenuIndex("w25");
            const int warming = filterMenuIndex("w81a");
            expect(deepRed > 0 && warming > 0,
                   "the filter drawer carries the two filters this section fits");

            // A ramp with a patch three stops over white in the middle of it, so the diffusion
            // filter has a highlight to bloom and the film has both ends of its curve to use.
            void (^lit)(int, int, float *) = ^(int x, int y, float *rgba) {
                const float t = (float)x / (float)(width - 1);
                const bool patch = x > width * 7 / 16 && x < width * 9 / 16 &&
                                   y > height * 7 / 16 && y < height * 9 / 16;
                rgba[0] = patch ? 8.0f : 0.02f + t * 1.6f;
                rgba[1] = patch ? 7.0f : 0.02f + t * 1.4f;
                rgba[2] = patch ? 6.0f : 0.02f + t * 1.1f;
                rgba[3] = 1.0f;
            };
            auto rmsBetween = [](const std::vector<float> &a, const std::vector<float> &b) {
                if (a.empty() || a.size() != b.size()) return 0.0;
                double energy = 0;
                for (size_t i = 0; i < a.size(); ++i) {
                    const double difference = a[i] - b[i];
                    energy += difference * difference;
                }
                return std::sqrt(energy / a.size());
            };
            // The convention the Resolve harness's own sweep uses: a change the engine made
            // shows as more than 1e-4 RMS over the frame, float noise as orders less.
            const double stirred = 1e-4;

            chooseStock(effect, host, printed >= 0 ? printed : 0);
            std::vector<float> bare;
            expect(develop(effect, host, width, height, lit, &bare),
                   "develops the frame with a bare lens");

            struct Lever {
                UInt32 parameter;
                id value;
                const char *what;
            };
            // Each is set on top of the one before it, so the second filter is genuinely stacked
            // behind the first and the metering has something to compensate for.
            const Lever levers[] = {
                {kFotufilmParam_LensFilter1, @(deepRed), "a filter reaches the engine"},
                {kFotufilmParam_LensFilter2, @(warming),
                 "a second filter stacks behind the first"},
                // From the default, Metered through, to None: the light the red filter took then
                // lands on the film as underexposure instead of being compensated away.
                {kFotufilmParam_Metering, @0, "metering reaches the engine"},
            };
            std::vector<float> previous = bare;
            for (const Lever &lever : levers) {
                host.values[@(lever.parameter)] = lever.value;
                [effect parameterChanged:lever.parameter atTime:kCMTimeZero error:&error];
                std::vector<float> after;
                const bool rendered = develop(effect, host, width, height, lit, &after);
                const double distance = rendered ? rmsBetween(previous, after) : 0;
                printf("       %s: RMS %.5f\n", lever.what, distance);
                expect(rendered && distance > stirred, lever.what);
                if (rendered) previous = after;
            }
            for (UInt32 parmId : {(UInt32)kFotufilmParam_LensFilter1,
                                  (UInt32)kFotufilmParam_LensFilter2}) {
                host.values[@(parmId)] = @0;
                [effect parameterChanged:parmId atTime:kCMTimeZero error:&error];
            }
            host.values[@(kFotufilmParam_Metering)] = @1;
            [effect parameterChanged:kFotufilmParam_Metering atTime:kCMTimeZero error:&error];

            // The diffusion filter, and the focal length its halo is imaged through. The focal
            // length is read by the diffusion filter and by nothing else, so it is moved with
            // one fitted.
            host.values[@(kFotufilmParam_Diffusion)] = @1;
            [effect parameterChanged:kFotufilmParam_Diffusion atTime:kCMTimeZero error:&error];
            std::vector<float> misted;
            const bool diffused = develop(effect, host, width, height, lit, &misted);
            const double bloom = diffused ? rmsBetween(bare, misted) : 0;
            printf("       diffusion: RMS %.5f\n", bloom);
            expect(diffused && bloom > stirred, "a diffusion filter reaches the engine");

            host.values[@(kFotufilmParam_FocalLength)] = @200.0;
            std::vector<float> longLens;
            const bool onLong = develop(effect, host, width, height, lit, &longLens);
            const double widened = onLong ? rmsBetween(misted, longLens) : 0;
            printf("       focal length: RMS %.5f\n", widened);
            expect(onLong && widened > stirred,
                   "the focal length reaches the diffusion filter");
            host.values[@(kFotufilmParam_FocalLength)] = @0.0;
            host.values[@(kFotufilmParam_Diffusion)] = @0;
            [effect parameterChanged:kFotufilmParam_Diffusion atTime:kCMTimeZero error:&error];

            // Where the lens is live. The scattering half — the mist, its grade and the focal
            // length that images it — reaches every span that runs the camera side or differences
            // the spatial stages, which is everything but Print Only. The absorbing half reaches
            // Full and nothing else: a fitted filter is two more air-glass faces, so the engine
            // raises its veiling-glare bit for one, and no compiled variant pairs that bit with
            // the density output the negative span writes or with the texture span. Left live in
            // either it would not weaken the frame, it would fail it — which the probe below
            // makes the engine say for itself.
            {
                bool greyedRight = true;
                for (int32_t span : {FOTUFILM_BRIDGE_STAGE_FULL, FOTUFILM_BRIDGE_STAGE_NEGATIVE,
                                     FOTUFILM_BRIDGE_STAGE_PRINT,
                                     FOTUFILM_BRIDGE_STAGE_TEXTURE}) {
                    host.values[@(kFotufilmParam_Stage)] = @(span);
                    host.values[@(kFotufilmParam_StageID)] = @"";
                    [effect parameterChanged:kFotufilmParam_Stage
                                      atTime:kCMTimeZero
                                       error:&error];
                    const BOOL exposesFilm = span == FOTUFILM_BRIDGE_STAGE_FULL;
                    const BOOL scatters = span != FOTUFILM_BRIDGE_STAGE_PRINT;
                    for (UInt32 parmId : {(UInt32)kFotufilmParam_LensFilter1,
                                          (UInt32)kFotufilmParam_LensFilter2,
                                          (UInt32)kFotufilmParam_LensFilter3,
                                          (UInt32)kFotufilmParam_Metering}) {
                        if (dimmed(host, parmId) == exposesFilm) greyedRight = false;
                    }
                    for (UInt32 parmId : {(UInt32)kFotufilmParam_Diffusion,
                                          (UInt32)kFotufilmParam_DiffusionGrade,
                                          (UInt32)kFotufilmParam_FocalLength}) {
                        if (dimmed(host, parmId) == scatters) greyedRight = false;
                    }
                }
                expect(greyedRight,
                       "an absorbing filter is live only in Full, and the scattering half "
                       "everywhere the film is exposed or its texture differenced");
                host.values[@(kFotufilmParam_Stage)] = @0;
                host.values[@(kFotufilmParam_StageID)] = @"";
                [effect parameterChanged:kFotufilmParam_Stage atTime:kCMTimeZero error:&error];
            }

            // Why the dimming above is not a matter of taste. The engine is asked directly,
            // through the raw parameter block the render reads, with the span set to Negative
            // Only and a filter in the first thread — the state the inspector now refuses to
            // produce. There is no compiled kernel for it, so the frame does not come out weak,
            // it does not come out. The day a glare-carrying negative variant is added this check
            // fails, which is the notice that the filters can be let back into that span.
            {
                host.values[@(kFotufilmParam_LensFilter1)] = @(deepRed);
                host.values[@(kFotufilmParam_LensFilter1ID)] = @"";
                [effect parameterChanged:kFotufilmParam_LensFilter1
                                  atTime:kCMTimeZero
                                   error:&error];
                NSData *state = nil;
                expect([effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error],
                       "packs a state with a filter fitted in Full");
                FotufilmState fitted{};
                [state getBytes:&fitted length:sizeof(fitted)];
                expect(fitted.parameters[FOTUFILM_BRIDGE_LENS_FILTER_1] == (float)deepRed,
                       "and the filter is in the block Full sends");

                FotufilmState onTheNegative = fitted;
                onTheNegative.parameters[FOTUFILM_BRIDGE_STAGE] =
                    (float)FOTUFILM_BRIDGE_STAGE_NEGATIVE;
                FotufilmState bareNegative = onTheNegative;
                bareNegative.parameters[FOTUFILM_BRIDGE_LENS_FILTER_1] = 0;
                bareNegative.parameters[FOTUFILM_BRIDGE_LENS_METERING] = 0;

                IOSurfaceRef sourceSurface = makeSurface(width, height);
                fill(sourceSurface, width, height, lit);
                const FxRect bounds{0, 0, width, height};
                auto renderBlock = [&](const FotufilmState &blob, NSError **outError) {
                    IOSurfaceRef out = makeSurface(width, height);
                    FxImageTile *source = makeTile(sourceSurface, bounds, bounds);
                    FxImageTile *destination = makeTile(out, bounds, bounds);
                    const BOOL ok =
                        [effect renderDestinationImage:destination
                                          sourceImages:@[ source ]
                                           pluginState:[NSData dataWithBytes:&blob
                                                                      length:sizeof(blob)]
                                                atTime:kCMTimeZero
                                                 error:outError];
                    CFRelease(out);
                    return ok;
                };
                NSError *refusal = nil;
                expect(!renderBlock(onTheNegative, &refusal),
                       "the engine refuses Negative Only with a filter fitted");
                expect([refusal.domain isEqualToString:FxPlugErrorDomain],
                       "and the refusal reaches the host as an FxPlug error");
                NSError *fine = nil;
                expect(renderBlock(bareNegative, &fine),
                       "while the same span with the thread empty develops");
                CFRelease(sourceSurface);

                host.values[@(kFotufilmParam_LensFilter1)] = @0;
                host.values[@(kFotufilmParam_LensFilter1ID)] = @"";
                [effect parameterChanged:kFotufilmParam_LensFilter1
                                  atTime:kCMTimeZero
                                   error:&error];
            }

            // Dimming a control does not clear it. The value the user set while the span was Full
            // stays in the parameter and the host hands it back whatever the inspector is
            // drawing, so the state call is where a control the span cannot carry has to be put
            // back to its off position — and zero is that position for every slot in this group.
            // Without it, switching to Negative Only with a filter still fitted fails every
            // frame, which is the failure the greying was supposed to have prevented.
            {
                auto developInSpan = [&](int32_t span, int filter, std::vector<float> &into) {
                    host.values[@(kFotufilmParam_Stage)] = @(span);
                    host.values[@(kFotufilmParam_StageID)] = @"";
                    host.values[@(kFotufilmParam_LensFilter1)] = @(filter);
                    host.values[@(kFotufilmParam_LensFilter1ID)] = @"";
                    [effect parameterChanged:kFotufilmParam_Stage
                                      atTime:kCMTimeZero
                                       error:&error];
                    return develop(effect, host, width, height, lit, &into);
                };
                // Texture Only is asked only for what this film has behind each stage, which is
                // what the inspector's own gating leaves switched on.
                const int32_t lensStock = printed >= 0 ? printed : 0;
                for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
                    host.values[@(kFotufilmParam_TextureStageFirst + i)] =
                        @(fotufilm_bridge_texture_stage_available(lensStock, i) != 0);
                }
                for (int32_t span : {FOTUFILM_BRIDGE_STAGE_NEGATIVE,
                                     FOTUFILM_BRIDGE_STAGE_TEXTURE}) {
                    std::vector<float> withFilter, without;
                    const bool fitted = developInSpan(span, deepRed, withFilter);
                    const bool bare = developInSpan(span, 0, without);
                    expect(fitted && bare,
                           span == FOTUFILM_BRIDGE_STAGE_NEGATIVE
                               ? "Negative Only develops with a filter left in the menu"
                               : "Texture Only develops with a filter left in the menu");
                    expect(fitted && bare && withFilter == without,
                           span == FOTUFILM_BRIDGE_STAGE_NEGATIVE
                               ? "and develops the frame it would have with the thread empty"
                               : "and Texture Only likewise");
                }

                // The other half, or the check above would pass on a plugin that had thrown the
                // filter away everywhere.
                std::vector<float> fullFitted, fullBare;
                const bool a = developInSpan(FOTUFILM_BRIDGE_STAGE_FULL, deepRed, fullFitted);
                const bool b = developInSpan(FOTUFILM_BRIDGE_STAGE_FULL, 0, fullBare);
                expect(a && b && rmsBetween(fullFitted, fullBare) > stirred,
                       "and back in Full the same filter moves the frame");

                for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
                    host.values[@(kFotufilmParam_TextureStageFirst + i)] = @YES;
                }
                host.values[@(kFotufilmParam_Stage)] = @0;
                host.values[@(kFotufilmParam_StageID)] = @"";
                [effect parameterChanged:kFotufilmParam_Stage atTime:kCMTimeZero error:&error];
            }

            // The negative viewing mode, which is read only where the negative is the output.
            int32_t negativeMedium = -1;
            for (int32_t i = 0; i < fotufilm_bridge_paper_count(); ++i) {
                if (fotufilm_bridge_paper_is_negative(i) != 0) { negativeMedium = i; break; }
            }
            expect(negativeMedium >= 0, "the engine offers the negative as an output medium");
            if (negativeMedium >= 0) {
                expect(dimmed(host, kFotufilmParam_NegativeViewing),
                       "Negative Viewing is dimmed while the output is a print");
                host.values[@(kFotufilmParam_Paper)] = @(negativeMedium);
                host.values[@(kFotufilmParam_PaperID)] = @"";
                [effect parameterChanged:kFotufilmParam_Paper atTime:kCMTimeZero error:&error];
                expect(!dimmed(host, kFotufilmParam_NegativeViewing),
                       "and live once the output medium is the negative");
                std::vector<float> lightBox, scanned;
                const bool onBox = develop(effect, host, width, height, lit, &lightBox);
                host.values[@(kFotufilmParam_NegativeViewing)] = @1;
                const bool onScanner = develop(effect, host, width, height, lit, &scanned);
                const double divided = onBox && onScanner ? rmsBetween(lightBox, scanned) : 0;
                printf("       negative viewing: RMS %.5f from the light box\n", divided);
                expect(onBox && onScanner && divided > stirred,
                       "dividing the base out reaches the engine");

                // And on a print, where it has nothing to say. This is the half that matters: a
                // stated viewing mode *is* the engine's instruction to show the negative, so a
                // plugin that passed it through unconditionally would print nothing at all.
                host.values[@(kFotufilmParam_Paper)] = @0;
                host.values[@(kFotufilmParam_PaperID)] = @"";
                [effect parameterChanged:kFotufilmParam_Paper atTime:kCMTimeZero error:&error];
                expect(dimmed(host, kFotufilmParam_NegativeViewing),
                       "and dimmed again on a medium that prints");
                std::vector<float> printedWithMode, printedWithout;
                const bool withMode =
                    develop(effect, host, width, height, lit, &printedWithMode);
                host.values[@(kFotufilmParam_NegativeViewing)] = @0;
                const bool without = develop(effect, host, width, height, lit, &printedWithout);
                expect(withMode && without && printedWithMode == printedWithout,
                       "a print is the same frame whichever viewing mode is selected");
            }

            // A project graded through a named filter keeps that filter when the drawer is
            // renumbered under it: the id is what was saved, the index only a position.
            {
                char id[64] = "";
                fotufilm_bridge_lens_filter_id((int32_t)(deepRed - 1), id, (int32_t)sizeof(id));
                host.values[@(kFotufilmParam_LensFilter1)] = @(deepRed);
                [effect parameterChanged:kFotufilmParam_LensFilter1
                                  atTime:kCMTimeZero
                                   error:&error];
                expect([host.values[@(kFotufilmParam_LensFilter1ID)] isEqualToString:@(id)],
                       "choosing a filter writes its id beside the menu");

                host.values[@(kFotufilmParam_LensFilter1)] = @0;
                NSData *state = nil;
                [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
                FotufilmState unpacked{};
                [state getBytes:&unpacked length:sizeof(unpacked)];
                expect(unpacked.parameters[FOTUFILM_BRIDGE_LENS_FILTER_1] == (float)deepRed,
                       "the persisted filter id outvotes a stale menu index");

                host.values[@(kFotufilmParam_LensFilter1ID)] = @"a-filter-nobody-has";
                [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
                [state getBytes:&unpacked length:sizeof(unpacked)];
                expect(unpacked.parameters[FOTUFILM_BRIDGE_LENS_FILTER_1] == 0.0f,
                       "an id this install does not have falls back to the menu");
                host.values[@(kFotufilmParam_LensFilter1ID)] = @"";
            }

            // The whole point of every slot in the block being zero-off. A project saved before
            // the Lens group existed carries a blob that stops at the halo colour; what the host
            // hands back for the rest is zero. That frame must not move by one bit.
            {
                IOSurfaceRef sourceSurface = makeSurface(width, height);
                fill(sourceSurface, width, height, lit);
                const FxRect bounds{0, 0, width, height};

                NSData *state = nil;
                expect([effect pluginState:&state
                                    atTime:kCMTimeZero
                                   quality:2
                                     error:&error],
                       "packs the state a fresh instance would send");
                FotufilmState legacy{};
                [state getBytes:&legacy length:sizeof(legacy)];
                for (int slot = FOTUFILM_BRIDGE_LENS_FILTER_1;
                     slot < FOTUFILM_BRIDGE_PARAMETER_COUNT; ++slot) {
                    legacy.parameters[slot] = 0;
                }
                NSData *legacyState = [NSData dataWithBytes:&legacy length:sizeof(legacy)];

                auto renderWith = [&](NSData *blob, std::vector<float> &into) {
                    IOSurfaceRef out = makeSurface(width, height);
                    FxImageTile *source = makeTile(sourceSurface, bounds, bounds);
                    FxImageTile *destination = makeTile(out, bounds, bounds);
                    NSError *renderError = nil;
                    const BOOL ok = [effect renderDestinationImage:destination
                                                      sourceImages:@[ source ]
                                                       pluginState:blob
                                                            atTime:kCMTimeZero
                                                             error:&renderError];
                    if (ok) into = readback(out, width, height);
                    CFRelease(out);
                    return ok;
                };
                std::vector<float> fresh, before;
                const bool both = renderWith(state, fresh) && renderWith(legacyState, before);
                expect(both, "develops the same frame from a new block and an old one");
                expect(both && fresh == before,
                       "a project saved before the Lens group existed renders bit-identically");
                CFRelease(sourceSurface);
            }

            chooseStock(effect, host, 0);
        }

        printf("render\n");
        std::vector<float> developed;
        // A horizontal ramp through the film's whole useful range, with a little colour in it so
        // the print stage has something to say.
        void (^ramp)(int, int, float *) = ^(int x, int y, float *rgba) {
            const float t = (float)x / (float)(width - 1);
            rgba[0] = 0.02f + t * 1.6f;
            rgba[1] = 0.02f + t * 1.4f;
            rgba[2] = 0.02f + t * 1.1f;
            rgba[3] = 1.0f;
        };
        if (!develop(effect, host, width, height, ramp, &developed)) return 1;

        bool finite = true, moved = false;
        for (size_t i = 0; i < developed.size(); ++i) {
            if (!std::isfinite(developed[i])) finite = false;
        }
        for (int x = 0; x < width; ++x) {
            const float t = (float)x / (float)(width - 1);
            if (std::fabs(developed[(size_t)x * 4] - (0.02f + t * 1.6f)) > 1e-3f) moved = true;
        }
        expect(finite, "the developed frame is finite everywhere");
        expect(moved, "the film changed the picture");

        printf("time\n");
        {
            // Grain is seeded on the frame, so two times must not develop to the same picture and
            // one time must always develop to the same one. A frame number derived by rescaling
            // the time to seconds would fail the first of those for every frame of a second.
            std::vector<float> first, again, later;
            IOSurfaceRef sourceSurface = makeSurface(width, height);
            fill(sourceSurface, width, height, ramp);
            const FxRect bounds{0, 0, width, height};
            FxImageTile *source = makeTile(sourceSurface, bounds, bounds);

            NSData *state = nil;
            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];

            const CMTime times[] = {CMTimeMake(0, 30), CMTimeMake(0, 30), CMTimeMake(1, 30)};
            std::vector<float> *results[] = {&first, &again, &later};
            for (int i = 0; i < 3; ++i) {
                IOSurfaceRef out = makeSurface(width, height);
                FxImageTile *destination = makeTile(out, bounds, bounds);
                if (![effect renderDestinationImage:destination
                                       sourceImages:@[ source ]
                                        pluginState:state
                                             atTime:times[i]
                                              error:&error]) {
                    printf("  FAIL render at time %d: %s\n", i,
                           error.localizedDescription.UTF8String);
                    ++gFailures;
                }
                *results[i] = readback(out, width, height);
                CFRelease(out);
            }
            CFRelease(sourceSurface);

            bool repeatable = first.size() == again.size();
            for (size_t i = 0; i < first.size() && repeatable; ++i) {
                if (first[i] != again[i]) repeatable = false;
            }
            bool advanced = false;
            for (size_t i = 0; i < first.size() && !advanced; ++i) {
                if (first[i] != later[i]) advanced = true;
            }
            expect(repeatable, "the same frame develops identically twice");
            expect(advanced, "the next frame develops differently");
        }

        printf("uniform fields\n");
        {
            // A repository invariant: the spatial stages must be no-ops on a uniform field. Grain
            // is a per-pixel perturbation by construction, so it is the one stage turned off to
            // ask the question.
            host.values[@(kFotufilmParam_Grain)] = @0.0;
            std::vector<float> flat;
            void (^grey)(int, int, float *) = ^(int x, int y, float *rgba) {
                rgba[0] = rgba[1] = rgba[2] = 0.18f;
                rgba[3] = 1.0f;
            };
            if (!develop(effect, host, width, height, grey, &flat)) return 1;
            float low[3] = {1e9f, 1e9f, 1e9f}, high[3] = {-1e9f, -1e9f, -1e9f};
            for (size_t i = 0; i < flat.size(); i += 4) {
                for (int c = 0; c < 3; ++c) {
                    low[c] = std::fmin(low[c], flat[i + c]);
                    high[c] = std::fmax(high[c], flat[i + c]);
                }
            }
            const float spread = std::fmax(std::fmax(high[0] - low[0], high[1] - low[1]),
                                           high[2] - low[2]);
            // 16-bit float carries about three decimal digits at these levels; anything wider than
            // that is a spatial stage having reached outside a pixel it should not have.
            expect(spread < 2e-3f, "a uniform field develops uniformly");
            host.values[@(kFotufilmParam_Grain)] = @1.0;
        }

        printf("tiling\n");
        {
            // NeedsFullBuffer asks the host not to tile, but a host may anyway, and tiles
            // developed separately would not join: every spatial stage reads outside its tile.
            // The tiled path must therefore land on the same frame the whole-frame path does.
            IOSurfaceRef sourceSurface = makeSurface(width, height);
            fill(sourceSurface, width, height, ramp);
            const FxRect bounds{0, 0, width, height};
            FxImageTile *source = makeTile(sourceSurface, bounds, bounds);

            NSData *state = nil;
            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];

            std::vector<float> whole;
            if (!develop(effect, host, width, height, ramp, &whole)) return 1;

            std::vector<float> joined((size_t)width * height * 4);
            const int half = height / 2;
            bool rendered = true;
            for (int band = 0; band < 2 && rendered; ++band) {
                const int rows = band == 0 ? half : height - half;
                // FxRect y grows upward, so the first band of surface rows is the top of the
                // image: top = height, bottom = height - rows.
                const FxRect tile{0, height - (band == 0 ? rows : height), width,
                                  height - (band == 0 ? 0 : rows)};
                IOSurfaceRef bandSurface = makeSurface(width, rows);
                FxImageTile *destination = makeTile(bandSurface, bounds, tile);
                rendered = [effect renderDestinationImage:destination
                                             sourceImages:@[ source ]
                                              pluginState:state
                                                   atTime:kCMTimeZero
                                                    error:&error];
                if (!rendered) {
                    printf("  FAIL tiled render: %s\n", error.localizedDescription.UTF8String);
                    ++gFailures;
                } else {
                    std::vector<float> got = readback(bandSurface, width, rows);
                    std::memcpy(joined.data() + (size_t)(band == 0 ? 0 : half) * width * 4,
                                got.data(), got.size() * sizeof(float));
                }
                CFRelease(bandSurface);
            }
            CFRelease(sourceSurface);

            float worst = 0;
            for (size_t i = 0; i < joined.size() && rendered; ++i) {
                worst = std::fmax(worst, std::fabs(joined[i] - whole[i]));
            }
            expect(rendered && worst == 0.0f,
                   "a tiled render joins into exactly the whole-frame render");
        }

        printf("geometry\n");
        {
            // A host is free to back a 1920x1080 image with a surface padded out to some
            // alignment, and the padding is not picture. Taking the frame size from the surface
            // rather than from the image bounds develops the padding as if it were the edge of
            // the frame: the wrong width, the wrong enlargement, grain on the wrong scale.
            const int pad = 64;
            std::vector<float> tight;
            void (^ramp)(int, int, float *) = ^(int x, int y, float *rgba) {
                const float t = (float)x / (float)(width - 1);
                rgba[0] = 0.02f + t * 1.6f;
                rgba[1] = 0.02f + t * 1.4f;
                rgba[2] = 0.02f + t * 1.1f;
                rgba[3] = 1.0f;
            };
            if (!develop(effect, host, width, height, ramp, &tight)) return 1;

            IOSurfaceRef wide = makeSurface(width + pad, height + pad / 2);
            // Picture in the top-left corner, and something loud everywhere else: a read that
            // walks the surface's width instead of the image's cannot come out the same.
            fill(wide, width + pad, height + pad / 2, ^(int x, int y, float *rgba) {
                if (x < width && y < height) { ramp(x, y, rgba); return; }
                rgba[0] = 9.0f; rgba[1] = -3.0f; rgba[2] = 6.0f; rgba[3] = 0.0f;
            });
            IOSurfaceRef into = makeSurface(width + pad, height + pad / 2);
            const FxRect bounds{0, 0, width, height};
            FxImageTile *source = makeTile(wide, bounds, bounds);
            FxImageTile *destination = makeTile(into, bounds, bounds);

            NSError *error = nil;
            NSData *state = nil;
            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];
            bool rendered = [effect renderDestinationImage:destination
                                              sourceImages:@[ source ]
                                               pluginState:state
                                                    atTime:kCMTimeZero
                                                     error:&error];
            if (!rendered) {
                printf("  FAIL render into a padded surface: %s\n",
                       error.localizedDescription.UTF8String);
                ++gFailures;
            }
            std::vector<float> padded = readback(into, width, height);
            expect(rendered && padded == tight,
                   "a surface larger than its image bounds develops the image, not the surface");
            CFRelease(wide);
            CFRelease(into);

            // The other way round: a surface smaller than the bounds it claims to hold. Writing
            // the frame into it would run off the end of it.
            IOSurfaceRef cramped = makeSurface(width / 2, height / 2);
            IOSurfaceRef whole = makeSurface(width, height);
            fill(whole, width, height, ramp);
            FxImageTile *good = makeTile(whole, bounds, bounds);
            FxImageTile *tooSmall = makeTile(cramped, bounds, bounds);
            error = nil;
            expect(![effect renderDestinationImage:tooSmall
                                      sourceImages:@[ good ]
                                       pluginState:state
                                            atTime:kCMTimeZero
                                             error:&error] &&
                       [error.domain isEqualToString:FxPlugErrorDomain],
                   "a destination surface smaller than its bounds is refused, not written over");
            expect([error.localizedDescription containsString:@"but its bounds ask for"],
                   "the refusal says what it was given and what it was asked for");

            // And a destination whose bounds are honestly smaller than the frame being written:
            // the surface fits its own bounds, so only the whole-frame write's own check catches
            // it.
            const FxRect halfBounds{0, 0, width / 2, height / 2};
            FxImageTile *honestlySmall = makeTile(cramped, halfBounds, halfBounds);
            error = nil;
            expect(![effect renderDestinationImage:honestlySmall
                                      sourceImages:@[ good ]
                                       pluginState:state
                                            atTime:kCMTimeZero
                                             error:&error] &&
                       [error.localizedDescription containsString:@"but the frame is"],
                   "a destination smaller than the frame is refused before the frame is written");
            CFRelease(cramped);
            CFRelease(whole);
        }

        printf("render state\n");
        {
            // A state blob written by another build of the plugin. Final Cut can hold two at once
            // — an update installed while it is running — and the blob is memcpy'd, so the older
            // one is a different length as well as a different shape: the Lens group appended
            // eight slots to the parameter block. Checking the length first would answer "cannot
            // read", which names nothing the user can do; the version is at a fixed offset and
            // is what actually happened.
            NSError *error = nil;
            NSData *good = nil;
            expect([effect pluginState:&good atTime:kCMTimeZero quality:2 error:&error],
                   "this build writes a state blob");

            IOSurfaceRef sourceSurface = makeSurface(width, height);
            IOSurfaceRef destinationSurface = makeSurface(width, height);
            fill(sourceSurface, width, height, ^(int x, int y, float *rgba) {
                rgba[0] = rgba[1] = rgba[2] = 0.18f;
                rgba[3] = 1.0f;
            });
            const FxRect stateBounds{0, 0, width, height};
            FxImageTile *stateSource = makeTile(sourceSurface, stateBounds, stateBounds);
            FxImageTile *stateDestination =
                makeTile(destinationSurface, stateBounds, stateBounds);

            // Version 1's blob: the same struct without the eight Lens slots.
            NSMutableData *version1 =
                [NSMutableData dataWithLength:sizeof(FotufilmState) - 8 * sizeof(float)];
            const uint32_t one = 1;
            [version1 replaceBytesInRange:NSMakeRange(0, sizeof(one)) withBytes:&one];
            error = nil;
            expect(![effect renderDestinationImage:stateDestination
                                      sourceImages:@[ stateSource ]
                                       pluginState:version1
                                            atTime:kCMTimeZero
                                             error:&error],
                   "a state blob from an older build is refused");
            expect([error.localizedDescription containsString:@"from another build"] &&
                       [error.localizedDescription containsString:@"restart Final Cut Pro"],
                   "and is refused for the reason the user can act on, not its length");

            // Shorter than the version field itself: nothing to read, and the length message is
            // the honest one.
            NSMutableData *truncated = [NSMutableData dataWithLength:2];
            error = nil;
            expect(![effect renderDestinationImage:stateDestination
                                      sourceImages:@[ stateSource ]
                                       pluginState:truncated
                                            atTime:kCMTimeZero
                                             error:&error] &&
                       [error.localizedDescription containsString:@"cannot read"],
                   "a blob too short to carry a version is refused as unreadable");

            error = nil;
            expect([effect renderDestinationImage:stateDestination
                                     sourceImages:@[ stateSource ]
                                      pluginState:good
                                           atTime:kCMTimeZero
                                            error:&error],
                   "and this build's own state still renders");
            CFRelease(sourceSurface);
            CFRelease(destinationSurface);
        }

        printf("content hash\n");
        {
            // The tiled path develops the whole frame once and cuts tiles from it, keyed on the
            // state, the time and the bounds. None of those move when the clip under a static
            // grade does, so without the pixels in the key the first frame's tiles are served for
            // every frame after it.
            const FxRect bounds{0, 0, width, height};
            const FxRect band{0, height / 2, width, height};

            NSError *error = nil;
            NSData *state = nil;
            [effect pluginState:&state atTime:kCMTimeZero quality:2 error:&error];

            std::vector<float> first, second;
            bool rendered = true;
            for (int pass = 0; pass < 2 && rendered; ++pass) {
                IOSurfaceRef sourceSurface = makeSurface(width, height);
                const float bias = pass == 0 ? 0.0f : 0.35f;
                fill(sourceSurface, width, height, ^(int x, int y, float *rgba) {
                    const float t = (float)x / (float)(width - 1);
                    rgba[0] = 0.02f + bias + t * 1.6f;
                    rgba[1] = 0.02f + bias + t * 1.4f;
                    rgba[2] = 0.02f + bias + t * 1.1f;
                    rgba[3] = 1.0f;
                });
                IOSurfaceRef bandSurface = makeSurface(width, height / 2);
                FxImageTile *source = makeTile(sourceSurface, bounds, bounds);
                FxImageTile *destination = makeTile(bandSurface, bounds, band);
                rendered = [effect renderDestinationImage:destination
                                             sourceImages:@[ source ]
                                              pluginState:state
                                                   atTime:kCMTimeZero
                                                    error:&error];
                if (rendered) {
                    (pass == 0 ? first : second) = readback(bandSurface, width, height / 2);
                }
                CFRelease(sourceSurface);
                CFRelease(bandSurface);
            }
            expect(rendered && first != second,
                   "the same state at the same time over different pixels develops differently");

            // What the key costs and what it is worth. The cheap half of it — the state block,
            // the frame time, the bounds and the primaries — is compared first, and the picture
            // is read only where it can still change the answer. So a band pays for exactly one
            // whole-frame hash and never two, a band whose develop the engine refuses pays for
            // none at all, and a surface rewritten by something that is not this CPU is still
            // caught: IOSurface's seed counts lock/unlock pairs and would not have noticed.
            {
                IOSurfaceRef held = makeSurface(width, height);
                fill(held, width, height, ^(int x, int y, float *rgba) {
                    rgba[0] = 0.05f + 0.9f * (float)x / (float)(width - 1);
                    rgba[1] = 0.05f + 0.7f * (float)x / (float)(width - 1);
                    rgba[2] = 0.05f + 0.5f * (float)x / (float)(width - 1);
                    rgba[3] = 1.0f;
                });
                const FxRect top{0, height / 2, width, height};
                const FxRect bottom{0, 0, width, height / 2};
                IOSurfaceRef topSurface = makeSurface(width, height / 2);
                IOSurfaceRef bottomSurface = makeSurface(width, height / 2);
                FxImageTile *heldSource = makeTile(held, bounds, bounds);

                const uint32_t before = FotufilmTestContentHashCount();
                NSError *tileError = nil;
                const BOOL firstTile =
                    [effect renderDestinationImage:makeTile(topSurface, bounds, top)
                                      sourceImages:@[ heldSource ]
                                       pluginState:state
                                            atTime:kCMTimeZero
                                             error:&tileError];
                const uint32_t afterFirst = FotufilmTestContentHashCount();
                std::vector<float> firstBand = readback(topSurface, width, height / 2);
                const BOOL secondTile =
                    [effect renderDestinationImage:makeTile(bottomSurface, bounds, bottom)
                                      sourceImages:@[ heldSource ]
                                       pluginState:state
                                            atTime:kCMTimeZero
                                             error:&tileError];
                const uint32_t afterSecond = FotufilmTestContentHashCount();
                expect(firstTile && secondTile, "serves two bands of one frame");
                expect(afterFirst == before + 1,
                       "the first band of a frame reads the picture once");
                expect(afterSecond == afterFirst + 1,
                       "and the second reads it once, never twice");

                // The pixels changed without IOSurface's lock, which is what a write by anything
                // but this CPU looks like: `IOSurfaceRef.h` bumps the seed on the unlock of a
                // write lock and says nothing about a GPU. The same state at the same time over a
                // pooled surface a Metal stage rewrote is the case a seed pre-key cannot see, and
                // it would serve the band it developed before the write.
                fillWithoutLocking(held, width, height, ^(int x, int y, float *rgba) {
                    rgba[0] = 0.9f - 0.7f * (float)x / (float)(width - 1);
                    rgba[1] = 0.8f - 0.6f * (float)x / (float)(width - 1);
                    rgba[2] = 0.7f - 0.5f * (float)x / (float)(width - 1);
                    rgba[3] = 1.0f;
                });
                const BOOL rewrittenTile =
                    [effect renderDestinationImage:makeTile(topSurface, bounds, top)
                                      sourceImages:@[ heldSource ]
                                       pluginState:state
                                            atTime:kCMTimeZero
                                             error:&tileError];
                std::vector<float> afterRewrite = readback(topSurface, width, height / 2);
                expect(rewrittenTile && afterRewrite != firstBand,
                       "a surface rewritten without IOSurface's lock is noticed, not served from "
                       "the cache");
                expect(FotufilmTestContentHashCount() == afterSecond + 1,
                       "and cost one read of the picture to notice it");

                // A band the engine refuses. Negative Only with a filter fitted is the pair with
                // no compiled kernel — the reason the inspector dims the filters outside Full —
                // and it arrives at a frame time nothing is cached against. The cheap half of the
                // key has already said "not this frame", so the picture is never read: a hash
                // taken in front of the render would have been spent on an answer that was
                // already settled.
                FotufilmState refused{};
                [state getBytes:&refused length:sizeof(refused)];
                refused.parameters[FOTUFILM_BRIDGE_STAGE] = (float)FOTUFILM_BRIDGE_STAGE_NEGATIVE;
                refused.parameters[FOTUFILM_BRIDGE_LENS_FILTER_1] = (float)filterMenuIndex("w25");
                const uint32_t beforeRefusal = FotufilmTestContentHashCount();
                NSError *refusalError = nil;
                expect(![effect renderDestinationImage:makeTile(topSurface, bounds, top)
                                          sourceImages:@[ heldSource ]
                                           pluginState:[NSData dataWithBytes:&refused
                                                                      length:sizeof(refused)]
                                                atTime:CMTimeMake(11, 30)
                                                 error:&refusalError],
                       "a band the engine will not develop is refused");
                expect(FotufilmTestContentHashCount() == beforeRefusal,
                       "and is refused without reading the picture at all");

                printf("  note  a tiled frame reads its source once per band, and not at all "
                       "for a band whose frame time already missed the key\n");
                CFRelease(held);
                CFRelease(topSurface);
                CFRelease(bottomSurface);
            }

            // What that costs. The hash is the one thing added to every tiled frame, so its price
            // is worth knowing at the size a delivery actually runs at.
            const int uhdWidth = 3840;
            const int uhdHeight = 2160;
            IOSurfaceRef uhd = makeSurface(uhdWidth, uhdHeight);
            fill(uhd, uhdWidth, uhdHeight, ^(int x, int y, float *rgba) {
                rgba[0] = (float)x / (float)uhdWidth;
                rgba[1] = (float)y / (float)uhdHeight;
                rgba[2] = 0.5f;
                rgba[3] = 1.0f;
            });
            const uint64_t once = FotufilmContentHash(uhd, uhdWidth, uhdHeight);
            expect(once == FotufilmContentHash(uhd, uhdWidth, uhdHeight),
                   "the same pixels hash to the same value");
            double best = 1e9;
            for (int i = 0; i < 5; ++i) {
                const auto started = std::chrono::steady_clock::now();
                const uint64_t hashed = FotufilmContentHash(uhd, uhdWidth, uhdHeight);
                const double milliseconds =
                    std::chrono::duration<double, std::milli>(
                        std::chrono::steady_clock::now() - started).count();
                if (hashed != once) {
                    printf("  FAIL the hash is not repeatable\n");
                    ++gFailures;
                }
                best = std::fmin(best, milliseconds);
            }
            const double bytes = (double)uhdWidth * uhdHeight * 8;
            printf("  note  the content hash costs %.2f ms on a %dx%d half-float frame "
                   "(%.1f GB/s)\n", best, uhdWidth, uhdHeight,
                   bytes / (best * 1e-3) / 1e9);

            // One changed pixel out of eight million has to change it, or a cut that only moves
            // part of the frame keeps the frame before it.
            IOSurfaceLock(uhd, 0, nullptr);
            uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(uhd);
            base[(size_t)IOSurfaceGetBytesPerRow(uhd) * (uhdHeight - 1)] ^= 0x01;
            IOSurfaceUnlock(uhd, 0, nullptr);
            expect(FotufilmContentHash(uhd, uhdWidth, uhdHeight) != once,
                   "one flipped bit in the last row changes the hash");
            CFRelease(uhd);
        }

        printf("\n%s (%d failure%s)\n", gFailures ? "FAILED" : "passed", gFailures,
               gFailures == 1 ? "" : "s");
        return gFailures ? 1 : 0;
    }
}
