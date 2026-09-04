// FxPlug 4 adapter for the shared film engine.
// FxPlug parameter APIs are unavailable during rendering, so the state callback copies every
// required value into `FotufilmState`. Spatial stages require full-frame context; the plugin
// requests full buffers and uses a one-frame cache when a host still renders in tiles.

#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

// The shipping build takes the SDK. `finalcut/tests` builds the same source against a stand-in so
// that the engine-facing half can be run on a machine without it; see FxPlugStub.h for what that
// does and does not prove.
#if defined(FOTUFILM_FXPLUG_STUB)
#import "FxPlugStub.h"
#else
#import <FxPlug/FxPlugSDK.h>
#endif

#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <string>
#include <vector>

#include <dlfcn.h>

#include "FotufilmEffect.h"

// MARK: - errors

/// Every error the plugin hands back is in `FxPlugErrorDomain`, as the SDK asks, with one of the
/// SDK's own codes where one fits and one of these where none does. They sit above
/// `kFxError_ThirdPartyDeveloperStart`, which is the block the SDK reserves for that.
enum : NSInteger {
    /// The engine could not be started — no licence, no stocks, no Metal device.
    kFotufilmError_Engine = kFxError_ThirdPartyDeveloperStart + 1,
    /// The engine refused or failed a frame it was given.
    kFotufilmError_Render = kFxError_ThirdPartyDeveloperStart + 2,
    /// An image the plugin cannot read from or write into.
    kFotufilmError_Surface = kFxError_ThirdPartyDeveloperStart + 3,
    /// A colour space that has to be named and was not.
    kFotufilmError_ColourSpace = kFxError_ThirdPartyDeveloperStart + 4,
};

static NSError *FotufilmError(NSInteger code, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

static NSError *FotufilmError(NSInteger code, NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    return [NSError errorWithDomain:FxPlugErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

/// The engine's own account of what went wrong, or a stand-in when it has nothing to say. A null
/// context is legal and asks for the initialisation error.
static NSString *FotufilmBridgeError(FotufilmBridgeContext context) {
    char message[512] = "";
    fotufilm_bridge_last_error(context, message, sizeof(message));
    return message[0] ? @(message) : @"the engine reported no reason";
}

// MARK: - the engine, once per process

/// One initialisation, one set of menus, for every effect instance in this process.
///
/// `fotufilm_bridge_initialize` mutates the environment — it sets `FOTUFILM_RESOURCES` and
/// `FOTUFILM_STOCKS`, and opens the sealed stock packs — so it must not run twice *successfully*;
/// but it may run again after a failure, and it has to. The one failure a user meets is the Mac
/// app not yet activated, which they fix with Final Cut still open; a failure latched for the
/// life of the XPC process would make them quit and relaunch to find out it worked. So the
/// object is made once and the start is retried, throttled, on each use until it succeeds. The
/// bridge re-reads the licence on every call, so the retry sees the activation.
@interface FotufilmEngine : NSObject
@property(class, readonly) FotufilmEngine *shared;

@property(readonly) BOOL ready;
@property(readonly, copy) NSString *failure;

@property(readonly) NSArray<NSString *> *stockLabels;
@property(readonly) NSArray<NSString *> *stockIDs;
@property(readonly) NSArray<NSString *> *formatLabels;
@property(readonly) NSArray<NSString *> *formatIDs;
@property(readonly) NSArray<NSString *> *paperLabels;
@property(readonly) NSArray<NSString *> *paperIDs;
@property(readonly) NSArray<NSString *> *stageLabels;
@property(readonly) NSArray<NSString *> *stageIDs;
@property(readonly) NSArray<NSString *> *textureLabels;
@property(readonly) NSArray<NSString *> *textureIDs;
@property(readonly) NSArray<NSNumber *> *textureMasks;
/// The lens. The filter and diffusion menus open with a "None" this side owns, so it is pushed
/// onto the front of both their label and id lists: a menu index and a list index are then the
/// same number, and the identity written for one choice cannot name another.
@property(readonly) NSArray<NSString *> *lensFilterLabels;
@property(readonly) NSArray<NSString *> *lensFilterIDs;
@property(readonly) NSArray<NSString *> *meteringLabels;
@property(readonly) NSArray<NSString *> *diffusionLabels;
@property(readonly) NSArray<NSString *> *diffusionIDs;
@property(readonly) NSArray<NSString *> *diffusionGradeLabels;
@property(readonly) NSArray<NSString *> *negativeViewingLabels;
/// The grade the engine's command line takes when none is named, so the menu opens where the
/// engine's own default is rather than where its list happens to start.
@property(readonly) NSInteger defaultDiffusionGrade;

/// The index "Match Film" sits at in the gauge menu: one past the engine's own presets. Passing
/// it to the bridge as `format` is how the plugin says "the gauge this stock is known on".
@property(readonly) NSInteger matchFilmFormat;
@property(readonly) NSInteger matchFilmOutput;
@end

@implementation FotufilmEngine {
    /// Guards the start. Every reader comes through `+shared`, which takes this lock before
    /// handing the object back, so a reader on any thread sees the arrays a start on another
    /// thread published before it released the lock.
    NSLock *_lock;
    BOOL _attempted;
    CFAbsoluteTime _lastAttempt;
    /// `fotufilm_bridge_initialize` has returned successfully, once, and must not be called
    /// again. It is the half of the start that touches process-wide state — it sets
    /// `FOTUFILM_RESOURCES` and opens the sealed stock packs — and the failures the retry exists
    /// for do not live in it: the licence is read inside it, so an inactive licence fails it and
    /// leaves this NO, while a missing Metal device, an empty pack or a texture-stage overflow
    /// all happen *after* it and leave it YES. Without this the retry timer reloaded the stock
    /// registry every few seconds for the whole session on any of the three.
    BOOL _initialized;
    /// Where the packs were opened from, kept for the messages the checks below write.
    NSString *_resources;
}

#if defined(FOTUFILM_FXPLUG_STUB)
/// How many times the bridge's own initialise has been called. Stub-only: the point of the
/// latch is a call that does not happen, and nothing else can see that.
uint32_t FotufilmTestBridgeInitializeCount = 0;
#endif

+ (FotufilmEngine *)shared {
    static FotufilmEngine *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[FotufilmEngine alloc] init]; });
    [shared startIfNeeded];
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _lock = [[NSLock alloc] init];
    _stockLabels = @[]; _stockIDs = @[];
    _formatLabels = @[]; _formatIDs = @[];
    _paperLabels = @[]; _paperIDs = @[];
    _stageLabels = @[]; _stageIDs = @[];
    _textureLabels = @[]; _textureIDs = @[]; _textureMasks = @[];
    _lensFilterLabels = @[]; _lensFilterIDs = @[];
    _meteringLabels = @[];
    _diffusionLabels = @[]; _diffusionIDs = @[]; _diffusionGradeLabels = @[];
    _negativeViewingLabels = @[];
    _failure = @"the engine has not been started";
    return self;
}

