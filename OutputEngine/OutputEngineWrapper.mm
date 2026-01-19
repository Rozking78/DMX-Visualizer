// OutputEngineWrapper.mm - Objective-C++ implementation bridging C++ output engine to Swift

#import "include/OutputEngineWrapper.h"
#import "output_display.h"
#import "output_ndi.h"
#import "switcher_frame.h"
#include <memory>

#pragma mark - GDCropRegion

@implementation GDCropRegion

+ (instancetype)fullFrame {
    return [[GDCropRegion alloc] initWithX:0 y:0 width:1 height:1];
}

- (instancetype)initWithX:(float)x y:(float)y width:(float)w height:(float)h {
    if (self = [super init]) {
        _x = x;
        _y = y;
        _width = w;
        _height = h;
    }
    return self;
}

- (instancetype)init {
    return [self initWithX:0 y:0 width:1 height:1];
}

@end

#pragma mark - GDEdgeBlendParams

@implementation GDEdgeBlendParams

+ (instancetype)disabled {
    return [[GDEdgeBlendParams alloc] initWithLeft:0 right:0 top:0 bottom:0];
}

- (instancetype)initWithLeft:(float)left right:(float)right top:(float)top bottom:(float)bottom {
    if (self = [super init]) {
        _leftFeather = left;
        _rightFeather = right;
        _topFeather = top;
        _bottomFeather = bottom;
        _gamma = 2.2f;
        _power = 1.0f;
        _blackLevel = 0.0f;
        // 8-point warp defaults (no warp)
        _warpTopLeftX = 0.0f;
        _warpTopLeftY = 0.0f;
        _warpTopMiddleX = 0.0f;
        _warpTopMiddleY = 0.0f;
        _warpTopRightX = 0.0f;
        _warpTopRightY = 0.0f;
        _warpMiddleLeftX = 0.0f;
        _warpMiddleLeftY = 0.0f;
        _warpMiddleRightX = 0.0f;
        _warpMiddleRightY = 0.0f;
        _warpBottomLeftX = 0.0f;
        _warpBottomLeftY = 0.0f;
        _warpBottomMiddleX = 0.0f;
        _warpBottomMiddleY = 0.0f;
        _warpBottomRightX = 0.0f;
        _warpBottomRightY = 0.0f;
        // Lens defaults (no distortion)
        _lensK1 = 0.0f;
        _lensK2 = 0.0f;
        _lensCenterX = 0.5f;
        _lensCenterY = 0.5f;
        // Corner overlay off by default
        _activeCorner = 0;
    }
    return self;
}

- (instancetype)init {
    return [self initWithLeft:0 right:0 top:0 bottom:0];
}

@end

#pragma mark - GDDisplayInfo

@interface GDDisplayInfo ()
@property (nonatomic, readwrite) uint32_t displayId;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) uint32_t width;
@property (nonatomic, readwrite) uint32_t height;
@property (nonatomic, readwrite) float refreshRate;
@property (nonatomic, readwrite) BOOL isMain;
@end

@implementation GDDisplayInfo
@end

#pragma mark - GDDisplayOutput

@implementation GDDisplayOutput {
    std::unique_ptr<RocKontrol::DisplayOutput> _impl;
    id<MTLDevice> _device;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (self = [super init]) {
        _device = device;
        _impl = std::make_unique<RocKontrol::DisplayOutput>(device);
    }
    return self;
}

- (void)dealloc {
    if (_impl) {
        _impl->stop();
    }
}

- (BOOL)configureWithDisplayId:(uint32_t)displayId
                    fullscreen:(BOOL)fullscreen
                         vsync:(BOOL)vsync
                         label:(NSString *)label {
    if (!_impl) return NO;

    RocKontrol::DisplayOutputConfig config;
    config.display_id = displayId;
    config.fullscreen = fullscreen;
    config.vsync = vsync;
    if (label) {
        config.label = [label UTF8String];
    }

    return _impl->configure(config);
}

- (BOOL)start {
    return _impl ? _impl->start() : NO;
}

- (void)stop {
    if (_impl) _impl->stop();
}

- (BOOL)isRunning {
    return _impl ? _impl->isRunning() : NO;
}

- (BOOL)pushFrameWithTexture:(id<MTLTexture>)texture
                   timestamp:(uint64_t)timestamp
                   frameRate:(float)frameRate {
    if (!_impl || !texture) return NO;

    RocKontrol::SwitcherFrame frame;
    frame.texture = texture;
    frame.width = (uint32_t)texture.width;
    frame.height = (uint32_t)texture.height;
    frame.timestamp_ns = timestamp;
    frame.frame_rate = frameRate;
    frame.valid = true;
    frame.interlaced = false;
    frame.top_field_first = true;

    return _impl->pushFrame(frame);
}

- (void)setCrop:(GDCropRegion *)crop {
    if (!crop || !_impl) return;
    _impl->setCrop(crop.x, crop.y, crop.width, crop.height);
}

