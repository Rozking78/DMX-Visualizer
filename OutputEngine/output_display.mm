// output_display.mm - Display output sink implementation
// Renders directly to physical displays via Metal

#import "output_display.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#include <vector>

namespace RocKontrol {

// Metal shader for display rendering with output warp (keystone) support
// Warp defines the visible region - content outside is black (keystone borders)
// This creates proper keystone correction with black borders when corners are pushed in
static NSString* const kDisplayShaderSource = @R"(
    #include <metal_stdlib>
    using namespace metal;

    // Parameters for crop and warp
    struct DisplayParams {
        // Crop region (normalized 0-1)
        float cropX;
        float cropY;
        float cropW;
        float cropH;
        // 8-point warp offsets (normalized -1 to 1, where display is -1 to 1)
        float2 warpTL;  // Top-left offset
        float2 warpTM;  // Top-middle offset
        float2 warpTR;  // Top-right offset
        float2 warpML;  // Middle-left offset
        float2 warpMR;  // Middle-right offset
        float2 warpBL;  // Bottom-left offset
        float2 warpBM;  // Bottom-middle offset
        float2 warpBR;  // Bottom-right offset
        // Output dimensions for pixel-to-normalized conversion
        float outputWidth;
        float outputHeight;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    // Simple fullscreen triangle vertex shader
    vertex VertexOut display_vertex(uint vid [[vertex_id]]) {
        float2 positions[3] = {
            float2(-1.0, -1.0),
            float2(3.0, -1.0),
            float2(-1.0, 3.0)
        };
        float2 texCoords[3] = {
            float2(0.0, 1.0),
            float2(2.0, 1.0),
            float2(0.0, -1.0)
        };

        VertexOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.texCoord = texCoords[vid];
        return out;
    }

    // Check if point is inside a quadrilateral defined by 4 corners (clockwise order)
    bool pointInQuad(float2 p, float2 tl, float2 tr, float2 br, float2 bl) {
        // Check if point is on the correct side of all 4 edges (clockwise winding)
        float2 edges[4] = { tr - tl, br - tr, bl - br, tl - bl };
        float2 corners[4] = { tl, tr, br, bl };

        for (int i = 0; i < 4; i++) {
            float2 toPoint = p - corners[i];
            float cross = edges[i].x * toPoint.y - edges[i].y * toPoint.x;
            if (cross < 0) return false;  // Outside this edge
        }
        return true;
    }

