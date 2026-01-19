// OutputEngineWrapper.h - Objective-C bridge for Swift to access C++ output engine
// This header exposes the Switcher output engine to Swift via Objective-C interfaces

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Enums

typedef NS_ENUM(NSInteger, GDOutputType) {
    GDOutputTypeDisplay = 0,
    GDOutputTypeNDI = 1,
    GDOutputTypeSyphon = 2
};

typedef NS_ENUM(NSInteger, GDOutputStatus) {
    GDOutputStatusStopped = 0,
    GDOutputStatusStarting = 1,
    GDOutputStatusRunning = 2,
    GDOutputStatusError = 3
};

#pragma mark - Crop Region

@interface GDCropRegion : NSObject
@property (nonatomic) float x;      // 0-1 normalized
@property (nonatomic) float y;      // 0-1 normalized
@property (nonatomic) float width;  // 0-1 normalized
@property (nonatomic) float height; // 0-1 normalized
+ (instancetype)fullFrame;
- (instancetype)initWithX:(float)x y:(float)y width:(float)w height:(float)h;
@end

#pragma mark - Edge Blend Parameters

@interface GDEdgeBlendParams : NSObject
@property (nonatomic) float leftFeather;   // pixels
@property (nonatomic) float rightFeather;
@property (nonatomic) float topFeather;
@property (nonatomic) float bottomFeather;
@property (nonatomic) float gamma;         // 1.0-3.0, default 2.2
@property (nonatomic) float power;         // blend curve power, default 1.0
@property (nonatomic) float blackLevel;    // 0-1, default 0
// 8-point warp (pixel offsets from default positions)
@property (nonatomic) float warpTopLeftX;
@property (nonatomic) float warpTopLeftY;
@property (nonatomic) float warpTopMiddleX;
@property (nonatomic) float warpTopMiddleY;
@property (nonatomic) float warpTopRightX;
@property (nonatomic) float warpTopRightY;
@property (nonatomic) float warpMiddleLeftX;
@property (nonatomic) float warpMiddleLeftY;
@property (nonatomic) float warpMiddleRightX;
@property (nonatomic) float warpMiddleRightY;
@property (nonatomic) float warpBottomLeftX;
@property (nonatomic) float warpBottomLeftY;
@property (nonatomic) float warpBottomMiddleX;
@property (nonatomic) float warpBottomMiddleY;
@property (nonatomic) float warpBottomRightX;
@property (nonatomic) float warpBottomRightY;
// Lens distortion correction
@property (nonatomic) float lensK1;        // Primary radial (+ = pincushion, - = barrel)
@property (nonatomic) float lensK2;        // Secondary radial
@property (nonatomic) float lensCenterX;   // Distortion center X (0.5 = center)
@property (nonatomic) float lensCenterY;   // Distortion center Y (0.5 = center)
// Warp curvature (for curved/spherical surfaces)
@property (nonatomic) float warpCurvature; // Curvature amount (0 = linear, + = convex, - = concave)
// Corner overlay (0=none, 1=TL, 2=TR, 3=BL, 4=BR)
@property (nonatomic) int activeCorner;
// Per-output shader processing toggles (for CPU/GPU optimization)
@property (nonatomic) BOOL enableEdgeBlend;      // Enable edge blend feathering
@property (nonatomic) BOOL enableWarp;           // Enable 8-point warp
@property (nonatomic) BOOL enableLensCorrection; // Enable lens distortion correction
@property (nonatomic) BOOL enableCurveWarp;      // Enable curvature warp
+ (instancetype)disabled;
- (instancetype)initWithLeft:(float)left right:(float)right top:(float)top bottom:(float)bottom;
@end

#pragma mark - Display Info

@interface GDDisplayInfo : NSObject
@property (nonatomic, readonly) uint32_t displayId;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) float refreshRate;
@property (nonatomic, readonly) BOOL isMain;
@end

#pragma mark - Display Output

@interface GDDisplayOutput : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device;

// Configuration (call before start)
- (BOOL)configureWithDisplayId:(uint32_t)displayId
                    fullscreen:(BOOL)fullscreen
                         vsync:(BOOL)vsync
                         label:(nullable NSString *)label;

// Lifecycle
- (BOOL)start;
- (void)stop;
- (BOOL)isRunning;

// Frame push - returns immediately, GPU renders async
- (BOOL)pushFrameWithTexture:(id<MTLTexture>)texture
                   timestamp:(uint64_t)timestamp
                   frameRate:(float)frameRate;

// Crop and blend
- (void)setCrop:(GDCropRegion *)crop;
- (void)setEdgeBlend:(GDEdgeBlendParams *)params;

// Intensity (0-1, default 1.0 = full brightness)
- (void)setIntensity:(float)intensity;

// Properties
@property (nonatomic, readonly) GDOutputType type;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) GDOutputStatus status;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) float frameRate;

- (BOOL)setName:(NSString *)name;
- (BOOL)setResolutionWidth:(uint32_t)width height:(uint32_t)height;

// Native display resolution
@property (nonatomic, readonly) uint32_t nativeWidth;
@property (nonatomic, readonly) uint32_t nativeHeight;

@end

#pragma mark - NDI Output

@interface GDNDIOutput : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device;

// Configuration (call before start)
- (BOOL)configureWithSourceName:(NSString *)sourceName
                         groups:(nullable NSString *)groups
               networkInterface:(nullable NSString *)networkInterface
                     clockVideo:(BOOL)clockVideo
                 asyncQueueSize:(uint32_t)queueSize;

// Lifecycle
- (BOOL)start;
- (void)stop;
- (BOOL)isRunning;

// Frame push - adds to async queue, returns immediately
- (BOOL)pushFrameWithTexture:(id<MTLTexture>)texture
                   timestamp:(uint64_t)timestamp
                   frameRate:(float)frameRate;

// Push pre-rendered pixel data (for batch processing - no GPU work in send thread)
// Data must be BGRA format, width*height*4 bytes
- (BOOL)pushPixelData:(const uint8_t *)data
                width:(uint32_t)width
               height:(uint32_t)height
            timestamp:(uint64_t)timestamp
            frameRate:(float)frameRate;

// Crop and edge blend
- (void)setCrop:(GDCropRegion *)crop;
- (void)setEdgeBlend:(GDEdgeBlendParams *)params;

// Intensity (0-1, default 1.0 = full brightness)
- (void)setIntensity:(float)intensity;

// Target frame rate throttling (0 = unlimited, otherwise target fps)
- (void)setTargetFrameRate:(float)fps;
- (float)targetFrameRate;

// Legacy mode (synchronous sending, more compatible with some receivers)
- (void)setLegacyMode:(BOOL)enabled;
- (BOOL)isLegacyMode;

// Properties
@property (nonatomic, readonly) GDOutputType type;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) GDOutputStatus status;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) float frameRate;

// Statistics
@property (nonatomic, readonly) uint64_t framesSent;
@property (nonatomic, readonly) uint64_t framesDropped;

- (BOOL)setName:(NSString *)name;
- (BOOL)setResolutionWidth:(uint32_t)width height:(uint32_t)height;

@end

#pragma mark - Utility Functions

// List all available displays
NSArray<GDDisplayInfo *> *GDListDisplays(void);

NS_ASSUME_NONNULL_END
