// Minimal FxPlug 4 SDK stub for compiling the engine-facing test harness without Apple's separate
// SDK download. Binaries built against this header cannot be loaded by Final Cut Pro.
// Declarations were checked against the installed SDK, but `finalcut/build.sh` remains authoritative
// because it compiles the same source against Apple's headers.

#ifndef FOTUFILM_FXPLUG_STUB_H
#define FOTUFILM_FXPLUG_STUB_H

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#import <IOSurface/IOSurfaceObjC.h>

typedef struct FxRect { SInt32 left; SInt32 bottom; SInt32 right; SInt32 top; } FxRect;

enum { kFxQuality_LOW = 0, kFxQuality_MEDIUM = 1, kFxQuality_HIGH = 2 };
typedef NSUInteger FxQuality;

enum {
    kFxParameterFlag_DEFAULT = 0,
    kFxParameterFlag_NOT_ANIMATABLE = 1 << 0,
    kFxParameterFlag_HIDDEN = 1 << 1,
    kFxParameterFlag_DISABLED = 1 << 2,
    kFxParameterFlag_COLLAPSED = 1 << 3,
};
typedef UInt32 FxParameterFlags;

enum { kFxImageColorInfo_RGB_LINEAR = 0, kFxImageColorInfo_RGB_GAMMA_VIDEO = 2 };
typedef NSUInteger FxImageColorInfo;

enum { kFxColorPrimaries_Rec709 = 0, kFxColorPrimaries_Rec2020 };
typedef NSUInteger FxColorPrimaries;

enum { kFxImageOrigin_BOTTOM_LEFT = 0, kFxImageOrigin_TOP_LEFT = 2 };
typedef NSUInteger FxImageOrigin;

enum {
    kFxPixelTransform_Scale = 1,
    kFxPixelTransform_ScaleTranslate = 3,
    kFxPixelTransform_Full = 6,
};

#define kFxPropertyKey_MayRemapTime @"MayRemapTime"
#define kFxPropertyKey_DesiredProcessingColorInfo @"DesiredProcessingColorInfo"
#define kFxPropertyKey_NeedsFullBuffer @"NeedsFullBuffer"
#define kFxPropertyKey_ChangesOutputSize @"ChangesOutputSize"
#define kFxPropertyKey_VariesWhenParamsAreStatic @"VariesWhenParamsAreStatic"
#define kFxPropertyKey_PixelTransformSupport @"PixelTransformSupport"

/// The SDK declares the domain and leaves its definition to the framework; the harness defines
/// it, because nothing links the framework there.
extern NSString *FxPlugErrorDomain;

/// The SDK's error codes, in its order. Only the values this plugin uses need to be right, but
/// the whole run is kept so that the numbering matches the real header.
enum {
    kFxError_Success = 0,
    kFxError_InvalidParameterID,
    kFxError_InvalidParameterChannelIndex,
    kFxError_InvalidKeyframeIndex,
    kFxError_InvalidTime,
    kFxError_InvalidParameter,
    kFxError_OutOfMemory,
    kFxError_MemoryNotAllocated,
    kFxError_OpenGLError,
    kFxError_InvalidPathID,
    kFxError_InvalidPathIndex,
    kFxError_InvalidSegmentIndex,
    kFxError_InvalidLightAccess,
    kFxError_InvalidPathStyle,
    kFxError_APIUnavailable,
    kFxError_InvalidDataLength,
    kFxError_PluginNotFound,
    kFxError_AnalysisExtensionNotFound,
    kFxError_NotYetImplemented,
    kFxError_UnableToCreateDynamicRegistrationEndpoint,
    kFxError_UnableToInstantiateDynamicRegistrar,
    kFxError_LostConnectionToPlugin,
    kFxError_AnalysisError,
    kFxError_HostUnreachable,
    kFxError_UserCancelled,
    kFxError_NoMediaFolder,
    kFxError_NoDocumentFound,
    kFxError_UnableToMovePlayhead,
    kFxError_NoViewFound,
    kFxError_InvalidTiming,
    kFxError_InvalidColorGamut,
    kFxError_InvalidPaths,
    kFxError_CommandNotProcessed,
    kFxError_UnableToObtainProjectAspectRatio,
    kFxError_ThirdPartyDeveloperStart = 100000
};
typedef NSInteger FxError;

@protocol PROAPIAccessing <NSObject>
- (id)apiForProtocol:(Protocol *)protocol;
@end