    fragment float4 display_fragment(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      sampler smp [[sampler(0)]],
                                      constant DisplayParams& params [[buffer(0)]]) {
        // Screen position in clip space (-1 to 1)
        float2 screenUV = in.texCoord;
        float2 screenPos = float2(screenUV.x * 2.0 - 1.0, (1.0 - screenUV.y) * 2.0 - 1.0);

        // DEBUG: Show red border if ANY warp offset is non-zero
        bool hasWarp = length(params.warpTL) > 0.001 ||
                       length(params.warpTR) > 0.001 ||
                       length(params.warpBL) > 0.001 ||
                       length(params.warpBR) > 0.001;

        // If warp is active, show a 50-pixel red border on all edges (for testing)
        if (hasWarp) {
            float borderSize = 50.0 / params.outputWidth;  // 50 pixels as fraction
            if (screenUV.x < borderSize || screenUV.x > 1.0 - borderSize ||
                screenUV.y < borderSize || screenUV.y > 1.0 - borderSize) {
                return float4(1.0, 0.0, 0.0, 1.0);  // RED border when warp active
            }
        }

        // Define the warped quad corners (where content should appear)
        // Warp offsets push corners inward (positive = toward center)
        float2 warpedTL = float2(-1.0, 1.0) + params.warpTL;
        float2 warpedTR = float2(1.0, 1.0) + params.warpTR;
        float2 warpedBL = float2(-1.0, -1.0) + params.warpBL;
        float2 warpedBR = float2(1.0, -1.0) + params.warpBR;

        // Check if this screen pixel is inside the warped quad
        if (!pointInQuad(screenPos, warpedTL, warpedTR, warpedBR, warpedBL)) {
            // Outside the warped region - render GREEN for debugging
            return float4(0.0, 1.0, 0.0, 1.0);
        }

        // Inside the warped region - use the SCREEN UV to sample the texture
        // This means the content is NOT distorted, just masked by the keystone shape
        // Apply crop to get final source UV
        float2 sourceUV;
        sourceUV.x = params.cropX + screenUV.x * params.cropW;
        sourceUV.y = params.cropY + screenUV.y * params.cropH;

        // Clamp and sample
        sourceUV = clamp(sourceUV, 0.0, 1.0);
        return tex.sample(smp, sourceUV);
    }
)";

// C++ struct matching shader DisplayParams
struct DisplayParams {
    float cropX = 0.0f;
    float cropY = 0.0f;
    float cropW = 1.0f;
    float cropH = 1.0f;
    // 8-point warp offsets (in normalized clip space)
    float warpTL[2] = {0.0f, 0.0f};
    float warpTM[2] = {0.0f, 0.0f};
    float warpTR[2] = {0.0f, 0.0f};
    float warpML[2] = {0.0f, 0.0f};
    float warpMR[2] = {0.0f, 0.0f};
    float warpBL[2] = {0.0f, 0.0f};
    float warpBM[2] = {0.0f, 0.0f};
    float warpBR[2] = {0.0f, 0.0f};
    float outputWidth = 1920.0f;
    float outputHeight = 1080.0f;
};

// Vertex structure for quad rendering
struct DisplayVertex {
    float position[2];
    float texCoord[2];
};

DisplayOutput::DisplayOutput(id<MTLDevice> device)
    : device_(device)
    , command_queue_(nil)
    , render_pipeline_(nil)
    , sampler_(nil)
    , vertex_buffer_(nil)
    , index_buffer_(nil)
    , index_count_(0)
    , window_(nil)
    , metal_view_(nil)
    , metal_layer_(nil) {

    if (device_) {
        command_queue_ = [device_ newCommandQueue];
        if (!command_queue_) {
            NSLog(@"DisplayOutput: Failed to create command queue");
        }
    } else {
        NSLog(@"DisplayOutput: Device is nil");
    }
}

DisplayOutput::~DisplayOutput() {
    stop();
}

bool DisplayOutput::configure(const DisplayOutputConfig& config) {
    if (running_.load()) {
        return false;
    }

    config_ = config;
    return true;
}

std::string DisplayOutput::name() const {
    if (!config_.label.empty()) {
        return config_.label;
    }
    return "Display";
}

bool DisplayOutput::setName(const std::string& name) {
    if (name.empty()) {
        NSLog(@"DisplayOutput: Cannot set empty name");
        return false;
    }

    config_.label = name;
    NSLog(@"DisplayOutput: Label set to '%s'", name.c_str());
    return true;
}

bool DisplayOutput::start() {
    if (running_.load()) {
        return true;
    }

    status_.store(OutputStatus::Starting);
    notifyStatus(OutputStatus::Starting, "Creating display output...");

    // Find the target display
    CGDirectDisplayID displayId = config_.display_id;
    if (displayId == 0) {
        displayId = CGMainDisplayID();
    }

    // Get display bounds
    CGRect displayBounds = CGDisplayBounds(displayId);
    native_width_ = (uint32_t)displayBounds.size.width;
    native_height_ = (uint32_t)displayBounds.size.height;
    width_.store(native_width_);
    height_.store(native_height_);

    // Get refresh rate
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayId);
    if (mode) {
        frame_rate_.store((float)CGDisplayModeGetRefreshRate(mode));
        CGDisplayModeRelease(mode);
    }
    if (frame_rate_.load() == 0) {
        frame_rate_.store(60.0f); // Default assumption
    }

    // Create window on main thread
    __block bool windowCreated = false;

    // Lambda to create the window
    auto createWindow = ^{
        NSRect frame = NSMakeRect(displayBounds.origin.x, displayBounds.origin.y,
                                  displayBounds.size.width, displayBounds.size.height);

        NSWindowStyleMask style = NSWindowStyleMaskBorderless;
        window_ = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];

        [window_ setLevel:NSScreenSaverWindowLevel];
        [window_ setOpaque:YES];
        [window_ setBackgroundColor:[NSColor blackColor]];
        [window_ setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                       NSWindowCollectionBehaviorFullScreenAuxiliary];

        // Create Metal view
        metal_view_ = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
        [metal_view_ setWantsLayer:YES];

        // Create and configure Metal layer
        metal_layer_ = [CAMetalLayer layer];
        metal_layer_.device = device_;
        metal_layer_.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metal_layer_.framebufferOnly = YES;
        metal_layer_.drawableSize = CGSizeMake(frame.size.width, frame.size.height);
        metal_layer_.displaySyncEnabled = config_.vsync;

        [metal_view_ setLayer:metal_layer_];
        [window_ setContentView:metal_view_];