/// Reads one NUL-terminated id or label out of the bridge. The bridge returns a length, not a
/// terminator count, so the string is built from it.
static NSString *FotufilmBridgeString(int32_t (*read)(int32_t, char *, int32_t), int32_t index) {
    char buffer[256];
    const int32_t length = read(index, buffer, (int32_t)sizeof(buffer));
    if (length < 0) return @"";
    return [[NSString alloc] initWithBytes:buffer length:(NSUInteger)length
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

- (void)startIfNeeded {
    [_lock lock];
    if (!_ready) {
        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!_attempted || now - _lastAttempt >= (CFAbsoluteTime)kFotufilmEngineRetrySeconds) {
            _attempted = YES;
            _lastAttempt = now;
            [self start];
        }
    }
    [_lock unlock];
}

/// One attempt. Called with the lock held; leaves `ready` set, or `failure` saying why not.
- (void)start {
#if defined(FOTUFILM_FXPLUG_STUB)
    // The harness's way of making an attempt fail before the bridge is touched at all. A licence
    // that is really inactive cannot be arranged in-process on a Mac that holds a certificate,
    // and the retry is what is under test.
    if (const char *injected = getenv("FOTUFILM_TEST_ENGINE_FAILURE")) {
        if (*injected) {
            _failure = @(injected);
            return;
        }
    }
#endif

    if (!_initialized) {
        // The resources sit beside the executable in the extension bundle:
        // .../Contents/MacOS/<exe> strips to .../Contents, and Resources hangs off that.
        // `bundleForClass:` is the direct way to the same place and is used first; dladdr is the
        // fallback for a build that ends up somewhere NSBundle cannot name.
        NSString *resources = [NSBundle bundleForClass:[self class]].resourcePath;
        if (resources.length == 0) {
            Dl_info info;
            if (dladdr((const void *)&FotufilmBridgeString, &info) != 0 && info.dli_fname) {
                NSString *path = @(info.dli_fname);
                for (int i = 0; i < 2; ++i) path = path.stringByDeletingLastPathComponent;
                resources = [path stringByAppendingPathComponent:@"Resources"];
            }
        }

#if defined(FOTUFILM_FXPLUG_STUB)
        ++FotufilmTestBridgeInitializeCount;
#endif
        const int32_t stocks =
            fotufilm_bridge_initialize(resources.length ? resources.UTF8String : NULL);
        if (stocks < 0) {
            // The bridge's own words first: for an inactive licence that is the sentence that
            // tells the user what to do, and burying it under a path would not help.
            _failure = FotufilmBridgeError(NULL);
            return;
        }
        _initialized = YES;
        _resources = resources;
    }
    NSString *resources = _resources;

#if defined(FOTUFILM_FXPLUG_STUB)
    // A failure of the other kind: everything the bridge does is done, and one of the checks
    // below refuses anyway. No Metal device, an empty pack and a texture-stage overflow all land
    // here, and none of them is a reason to open the stock packs again.
    if (const char *injected = getenv("FOTUFILM_TEST_ENGINE_POST_FAILURE")) {
        if (*injected) {
            _failure = @(injected);
            return;
        }
    }
#endif

    NSMutableArray<NSString *> *stockLabels = [NSMutableArray array];
    NSMutableArray<NSString *> *stockIDs = [NSMutableArray array];
    for (int32_t i = 0; i < fotufilm_bridge_stock_count(); ++i) {
        [stockLabels addObject:FotufilmBridgeString(fotufilm_bridge_stock_name, i)];
        [stockIDs addObject:FotufilmBridgeString(fotufilm_bridge_stock_id, i)];
    }
    NSMutableArray<NSString *> *formatLabels = [NSMutableArray array];
    NSMutableArray<NSString *> *formatIDs = [NSMutableArray array];
    for (int32_t i = 0; i < fotufilm_bridge_format_count(); ++i) {
        [formatLabels addObject:FotufilmBridgeString(fotufilm_bridge_format_name, i)];
        [formatIDs addObject:FotufilmBridgeString(fotufilm_bridge_format_id, i)];
    }
    // The menu appends Match Film after the engine's gauges, so the id list has to agree with it
    // entry for entry — or the identity written for one choice names another.
    const NSInteger matchFilmFormat = (NSInteger)formatLabels.count;
    [formatLabels addObject:@"Match Film"];
    [formatIDs addObject:@kFotufilmMatchFilmFormatID];

    NSMutableArray<NSString *> *paperLabels = [NSMutableArray array];
    NSMutableArray<NSString *> *paperIDs = [NSMutableArray array];
    for (int32_t i = 0; i < fotufilm_bridge_paper_count(); ++i) {
        [paperLabels addObject:FotufilmBridgeString(fotufilm_bridge_paper_name, i)];
        [paperIDs addObject:FotufilmBridgeString(fotufilm_bridge_paper_id, i)];
    }
    const NSInteger matchFilmOutput = (NSInteger)paperLabels.count;
    [paperLabels addObject:@"Match Film"];
    [paperIDs addObject:@kFotufilmMatchFilmPaperID];
    NSMutableArray<NSString *> *stageLabels = [NSMutableArray array];
    NSMutableArray<NSString *> *stageIDs = [NSMutableArray array];
    for (int32_t i = 0; i < fotufilm_bridge_stage_count(); ++i) {
        [stageLabels addObject:FotufilmBridgeString(fotufilm_bridge_stage_name, i)];
        [stageIDs addObject:FotufilmBridgeString(fotufilm_bridge_stage_id, i)];
    }
    NSMutableArray<NSString *> *textureLabels = [NSMutableArray array];
    NSMutableArray<NSString *> *textureIDs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *textureMasks = [NSMutableArray array];
    for (int32_t i = 0; i < fotufilm_bridge_texture_stage_count(); ++i) {
        [textureLabels addObject:FotufilmBridgeString(fotufilm_bridge_texture_stage_name, i)];
        [textureIDs addObject:FotufilmBridgeString(fotufilm_bridge_texture_stage_id, i)];
        [textureMasks addObject:@(fotufilm_bridge_texture_stage_mask(i))];
    }

    // The lens, with the plugin's own "None" on the front of the two menus that need one.
    NSMutableArray<NSString *> *lensFilterLabels = [NSMutableArray arrayWithObject:@"None"];
    NSMutableArray<NSString *> *lensFilterIDs =
        [NSMutableArray arrayWithObject:@kFotufilmNoFilterID];
    for (int32_t i = 0; i < fotufilm_bridge_lens_filter_count(); ++i) {
        [lensFilterLabels addObject:FotufilmBridgeString(fotufilm_bridge_lens_filter_name, i)];
        [lensFilterIDs addObject:FotufilmBridgeString(fotufilm_bridge_lens_filter_id, i)];
    }
    NSMutableArray<NSString *> *meteringLabels = [NSMutableArray array];
    for (int32_t i = 0; i < fotufilm_bridge_metering_count(); ++i) {
        [meteringLabels addObject:FotufilmBridgeString(fotufilm_bridge_metering_name, i)];
    }
    NSMutableArray<NSString *> *diffusionLabels = [NSMutableArray arrayWithObject:@"None"];
    NSMutableArray<NSString *> *diffusionIDs =
        [NSMutableArray arrayWithObject:@kFotufilmNoFilterID];
    for (int32_t i = 0; i < fotufilm_bridge_diffusion_family_count(); ++i) {
        [diffusionLabels addObject:FotufilmBridgeString(fotufilm_bridge_diffusion_family_name, i)];
        [diffusionIDs addObject:FotufilmBridgeString(fotufilm_bridge_diffusion_family_id, i)];
    }
    NSMutableArray<NSString *> *gradeLabels = [NSMutableArray array];
    for (int32_t i = 0; i < fotufilm_bridge_diffusion_grade_count(); ++i) {
        [gradeLabels addObject:FotufilmBridgeString(fotufilm_bridge_diffusion_grade_name, i)];
    }
    NSMutableArray<NSString *> *viewingLabels = [NSMutableArray array];
    for (int32_t i = 0; i < fotufilm_bridge_negative_viewing_count(); ++i) {
        [viewingLabels addObject:FotufilmBridgeString(fotufilm_bridge_negative_viewing_name, i)];
    }

    if (fotufilm_bridge_available() == 0) {
        _failure = @"no Metal device the Halide engine can use";
        return;
    }
    if (stockLabels.count == 0) {
        _failure = [NSString stringWithFormat:@"no film stocks found in %@", resources];
        return;
    }
    if (textureLabels.count > (NSUInteger)(kFotufilmParam_TextureStageLimit -
                                           kFotufilmParam_TextureStageFirst)) {
        // Reject overflow instead of creating stages without corresponding controls.
        _failure = @"more texture stages than the reserved parameter id block holds";
        return;
    }

    _stockLabels = stockLabels; _stockIDs = stockIDs;
    _formatLabels = formatLabels; _formatIDs = formatIDs;
    _paperLabels = paperLabels; _paperIDs = paperIDs;
    _stageLabels = stageLabels; _stageIDs = stageIDs;
    _textureLabels = textureLabels; _textureIDs = textureIDs; _textureMasks = textureMasks;
    _lensFilterLabels = lensFilterLabels; _lensFilterIDs = lensFilterIDs;
    _meteringLabels = meteringLabels;
    _diffusionLabels = diffusionLabels; _diffusionIDs = diffusionIDs;
    _diffusionGradeLabels = gradeLabels;
    _negativeViewingLabels = viewingLabels;
    _defaultDiffusionGrade = (NSInteger)fotufilm_bridge_diffusion_default_grade();
    _matchFilmFormat = matchFilmFormat;
    _matchFilmOutput = matchFilmOutput;
    _failure = nil;
    _ready = YES;
}

/// The index a persisted id names, or `fallback` when the id is empty (a project saved before the
/// id existed) or names something this install does not have.
- (NSInteger)indexForID:(NSString *)identity
                     in:(NSArray<NSString *> *)ids
               fallback:(NSInteger)fallback {
    if (identity.length == 0) return fallback;
    const NSUInteger found = [ids indexOfObject:identity];
    return found == NSNotFound ? fallback : (NSInteger)found;
}
@end

// MARK: - surfaces

namespace {

/// One image tile as tightly packed interleaved RGBA float32, top row of the surface first.
///
/// Row order is deliberately not normalised. The same mapping is used reading the source and
/// writing the destination, so whatever the surface's first row means, it means the same on both
/// sides and cancels; and no stage in the engine is orientation-dependent — grain is isotropic,
/// halation is an annulus, the enlarger's MTF is separable and symmetric, and the glare term is a
/// whole-frame mean.
///
/// The size is the *bounds'*, not the surface's. A host may back a 1920×1080 image with a surface
/// padded out to some alignment, and the padding is not picture: developing it would put the
/// frame's edge in the wrong place and its grain on the wrong scale. Rows are walked at the
/// surface's own stride, and `originX`/`originY` say where the wanted pixels start in it.
struct Surface {
    IOSurfaceRef surface = nullptr;
    int width = 0;
    int height = 0;
    int originX = 0;
    int originY = 0;
    OSType format = 0;
    /// Empty when the surface can be used; otherwise why not, in words for the error.
    std::string problem;
};

bool supported(OSType format) {
    return format == kCVPixelFormatType_64RGBAHalf ||
           format == kCVPixelFormatType_128RGBAFloat ||
           format == kCVPixelFormatType_32BGRA;
}

size_t bytesPerPixel(OSType format) {
    return format == kCVPixelFormatType_128RGBAFloat ? 16
         : format == kCVPixelFormatType_64RGBAHalf ? 8 : 4;
}

NSString *formatName(OSType format) {
    char code[5] = {(char)(format >> 24), (char)(format >> 16), (char)(format >> 8),
                    (char)format, 0};
    return [NSString stringWithFormat:@"'%s'", code];
}

/// Describes the `wanted` pixels of a tile. The surface holds the tile's own bounds, which is the
/// whole image for a source (the plugin asks for it) and for an untiled destination, and one band
/// of it for a tiled destination; `wanted` must lie inside them, and the surface must be at least
/// big enough to hold them, or the read would run off the end of it and the write over it.
Surface describe(FxImageTile *tile, FxRect wanted) {
    Surface out;
    out.surface = (__bridge IOSurfaceRef)tile.ioSurface;
    if (!out.surface) {
        out.problem = "there is no surface behind it";
        return out;
    }
    out.format = (OSType)IOSurfaceGetPixelFormat(out.surface);
    const FxRect held = tile.tilePixelBounds;
    const int width = wanted.right - wanted.left;
    const int height = wanted.top - wanted.bottom;
    if (width <= 0 || height <= 0) {
        out.problem = "its bounds are empty";
        return out;
    }
    if (wanted.left < held.left || wanted.right > held.right ||
        wanted.bottom < held.bottom || wanted.top > held.top) {
        out.problem = "the tile handed over does not cover the frame it belongs to";
        return out;
    }
    const int originX = wanted.left - held.left;
    const int originY = tile.imageOrigin == kFxImageOrigin_TOP_LEFT ? held.top - wanted.top
                                                                    : wanted.bottom - held.bottom;
    const int surfaceWidth = (int)IOSurfaceGetWidth(out.surface);
    const int surfaceHeight = (int)IOSurfaceGetHeight(out.surface);
    if (surfaceWidth < originX + width || surfaceHeight < originY + height) {
        out.problem = "its surface holds " + std::to_string(surfaceWidth) + "x" +
                      std::to_string(surfaceHeight) + " pixels but its bounds ask for " +
                      std::to_string(width) + "x" + std::to_string(height) +
                      (originX || originY ? " at an offset" : "");
        return out;
    }
    out.width = width;
    out.height = height;
    out.originX = originX;
    out.originY = originY;
    return out;
}

/// Reads a surface into `out`, which must hold `width * height * 4` floats.
void read(const Surface &surface, float *out) {
    IOSurfaceLock(surface.surface, kIOSurfaceLockReadOnly, nullptr);
    const size_t stride = IOSurfaceGetBytesPerRow(surface.surface);
    const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(surface.surface) +
                          (size_t)surface.originY * stride +
                          (size_t)surface.originX * bytesPerPixel(surface.format);
    const size_t channels = (size_t)surface.width * 4;

    if (surface.format == kCVPixelFormatType_64RGBAHalf) {
        // Interleaved RGBA halves are just 4x as many scalars, so the whole frame converts in one
        // call rather than one per channel.
        vImage_Buffer source{(void *)base, (vImagePixelCount)surface.height,
                             (vImagePixelCount)channels, stride};
        vImage_Buffer destination{out, (vImagePixelCount)surface.height,
                                  (vImagePixelCount)channels, channels * sizeof(float)};
        vImageConvert_Planar16FtoPlanarF(&source, &destination, kvImageNoFlags);
    } else if (surface.format == kCVPixelFormatType_128RGBAFloat) {
        for (int y = 0; y < surface.height; ++y) {
            std::memcpy(out + (size_t)y * channels, base + (size_t)y * stride,
                        channels * sizeof(float));
        }
    } else {
        // 8-bit BGRA. Present only when the host hands over an SDR proxy; the values are linear
        // because that is what the plugin asked to be given.
        for (int y = 0; y < surface.height; ++y) {
            const uint8_t *row = base + (size_t)y * stride;
            float *destination = out + (size_t)y * channels;
            for (int x = 0; x < surface.width; ++x) {
                destination[x * 4 + 0] = row[x * 4 + 2] * (1.0f / 255.0f);
                destination[x * 4 + 1] = row[x * 4 + 1] * (1.0f / 255.0f);
                destination[x * 4 + 2] = row[x * 4 + 0] * (1.0f / 255.0f);
                destination[x * 4 + 3] = row[x * 4 + 3] * (1.0f / 255.0f);
            }
        }
    }
    IOSurfaceUnlock(surface.surface, kIOSurfaceLockReadOnly, nullptr);
}

/// Writes `rows` rows of `width` interleaved RGBA floats into the surface, starting at row
/// `rowOffset` and column `columnOffset` of the surface's wanted region. `sourceStride` is the
/// source's own row length in pixels, which is the whole frame's width when a tile is being cut
/// out of a cached frame.
void write(const Surface &surface, const float *in, int sourceStride,
           int columnOffset, int rowOffset, int width, int rows) {
    IOSurfaceLock(surface.surface, 0, nullptr);
    const size_t stride = IOSurfaceGetBytesPerRow(surface.surface);
    const size_t pixel = bytesPerPixel(surface.format);
    uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(surface.surface) +
                    (size_t)surface.originY * stride + (size_t)surface.originX * pixel;

    for (int y = 0; y < rows; ++y) {
        const float *from = in + (size_t)y * sourceStride * 4;
        uint8_t *row = base + (size_t)(y + rowOffset) * stride + (size_t)columnOffset * pixel;
        if (surface.format == kCVPixelFormatType_64RGBAHalf) {
            vImage_Buffer source{(void *)from, 1, (vImagePixelCount)width * 4, 0};
            vImage_Buffer destination{row, 1, (vImagePixelCount)width * 4, 0};
            vImageConvert_PlanarFtoPlanar16F(&source, &destination, kvImageNoFlags);
        } else if (surface.format == kCVPixelFormatType_128RGBAFloat) {
            std::memcpy(row, from, (size_t)width * 4 * sizeof(float));
        } else {
            uint8_t *destination = row;
            for (int x = 0; x < width; ++x) {
                // The engine's output is display-linear and can sit above one; 8 bits cannot
                // carry that, so the clamp here is the format's, not the model's.
                const float r = std::fmin(std::fmax(from[x * 4 + 0], 0.0f), 1.0f);
                const float g = std::fmin(std::fmax(from[x * 4 + 1], 0.0f), 1.0f);
                const float b = std::fmin(std::fmax(from[x * 4 + 2], 0.0f), 1.0f);
                const float a = std::fmin(std::fmax(from[x * 4 + 3], 0.0f), 1.0f);
                destination[x * 4 + 0] = (uint8_t)std::lround(b * 255.0f);
                destination[x * 4 + 1] = (uint8_t)std::lround(g * 255.0f);
                destination[x * 4 + 2] = (uint8_t)std::lround(r * 255.0f);
                destination[x * 4 + 3] = (uint8_t)std::lround(a * 255.0f);
            }
        }
    }
    IOSurfaceUnlock(surface.surface, 0, nullptr);
}

/// The band a striped decode walks, in rows: a 16 MiB working set, and never less than one row.
int decodeBandRows(int width) {
    const size_t bytes = 16u << 20;
    const size_t row = (size_t)width * 4 * sizeof(float) * 2;  // in and out
    const size_t rows = row ? bytes / row : 0;
    return rows < 1 ? 1 : (int)rows;
}

// MARK: content hash

/// Four independent multiply-xorshift lanes, 32 bytes a step, so the loop is bound by memory
/// rather than by one multiplier's latency. Not cryptographic and not meant to be: it exists to
/// tell one frame from the next, and a collision costs one stale tile, not a wrong answer kept.
constexpr uint64_t kHashMultiplier[4] = {0x9E3779B97F4A7C15ull, 0xC2B2AE3D27D4EB4Full,
                                         0x165667B19E3779F9ull, 0x27D4EB2F165667C5ull};

inline void mixBlock(uint64_t *lane, const uint8_t *block) {
    uint64_t word[4];
    std::memcpy(word, block, sizeof(word));
    for (int i = 0; i < 4; ++i) {
        lane[i] = (lane[i] ^ word[i]) * kHashMultiplier[i];
        lane[i] ^= lane[i] >> 29;
    }
}

#if defined(FOTUFILM_FXPLUG_STUB)
/// How many whole-frame hashes have been taken. Stub-only: what the surface pre-key buys is a
/// hash that does *not* happen, and nothing else can see that.
uint32_t gContentHashes = 0;
#endif

uint64_t contentHash(const Surface &surface) {
#if defined(FOTUFILM_FXPLUG_STUB)
    ++gContentHashes;
#endif
    uint64_t lane[4] = {0x243F6A8885A308D3ull, 0x13198A2E03707344ull,
                        0xA4093822299F31D0ull, 0x082EFA98EC4E6C89ull};
    IOSurfaceLock(surface.surface, kIOSurfaceLockReadOnly, nullptr);
    const size_t stride = IOSurfaceGetBytesPerRow(surface.surface);
    const size_t pixel = bytesPerPixel(surface.format);
    const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(surface.surface) +
                          (size_t)surface.originY * stride + (size_t)surface.originX * pixel;
    const size_t rowBytes = (size_t)surface.width * pixel;
    for (int y = 0; y < surface.height; ++y) {
        const uint8_t *row = base + (size_t)y * stride;
        size_t i = 0;
        for (; i + 32 <= rowBytes; i += 32) mixBlock(lane, row + i);
        if (i < rowBytes) {
            uint8_t tail[32] = {0};
            std::memcpy(tail, row + i, rowBytes - i);
            mixBlock(lane, tail);
        }
    }
    IOSurfaceUnlock(surface.surface, kIOSurfaceLockReadOnly, nullptr);

    uint64_t h = lane[0];
    h = (h ^ lane[1]) * kHashMultiplier[0]; h ^= h >> 31;
    h = (h ^ lane[2]) * kHashMultiplier[1]; h ^= h >> 29;
    h = (h ^ lane[3]) * kHashMultiplier[2]; h ^= h >> 32;
    h ^= ((uint64_t)(uint32_t)surface.width << 32) | (uint64_t)(uint32_t)surface.height;
    h *= kHashMultiplier[3];
    h ^= h >> 29;
    return h;
}

}  // namespace

#if defined(FOTUFILM_FXPLUG_STUB)
uint32_t FotufilmTestContentHashCount(void) { return gContentHashes; }
#endif

uint64_t FotufilmContentHash(IOSurfaceRef surface, int width, int height) {
    Surface described;
    described.surface = surface;
    described.width = width;
    described.height = height;
    described.format = (OSType)IOSurfaceGetPixelFormat(surface);
    return contentHash(described);
}

// MARK: - colour spaces

/// The colour space menu. Its order is an ABI — the choice persists by index — so the layout is
/// frozen: the seven spaces the plugin shipped with at their original indices, "Auto (from host)"
/// at 7, and anything added since appended after Auto.
///
/// What an entry *means* is not frozen, and four of them have changed. The plugin asks for
/// `kFxImageColorInfo_RGB_LINEAR`, so Final Cut hands it linear light whatever the library's
/// transfer curve is; a choice that applied a Rec.709 or sRGB or ACEScct or DaVinci Intermediate
/// decode to light that is already linear would bend it twice. Those entries now name only their
/// primaries, decoded with a linear transfer, and their labels say so. The index a project saved
/// still names the library it was chosen for, so nothing is renumbered.

/// The encoding a menu index names, or `Count` for Auto — which only the render can resolve.
fotufilm::Encoding FotufilmMenuPrimaries(int choice) {
    if (choice >= 0 && choice < kFotufilmColorSpaceAuto) return (fotufilm::Encoding)choice;
    const int appended = choice - kFotufilmColorSpaceAuto - 1;
    if (appended >= 0 && kFotufilmColorSpaceAuto + appended < (int)fotufilm::Encoding::Count) {
        return (fotufilm::Encoding)(kFotufilmColorSpaceAuto + appended);
    }
    return fotufilm::Encoding::Count;
}

/// The encoding whose *transfer* a choice decodes with: the linear one on the same primaries.
/// The matrices still come from `transformFor` of the choice itself, so DaVinci Intermediate —
/// which has no linear twin in `fotufilm::Encoding` — keeps its Wide Gamut matrix and takes the
/// identity transfer that any linear encoding names.
static fotufilm::Encoding FotufilmLinearEncoding(fotufilm::Encoding encoding) {
    switch (encoding) {
        case fotufilm::Encoding::Rec709Gamma24:
        case fotufilm::Encoding::SRGB: return fotufilm::Encoding::LinearRec709;
        case fotufilm::Encoding::ACEScct: return fotufilm::Encoding::ACEScg;
        case fotufilm::Encoding::DaVinciIntermediate: return fotufilm::Encoding::LinearRec2020;
        default: return encoding;
    }
}

fotufilm::Encoding FotufilmMenuTransfer(int choice) {
    return FotufilmLinearEncoding(FotufilmMenuPrimaries(choice));
}

/// What a choice decodes as, for the status line.
static NSString *FotufilmDecodeName(fotufilm::Encoding encoding) {
    switch (encoding) {
        case fotufilm::Encoding::Rec709Gamma24:
        case fotufilm::Encoding::SRGB:
        case fotufilm::Encoding::LinearRec709: return @"linear Rec.709";
        case fotufilm::Encoding::DaVinciIntermediate: return @"linear DaVinci Wide Gamut";
        case fotufilm::Encoding::ACEScct:
        case fotufilm::Encoding::ACEScg: return @"linear AP1";
        case fotufilm::Encoding::LinearDisplayP3: return @"linear Display P3";
        case fotufilm::Encoding::LinearRec2020: return @"linear Rec.2020";
        case fotufilm::Encoding::Count: break;
    }
    return @"linear Rec.709";
}

/// The menu label: the primaries, and the library the entry was chosen for where that differs.
static NSString *FotufilmMenuLabel(fotufilm::Encoding encoding) {
    switch (encoding) {
        case fotufilm::Encoding::Rec709Gamma24: return @"Linear Rec.709 (Rec.709 / Gamma 2.4 library)";
        case fotufilm::Encoding::SRGB: return @"Linear Rec.709 (sRGB library)";
        case fotufilm::Encoding::DaVinciIntermediate: return @"Linear DaVinci Wide Gamut";
        case fotufilm::Encoding::ACEScct: return @"Linear AP1 (ACEScct library)";
        case fotufilm::Encoding::ACEScg: return @"Linear AP1 (ACEScg)";
        default: return @(fotufilm::encodingLabel(encoding));
    }
}

/// Which controls a film has something behind, asked of the engine rather than worked out here:
/// what a film has is the film's own data, and a second copy of that judgement would drift.
struct FotufilmGating {
    bool pushes = true;
    bool prints = true;
    std::vector<bool> offered;
    NSString *withheld = nil;
    int withheldCount = 0;
};

// MARK: - the effect

@interface FotufilmEffect : NSObject <FxTileableEffect> {
    FotufilmBridgeContext _bridge;

    /// The striped path's two frame buffers — scene light in, developed rows out — and the
    /// finished frame the tiled path serves cuts from. All three are reused across frames rather
    /// than reallocated, and all three are guarded by `lock`.
    ///
    /// The streamed rows need a buffer of their own: `fotufilm_bridge_render` hands rows back as
    /// it develops them, so it is still reading the scene buffer while they arrive.
    std::vector<float> _scene;
    std::vector<float> _output;
    std::vector<float> _developed;

    /// One-shot diagnostics, so a bad clip says its piece once rather than once per frame.
    std::atomic<bool> _warnedOverRange;
    std::atomic<bool> _warnedNonFinite;
    std::atomic<bool> _warnedUnnamedSpace;

    /// What the last Auto resolve found: a clip whose colour space had no name, read as Rec.709.
    /// The render cannot reach the status line, so it leaves this for the next refresh to report.
    std::atomic<bool> _unnamedSpace;

    /// Set while the controls are being refreshed, so a host that reports the plugin's own
    /// writes back as changes does not start the refresh over.
    BOOL _refreshing;

    /// What this instance's inspector actually holds, recorded when it was built.
    ///
    /// Final Cut builds a panel once, from whatever the engine could say at the time, and an
    /// engine that starts afterwards cannot add a control to that panel or fill in a menu on it.
    /// Both halves of that matter and neither is visible from the engine: a toggle that was never
    /// created reads back as off, and a menu index into a stand-in list names a position Final Cut
    /// never showed. So the panel's own shape is kept here, per instance, and compared with what
    /// the engine knows now.
    ///
    /// The counts are `described` in exactly the OFX plugin's sense — see `ChoiceIdentity` in
    /// `resolve/FotufilmPlugin.cpp`. A menu whose described count is short of the engine's list is
    /// a placeholder.
    NSUInteger _describedTextureStages;
    NSUInteger _describedStages;
    NSUInteger _describedFormats;
    NSUInteger _describedPapers;
    NSUInteger _describedLensFilters;
    NSUInteger _describedDiffusions;

    /// The whole-frame hash of the source the cached frame was developed from, and whether there
    /// is one. It is the last term of the tiled path's cache key and the only expensive one, so
    /// it is kept beside the key rather than inside it: the cheap terms are compared first and
    /// the pixels are only read when they can still change the answer.
    ///
    /// IOSurface's own seed is deliberately not used to skip it. `IOSurfaceRef.h` says the seed
    /// is "the internal seed value at the time of the unlock", incremented "as the unlock is
    /// performed" on a buffer that was locked for writing — it counts CPU lock/unlock pairs and
    /// says nothing about a GPU or other hardware write. A Metal stage upstream rewriting a
    /// pooled surface bumps nothing, so a surface-and-seed pre-key would hand this frame's tiles
    /// back for the next frame's pixels.
    uint64_t _cachedContent;
    BOOL _haveCachedContent;
}
@property(nonatomic, weak) id<PROAPIAccessing> apiManager;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSData *cacheKey;
@end

@implementation FotufilmEffect

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
    self = [super init];
    if (!self) return nil;
    _apiManager = apiManager;
    _lock = [[NSLock alloc] init];
    _bridge = fotufilm_bridge_context_create();
    _warnedOverRange = false;
    _warnedNonFinite = false;
    _warnedUnnamedSpace = false;
    _unnamedSpace = false;
    _refreshing = NO;
    _haveCachedContent = NO;
    return self;
}