@interface FxImageTile : NSObject
@property(assign) IOSurface *ioSurface;
@property(assign) FxRect imagePixelBounds;
@property(assign) FxRect tilePixelBounds;
@property(assign) unsigned long long deviceRegistryID;
@property(assign) FxImageOrigin imageOrigin;
@property(assign) CGColorSpaceRef colorSpace;
@end

// Does not adopt NSObject, as the SDK's does not.
@protocol FxParameterCreationAPI_v5
- (BOOL)addFloatSliderWithName:(NSString *)name parameterID:(UInt32)parameterID
                  defaultValue:(double)v parameterMin:(double)a parameterMax:(double)b
                     sliderMin:(double)c sliderMax:(double)d delta:(double)e
                parameterFlags:(FxParameterFlags)f;
- (BOOL)addIntSliderWithName:(NSString *)name parameterID:(UInt32)parameterID
                defaultValue:(int)v parameterMin:(int)a parameterMax:(int)b
                   sliderMin:(int)c sliderMax:(int)d delta:(int)e
              parameterFlags:(FxParameterFlags)f;
- (BOOL)addToggleButtonWithName:(NSString *)name parameterID:(UInt32)parameterID
                   defaultValue:(BOOL)v parameterFlags:(FxParameterFlags)f;
- (BOOL)addPopupMenuWithName:(NSString *)name parameterID:(UInt32)parameterID
                defaultValue:(UInt32)v menuEntries:(NSArray *)entries
              parameterFlags:(FxParameterFlags)f;
- (BOOL)addStringParameterWithName:(NSString *)name parameterID:(UInt32)parameterID
                      defaultValue:(NSString *)v parameterFlags:(FxParameterFlags)f;
- (BOOL)startParameterSubGroup:(NSString *)name parameterID:(UInt32)parameterID
                parameterFlags:(FxParameterFlags)f;
- (BOOL)endParameterSubGroup;
@end

@protocol FxParameterRetrievalAPI_v6 <NSObject>
- (BOOL)getFloatValue:(double *)value fromParameter:(UInt32)parameterID atTime:(CMTime)time;
- (BOOL)getIntValue:(int *)value fromParameter:(UInt32)parameterID atTime:(CMTime)time;
- (BOOL)getBoolValue:(BOOL *)value fromParameter:(UInt32)parameterID atTime:(CMTime)time;
- (BOOL)getStringParameterValue:(NSString *_Nonnull *_Nullable)string
                  fromParameter:(UInt32)parameterID;
- (BOOL)getParameterFlags:(FxParameterFlags *)flags fromParameter:(UInt32)parameterID;
@end

@protocol FxParameterSettingAPI_v5 <NSObject>
- (BOOL)setStringParameterValue:(NSString *)string toParameter:(UInt32)parameterID;
- (BOOL)setFloatValue:(double)value toParameter:(UInt32)parameterID atTime:(CMTime)time;
- (BOOL)setIntValue:(int)value toParameter:(UInt32)parameterID atTime:(CMTime)time;
- (BOOL)setParameterFlags:(FxParameterFlags)flags toParameter:(UInt32)parameterID;
@end

/// `startAction:`/`endAction:` return nothing in the SDK; a host that answers them with a value
/// is a stub that has drifted. The protocol does not adopt NSObject — the SDK's does not either,
/// and a stub that adds it lets `respondsToSelector:` compile here and fail against the real
/// header, which is exactly the class of mistake this file exists to avoid.
@protocol FxCustomParameterActionAPI_v4
- (void)startAction:(id)sender;
- (void)endAction:(id)sender;
- (CMTime)currentTime;
@end

@protocol FxTileableEffect <NSObject>
- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;
- (BOOL)addParametersWithError:(NSError **)error;
- (BOOL)properties:(NSDictionary *_Nonnull *_Nullable)properties error:(NSError **)error;
- (BOOL)pluginState:(NSData *_Nonnull *_Nullable)pluginState atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel error:(NSError **)error;
- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState atTime:(CMTime)renderTime
                       error:(NSError **)error;
- (BOOL)sourceTileRect:(FxRect *)sourceTileRect sourceImageIndex:(NSUInteger)sourceImageIndex
          sourceImages:(NSArray<FxImageTile *> *)sourceImages
   destinationTileRect:(FxRect)destinationTileRect destinationImage:(FxImageTile *)destinationImage
           pluginState:(NSData *)pluginState atTime:(CMTime)renderTime error:(NSError **)error;
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState atTime:(CMTime)renderTime
                         error:(NSError **)error;
@optional
- (BOOL)parameterChanged:(UInt32)parameterID atTime:(CMTime)time error:(NSError **)error;
- (void)pluginInstanceAddedToDocument;
@end

#endif