        // Show window
        [window_ makeKeyAndOrderFront:nil];

        windowCreated = (window_ != nil);
    };

    if ([NSThread isMainThread]) {
        // Already on main thread, create directly
        createWindow();
    } else {
        // Dispatch to main thread and wait
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            createWindow();
            dispatch_semaphore_signal(semaphore);
        });

        // Wait for window creation with timeout (5 seconds)
        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
        if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
            NSLog(@"DisplayOutput: Timeout waiting for window creation");
            notifyStatus(OutputStatus::Error, "Window creation timeout");
            return false;
        }
    }

    if (!windowCreated || !window_) {
        NSLog(@"DisplayOutput: Failed to create window");
        notifyStatus(OutputStatus::Error, "Failed to create window");
        return false;
    }

    // Create render pipeline
    NSError* error = nil;

    MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
    id<MTLLibrary> library = [device_ newLibraryWithSource:kDisplayShaderSource
                                                   options:options
                                                     error:&error];
    if (!library) {
        NSLog(@"DisplayOutput: Failed to compile shaders: %@", error);
        stop();
        return false;
    }

    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"display_vertex"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"display_fragment"];

    // Simple pipeline without vertex descriptor (using vertex_id in shader)
    MTLRenderPipelineDescriptor* pipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDesc.vertexFunction = vertexFunc;
    pipelineDesc.fragmentFunction = fragmentFunc;
    pipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    render_pipeline_ = [device_ newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
    if (!render_pipeline_) {
        NSLog(@"DisplayOutput: Failed to create render pipeline: %@", error);
        stop();
        return false;
    }

    // Create sampler
    MTLSamplerDescriptor* samplerDesc = [[MTLSamplerDescriptor alloc] init];
    samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler_ = [device_ newSamplerStateWithDescriptor:samplerDesc];

    running_.store(true);
    status_.store(OutputStatus::Running);
    notifyStatus(OutputStatus::Running, "Display output running");

    NSLog(@"DisplayOutput: Started on display %u (%ux%u @ %.1f Hz)",
          displayId, width_.load(), height_.load(), frame_rate_.load());

    return true;
}

// Static storage for windows to prevent crash on deletion
// Windows are kept alive until app exit to avoid autorelease pool issues
static NSMutableArray* sPendingWindows = nil;

void DisplayOutput::stop() {
    if (!running_.load()) {
        return;
    }

    running_.store(false);

    // DON'T close window - just hide it and keep reference alive
    // Closing causes EXC_BAD_ACCESS in autorelease pool
    if ([NSThread isMainThread]) {
        if (window_) {
            [window_ orderOut:nil];  // Hide, don't close
            if (!sPendingWindows) {
                sPendingWindows = [[NSMutableArray alloc] init];
            }
            [sPendingWindows addObject:window_];  // Keep alive
            window_ = nil;
        }
        metal_view_ = nil;
        metal_layer_ = nil;
    } else {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (window_) {
                [window_ orderOut:nil];  // Hide, don't close
                if (!sPendingWindows) {
                    sPendingWindows = [[NSMutableArray alloc] init];
                }
                [sPendingWindows addObject:window_];  // Keep alive
                window_ = nil;
            }
            metal_view_ = nil;
            metal_layer_ = nil;
            dispatch_semaphore_signal(semaphore);
        });

        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC);
        dispatch_semaphore_wait(semaphore, timeout);
    }

    render_pipeline_ = nil;
    sampler_ = nil;
    vertex_buffer_ = nil;
    index_buffer_ = nil;

    status_.store(OutputStatus::Stopped);
    notifyStatus(OutputStatus::Stopped, "Display output stopped");

    NSLog(@"DisplayOutput: Stopped");
}

bool DisplayOutput::pushFrame(const SwitcherFrame& frame) {
    if (!running_.load() || !frame.valid || !frame.texture) {
        return false;
    }

    std::lock_guard<std::mutex> lock(render_mutex_);
    renderFrame(frame);
    return true;
}