- (void)dealloc {
    if (_bridge) fotufilm_bridge_context_destroy(_bridge);
}

// MARK: properties

- (BOOL)properties:(NSDictionary *_Nonnull *_Nullable)properties error:(NSError **)error {
    if (!properties) {
        if (error) *error = FotufilmError(kFxError_InvalidParameter,
                                          @"Fotufilm was asked for its properties with nowhere "
                                           "to put them");
        return NO;
    }
    *properties = @{
        // The model is scene-referred: mid-grey is 0.18 and a specular highlight is a number
        // above one. Asking for linear is the one request that is not taste — handed the
        // project's transfer curve instead, the film would meet the wrong light. The primaries
        // still follow the library's gamut, which is what the colour space control resolves.
        kFxPropertyKey_DesiredProcessingColorInfo : @(kFxImageColorInfo_RGB_LINEAR),

        // Every spatial stage reads outside its own pixel — grain clumps, halation spreads over
        // millimetres of film, the enlarger's MTF is a kernel, and veiling glare is a mean over
        // the whole frame. A tile is not enough information to develop, so ask not to be tiled.
        kFxPropertyKey_NeedsFullBuffer : @YES,

        // The output frame is the input frame, at the input's size and position.
        kFxPropertyKey_ChangesOutputSize : @NO,

        // Grain is seeded on the frame number, so two frames of a frozen image are not the same
        // frame. Saying otherwise would let the host cache one and show it for the whole clip.
        kFxPropertyKey_VariesWhenParamsAreStatic : @YES,

        // One frame in, the same frame out: the plugin never samples its input at any time but
        // the one it is rendering. The SDK's default is YES, which makes the host keep more of
        // the clip around than this needs.
        kFxPropertyKey_MayRemapTime : @NO,

        kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    };
    return YES;
}

// MARK: parameters