- (void)setEdgeBlend:(GDEdgeBlendParams *)params {
    if (!params || !_impl) return;
    _impl->setEdgeBlend(params.leftFeather, params.rightFeather,
                        params.topFeather, params.bottomFeather,
                        params.gamma, params.power, params.blackLevel,
                        1.0f, 1.0f, 1.0f,  // gammaR, gammaG, gammaB
                        params.warpTopLeftX, params.warpTopLeftY,
                        params.warpTopMiddleX, params.warpTopMiddleY,
                        params.warpTopRightX, params.warpTopRightY,
                        params.warpMiddleLeftX, params.warpMiddleLeftY,
                        params.warpMiddleRightX, params.warpMiddleRightY,
                        params.warpBottomLeftX, params.warpBottomLeftY,
                        params.warpBottomMiddleX, params.warpBottomMiddleY,
                        params.warpBottomRightX, params.warpBottomRightY,
                        params.warpCurvature,
                        params.lensK1, params.lensK2,
                        params.lensCenterX, params.lensCenterY,
                        params.activeCorner,
                        params.enableEdgeBlend, params.enableWarp,
                        params.enableLensCorrection, params.enableCurveWarp);
}

- (void)setIntensity:(float)intensity {
    if (_impl) _impl->setIntensity(intensity);
}

- (GDOutputType)type {
    return GDOutputTypeDisplay;
}

- (NSString *)name {
    if (!_impl) return @"Display";
    return [NSString stringWithUTF8String:_impl->name().c_str()];
}

- (GDOutputStatus)status {
    if (!_impl) return GDOutputStatusStopped;
    switch (_impl->status()) {
        case RocKontrol::OutputStatus::Stopped: return GDOutputStatusStopped;
        case RocKontrol::OutputStatus::Starting: return GDOutputStatusStarting;
        case RocKontrol::OutputStatus::Running: return GDOutputStatusRunning;
        case RocKontrol::OutputStatus::Error: return GDOutputStatusError;
    }
    return GDOutputStatusStopped;
}

- (uint32_t)width {
    return _impl ? _impl->width() : 0;
}

- (uint32_t)height {
    return _impl ? _impl->height() : 0;
}

- (float)frameRate {
    return _impl ? _impl->frameRate() : 0;
}

- (BOOL)setName:(NSString *)name {
    if (!_impl || !name) return NO;
    return _impl->setName([name UTF8String]);
}

- (BOOL)setResolutionWidth:(uint32_t)width height:(uint32_t)height {
    if (!_impl) return NO;
    return _impl->setResolution(width, height);
}

- (uint32_t)nativeWidth {
    return _impl ? _impl->nativeWidth() : 0;
}

- (uint32_t)nativeHeight {
    return _impl ? _impl->nativeHeight() : 0;
}

@end

#pragma mark - GDNDIOutput

@implementation GDNDIOutput {
    std::unique_ptr<RocKontrol::NDIOutput> _impl;
    id<MTLDevice> _device;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (self = [super init]) {
        _device = device;
        _impl = std::make_unique<RocKontrol::NDIOutput>(device);
    }
    return self;
}

- (void)dealloc {
    if (_impl) {
        _impl->stop();
    }
}

- (BOOL)configureWithSourceName:(NSString *)sourceName
                         groups:(NSString *)groups
               networkInterface:(NSString *)networkInterface
                     clockVideo:(BOOL)clockVideo
                 asyncQueueSize:(uint32_t)queueSize {
    if (!_impl) return NO;

    RocKontrol::NDIOutputConfig config;
    config.source_name = sourceName ? [sourceName UTF8String] : "GeoDraw";
    if (groups) {
        config.groups = [groups UTF8String];
    }
    if (networkInterface) {
        config.network_interface = [networkInterface UTF8String];
    }
    config.clock_video = clockVideo;
    config.async_queue_size = queueSize;

    return _impl->configure(config);
}

- (BOOL)start {
    return _impl ? _impl->start() : NO;
}

- (void)stop {
    if (_impl) _impl->stop();
}

- (BOOL)isRunning {
    return _impl ? _impl->isRunning() : NO;
}

- (BOOL)pushFrameWithTexture:(id<MTLTexture>)texture
                   timestamp:(uint64_t)timestamp
                   frameRate:(float)frameRate {
    if (!_impl || !texture) return NO;

    RocKontrol::SwitcherFrame frame;
    frame.texture = texture;
    frame.width = (uint32_t)texture.width;
    frame.height = (uint32_t)texture.height;
    frame.timestamp_ns = timestamp;
    frame.frame_rate = frameRate;
    frame.valid = true;
    frame.interlaced = false;
    frame.top_field_first = true;

    return _impl->pushFrame(frame);
}

- (BOOL)pushPixelData:(const uint8_t *)data
                width:(uint32_t)width
               height:(uint32_t)height
            timestamp:(uint64_t)timestamp
            frameRate:(float)frameRate {
    if (!_impl || !data) return NO;
    return _impl->pushPixelData(data, width, height, timestamp, frameRate);
}