void DisplayOutput::renderFrame(const SwitcherFrame& frame) {
    // Thread-safe checks - capture local copies
    CAMetalLayer* layer = metal_layer_;
    id<MTLRenderPipelineState> pipeline = render_pipeline_;
    id<MTLCommandQueue> queue = command_queue_;
    id<MTLSamplerState> sampler = sampler_;

    if (!layer || !pipeline || !queue || !sampler) {
        NSLog(@"DisplayOutput: renderFrame called with invalid state (layer=%p, pipeline=%p, queue=%p)",
              layer, pipeline, queue);
        return;
    }

    // Validate input texture
    if (!frame.texture) {
        NSLog(@"DisplayOutput: frame.texture is nil");
        return;
    }

    @autoreleasepool {
        // Get next drawable - may fail if layer not ready
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable) {
            return;
        }

        // Validate drawable texture
        id<MTLTexture> drawableTexture = drawable.texture;
        if (!drawableTexture) {
            NSLog(@"DisplayOutput: drawable.texture is nil");
            return;
        }

        // Create render pass
        MTLRenderPassDescriptor* passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        passDesc.colorAttachments[0].texture = drawableTexture;
        passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        if (!commandBuffer) {
            NSLog(@"DisplayOutput: Failed to create command buffer");
            return;
        }

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];
        if (!encoder) {
            NSLog(@"DisplayOutput: Failed to create render encoder");
            return;
        }

        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentTexture:frame.texture atIndex:0];
        [encoder setFragmentSamplerState:sampler atIndex:0];

        // Build DisplayParams with crop and warp settings
        DisplayParams params;
        params.cropX = current_crop_.x;
        params.cropY = current_crop_.y;
        params.cropW = current_crop_.w;
        params.cropH = current_crop_.h;

        // Convert warp from pixel offsets to normalized clip space (-1 to 1)
        // Pixel offsets are stored in current_edge_blend_, need to convert to clip space
        float w = (float)width_.load();
        float h = (float)height_.load();
        if (w > 0 && h > 0) {
            // Warp offsets are in pixels, convert to clip space (multiply by 2/dimension)
            params.warpTL[0] = current_edge_blend_.warpTopLeftX * 2.0f / w;
            params.warpTL[1] = current_edge_blend_.warpTopLeftY * 2.0f / h;
            params.warpTM[0] = current_edge_blend_.warpTopMiddleX * 2.0f / w;
            params.warpTM[1] = current_edge_blend_.warpTopMiddleY * 2.0f / h;
            params.warpTR[0] = current_edge_blend_.warpTopRightX * 2.0f / w;
            params.warpTR[1] = current_edge_blend_.warpTopRightY * 2.0f / h;
            params.warpML[0] = current_edge_blend_.warpMiddleLeftX * 2.0f / w;
            params.warpML[1] = current_edge_blend_.warpMiddleLeftY * 2.0f / h;
            params.warpMR[0] = current_edge_blend_.warpMiddleRightX * 2.0f / w;
            params.warpMR[1] = current_edge_blend_.warpMiddleRightY * 2.0f / h;
            params.warpBL[0] = current_edge_blend_.warpBottomLeftX * 2.0f / w;
            params.warpBL[1] = current_edge_blend_.warpBottomLeftY * 2.0f / h;
            params.warpBM[0] = current_edge_blend_.warpBottomMiddleX * 2.0f / w;
            params.warpBM[1] = current_edge_blend_.warpBottomMiddleY * 2.0f / h;
            params.warpBR[0] = current_edge_blend_.warpBottomRightX * 2.0f / w;
            params.warpBR[1] = current_edge_blend_.warpBottomRightY * 2.0f / h;
        }
        params.outputWidth = w;
        params.outputHeight = h;

        // Pass params to fragment shader
        [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];

        // Draw fullscreen triangle
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

        [encoder endEncoding];

        // Present
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
}

bool DisplayOutput::setResolution(uint32_t width, uint32_t height) {
    if (!running_.load() || !window_) {
        return false;
    }

    // Store new dimensions
    width_.store(width);
    height_.store(height);

    // Resize window and Metal layer on main thread
    __block bool success = false;

    auto resizeWindow = ^{
        // Get current window frame
        NSRect frame = [window_ frame];

        // Calculate new frame - center the window on the display
        CGDirectDisplayID displayId = config_.display_id;
        if (displayId == 0) {
            displayId = CGMainDisplayID();
        }
        CGRect displayBounds = CGDisplayBounds(displayId);

        // Center the new window size on the display
        CGFloat newX = displayBounds.origin.x + (displayBounds.size.width - width) / 2;
        CGFloat newY = displayBounds.origin.y + (displayBounds.size.height - height) / 2;
        NSRect newFrame = NSMakeRect(newX, newY, width, height);

        // Resize window
        [window_ setFrame:newFrame display:YES];

        // Resize Metal view
        [metal_view_ setFrame:NSMakeRect(0, 0, width, height)];

        // Resize Metal layer drawable
        metal_layer_.drawableSize = CGSizeMake(width, height);

        success = true;
        NSLog(@"DisplayOutput: Resized to %ux%u", width, height);
    };

    if ([NSThread isMainThread]) {
        resizeWindow();
    } else {
        dispatch_sync(dispatch_get_main_queue(), resizeWindow);
    }

    return success;
}