- (id<FxParameterCreationAPI_v5>)creationAPI {
    return [_apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
}

- (id<FxParameterRetrievalAPI_v6>)retrievalAPI {
    return [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
}

- (id<FxParameterSettingAPI_v5>)settingAPI {
    return [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
}

- (id<FxCustomParameterActionAPI_v4>)actionAPI {
    return [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
}

/// Asks the engine what `stock` has behind each gated control. An engine that is not ready
/// gates nothing: the stand-in menus have nothing to say about any film.
- (FotufilmGating)gatingForStock:(NSInteger)stock {
    FotufilmGating gating;
    FotufilmEngine *engine = FotufilmEngine.shared;
    if (!engine.ready || stock < 0 || stock >= (NSInteger)engine.stockIDs.count) {
        gating.offered.assign(engine.textureLabels.count, true);
        return gating;
    }
    gating.pushes = fotufilm_bridge_stock_pushes((int32_t)stock) != 0;
    gating.prints = fotufilm_bridge_stock_prints((int32_t)stock) != 0;
    NSMutableArray<NSString *> *withheld = [NSMutableArray array];
    for (NSUInteger i = 0; i < engine.textureLabels.count; ++i) {
        const bool offered =
            fotufilm_bridge_texture_stage_available((int32_t)stock, (int32_t)i) != 0;
        gating.offered.push_back(offered);
        if (!offered) [withheld addObject:engine.textureLabels[i]];
    }
    gating.withheldCount = (int)withheld.count;
    gating.withheld = withheld.count ? [withheld componentsJoinedByString:@", "] : nil;
    return gating;
}

/// Whether a menu on this instance's panel was built from a stand-in list rather than from the
/// engine's own. `described` is how many entries Final Cut was actually given; `available` is how
/// many the engine has now. They differ only one way round — a panel is built once and the engine
/// can only gain entries afterwards — and when they differ the menu's index is a position in a
/// list nobody ever saw.
- (BOOL)menuIsPlaceholder:(NSUInteger)described available:(NSUInteger)available {
    return described < available;
}

/// Whether any of the four menus that have a default identity to fall back on is a placeholder.
/// The stock menu is not among them: its stand-in entry is "No stocks installed", and the index
/// it holds — zero — names the first stock, which is the same film a panel built against a live
/// engine would have defaulted to. There is nothing better to name it with.
- (BOOL)anyMenuIsPlaceholder {
    FotufilmEngine *engine = FotufilmEngine.shared;
    return [self menuIsPlaceholder:_describedStages available:engine.stageIDs.count] ||
           [self menuIsPlaceholder:_describedFormats available:engine.formatIDs.count] ||
           [self menuIsPlaceholder:_describedPapers available:engine.paperIDs.count] ||
           [self menuIsPlaceholder:_describedLensFilters available:engine.lensFilterIDs.count] ||
           [self menuIsPlaceholder:_describedDiffusions available:engine.diffusionIDs.count];
}

/// The status line, composed from what the plugin would do right now. `requested` and `measured`
/// are the push the user asked for and the one the film was measured at; they differ when the
/// slider had to be snapped.
- (NSString *)statusForStock:(NSInteger)stock
                       stage:(NSInteger)stage
                  colorSpace:(int)choice
                      gating:(const FotufilmGating &)gating
               pushRequested:(double)requested
                pushMeasured:(double)measured {
    FotufilmEngine *engine = FotufilmEngine.shared;
    if (!engine.ready) {
        return [NSString stringWithFormat:@"%@ Fotufilm could not start its engine; it will try "
                                           "again the next time a control moves.",
                                          engine.failure ?: @"The engine did not start."];
    }
    NSString *film = stock >= 0 && stock < (NSInteger)engine.stockLabels.count
                         ? engine.stockLabels[(NSUInteger)stock] : @"This film";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    // What this instance's panel is missing, first, because it is the only thing here the user
    // cannot fix from the inspector. Both of these mean the engine came up after Final Cut built
    // the controls, which nothing but a restart undoes.
    if (_describedTextureStages < engine.textureMasks.count) {
        [lines addObject:[NSString stringWithFormat:
            @"Fotufilm's engine started after Final Cut Pro built this effect's inspector, so "
             "%lu of its %lu spatial-stage toggles are missing and Texture Only cannot be "
             "rendered. Restart Final Cut Pro.",
            (unsigned long)(engine.textureMasks.count - _describedTextureStages),
            (unsigned long)engine.textureMasks.count]];
    }
    if ([self anyMenuIsPlaceholder]) {
        [lines addObject:@"Fotufilm's Stage, Format, Output Medium and lens menus are "
                          "placeholders: the engine started after Final Cut Pro built this "
                          "effect's inspector, so each holds a single stand-in entry and the "
                          "render uses the menu's own default rather than what the entry names. "
                          "Restart Final Cut Pro."];
    }

    const fotufilm::Encoding encoding = FotufilmMenuPrimaries(choice);
    if (encoding == fotufilm::Encoding::Count && stage == FOTUFILM_BRIDGE_STAGE_PRINT) {
        [lines addObject:@"Print Only needs Timeline Color Space named: its input is optical "
                          "density, which carries no colour space, and Auto will not guess."];
    }
    if (!gating.pushes) {
        [lines addObject:[NSString stringWithFormat:@"%@ has no measured push or pull, so "
                                                     "Push / Pull stays at 0.", film]];
    } else if (std::fabs(requested - measured) > 1e-4) {
        [lines addObject:[NSString stringWithFormat:@"Push / Pull %+.2f is not a development "
                                                     "%@ was measured at; it is snapped to "
                                                     "%+.2f for the render.",
                                                    requested, film, measured]];
    }
    if (!gating.prints) {
        [lines addObject:[NSString stringWithFormat:@"%@ is its own positive and has no print, "
                                                     "so Output Medium, Viewing Illuminant and "
                                                     "Channel Contrast Match do not apply.",
                                                    film]];
    }
    if (gating.withheld) {
        [lines addObject:[NSString stringWithFormat:@"%@ has no %@ to give, so %@ not offered.",
                                                    film, gating.withheld,
                                                    gating.withheldCount == 1 ? @"that stage is"
                                                                              : @"those stages are"]];
    }
    if (lines.count == 0) [lines addObject:@"Ready."];

    if (encoding == fotufilm::Encoding::Count) {
        [lines addObject:_unnamedSpace.load()
                             ? @"Timeline Color Space: Auto — this clip's colour space has no "
                                "name, so it is being read as linear Rec.709; name the space to "
                                "be sure."
                             : @"Timeline Color Space: Auto — the primaries are read off the "
                                "clip, and the light is linear."];
    } else {
        [lines addObject:[NSString stringWithFormat:@"Timeline Color Space: %@ — decoded as %@; "
                                                     "Final Cut hands Fotufilm linear light, so "
                                                     "no transfer curve is applied.",
                                                    FotufilmMenuLabel(encoding),
                                                    FotufilmDecodeName(encoding)]];
    }
    return [lines componentsJoinedByString:@" "];
}

- (BOOL)addParametersWithError:(NSError **)error {
    id<FxParameterCreationAPI_v5> api = [self creationAPI];
    if (!api) {
        if (error) *error = FotufilmError(kFxError_APIUnavailable,
                                          @"Final Cut did not offer a parameter creation API");
        return NO;
    }
    FotufilmEngine *engine = FotufilmEngine.shared;

    // A menu with nothing in it cannot be added, and an engine that failed to load has nothing to
    // put in one. The stand-ins keep the inspector coherent; the status line says why.
    NSArray<NSString *> *stages =
        engine.stageLabels.count ? engine.stageLabels : @[ @"Full" ];
    NSArray<NSString *> *stocks =
        engine.stockLabels.count ? engine.stockLabels : @[ @"No stocks installed" ];
    NSArray<NSString *> *formats =
        engine.formatLabels.count ? engine.formatLabels : @[ @"Match Film" ];
    NSArray<NSString *> *papers =
        engine.paperLabels.count ? engine.paperLabels : @[ @"Ektacolor Edge" ];
    NSArray<NSString *> *viewings =
        engine.negativeViewingLabels.count ? engine.negativeViewingLabels : @[ @"Light Box" ];
    NSArray<NSString *> *filters =
        engine.lensFilterLabels.count ? engine.lensFilterLabels : @[ @"None" ];
    NSArray<NSString *> *meterings =
        engine.meteringLabels.count ? engine.meteringLabels : @[ @"Metered through" ];
    NSArray<NSString *> *diffusions =
        engine.diffusionLabels.count ? engine.diffusionLabels : @[ @"None" ];
    NSArray<NSString *> *grades =
        engine.diffusionGradeLabels.count ? engine.diffusionGradeLabels : @[ @"1/4" ];

    // What this panel is about to be given, recorded before the first control is created —
    // the status line is one of them, and it reports on exactly this. Every count below is the
    // length of the list the menu is built from, and the texture count is how many toggles the
    // loop further down will make. An engine that starts later cannot change any of them: Final
    // Cut builds an inspector once.
    _describedStages = stages.count;
    _describedFormats = formats.count;
    _describedPapers = papers.count;
    _describedLensFilters = filters.count;
    _describedDiffusions = diffusions.count;
    _describedTextureStages = engine.textureLabels.count;

    // The controls are created against the defaults — stock 0, the Full span, Auto — because
    // nothing else can be read here. A restored project is re-gated when it joins its document.
    const FotufilmGating gating = [self gatingForStock:0];
    const FxParameterFlags whenPushes = gating.pushes ? kFxParameterFlag_DEFAULT
                                                      : kFxParameterFlag_DISABLED;
    const FxParameterFlags whenPrints = gating.prints ? kFxParameterFlag_DEFAULT
                                                      : kFxParameterFlag_DISABLED;

    // Read-only, so DISABLED: the host draws it dimmed, which is what a line the user cannot type
    // into should look like. Its value is derived and refreshed, never read back.
    [api addStringParameterWithName:@"Status"
                             parameterID:kFotufilmParam_Status
                       defaultValue:[self statusForStock:0
                                                  stage:FOTUFILM_BRIDGE_STAGE_FULL
                                             colorSpace:kFotufilmColorSpaceAuto
                                                 gating:gating
                                          pushRequested:0
                                           pushMeasured:0]
                          parameterFlags:kFxParameterFlag_DISABLED | kFxParameterFlag_NOT_ANIMATABLE];

    [api startParameterSubGroup:@"Pipeline"
                         parameterID:kFotufilmParam_PipelineGroup
                      parameterFlags:kFxParameterFlag_COLLAPSED];
    [api addPopupMenuWithName:@"Stage"
                       parameterID:kFotufilmParam_Stage
                 defaultValue:0
                  menuEntries:stages
                    parameterFlags:kFxParameterFlag_DEFAULT];
    for (NSUInteger i = 0; i < engine.textureLabels.count; ++i) {
        const bool offered = i < gating.offered.size() ? gating.offered[i] : true;
        [api addToggleButtonWithName:engine.textureLabels[i]
                              parameterID:(UInt32)(kFotufilmParam_TextureStageFirst + i)
                        defaultValue:YES
                           parameterFlags:offered ? kFxParameterFlag_DEFAULT
                                                  : kFxParameterFlag_DISABLED];
    }
    [api endParameterSubGroup];

    [api startParameterSubGroup:@"Film"
                         parameterID:kFotufilmParam_FilmGroup
                      parameterFlags:kFxParameterFlag_DEFAULT];
    [api addPopupMenuWithName:@"Stock"
                       parameterID:kFotufilmParam_Stock
                 defaultValue:0
                  menuEntries:stocks
                    parameterFlags:kFxParameterFlag_DEFAULT];
    // Match Film is the default gauge: the format a stock is actually known on, rather than a
    // number the user has to look up. Naming a gauge pins it.
    [api addPopupMenuWithName:@"Format"
                       parameterID:kFotufilmParam_Format
                 defaultValue:(int)engine.matchFilmFormat
                  menuEntries:formats
                    parameterFlags:kFxParameterFlag_DEFAULT];
    [api addPopupMenuWithName:@"Timeline Color Space"
                       parameterID:kFotufilmParam_ColorSpace
                 defaultValue:kFotufilmColorSpaceAuto
                  menuEntries:[self colorSpaceMenu]
                    parameterFlags:kFxParameterFlag_DEFAULT];
    [api endParameterSubGroup];

    [api startParameterSubGroup:@"Output"
                         parameterID:kFotufilmParam_OutputGroup
                      parameterFlags:kFxParameterFlag_DEFAULT];
    [api addPopupMenuWithName:@"Output Medium"
                       parameterID:kFotufilmParam_Paper
                 defaultValue:(int)engine.matchFilmOutput
                  menuEntries:papers
                    parameterFlags:whenPrints];
    [api addPopupMenuWithName:@"Viewing Illuminant"
                       parameterID:kFotufilmParam_PrintLight
                 defaultValue:0
                  menuEntries:@[ @"Medium Reference · Auto", @"Proofing Booth · D50",
                                 @"Tungsten · 2856 K", @"Daylight · D65" ]
                    parameterFlags:whenPrints];
    [self addSlider:api name:@"Channel Contrast Match"
            parameterID:kFotufilmParam_PrintCorrection
            value:0.05 min:0 max:1 delta:0.01 flags:whenPrints];
    // How a developed negative is read, and it is read only where the negative *is* the output.
    // The controls are created against the default medium, Match Film, which is not the negative,
    // so it starts dimmed; `refreshControlsAtTime` follows the menu from there.
    [api addPopupMenuWithName:@"Negative Viewing"
                       parameterID:kFotufilmParam_NegativeViewing
                 defaultValue:0
                  menuEntries:viewings
                    parameterFlags:kFxParameterFlag_DISABLED];
    [api endParameterSubGroup];

    // The durable identity of each menu choice, hidden. See kFotufilmParam_StageID.
    for (UInt32 identity : {(UInt32)kFotufilmParam_StageID, (UInt32)kFotufilmParam_StockID,
                            (UInt32)kFotufilmParam_FormatID, (UInt32)kFotufilmParam_PaperID}) {
        [api addStringParameterWithName:@"id"
                                 parameterID:identity
                           defaultValue:@""
                              parameterFlags:kFxParameterFlag_HIDDEN];
    }

    [api startParameterSubGroup:@"Exposure"
                         parameterID:kFotufilmParam_ExposureGroup
                      parameterFlags:kFxParameterFlag_DEFAULT];
    [self addSlider:api name:@"Exposure" parameterID:kFotufilmParam_Exposure
            value:0 min:-5 max:5 delta:0.01];
    [self addSlider:api name:@"Temperature" parameterID:kFotufilmParam_Temperature
            value:6504 min:2000 max:12000 delta:10];
    [self addSlider:api name:@"Tint" parameterID:kFotufilmParam_Tint
            value:0 min:-100 max:100 delta:0.5];
    [api endParameterSubGroup];

    // The lens, in the order the light meets it: the absorbing glass, how the exposure was set
    // behind it, then the diffusion filter and the focal length its scattering is imaged through.
    [api startParameterSubGroup:@"Lens"
                         parameterID:kFotufilmParam_LensGroup
                      parameterFlags:kFxParameterFlag_COLLAPSED];
    NSString *const filterNames[3] = { @"Filter 1", @"Filter 2", @"Filter 3" };
    const UInt32 filterIDs[3] = { kFotufilmParam_LensFilter1, kFotufilmParam_LensFilter2,
                                  kFotufilmParam_LensFilter3 };
    for (int i = 0; i < 3; ++i) {
        [api addPopupMenuWithName:filterNames[i]
                           parameterID:filterIDs[i]
                     defaultValue:0
                      menuEntries:filters
                        parameterFlags:kFxParameterFlag_DEFAULT];
    }
    // The default is the engine's own, through-the-lens metering, which is entry 1 of its list.
    [api addPopupMenuWithName:@"Metering"
                       parameterID:kFotufilmParam_Metering
                 defaultValue:(UInt32)(meterings.count > 1 ? 1 : 0)
                  menuEntries:meterings
                    parameterFlags:kFxParameterFlag_DEFAULT];
    [api addPopupMenuWithName:@"Diffusion"
                       parameterID:kFotufilmParam_Diffusion
                 defaultValue:0
                  menuEntries:diffusions
                    parameterFlags:kFxParameterFlag_DEFAULT];
    const NSInteger defaultGrade =
        engine.defaultDiffusionGrade >= 0 && engine.defaultDiffusionGrade < (NSInteger)grades.count
            ? engine.defaultDiffusionGrade : 0;
    [api addPopupMenuWithName:@"Diffusion Grade"
                       parameterID:kFotufilmParam_DiffusionGrade
                 defaultValue:(UInt32)defaultGrade
                  menuEntries:grades
                    parameterFlags:kFxParameterFlag_DEFAULT];
    // Zero is the gauge's own normal lens, which is what the grade numbering on a filter's ring
    // is calibrated around.
    [self addSlider:api name:@"Focal Length" parameterID:kFotufilmParam_FocalLength
            value:0 min:0 max:300 delta:1];
    [api endParameterSubGroup];

    // The durable identity of the four catalogue menus above, hidden, as 26...29 are.
    for (UInt32 identity : {(UInt32)kFotufilmParam_LensFilter1ID,
                            (UInt32)kFotufilmParam_LensFilter2ID,
                            (UInt32)kFotufilmParam_LensFilter3ID,
                            (UInt32)kFotufilmParam_DiffusionID}) {
        [api addStringParameterWithName:@"id"
                                 parameterID:identity
                           defaultValue:@""
                              parameterFlags:kFxParameterFlag_HIDDEN];
    }

    [api startParameterSubGroup:@"Tone"
                         parameterID:kFotufilmParam_ToneGroup
                      parameterFlags:kFxParameterFlag_DEFAULT];
    [self addSlider:api name:@"Highlights" parameterID:kFotufilmParam_Highlights
            value:0 min:-1 max:1 delta:0.01];
    [self addSlider:api name:@"Shadows" parameterID:kFotufilmParam_Shadows
            value:0 min:-1 max:1 delta:0.01];
    [api addToggleButtonWithName:@"Regional Tone Mask"
                          parameterID:kFotufilmParam_LocalTone
                    defaultValue:YES
                       parameterFlags:kFxParameterFlag_DEFAULT];
    [self addSlider:api name:@"Saturation" parameterID:kFotufilmParam_Saturation
            value:1 min:0 max:2 delta:0.01];
    [self addSlider:api name:@"Vibrance" parameterID:kFotufilmParam_Vibrance
            value:0 min:-1 max:1 delta:0.01];
    [api endParameterSubGroup];

    [api startParameterSubGroup:@"Film Response"
                         parameterID:kFotufilmParam_ResponseGroup
                      parameterFlags:kFxParameterFlag_DEFAULT];
    [self addSlider:api name:@"Grain" parameterID:kFotufilmParam_Grain
            value:1 min:0 max:2 delta:0.01];
    // The slider stays 0-10; the hard range admits typed values to 100, so a pack's authored look
    // can be pushed well past itself without touching the calibrated sheets.
    [api addFloatSliderWithName:@"Halation"
                         parameterID:kFotufilmParam_Halation
                   defaultValue:1
                   parameterMin:0
                   parameterMax:100
                      sliderMin:0
                      sliderMax:10
                          delta:0.01
                      parameterFlags:kFxParameterFlag_DEFAULT];
    [api addToggleButtonWithName:@"Estimated Halation Shape"
                          parameterID:kFotufilmParam_EstimatedHalation
                    defaultValue:NO
                       parameterFlags:kFxParameterFlag_DEFAULT];
    [self addSlider:api name:@"Halo Colour" parameterID:kFotufilmParam_HalationColour
            value:0 min:0 max:1 delta:0.01];
    // Zero leaves the stage out: a photographed clip already carries its own lens's glare.
    [self addSlider:api name:@"Lens Flare" parameterID:kFotufilmParam_Flare
            value:0 min:0 max:2 delta:0.01];
    [self addSlider:api name:@"DIR Couplers" parameterID:kFotufilmParam_Couplers
            value:1 min:0 max:2 delta:0.01];
    [api addIntSliderWithName:@"Grain Seed"
                       parameterID:kFotufilmParam_Seed
                 defaultValue:0x46494C4D
                 parameterMin:0
                 parameterMax:INT32_MAX
                    sliderMin:0
                    sliderMax:INT32_MAX
                        delta:1
                    parameterFlags:kFxParameterFlag_NOT_ANIMATABLE];
    [api endParameterSubGroup];

    [api startParameterSubGroup:@"The Lab"
                         parameterID:kFotufilmParam_LabGroup
                      parameterFlags:kFxParameterFlag_COLLAPSED];
    // A continuous slider over a set of measured conditions: the engine carries a film's response
    // only at the developments it was measured at, and refuses anything between. The value is
    // snapped to the nearest one on the way to the engine — not in the control, which animates —
    // and the slider is disabled on a film that has none.
    [self addSlider:api name:@"Push / Pull" parameterID:kFotufilmParam_Push
            value:0 min:-1 max:3 delta:0.01 flags:whenPushes];
    [self addSlider:api name:@"Bleach Bypass" parameterID:kFotufilmParam_BleachBypass
            value:0 min:0 max:1 delta:0.01];
    [self addSlider:api name:@"Expired" parameterID:kFotufilmParam_Expired
            value:0 min:0 max:30 delta:0.1];
    [api endParameterSubGroup];

    return YES;
}

- (void)addSlider:(id<FxParameterCreationAPI_v5>)api
             name:(NSString *)name
           parameterID:(UInt32)parameterID
            value:(double)value
              min:(double)minimum
              max:(double)maximum
            delta:(double)delta {
    [self addSlider:api name:name parameterID:parameterID value:value min:minimum max:maximum
              delta:delta flags:kFxParameterFlag_DEFAULT];
}

- (void)addSlider:(id<FxParameterCreationAPI_v5>)api
             name:(NSString *)name
           parameterID:(UInt32)parameterID
            value:(double)value
              min:(double)minimum
              max:(double)maximum
            delta:(double)delta
            flags:(FxParameterFlags)flags {
    [api addFloatSliderWithName:name
                         parameterID:parameterID
                   defaultValue:value
                   parameterMin:minimum
                   parameterMax:maximum
                      sliderMin:minimum
                      sliderMax:maximum
                          delta:delta
                      parameterFlags:flags];
}

- (NSArray<NSString *> *)colorSpaceMenu {
    NSMutableArray<NSString *> *spaces = [NSMutableArray array];
    for (int i = 0; i < kFotufilmColorSpaceAuto; ++i) {
        [spaces addObject:FotufilmMenuLabel((fotufilm::Encoding)i)];
    }
    [spaces addObject:@"Auto (from host)"];
    for (int i = kFotufilmColorSpaceAuto; i < (int)fotufilm::Encoding::Count; ++i) {
        [spaces addObject:FotufilmMenuLabel((fotufilm::Encoding)i)];
    }
    return spaces;
}

// MARK: identity reconciliation and gating

/// Writes the identity of whatever the menus now hold, then brings every derived control into
/// step with them. Called when the user moves anything, so that the project keeps the choice by
/// name and survives a pack that renumbers its menu, and so that a film change re-gates the
/// controls that depend on the film.
- (BOOL)parameterChanged:(UInt32)parameterID atTime:(CMTime)time error:(NSError **)error {
    if (_refreshing) return YES;
    FotufilmEngine *engine = FotufilmEngine.shared;
    NSArray<NSString *> *ids = nil;
    UInt32 identityID = 0;
    switch (parameterID) {
        case kFotufilmParam_Stage: ids = engine.stageIDs; identityID = kFotufilmParam_StageID; break;
        case kFotufilmParam_Stock: ids = engine.stockIDs; identityID = kFotufilmParam_StockID; break;
        case kFotufilmParam_Format: ids = engine.formatIDs; identityID = kFotufilmParam_FormatID; break;
        case kFotufilmParam_Paper: ids = engine.paperIDs; identityID = kFotufilmParam_PaperID; break;
        case kFotufilmParam_LensFilter1:
            ids = engine.lensFilterIDs; identityID = kFotufilmParam_LensFilter1ID; break;
        case kFotufilmParam_LensFilter2:
            ids = engine.lensFilterIDs; identityID = kFotufilmParam_LensFilter2ID; break;
        case kFotufilmParam_LensFilter3:
            ids = engine.lensFilterIDs; identityID = kFotufilmParam_LensFilter3ID; break;
        case kFotufilmParam_Diffusion:
            ids = engine.diffusionIDs; identityID = kFotufilmParam_DiffusionID; break;
        default: break;
    }

    // Which controls a refresh can actually change. It is about twenty-five `setParameterFlags:`
    // round trips to the host, a snap through the bridge and a status string formatted from
    // scratch, and Final Cut reports every parameter through here — including a slider being
    // dragged, which arrives on every mouse sample. Only these five decide what is dimmed or what
    // the status line says: the span (the lens and the exposure), the film (the push, the print
    // controls and the texture toggles), the output medium (the negative-viewing mode), the
    // colour space and the push. The lens menus are deliberately not among them: nothing is
    // gated on which filter is fitted, and the status line does not mention one.
    BOOL gatesSomething = NO;
    switch (parameterID) {
        case kFotufilmParam_Stage:
        case kFotufilmParam_Stock:
        case kFotufilmParam_Paper:
        case kFotufilmParam_ColorSpace:
        case kFotufilmParam_Push: gatesSomething = YES; break;
        default: break;
    }

    id<FxParameterRetrievalAPI_v6> retrieval = [self retrievalAPI];
    id<FxParameterSettingAPI_v5> setting = [self settingAPI];
    if (!retrieval || !setting) return YES;

    if (ids) {
        int choice = 0;
        [retrieval getIntValue:&choice fromParameter:parameterID atTime:time];
        if (choice >= 0 && choice < (int)ids.count) {
            id<FxCustomParameterActionAPI_v4> action = [self actionAPI];
            [action startAction:self];
            [setting setStringParameterValue:ids[(NSUInteger)choice] toParameter:identityID];
            [action endAction:self];
        }
    }

    // After the id is written, because that is what the render — and this — resolve against.
    if (gatesSomething) [self refreshControlsAtTime:time];

    // The choice is part of the render, and the developed frame is cached against it.
    [self.lock lock];
    self.cacheKey = nil;
    [self.lock unlock];
    return YES;
}

/// A restored instance: the menus hold whatever the project saved, which the creation-time
/// gating against the defaults knows nothing about.
- (void)pluginInstanceAddedToDocument {
    id<FxCustomParameterActionAPI_v4> action = [self actionAPI];
    // Through `id`: the SDK's action protocol does not adopt NSObject, so `respondsToSelector:`
    // is not one of its methods. It is still the right question — the API may be absent, and a
    // document being loaded has no playhead to ask about until it is.
    const CMTime time = [(id)action respondsToSelector:@selector(currentTime)]
                            ? [action currentTime] : kCMTimeZero;
    [self adoptPlaceholderIdentities];
    [self refreshControlsAtTime:CMTIME_IS_VALID(time) ? time : kCMTimeZero];
}

/// Writes down what a placeholder menu was actually showing, once, when the instance joins its
/// document.
///
/// A panel built while the engine was down holds one stand-in entry per menu, and the index the
/// instance carries is a position in a list Final Cut never had. Read into the engine's own list
/// later it names whatever now sits there — the first real gauge, where the inspector said Match
/// Film — and the frame develops on it while the control still reads the other thing. The only
/// honest identity for what was shown is the menu's own default, so it is persisted here.
///
/// Best effort, exactly as the OFX plugin's `reconcile` is: a host that refuses a write outside a
/// user action leaves the id empty, and `choiceFor:` resolves the same default on every read. An
/// id that is already there is never overwritten — that is the user's choice or the project's.
- (void)adoptPlaceholderIdentities {
    id<FxParameterRetrievalAPI_v6> retrieval = [self retrievalAPI];
    id<FxParameterSettingAPI_v5> setting = [self settingAPI];
    if (!retrieval || !setting) return;
    FotufilmEngine *engine = FotufilmEngine.shared;

    struct Placeholder {
        UInt32 identityID;
        NSUInteger described;
        NSUInteger available;
        NSString *defaultID;
    };
    const Placeholder menus[] = {
        {kFotufilmParam_StageID, _describedStages, engine.stageIDs.count,
         @kFotufilmFullStageID},
        {kFotufilmParam_FormatID, _describedFormats, engine.formatIDs.count,
         @kFotufilmMatchFilmFormatID},
        {kFotufilmParam_PaperID, _describedPapers, engine.paperIDs.count,
         @kFotufilmMatchFilmPaperID},
        {kFotufilmParam_LensFilter1ID, _describedLensFilters, engine.lensFilterIDs.count,
         @kFotufilmNoFilterID},
        {kFotufilmParam_LensFilter2ID, _describedLensFilters, engine.lensFilterIDs.count,
         @kFotufilmNoFilterID},
        {kFotufilmParam_LensFilter3ID, _describedLensFilters, engine.lensFilterIDs.count,
         @kFotufilmNoFilterID},
        {kFotufilmParam_DiffusionID, _describedDiffusions, engine.diffusionIDs.count,
         @kFotufilmNoFilterID},
    };

    id<FxCustomParameterActionAPI_v4> action = [self actionAPI];
    [action startAction:self];
    for (const Placeholder &menu : menus) {
        if (![self menuIsPlaceholder:menu.described available:menu.available]) continue;
        NSString *saved = nil;
        [retrieval getStringParameterValue:&saved fromParameter:menu.identityID];
        if (saved.length) continue;
        [setting setStringParameterValue:menu.defaultID toParameter:menu.identityID];
    }
    [action endAction:self];
}

/// Everything derived from the film, the span and the colour space choice: the Push / Pull slider
/// live or dimmed, the print controls live or dimmed, the texture stages the film can back, and
/// the status line saying all of it — including which measured development an off-grid push will
/// actually be developed at. Nothing here writes a parameter value; see the note on Push / Pull.
- (void)refreshControlsAtTime:(CMTime)time {
    id<FxParameterRetrievalAPI_v6> retrieval = [self retrievalAPI];
    id<FxParameterSettingAPI_v5> setting = [self settingAPI];
    if (!retrieval || !setting || _refreshing) return;
    _refreshing = YES;
    FotufilmEngine *engine = FotufilmEngine.shared;

    const NSInteger stock = [self choiceFor:kFotufilmParam_Stock
                                 identityID:kFotufilmParam_StockID
                                        ids:engine.stockIDs
                                        api:retrieval
                                     atTime:time];
    const NSInteger stage = [self choiceFor:kFotufilmParam_Stage
                                 identityID:kFotufilmParam_StageID
                                        ids:engine.stageIDs
                                  described:_describedStages
                                  defaultID:@kFotufilmFullStageID
                                        api:retrieval
                                     atTime:time];
    int colorSpace = kFotufilmColorSpaceAuto;
    [retrieval getIntValue:&colorSpace fromParameter:kFotufilmParam_ColorSpace atTime:time];
    double requested = 0;
    [retrieval getFloatValue:&requested fromParameter:kFotufilmParam_Push atTime:time];

    const FotufilmGating gating = [self gatingForStock:stock];
    double measured = requested;
    if (engine.ready) {
        measured = fotufilm_bridge_stock_snap_push((int32_t)stock, (float)requested);
    }

    id<FxCustomParameterActionAPI_v4> action = [self actionAPI];
    [action startAction:self];

    // Push / Pull is *not* written back. It animates, so `setFloatValue:atTime:` on it does not
    // correct a value — it lays a keyframe, at whatever time the playhead happens to be on, in a
    // project the user has only just opened. This method runs when an instance joins a document,
    // so that is a document mutated by being looked at. The snap is not lost by leaving it: the
    // state call snaps again on the way to the engine, which is the one place it has to be
    // right, and a keyframed curve between two measured stops has to be snapped there anyway.
    // So the control keeps what the user put in it and the status line says where it develops.
    [setting setParameterFlags:gating.pushes ? kFxParameterFlag_DEFAULT : kFxParameterFlag_DISABLED
                   toParameter:kFotufilmParam_Push];
    for (UInt32 printOnly : {(UInt32)kFotufilmParam_Paper, (UInt32)kFotufilmParam_PrintLight,
                             (UInt32)kFotufilmParam_PrintCorrection}) {
        [setting setParameterFlags:gating.prints ? kFxParameterFlag_DEFAULT
                                                 : kFxParameterFlag_DISABLED
                       toParameter:printOnly];
    }
    // The lens is camera-side: nothing screwed onto the front of it exists in a span that starts
    // at the developed negative, so Print Only dims the whole group as it dims the exposure.
    //
    // The absorbing half is dimmed everywhere but Full, and that is a limit of the compiled
    // kernels rather than of the physics. A fitted filter is two more air-glass faces, so the
    // engine raises its veiling-glare feature bit for one whatever the Lens Flare slider says
    // (`FilmEngine.swift`). Every compiled `FOTUFILM_AOT_FLARE` variant is built on
    // `FOTUFILM_AOT_ALL_STAGES`, which is the Full span: neither `FOTUFILM_AOT_NEGATIVE_SPAN`,
    // which carries `FOTUFILM_FRAME_DENSITY_OUT`, nor `FOTUFILM_AOT_TEXTURE_SPAN` has a
    // glare-carrying twin. `select_variant` matches a request exactly, so a filter fitted in
    // either span does not weaken the frame, it fails every frame of it. Negative Only and
    // Texture Only are the same refusal for the same reason.
    //
    // The scattering half survives into both. Texture Only develops the frame twice — once with
    // the spatial stages it was asked for and once with none of them — and returns what the two
    // densities differ by, so a mist filter reaches it easily: the halo and the grain are
    // computed over softened light. Negative Only runs the whole camera side, so it carries the
    // mist as it carries the exposure.
    const BOOL exposesFilm = stage == FOTUFILM_BRIDGE_STAGE_FULL;
    const BOOL cameraSide = stage == FOTUFILM_BRIDGE_STAGE_FULL ||
                            stage == FOTUFILM_BRIDGE_STAGE_NEGATIVE;
    const BOOL texturing = stage == FOTUFILM_BRIDGE_STAGE_TEXTURE;
    for (UInt32 absorbing : {(UInt32)kFotufilmParam_LensFilter1,
                             (UInt32)kFotufilmParam_LensFilter2,
                             (UInt32)kFotufilmParam_LensFilter3,
                             (UInt32)kFotufilmParam_Metering}) {
        [setting setParameterFlags:exposesFilm ? kFxParameterFlag_DEFAULT
                                               : kFxParameterFlag_DISABLED
                       toParameter:absorbing];
    }
    for (UInt32 scattering : {(UInt32)kFotufilmParam_Diffusion,
                              (UInt32)kFotufilmParam_DiffusionGrade,
                              (UInt32)kFotufilmParam_FocalLength}) {
        [setting setParameterFlags:(cameraSide || texturing) ? kFxParameterFlag_DEFAULT
                                                             : kFxParameterFlag_DISABLED
                       toParameter:scattering];
    }

    // Negative Viewing reads only where the negative is the output. Every other medium has a
    // print or a scan of its own, and Match Film leaves the choice to the film. It follows the
    // medium menu rather than the film, so it is gated here rather than in `gatingForStock:`.
    const NSInteger paper = [self choiceFor:kFotufilmParam_Paper
                                 identityID:kFotufilmParam_PaperID
                                        ids:engine.paperIDs
                                  described:_describedPapers
                                  defaultID:@kFotufilmMatchFilmPaperID
                                        api:retrieval
                                     atTime:time];
    const BOOL readsNegative = engine.ready && gating.prints &&
                               fotufilm_bridge_paper_is_negative((int32_t)paper) != 0;
    [setting setParameterFlags:readsNegative ? kFxParameterFlag_DEFAULT
                                             : kFxParameterFlag_DISABLED
                   toParameter:kFotufilmParam_NegativeViewing];
    // Bounded by what this panel was given as well as by what the film offers: an engine that
    // started after the inspector was built knows about stages there is no control here to dim,
    // and asking Final Cut to set flags on a parameter id it was never handed is asking about
    // nothing. The status line is where that panel is reported instead.
    for (NSUInteger i = 0; i < _describedTextureStages && i < gating.offered.size(); ++i) {
        [setting setParameterFlags:gating.offered[i] ? kFxParameterFlag_DEFAULT
                                                     : kFxParameterFlag_DISABLED
                       toParameter:(UInt32)(kFotufilmParam_TextureStageFirst + i)];
    }

    NSString *status = [self statusForStock:stock
                                      stage:stage
                                 colorSpace:colorSpace
                                     gating:gating
                              pushRequested:requested
                               pushMeasured:measured];
    NSString *shown = nil;
    [retrieval getStringParameterValue:&shown fromParameter:kFotufilmParam_Status];
    if (![shown isEqualToString:status]) {
        [setting setStringParameterValue:status toParameter:kFotufilmParam_Status];
    }

    [action endAction:self];
    _refreshing = NO;
}

// MARK: state

- (BOOL)pluginState:(NSData *_Nonnull *_Nullable)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
    if (!pluginState) {
        if (error) *error = FotufilmError(kFxError_InvalidParameter,
                                          @"Fotufilm was asked for its state with nowhere to "
                                           "put it");
        return NO;
    }
    id<FxParameterRetrievalAPI_v6> api = [self retrievalAPI];
    if (!api) {
        if (error) *error = FotufilmError(kFxError_APIUnavailable,
                                          @"Final Cut did not offer a parameter retrieval API");
        return NO;
    }
    FotufilmEngine *engine = FotufilmEngine.shared;

    FotufilmState state{};
    state.version = kFotufilmStateVersion;
    state.quality = (uint32_t)qualityLevel;

    // The float block, slot by slot. Only the viewing lamp is converted — a popup reads as an
    // index and the bridge wants kelvin. Nothing is clamped: a typed value past a slider's end is
    // the user asking for it, and the engine is the one that decides what it means. The one
    // exception is the push, below, which the engine would refuse rather than interpret.
    double value = 0;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Exposure atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_EXPOSURE_EV] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Temperature atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_TEMPERATURE] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Tint atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_TINT] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Highlights atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_HIGHLIGHTS] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Shadows atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_SHADOWS] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Saturation atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_SATURATION] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Vibrance atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_VIBRANCE] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Grain atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_GRAIN_SCALE] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Halation atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_HALATION_SCALE] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_HalationColour atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_HALATION_COLOUR] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Flare atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_FLARE_SCALE] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Couplers atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_COUPLER_SCALE] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_PrintCorrection atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_PRINT_CORRECTION] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Push atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_PUSH_PULL] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_BleachBypass atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_BLEACH_BYPASS] = (float)value;
    [api getFloatValue:&value fromParameter:kFotufilmParam_Expired atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_EXPIRED_YEARS] = (float)value;

    BOOL flag = NO;
    [api getBoolValue:&flag fromParameter:kFotufilmParam_LocalTone atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_LOCAL_TONE] = flag ? 1.0f : 0.0f;
    [api getBoolValue:&flag fromParameter:kFotufilmParam_EstimatedHalation atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_ESTIMATED_HALATION] = flag ? 1.0f : 0.0f;

    int choice = 0;
    [api getIntValue:&choice fromParameter:kFotufilmParam_PrintLight atTime:renderTime];
    const int lamps = (int)(sizeof(kFotufilmPrintLightKelvin) / sizeof(*kFotufilmPrintLightKelvin));
    state.parameters[FOTUFILM_BRIDGE_PRINT_LIGHT] =
        kFotufilmPrintLightKelvin[choice >= 0 && choice < lamps ? choice : 0];

    // The lens. Each of these slots is "engine index plus one, zero meaning off", so that a
    // project saved before the group existed — whose blob stops at the halo colour and whose
    // remaining slots are zero — develops exactly the frame it always did.
    //
    // Two of the menus already carry that offset in their entries: the filter and diffusion menus
    // open with a "None" this side owns, so their menu index *is* the offset number, and they are
    // resolved through their persisted id rather than through the position they occupy. The other
    // two come straight out of an engine enum and have the one added here. The grade is a bare
    // index, gated by a family being chosen.
    const UInt32 lensFilterMenus[3] = { kFotufilmParam_LensFilter1, kFotufilmParam_LensFilter2,
                                        kFotufilmParam_LensFilter3 };
    const UInt32 lensFilterIdentities[3] = { kFotufilmParam_LensFilter1ID,
                                             kFotufilmParam_LensFilter2ID,
                                             kFotufilmParam_LensFilter3ID };
    const int lensSlots[3] = { FOTUFILM_BRIDGE_LENS_FILTER_1, FOTUFILM_BRIDGE_LENS_FILTER_2,
                               FOTUFILM_BRIDGE_LENS_FILTER_3 };
    for (int i = 0; i < 3; ++i) {
        state.parameters[lensSlots[i]] = (float)[self choiceFor:lensFilterMenus[i]
                                                     identityID:lensFilterIdentities[i]
                                                            ids:engine.lensFilterIDs
                                                      described:_describedLensFilters
                                                      defaultID:@kFotufilmNoFilterID
                                                            api:api
                                                         atTime:renderTime];
    }
    state.parameters[FOTUFILM_BRIDGE_DIFFUSION_FAMILY] =
        (float)[self choiceFor:kFotufilmParam_Diffusion
                    identityID:kFotufilmParam_DiffusionID
                           ids:engine.diffusionIDs
                     described:_describedDiffusions
                     defaultID:@kFotufilmNoFilterID
                           api:api
                        atTime:renderTime];
    [api getIntValue:&choice fromParameter:kFotufilmParam_Metering atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_LENS_METERING] = (float)(MAX(choice, 0) + 1);
    [api getIntValue:&choice fromParameter:kFotufilmParam_DiffusionGrade atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_DIFFUSION_GRADE] = (float)MAX(choice, 0);
    [api getIntValue:&choice fromParameter:kFotufilmParam_NegativeViewing atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_NEGATIVE_VIEWING] = (float)(MAX(choice, 0) + 1);
    [api getFloatValue:&value fromParameter:kFotufilmParam_FocalLength atTime:renderTime];
    state.parameters[FOTUFILM_BRIDGE_FOCAL_LENGTH] = (float)value;

    [api getIntValue:&choice fromParameter:kFotufilmParam_Seed atTime:renderTime];
    state.seed = (uint32_t)choice;

    [api getIntValue:&choice fromParameter:kFotufilmParam_ColorSpace atTime:renderTime];
    state.colorSpace = choice;

    // The menus, resolved through their persisted identity. The id wins: it is what the project
    // actually saved, and the index only means something against the pack that built the menu.
    state.stock = (int32_t)[self choiceFor:kFotufilmParam_Stock
                                identityID:kFotufilmParam_StockID
                                       ids:engine.stockIDs
                                       api:api
                                    atTime:renderTime];
    state.format = (int32_t)[self choiceFor:kFotufilmParam_Format
                                 identityID:kFotufilmParam_FormatID
                                        ids:engine.formatIDs
                                  described:_describedFormats
                                  defaultID:@kFotufilmMatchFilmFormatID
                                        api:api
                                     atTime:renderTime];
    state.paper = (int32_t)[self choiceFor:kFotufilmParam_Paper
                                identityID:kFotufilmParam_PaperID
                                       ids:engine.paperIDs
                                 described:_describedPapers
                                 defaultID:@kFotufilmMatchFilmPaperID
                                       api:api
                                    atTime:renderTime];
    NSInteger stage = [self choiceFor:kFotufilmParam_Stage
                           identityID:kFotufilmParam_StageID
                                  ids:engine.stageIDs
                            described:_describedStages
                            defaultID:@kFotufilmFullStageID
                                  api:api
                               atTime:renderTime];
    if (stage < 0 || stage >= (NSInteger)engine.stageIDs.count) {
        stage = FOTUFILM_BRIDGE_STAGE_FULL;
    }
    state.parameters[FOTUFILM_BRIDGE_STAGE] = (float)stage;

    // A dimmed control is a control that is not applied, and dimming it is only half of saying
    // so: the value the user set while the span was Full stays in the parameter, and the host
    // hands it back whatever the inspector is drawing. So the slots the span cannot carry are
    // cleared here, on the one road every render takes to the engine. Zero is each slot's own off
    // position — the same zero a project saved before the Lens group existed hands back — so this
    // is the span rendering as though the glass had been unscrewed, not as though it had been
    // given some other value.
    //
    // The absorbing half goes outside Full for the reason `refreshControlsAtTime:` dims it: a
    // fitted filter raises the engine's veiling-glare bit, and no compiled variant pairs glare
    // with the negative span's density output or with the texture span. Left in the block it
    // would not weaken those frames, it would fail them.
    if (stage != FOTUFILM_BRIDGE_STAGE_FULL) {
        state.parameters[FOTUFILM_BRIDGE_LENS_FILTER_1] = 0;
        state.parameters[FOTUFILM_BRIDGE_LENS_FILTER_2] = 0;
        state.parameters[FOTUFILM_BRIDGE_LENS_FILTER_3] = 0;
        state.parameters[FOTUFILM_BRIDGE_LENS_METERING] = 0;
    }
    // The scattering half survives wherever the film is exposed or the spatial stages are being
    // differenced. Print Only is the one span that is neither: it starts at a developed negative,
    // where nothing on the front of the lens exists at all.
    if (stage == FOTUFILM_BRIDGE_STAGE_PRINT) {
        state.parameters[FOTUFILM_BRIDGE_DIFFUSION_FAMILY] = 0;
        state.parameters[FOTUFILM_BRIDGE_DIFFUSION_GRADE] = 0;
        state.parameters[FOTUFILM_BRIDGE_FOCAL_LENGTH] = 0;
    }

    // The push, snapped again here even though `parameterChanged:` already snaps it: a project
    // restored with a value saved under another film, or a keyframe interpolated between two
    // measured stops, reaches this call without ever having passed through that one, and the
    // engine refuses a development it was not measured at rather than inventing one.
    if (engine.ready) {
        state.parameters[FOTUFILM_BRIDGE_PUSH_PULL] = fotufilm_bridge_stock_snap_push(
            state.stock, state.parameters[FOTUFILM_BRIDGE_PUSH_PULL]);
    }

    // Texture Only on an inspector whose per-stage toggles were never created.
    //
    // `addParametersWithError:` makes one toggle per spatial stage the engine hands out, and an
    // engine that was down when Final Cut built this panel handed out none. The retry starts it
    // later, and from then on the engine knows about stages this instance has no control for:
    // the toggles that do not exist read back as off, the mask packs as zero, and zero is the
    // selection that lays nothing over the frame. That is indistinguishable from the user having
    // switched every stage off, so developing it would quietly hand the source straight back
    // under a span they asked to do something. Refuse, and name the one thing that fixes it —
    // the panel cannot be rebuilt without rebuilding the document that holds it.
    if (stage == FOTUFILM_BRIDGE_STAGE_TEXTURE &&
        [self menuIsPlaceholder:_describedTextureStages available:engine.textureMasks.count]) {
        if (error) *error = FotufilmError(
            kFotufilmError_Engine,
            @"Fotufilm's Texture Only stage cannot read which spatial stages it was asked for: "
             "the engine started after Final Cut Pro built this effect's inspector, so the "
             "per-stage toggles are not on it. Restart Final Cut Pro and the effect will render.");
        return NO;
    }

    // The texture selection is the OR of the toggles, each carrying the bit the engine handed out
    // for it. The bits are asked for rather than hardcoded so the two sides cannot drift, and the
    // loop stops at the toggles this panel actually has rather than asking the host about
    // parameter ids it was never given.
    int32_t mask = 0;
    for (NSUInteger i = 0; i < engine.textureMasks.count && i < _describedTextureStages; ++i) {
        flag = NO;
        [api getBoolValue:&flag
            fromParameter:(UInt32)(kFotufilmParam_TextureStageFirst + i)
                   atTime:renderTime];
        if (flag) mask |= engine.textureMasks[i].intValue;
    }
    state.parameters[FOTUFILM_BRIDGE_TEXTURE_STAGES] = (float)mask;

    for (float parameter : state.parameters) {
        if (!std::isfinite(parameter)) {
            if (error) *error = FotufilmError(kFxError_InvalidParameter,
                                              @"Fotufilm received a non-finite parameter value");
            return NO;
        }
    }

    *pluginState = [NSData dataWithBytes:&state length:sizeof(state)];
    return YES;
}