- (void)setCrop:(GDCropRegion *)crop {
    if (!crop || !_impl) return;
    _impl->setCrop(crop.x, crop.y, crop.width, crop.height);
}

- (void)setEdgeBlend:(GDEdgeBlendParams *)params {
    if (!params || !_impl) return;

    // Debug: log middle warp values when they're non-zero
    if (params.warpTopMiddleX != 0 || params.warpTopMiddleY != 0 ||
        params.warpMiddleLeftX != 0 || params.warpMiddleRightX != 0) {
        NSLog(@"GDNDIOutput.setEdgeBlend: Middle warp - TM(%.1f,%.1f) ML(%.1f,%.1f) MR(%.1f,%.1f) BM(%.1f,%.1f)",
              params.warpTopMiddleX, params.warpTopMiddleY,
              params.warpMiddleLeftX, params.warpMiddleLeftY,
              params.warpMiddleRightX, params.warpMiddleRightY,
              params.warpBottomMiddleX, params.warpBottomMiddleY);
    }

    _impl->setEdgeBlend(params.leftFeather, params.rightFeather,
                        params.topFeather, params.bottomFeather,
                        params.gamma, params.power, params.blackLevel,
                        1.0f, 1.0f, 1.0f,  // gammaR, gammaG, gammaB
                        params.warpTopLeftX, params.warpTopLeftY,
                        params.warpTopMiddleX, params.warpTopMiddleY,
                        params.warpTopRightX, params.warpTopRightY,
                        params.warpMiddleLeftX, params.warpMiddleLeftY,
                        params.warpMiddleRightX, params.warpMiddleRightY,
                        params.warpBottomLeftX, params.warpBottomLeftY,
                        params.warpBottomMiddleX, params.warpBottomMiddleY,
                        params.warpBottomRightX, params.warpBottomRightY,
                        params.warpCurvature,
                        params.lensK1, params.lensK2,
                        params.lensCenterX, params.lensCenterY,
                        params.activeCorner,
                        params.enableEdgeBlend, params.enableWarp,
                        params.enableLensCorrection, params.enableCurveWarp);
}

- (void)setIntensity:(float)intensity {
    if (_impl) _impl->setIntensity(intensity);
}

- (void)setTargetFrameRate:(float)fps {
    if (_impl) _impl->setTargetFrameRate(fps);
}

- (float)targetFrameRate {
    return _impl ? _impl->targetFrameRate() : 0.0f;
}

- (void)setLegacyMode:(BOOL)enabled {
    if (_impl) _impl->setLegacyMode(enabled);
}

- (BOOL)isLegacyMode {
    return _impl ? _impl->isLegacyMode() : NO;
}

- (GDOutputType)type {
    return GDOutputTypeNDI;
}

- (NSString *)name {
    if (!_impl) return @"NDI";
    return [NSString stringWithUTF8String:_impl->name().c_str()];
}

- (GDOutputStatus)status {
    if (!_impl) return GDOutputStatusStopped;
    switch (_impl->status()) {
        case RocKontrol::OutputStatus::Stopped: return GDOutputStatusStopped;
        case RocKontrol::OutputStatus::Starting: return GDOutputStatusStarting;
        case RocKontrol::OutputStatus::Running: return GDOutputStatusRunning;
        case RocKontrol::OutputStatus::Error: return GDOutputStatusError;
    }
    return GDOutputStatusStopped;
}

- (uint32_t)width {
    return _impl ? _impl->width() : 0;
}

- (uint32_t)height {
    return _impl ? _impl->height() : 0;
}

- (float)frameRate {
    return _impl ? _impl->frameRate() : 0;
}

- (uint64_t)framesSent {
    return _impl ? _impl->framesSent() : 0;
}

- (uint64_t)framesDropped {
    return _impl ? _impl->framesDropped() : 0;
}

- (BOOL)setName:(NSString *)name {
    if (!_impl || !name) return NO;
    return _impl->setName([name UTF8String]);
}

- (BOOL)setResolutionWidth:(uint32_t)width height:(uint32_t)height {
    if (!_impl) return NO;
    return _impl->setResolution(width, height);
}

@end

#pragma mark - Utility Functions

NSArray<GDDisplayInfo *> *GDListDisplays(void) {
    std::vector<RocKontrol::DisplayInfo> displays = RocKontrol::listDisplays();

    NSMutableArray<GDDisplayInfo *> *result = [NSMutableArray arrayWithCapacity:displays.size()];

    for (const auto& info : displays) {
        GDDisplayInfo *gdInfo = [[GDDisplayInfo alloc] init];
        gdInfo.displayId = info.display_id;
        gdInfo.name = [NSString stringWithUTF8String:info.name.c_str()];
        gdInfo.width = info.width;
        gdInfo.height = info.height;
        gdInfo.refreshRate = info.refresh_rate;
        gdInfo.isMain = info.is_main;
        [result addObject:gdInfo];
    }

    return result;
}