// List available displays
std::vector<DisplayInfo> listDisplays() {
    std::vector<DisplayInfo> displays;

    CGDirectDisplayID displayIds[16];
    uint32_t displayCount = 0;

    if (CGGetActiveDisplayList(16, displayIds, &displayCount) != kCGErrorSuccess) {
        NSLog(@"listDisplays: Failed to get display list");
        return displays;
    }

    NSLog(@"listDisplays: Found %d displays", displayCount);
    CGDirectDisplayID mainId = CGMainDisplayID();

    for (uint32_t i = 0; i < displayCount; i++) {
        CGDirectDisplayID id = displayIds[i];

        DisplayInfo info;
        info.display_id = id;
        info.is_main = (id == mainId);

        // Get dimensions
        CGRect bounds = CGDisplayBounds(id);
        info.width = (uint32_t)bounds.size.width;
        info.height = (uint32_t)bounds.size.height;

        // Get refresh rate
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(id);
        if (mode) {
            info.refresh_rate = (float)CGDisplayModeGetRefreshRate(mode);
            CGDisplayModeRelease(mode);
        }

        // Try to get display name from NSScreen (most reliable on modern macOS)
        for (NSScreen *screen in [NSScreen screens]) {
            NSDictionary *deviceDesc = [screen deviceDescription];
            NSNumber *screenNumber = deviceDesc[@"NSScreenNumber"];
            if (screenNumber && [screenNumber unsignedIntValue] == id) {
                // Use localizedName which gives friendly names like "LG HDR 4K"
                if (@available(macOS 10.15, *)) {
                    NSString *name = screen.localizedName;
                    if (name && name.length > 0) {
                        info.name = [name UTF8String];
                    }
                }
                break;
            }
        }

        // Fallback: Try IOKit if NSScreen didn't give us a name
        if (info.name.empty()) {
            io_iterator_t iterator;
            if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                             IOServiceMatching("IODisplayConnect"),
                                             &iterator) == kIOReturnSuccess) {
                io_service_t service;
                while ((service = IOIteratorNext(iterator))) {
                    CFDictionaryRef infoDict = IODisplayCreateInfoDictionary(service, kIODisplayOnlyPreferredName);
                    if (infoDict) {
                        CFNumberRef vendorID = (CFNumberRef)CFDictionaryGetValue(infoDict, CFSTR(kDisplayVendorID));
                        CFNumberRef productID = (CFNumberRef)CFDictionaryGetValue(infoDict, CFSTR(kDisplayProductID));

                        uint32_t cgVendor = CGDisplayVendorNumber(id);
                        uint32_t cgModel = CGDisplayModelNumber(id);

                        uint32_t ioVendor = 0, ioProduct = 0;
                        if (vendorID) CFNumberGetValue(vendorID, kCFNumberSInt32Type, &ioVendor);
                        if (productID) CFNumberGetValue(productID, kCFNumberSInt32Type, &ioProduct);

                        if (cgVendor == ioVendor && cgModel == ioProduct) {
                            CFDictionaryRef names = (CFDictionaryRef)CFDictionaryGetValue(infoDict, CFSTR(kDisplayProductName));
                            if (names && CFDictionaryGetCount(names) > 0) {
                                CFStringRef firstKey;
                                CFStringRef firstName;
                                CFDictionaryGetKeysAndValues(names, (const void**)&firstKey, (const void**)&firstName);
                                if (firstName) {
                                    char name[256];
                                    if (CFStringGetCString(firstName, name, sizeof(name), kCFStringEncodingUTF8)) {
                                        info.name = name;
                                    }
                                }
                            }
                        }
                        CFRelease(infoDict);
                    }
                    IOObjectRelease(service);
                    if (!info.name.empty()) break;
                }
                IOObjectRelease(iterator);
            }
        }

        if (info.name.empty()) {
            info.name = "Display " + std::to_string(i + 1);
        }

        NSLog(@"listDisplays: [%d] id=%u name='%s' %dx%d @ %.1fHz %s",
              i, id, info.name.c_str(), info.width, info.height,
              info.refresh_rate, info.is_main ? "(main)" : "");

        displays.push_back(info);
    }

    return displays;
}

} // namespace RocKontrol