/// The index a menu names, resolved through the identity beside it.
///
/// `described` is how many entries this instance's panel was actually given for the menu, and
/// `defaultID` is the identity of the entry a placeholder panel showed in its one slot. When the
/// panel is short of the engine's list, the menu index is not an identity at all — it is a
/// position in a list the host never had — so the fallback is the menu's own default rather than
/// whatever now occupies that position. Without it a project built while the engine was down
/// develops every frame on the first real gauge while the inspector still says Match Film.
- (NSInteger)choiceFor:(UInt32)parameterID
            identityID:(UInt32)identityID
                   ids:(NSArray<NSString *> *)ids
             described:(NSUInteger)described
             defaultID:(NSString *)defaultID
                   api:(id<FxParameterRetrievalAPI_v6>)api
                atTime:(CMTime)time {
    int index = 0;
    [api getIntValue:&index fromParameter:parameterID atTime:time];
    NSString *identity = nil;
    [api getStringParameterValue:&identity fromParameter:identityID];
    if (identity.length == 0 && defaultID.length &&
        [self menuIsPlaceholder:described available:ids.count]) {
        identity = defaultID;
    }
    return [FotufilmEngine.shared indexForID:identity in:ids fallback:index];
}

/// A menu with no default identity to fall back on, which is the stock menu and nothing else: its
/// stand-in entry says "No stocks installed", and the index behind it — zero — names the first
/// stock, which is the film a panel built against a live engine would have defaulted to anyway.
- (NSInteger)choiceFor:(UInt32)parameterID
            identityID:(UInt32)identityID
                   ids:(NSArray<NSString *> *)ids
                   api:(id<FxParameterRetrievalAPI_v6>)api
                atTime:(CMTime)time {
    return [self choiceFor:parameterID
                identityID:identityID
                       ids:ids
                 described:ids.count
                 defaultID:nil
                       api:api
                    atTime:time];
}

// MARK: geometry

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError **)error {
    if (sourceImages.count == 0) {
        if (error) *error = FotufilmError(kFxError_InvalidParameter,
                                          @"Fotufilm was given no input image");
        return NO;
    }
    *destinationImageRect = sourceImages[0].imagePixelBounds;
    return YES;
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
      sourceImageIndex:(NSUInteger)sourceImageIndex
          sourceImages:(NSArray<FxImageTile *> *)sourceImages
   destinationTileRect:(FxRect)destinationTileRect
      destinationImage:(FxImageTile *)destinationImage
           pluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
    if (sourceImageIndex >= sourceImages.count) {
        if (error) *error = FotufilmError(kFxError_InvalidParameter,
                                          @"Fotufilm was asked for an input it does not have");
        return NO;
    }
    // The whole image, whatever tile is being asked for. Every spatial stage reads outside the
    // tile, so a tile's worth of input develops a different frame from the one it belongs to.
    *sourceTileRect = sourceImages[sourceImageIndex].imagePixelBounds;
    return YES;
}

// MARK: render

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError **)error {
    // One frame at a time per instance. The host may call this on several threads at once, and
    // the frame buffers, the cached frame and the bridge context are all this instance's. Two
    // instances still develop in parallel — the engine gives each context its own staging.
    [self.lock lock];
    const BOOL rendered = [self renderLocked:destinationImage
                                sourceImages:sourceImages
                                 pluginState:pluginState
                                      atTime:renderTime
                                       error:error];
    [self.lock unlock];
    return rendered;
}

- (BOOL)renderLocked:(FxImageTile *)destinationImage
        sourceImages:(NSArray<FxImageTile *> *)sourceImages
         pluginState:(NSData *)pluginState
              atTime:(CMTime)renderTime
               error:(NSError **)error {
    FotufilmEngine *engine = FotufilmEngine.shared;
    if (!engine.ready) {
        if (error) *error = FotufilmError(kFotufilmError_Engine,
                                          @"Fotufilm could not start its engine: %@",
                                          engine.failure ?: FotufilmBridgeError(NULL));
        return NO;
    }
    if (!_bridge) {
        if (error) *error = FotufilmError(kFxError_OutOfMemory,
                                          @"Fotufilm could not allocate its render context");
        return NO;
    }
    if (sourceImages.count == 0) {
        if (error) *error = FotufilmError(kFxError_InvalidParameter,
                                          @"Fotufilm was given no input image");
        return NO;
    }
    // Version before length, because a state from another build is a different length as well
    // as a different shape: checking the length first turns the one failure the user can act on
    // — a live plugin update, fixed by restarting Final Cut — into "cannot read", which tells
    // them nothing. `version` is the first field of the POD and never moves, so it can be read
    // out of a blob of any other size.
    static_assert(offsetof(FotufilmState, version) == 0,
                  "the version must stay readable out of a blob of the wrong length");
    uint32_t version = 0;
    if (pluginState.length >= sizeof(version)) {
        [pluginState getBytes:&version length:sizeof(version)];
        if (version != kFotufilmStateVersion) {
            if (error) *error = FotufilmError(kFxError_InvalidDataLength,
                                              @"Fotufilm was handed a render state from another "
                                               "build; restart Final Cut Pro");
            return NO;
        }
    }
    if (pluginState.length != sizeof(FotufilmState)) {
        if (error) *error = FotufilmError(kFxError_InvalidDataLength,
                                          @"Fotufilm was handed a render state it cannot read");
        return NO;
    }
    FotufilmState state{};
    [pluginState getBytes:&state length:sizeof(state)];

    // The source is the whole image — that is what `sourceTileRect:` asked for — and the
    // destination is whatever tile the host wants filled, which is the whole image unless it
    // ignored `NeedsFullBuffer`.
    const Surface source = describe(sourceImages[0], sourceImages[0].imagePixelBounds);
    const Surface destination = describe(destinationImage, destinationImage.tilePixelBounds);
    if (!source.problem.empty()) {
        if (error) *error = FotufilmError(kFotufilmError_Surface,
                                          @"Fotufilm cannot read its input image: %s",
                                          source.problem.c_str());
        return NO;
    }
    if (!destination.problem.empty()) {
        if (error) *error = FotufilmError(kFotufilmError_Surface,
                                          @"Fotufilm cannot write its output image: %s",
                                          destination.problem.c_str());
        return NO;
    }
    if (!supported(source.format) || !supported(destination.format)) {
        if (error) *error =
            FotufilmError(kFotufilmError_Surface,
                          @"Fotufilm cannot read this pixel format (input %@, output %@)",
                          formatName(source.format), formatName(destination.format));
        return NO;
    }

    const int width = source.width;
    const int height = source.height;
    const int stage = (int)state.parameters[FOTUFILM_BRIDGE_STAGE];
    const bool readsInterchange = stage == FOTUFILM_BRIDGE_STAGE_PRINT;
    const bool writesInterchange = stage == FOTUFILM_BRIDGE_STAGE_NEGATIVE;
    const bool deliversSceneBasis = stage == FOTUFILM_BRIDGE_STAGE_TEXTURE;

    // Print Only is handed per-layer optical density, which carries no colour tag and no transfer
    // curve; Auto has nothing to read and must not guess.
    fotufilm::Encoding primaries = FotufilmMenuPrimaries(state.colorSpace);
    if (primaries == fotufilm::Encoding::Count) {
        if (readsInterchange) {
            if (error) *error = FotufilmError(
                kFotufilmError_ColourSpace,
                @"Print Only is handed optical density, which carries no colour space. "
                 "Set Timeline Color Space explicitly.");
            return NO;
        }
        primaries = [self encodingForImage:sourceImages[0]];
    }
    // The matrices are the choice's own; the transfer is always linear, because that is what the
    // plugin asked the host for and what it is therefore holding.
    const fotufilm::Encoding transfer = FotufilmLinearEncoding(primaries);

    const fotufilm::Transform transform = fotufilm::transformFor(primaries);
    // The texture span hands back light that never left the scene working space, so the way out of
    // it is the way in reversed, not the print's own path out of Display P3.
    fotufilm::Transform outputBasis = transform;
    if (deliversSceneBasis) {
        std::memcpy(outputBasis.fromWorking, transform.fromScene, sizeof(outputBasis.fromWorking));
    }

    // Final Cut composites premultiplied; the engine wants straight alpha, because developing a
    // matte that has already been folded into the colour puts the film's response on the wrong
    // side of the composite.
    const bool premultiplied = true;

    const FxRect destinationTile = destinationImage.tilePixelBounds;
    const FxRect destinationBounds = destinationImage.imagePixelBounds;
    const bool wholeFrame = destinationTile.left == destinationBounds.left &&
                            destinationTile.right == destinationBounds.right &&
                            destinationTile.bottom == destinationBounds.bottom &&
                            destinationTile.top == destinationBounds.top;

    if (!wholeFrame) {
        return [self serveTile:destinationImage
                        source:source
                   destination:destination
                         state:state
                     primaries:primaries
                      transfer:transfer
                     transform:transform
                   outputBasis:outputBasis
                  premultiplied:premultiplied
                    renderTime:renderTime
                         error:error];
    }

    return [self develop:state
                  source:source
             destination:destination
                encoding:transfer
               transform:transform
             outputBasis:outputBasis
           premultiplied:premultiplied
              renderTime:renderTime
                   width:width
                  height:height
        readsInterchange:readsInterchange
       writesInterchange:writesInterchange
                    into:nullptr
                   error:error];
}

/// Auto: the primaries the host is working in. The plugin asked for linear light in
/// `properties:error:`, so the transfer is identity either way and only the primaries are in
/// question — and the image carries the colour space it was made in, which is the one thing the
/// render can still ask.
///
/// Matched on the name rather than against the constants, because the constant a linear wide-gamut
/// space arrives as is not fixed: Core Graphics has several spellings of Rec.2020 and of P3, and
/// the extended-range linear variants are the ones a scene-referred host is most likely to hand
/// over. The substring is what they agree on.
- (fotufilm::Encoding)encodingForImage:(FxImageTile *)image {
    CGColorSpaceRef space = image.colorSpace;
    NSString *name = space ? (__bridge_transfer NSString *)CGColorSpaceCopyName(space) : nil;
    if (name.length == 0) {
        // A space with no name is read as Rec.709, which is what an image whose space does not
        // name itself is far more likely to be than anything wider — but it is a guess, and a
        // guess is said once here and kept for the status line.
        _unnamedSpace = true;
        if (!_warnedUnnamedSpace.exchange(true)) {
            NSLog(@"Fotufilm: the clip's colour space has no name; reading it as linear Rec.709. "
                  @"Set Timeline Color Space to the space this clip is actually in.");
        }
        return fotufilm::Encoding::LinearRec709;
    }
    _unnamedSpace = false;
    if ([name containsString:@"2020"]) return fotufilm::Encoding::LinearRec2020;
    if ([name containsString:@"P3"]) return fotufilm::Encoding::LinearDisplayP3;
    // A standard-gamut library is Rec.709. Naming the space explicitly is the way out of guessing.
    return fotufilm::Encoding::LinearRec709;
}

/// Develops one whole frame. With `into` non-null the developed pixels are kept there — the frame
/// a tiled host cuts from — instead of being written straight to the destination surface.
/// `encoding` names the transfer, which is linear on every road in; the matrices are `transform`'s.
- (BOOL)develop:(FotufilmState)state
           source:(const Surface &)source
      destination:(const Surface &)destination
         encoding:(fotufilm::Encoding)encoding
        transform:(const fotufilm::Transform &)transform
      outputBasis:(const fotufilm::Transform &)outputBasis
    premultiplied:(bool)premultiplied
       renderTime:(CMTime)renderTime
            width:(int)width
           height:(int)height
 readsInterchange:(bool)readsInterchange
writesInterchange:(bool)writesInterchange
             into:(std::vector<float> *)into
            error:(NSError **)error {
    const size_t pixels = (size_t)width * height;

    // The whole frame is about to be written; the surface it goes into has already been checked
    // against its own bounds, and this checks those bounds against the frame.
    if (!into && (destination.width < width || destination.height < height)) {
        if (error) *error = FotufilmError(kFotufilmError_Surface,
                                          @"Fotufilm cannot write its output image: it is %dx%d "
                                           "but the frame is %dx%d",
                                          destination.width, destination.height, width, height);
        return NO;
    }

    // Claim the engine's own frame staging if it fits. When it does the pixels never cross the
    // host/device boundary; when it does not, the frame is too large for one pass and the striped
    // path develops it instead. The choice is the engine's, not a policy here.
    float *stagedInput = nullptr;
    float *stagedOutput = nullptr;
    const bool staged =
        fotufilm_bridge_frame_staging(_bridge, width, height, &stagedInput, &stagedOutput) == 1;
    // The staging stays borrowed until the developed frame has been copied out, and must be
    // returned on every exit after this point — including one that fails before the engine runs.
    struct Release {
        FotufilmBridgeContext context;
        bool active;
        ~Release() { if (active) fotufilm_bridge_release_staging(context); }
    } release{_bridge, staged};

    if (!staged) _scene.resize(pixels * 4);
    float *scene = staged ? stagedInput : _scene.data();

    fotufilm::InputTransform inputCurve = fotufilm::inputTransformFor(encoding);
    FotufilmInputTransform inputTransform{};
    inputTransform.transfer = inputCurve.shape;
    inputTransform.premultiplied = premultiplied ? 1 : 0;
    std::memcpy(inputTransform.matrix, transform.toWorking, sizeof(inputTransform.matrix));
    std::memcpy(inputTransform.coefficients, inputCurve.coefficients,
                sizeof(inputTransform.coefficients));

    float peak = 0;
    int32_t repaired = 0;

    if (readsInterchange) {
        // Print Only is handed per-layer optical density. It is not a display encoding and it is
        // not light: decoding it would put a transfer curve on a density.
        read(source, scene);
    } else if (staged) {
        // The output staging is the frame-sized scratch: idle until the render fills it, and
        // overwritten by the render regardless. Reading and writing one buffer instead would
        // leave the result depending on which kernel the scheduler ran first.
        read(source, stagedOutput);
        if (fotufilm_bridge_decode_staged(_bridge, width, height, &inputTransform,
                                         &peak, &repaired) != 1) {
            if (error) *error = FotufilmError(kFotufilmError_Render,
                                              @"Fotufilm could not decode the frame: %@",
                                              FotufilmBridgeError(_bridge));
            return NO;
        }
    } else {
        read(source, scene);
        // Bands, because Halide takes host memory across the device boundary and back, and a
        // frame with no staging is a frame with little to spare. The decode is pointwise, so a
        // band's answer does not depend on how the frame was banded.
        const int band = decodeBandRows(width);
        std::vector<float> scratch((size_t)band * width * 4);
        for (int y = 0; y < height; y += band) {
            const int rows = std::min(band, height - y);
            float *from = scene + (size_t)y * width * 4;
            float bandPeak = 0;
            int32_t bandRepaired = 0;
            if (fotufilm_bridge_decode_rows(from, scratch.data(), width, rows, &inputTransform,
                                           &bandPeak, &bandRepaired) != 1) {
                if (error) *error = FotufilmError(kFotufilmError_Render,
                                                  @"Fotufilm could not decode the frame: %@",
                                                  FotufilmBridgeError(_bridge));
                return NO;
            }
            std::memcpy(from, scratch.data(), (size_t)rows * width * 4 * sizeof(float));
            peak = std::fmax(peak, bandPeak);
            repaired |= bandRepaired;
        }
    }

    if (repaired && !_warnedNonFinite.exchange(true)) {
        NSLog(@"Fotufilm: the input carried non-finite pixels; they were replaced with black.");
    }
    // Use 1.05 instead of 1.0 to avoid warnings for legal-white overshoot from codec ringing.
    if (peak > 1.05f && !_warnedOverRange.exchange(true)) {
        NSLog(@"Fotufilm: the input peaks at %.3f. If that is display-referred rather than scene "
              @"light, set Timeline Color Space to the space this clip is actually in.", peak);
    }

    // Whether the engine can carry the host's own last step — the matrix out of the print's
    // delivery basis and the transfer encode — in the kernel that produced the pixel. Asked
    // before the render, never read out of it afterwards: `fotufilm_bridge_render` streams its
    // rows as it develops them, so a caller that only learned on return would already have
    // written the frame out under the wrong reading.
    //
    // The flag is what `fotufilm_bridge_render_staged` will be given, which is the contract
    // `FotufilmBridge.h` states and the same expression the OFX plugin uses: only a staged render
    // can take the kernel that measures its own glare, so a striped frame asks as a delivered
    // one whatever the host said about the session. Passing the ungated flag would ask about a
    // road this frame is not taking.
    const bool interactive = state.quality < (uint32_t)kFotufilmDeliveryQuality;
    const bool encodeInKernel =
        !writesInterchange &&
        fotufilm_bridge_encodes_output(_bridge, state.stock, state.format, state.paper,
                                      state.parameters, width, height,
                                      (staged && interactive) ? 1 : 0) != 0;

    fotufilm::OutputTransform outputCurve = fotufilm::outputTransformFor(encoding);
    FotufilmOutputTransform outputTransform{};
    outputTransform.transfer = outputCurve.shape;
    outputTransform.premultiplied = premultiplied ? 1 : 0;
    std::memcpy(outputTransform.matrix, outputBasis.fromWorking, sizeof(outputTransform.matrix));
    std::memcpy(outputTransform.coefficients, outputCurve.coefficients,
                sizeof(outputTransform.coefficients));

    // A negative span emits per-layer density, which no transfer encodes; the engine already
    // encoded everything else when the gate above opened. Either way the pixels are final.
    const bool verbatim = encodeInKernel || writesInterchange;
    // Grain advances with the frame, so the engine wants a number that is the same every time this
    // frame is developed and different for the next one. `renderTime.value` is exactly that, and it
    // is the only such number available here: converting to a frame index would need the sequence's
    // frame rate, which is the host's to tell and the render's not to ask. Rescaling to seconds
    // would be worse than useless — every frame of a second would share a grain pattern.
    const uint64_t frame = (uint64_t)llabs(renderTime.value);

    // FOTUFILM_TRACE_BRIDGE: the same line, in the same format, as the OFX plugin prints. See
    // there for why.
    if (getenv("FOTUFILM_TRACE_BRIDGE")) {
        std::string trace = "TRACE stock=" + std::to_string(state.stock) +
            " format=" + std::to_string(state.format) + " paper=" + std::to_string(state.paper) +
            " seed=" + std::to_string(state.seed) +
            " frame=" + std::to_string(frame) +
            " size=" + std::to_string(width) + "x" + std::to_string(height) +
            " interactive=" + std::to_string(interactive ? 1 : 0) +
            " staged=" + std::to_string(staged ? 1 : 0) +
            " encode=" + std::to_string(encodeInKernel ? 1 : 0);
        char number[64];
        trace += " params=";
        for (int i = 0; i < FOTUFILM_BRIDGE_PARAMETER_COUNT; ++i) {
            snprintf(number, sizeof(number), "%.9g,", state.parameters[i]);
            trace += number;
        }
        trace += " in.transfer=" + std::to_string(inputTransform.transfer) +
                 " in.premul=" + std::to_string(inputTransform.premultiplied) + " in.m=";
        for (float v : inputTransform.matrix) {
            snprintf(number, sizeof(number), "%.9g,", v); trace += number;
        }
        trace += " in.c=";
        for (float v : inputTransform.coefficients) {
            snprintf(number, sizeof(number), "%.9g,", v); trace += number;
        }
        trace += " out.transfer=" + std::to_string(outputTransform.transfer) +
                 " out.premul=" + std::to_string(outputTransform.premultiplied) + " out.m=";
        for (float v : outputTransform.matrix) {
            snprintf(number, sizeof(number), "%.9g,", v); trace += number;
        }
        trace += " out.c=";
        for (float v : outputTransform.coefficients) {
            snprintf(number, sizeof(number), "%.9g,", v); trace += number;
        }
        fprintf(stderr, "%s\n", trace.c_str());
    }

    int32_t developed = 0;
    if (staged) {
        developed = fotufilm_bridge_render_staged(
            _bridge, state.stock, state.format, state.paper, state.parameters, state.seed,
            width, height, frame, interactive ? 1 : 0,
            encodeInKernel ? &outputTransform : nullptr, nullptr, nullptr);
    } else {
        // The striped path streams rows back into their own buffer: the engine is still reading
        // the scene it was handed while the developed rows arrive.
        _output.resize(pixels * 4);
        struct Gather {
            float *frame;
            int width;
        } gather{_output.data(), width};
        developed = fotufilm_bridge_render(
            _bridge, state.stock, state.format, state.paper, state.parameters, state.seed,
            scene, width, height, frame,
            [](void *context, int32_t begin, int32_t end, const float *rows) {
                Gather *g = (Gather *)context;
                std::memcpy(g->frame + (size_t)begin * g->width * 4, rows,
                            (size_t)(end - begin) * g->width * 4 * sizeof(float));
            },
            &gather, encodeInKernel ? &outputTransform : nullptr, nullptr, nullptr);
    }

    if (developed <= 0) {
        if (error) *error = FotufilmError(kFotufilmError_Render, @"Fotufilm render failed: %@",
                                          FotufilmBridgeError(_bridge));
        return NO;
    }

    float *result = staged ? stagedOutput : _output.data();
    if (!verbatim) {
        fotufilm::encodePixels(encoding, outputBasis, result, result, (int)pixels, premultiplied);
    }

    if (into) {
        into->assign(result, result + pixels * 4);
    } else {
        write(destination, result, width, 0, 0, width, height);
    }
    return YES;
}

/// A destination tile smaller than its image. `kFxPropertyKey_NeedsFullBuffer` asks the host not
/// to do this, but a host is free to anyway, and the answer cannot be "develop the tile" — every
/// spatial stage reads outside it, so tiles developed separately do not join. The whole frame is
/// developed once, kept, and cut from.
- (BOOL)serveTile:(FxImageTile *)destinationImage
           source:(const Surface &)source
      destination:(const Surface &)destination
            state:(FotufilmState)state
        primaries:(fotufilm::Encoding)primaries
         transfer:(fotufilm::Encoding)transfer
        transform:(const fotufilm::Transform &)transform
      outputBasis:(const fotufilm::Transform &)outputBasis
    premultiplied:(bool)premultiplied
       renderTime:(CMTime)renderTime
            error:(NSError **)error {
    const FxRect bounds = destinationImage.imagePixelBounds;
    const FxRect tile = destinationImage.tilePixelBounds;

    // The frame is identified by everything that changes a pixel: the state block, the time, the
    // frame's size, the colour space — and the picture itself. The picture has to be in there
    // because the parameters can stand still while the clip under them moves: an upstream change
    // with the playhead parked re-renders the same time with the same state over different
    // pixels, and a key without the pixels in it would hand back the frame developed before the
    // change.
    //
    // The cheap terms are compared first and the pixels are read only when they can still change
    // the answer. On playback the time moves every frame, so the cheap half has already said
    // "different frame" and hashing eight million pixels in front of the render could not have
    // said anything else; the hash is taken after the develop instead, to seal the key the tiles
    // after this one will hit on.
    //
    // What is *not* done is asking IOSurface's seed instead. `IOSurfaceRef.h` describes the seed
    // as the value "at the time of the unlock", incremented "as the unlock is performed" on a
    // buffer that was locked for writing — it counts CPU lock/unlock pairs and says nothing about
    // a GPU or other hardware write. A Metal stage upstream rewriting a pooled surface bumps
    // nothing, and a plugin that trusted the seed would serve this frame's tiles for the next
    // frame's pixels.
    NSMutableData *key = [NSMutableData dataWithBytes:&state length:sizeof(state)];
    [key appendBytes:&renderTime length:sizeof(renderTime)];
    [key appendBytes:&bounds length:sizeof(bounds)];
    [key appendBytes:&primaries length:sizeof(primaries)];

    // `lock` is already held: the render entry point takes it for the whole frame.
    const BOOL sameSettings = self.cacheKey && [self.cacheKey isEqualToData:key] &&
                              _developed.size() == (size_t)source.width * source.height * 4;
    uint64_t content = 0;
    BOOL hashed = NO;
    BOOL hit = NO;
    if (sameSettings && _haveCachedContent) {
        content = contentHash(source);
        hashed = YES;
        hit = content == _cachedContent;
    }
    if (!hit) {
        self.cacheKey = nil;
        _haveCachedContent = NO;
        const int stage = (int)state.parameters[FOTUFILM_BRIDGE_STAGE];
        if (![self develop:state
                    source:source
               destination:destination
                  encoding:transfer
                 transform:transform
               outputBasis:outputBasis
             premultiplied:premultiplied
                renderTime:renderTime
                     width:source.width
                    height:source.height
          readsInterchange:stage == FOTUFILM_BRIDGE_STAGE_PRINT
         writesInterchange:stage == FOTUFILM_BRIDGE_STAGE_NEGATIVE
                      into:&_developed
                     error:error]) {
            return NO;
        }
        // Sealed only now. A develop that failed leaves no key and pays for no hash; a develop
        // that the cheap half of the key had already decided on pays for its hash here rather
        // than in front of the render it was never going to prevent.
        if (!hashed) content = contentHash(source);
        _cachedContent = content;
        _haveCachedContent = YES;
        self.cacheKey = key;
    }

    // Which edge the surface's first row belongs to is the image's to say, and both answers occur:
    // a bottom-up image measures the tile's offset from the image's bottom, a top-down one from its
    // top. Getting this backwards puts the right pixels in the wrong half of the frame, which on a
    // two-band render looks like the picture cut and swapped.
    const int columnOffset = tile.left - bounds.left;
    const int rowOffset = destinationImage.imageOrigin == kFxImageOrigin_TOP_LEFT
                              ? bounds.top - tile.top
                              : tile.bottom - bounds.bottom;
    const int tileWidth = std::min(destination.width, source.width - columnOffset);
    const int tileHeight = std::min(destination.height, source.height - rowOffset);
    if (columnOffset < 0 || rowOffset < 0 || tileWidth <= 0 || tileHeight <= 0) {
        if (error) *error = FotufilmError(kFotufilmError_Surface,
                                          @"Fotufilm was asked for a tile outside the frame");
        return NO;
    }

    const float *from = _developed.data() +
                        ((size_t)rowOffset * source.width + columnOffset) * 4;
    write(destination, from, source.width, 0, 0, tileWidth, tileHeight);
    return YES;
}

@end
