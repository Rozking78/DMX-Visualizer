# OutputEngine Complete Architecture Documentation

## Overview

The OutputEngine renders frames to physical displays and NDI network outputs. It bridges Swift application code through Objective-C wrappers to C++ implementations that use Metal for GPU rendering.

---

## File Structure

```
OutputEngine/
├── include/
│   └── OutputEngineWrapper.h    # Objective-C interface for Swift
├── OutputEngineWrapper.mm       # Obj-C bridge implementation
├── output_sink.h                # Abstract base class for all outputs
├── output_display.h             # Display output header
├── output_display.mm            # Display output implementation
├── output_ndi.h                 # NDI output header
├── output_ndi.mm                # NDI output implementation
└── switcher_frame.h             # Frame structure and utilities
```

---

## Class Hierarchy

```
┌─────────────────────────────────────────────────────────────────┐
│                        Swift Layer                               │
│  GeoDrawOutputManager.swift                                     │
│  ├── ManagedOutput (wrapper class)                              │
│  ├── outputs: [ManagedOutput] array                             │
│  └── pushFrame() → calls Obj-C wrappers                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Objective-C Layer                             │
│  OutputEngineWrapper.mm                                          │
│  ├── GDDisplayOutput                                            │
│  │   └── std::unique_ptr<RocKontrol::DisplayOutput> _impl       │
│  ├── GDNDIOutput                                                │
│  │   └── std::unique_ptr<RocKontrol::NDIOutput> _impl           │
│  ├── GDCropRegion                                               │
│  ├── GDEdgeBlendParams                                          │
│  ├── GDDisplayInfo                                              │
│  └── GDListDisplays() → std::vector<DisplayInfo>                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       C++ Layer                                  │
│  Namespace: RocKontrol                                          │
│                                                                  │
│  OutputSink (Abstract Base Class)                               │
│  ├── virtual start() = 0                                        │
│  ├── virtual stop() = 0                                         │
│  ├── virtual pushFrame(SwitcherFrame) = 0                       │
│  ├── CropRegion current_crop_, pending_crop_                    │
│  ├── EdgeBlendParams current_edge_blend_, pending_edge_blend_   │
│  └── Transition state machine                                   │
│                                                                  │
│  DisplayOutput : public OutputSink                              │
│  ├── Metal render pipeline                                      │
│  ├── NSWindow + CAMetalLayer                                    │
│  └── renderFrame() → Metal commands                             │
│                                                                  │
│  NDIOutput : public OutputSink                                  │
│  ├── Edge blend pipeline (GPU)                                  │
│  ├── Async send thread                                          │
│  └── NDI SDK integration                                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Metal GPU Layer                             │
│  ├── DisplayOutput shader: display_vertex + display_fragment    │
│  └── NDIOutput shader: edgeBlendVertex + edgeBlendFragment      │
└─────────────────────────────────────────────────────────────────┘
```

---

## Core Data Structures

### SwitcherFrame (switcher_frame.h:17-43)

```cpp
struct SwitcherFrame {
    id<MTLTexture> texture;      // GPU texture (BGRA8Unorm)
    uint64_t timestamp_ns;       // Presentation timestamp
    uint64_t frame_number;       // Sequential frame ID
    uint32_t width, height;      // Dimensions
    float frame_rate;            // Source FPS
    bool valid;                  // Frame contains valid data
    bool interlaced;             // Interlaced frame?
    bool top_field_first;        // TFF or BFF
};
```

### CropRegion (output_sink.h:287-296)

```cpp
struct CropRegion {
    float x = 0.0f;   // Start X (0-1 normalized)
    float y = 0.0f;   // Start Y (0-1 normalized)
    float w = 1.0f;   // Width (0-1 normalized)
    float h = 1.0f;   // Height (0-1 normalized)
};
```

### EdgeBlendParams (output_sink.h:305-346)

```cpp
struct EdgeBlendParams {
    // Feathering (pixels)
    float featherLeft, featherRight, featherTop, featherBottom;

    // Blend curve
    float blendGamma = 2.2f;     // Gamma curve
    float blendPower = 1.0f;     // Power/slope
    float blackLevel = 0.0f;     // Black compensation
    float gammaR, gammaG, gammaB; // Per-channel gamma

    // 8-point warp (pixel offsets from corners/edges)
    float warpTopLeftX, warpTopLeftY;
    float warpTopMiddleX, warpTopMiddleY;
    float warpTopRightX, warpTopRightY;
    float warpMiddleLeftX, warpMiddleLeftY;
    float warpMiddleRightX, warpMiddleRightY;
    float warpBottomLeftX, warpBottomLeftY;
    float warpBottomMiddleX, warpBottomMiddleY;
    float warpBottomRightX, warpBottomRightY;

    // Curvature for spherical surfaces
    float warpCurvature = 0.0f;  // 0=linear, +=convex, -=concave

    // Lens distortion
    float lensK1, lensK2;        // Radial coefficients
    float lensCenterX, lensCenterY;

    // Corner overlay indicator
    int activeCorner = 0;        // 0=none, 1=TL, 2=TR, 3=BL, 4=BR
};
```

---

## Frame Flow: Display Output

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Swift: GeoDrawOutputManager.pushFrame(texture)               │
│    └── Calls ManagedOutput.displayOutput?.pushFrameWithTexture  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. Obj-C: GDDisplayOutput.pushFrameWithTexture:timestamp:       │
│    └── Creates SwitcherFrame from texture                       │
│    └── Calls _impl->pushFrame(frame)                            │
│    Location: OutputEngineWrapper.mm:148-164                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. C++: DisplayOutput::pushFrame(frame)                         │
│    ├── Validates: frame.valid && frame.texture != nil           │
│    ├── Acquires render_mutex_                                   │
│    └── Calls renderFrame(frame)                                 │
│    Location: output_display.mm:437-456                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. C++: DisplayOutput::renderFrame(frame)                       │
│    ├── Gets drawable: [metal_layer_ nextDrawable]               │
│    ├── Creates render pass targeting drawable.texture           │
│    ├── Binds frame.texture + sampler                            │
│    ├── Builds DisplayParams (crop + 8-point warp)               │
│    ├── Passes params to fragment shader                         │
│    ├── Draws fullscreen triangle (3 vertices)                   │
│    └── [commandBuffer presentDrawable:drawable]                 │
│    Location: output_display.mm:458-570                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. Metal: display_fragment shader                               │
│    ├── Convert screen UV to clip space (-1 to 1)                │
│    ├── Calculate warped quad corners                            │
│    ├── pointInQuad test (clockwise winding)                     │
│    │   └── Outside quad → return black                          │
│    ├── Apply crop to UV coordinates                             │
│    └── Sample texture and return color                          │
│    Location: output_display.mm:78-109                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Frame Flow: NDI Output

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Swift: ManagedOutput.ndiOutput?.pushFrameWithTexture         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. Obj-C: GDNDIOutput.pushFrameWithTexture:timestamp:           │
│    └── Creates SwitcherFrame, calls _impl->pushFrame()          │
│    Location: OutputEngineWrapper.mm:301-317                     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. C++: NDIOutput::pushFrame(frame) - ON CALLER THREAD          │
│    ├── Apply crop region                                        │
│    ├── Check if edge blend/warp needed                          │
│    ├── If edge blend active:                                    │
│    │   ├── Ensure temp texture exists                           │
│    │   ├── Render through edgeBlendFragment shader              │
│    │   └── Read pixels from temp_texture_                       │
│    ├── Else: Read directly from frame.texture                   │
│    └── Queue PixelFrame to async queue (max 5)                  │
│    Location: output_ndi.mm:883-1043                             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. Send Thread: NDIOutput::sendLoop() - BACKGROUND THREAD       │
│    ├── Wait on queue_cv_ for frames                             │
│    ├── Pop PixelFrame from queue                                │
│    ├── Build NDIlib_video_frame_v2_t                            │
│    └── ndi_lib->send_send_video_v2(sender_, &ndi_frame)         │
│    Location: output_ndi.mm:1085-1156                            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Metal Shader Details

### Display Output Shader (output_display.mm:15-110)

**Vertex Shader: `display_vertex`**
```cpp
// Generates fullscreen triangle (3 vertices)
float2 positions[3] = {
    float2(-1.0, -1.0),  // Bottom-left
    float2(3.0, -1.0),   // Far right
    float2(-1.0, 3.0)    // Far top
};
float2 texCoords[3] = {
    float2(0.0, 1.0),    // UV for bottom-left
    float2(2.0, 1.0),    // UV for far right
    float2(0.0, -1.0)    // UV for far top
};
```

**Fragment Shader: `display_fragment`**
```cpp
// 1. Convert screen UV to clip space
float2 screenPos = float2(screenUV.x * 2.0 - 1.0, (1.0 - screenUV.y) * 2.0 - 1.0);

// 2. Calculate warped quad corners
float2 warpedTL = float2(-1.0, 1.0) + params.warpTL;
float2 warpedTR = float2(1.0, 1.0) + params.warpTR;
float2 warpedBL = float2(-1.0, -1.0) + params.warpBL;
float2 warpedBR = float2(1.0, -1.0) + params.warpBR;

// 3. Point-in-quad test (clockwise winding)
if (!pointInQuad(screenPos, warpedTL, warpedTR, warpedBR, warpedBL)) {
    return float4(0.0, 0.0, 0.0, 1.0);  // Black keystone border
}

// 4. Apply crop and sample
float2 sourceUV;
sourceUV.x = params.cropX + screenUV.x * params.cropW;
sourceUV.y = params.cropY + screenUV.y * params.cropH;
return tex.sample(smp, sourceUV);
```

**pointInQuad Function:**
```cpp
bool pointInQuad(float2 p, float2 tl, float2 tr, float2 br, float2 bl) {
    float2 edges[4] = { tr - tl, br - tr, bl - br, tl - bl };
    float2 corners[4] = { tl, tr, br, bl };
    for (int i = 0; i < 4; i++) {
        float2 toPoint = p - corners[i];
        float cross = edges[i].x * toPoint.y - edges[i].y * toPoint.x;
        if (cross > 0) return false;  // Outside (clockwise winding)
    }
    return true;
}
```

### NDI Edge Blend Shader (output_ndi.mm:54-502)

**Full 8-point warp with quadrant interpolation:**
```cpp
// Calculate 9-point grid (8 corners + center)
float2 center = (tm + ml + mr + bm) * 0.25;

// Split into 4 quadrants for curved surface mapping
// Top-left quadrant: tl, tm, ml, center
// Top-right quadrant: tm, tr, center, mr
// Bottom-left quadrant: ml, center, bl, bm
// Bottom-right quadrant: center, mr, bm, br

// Use inverse bilinear interpolation for each quadrant
float2 inverseQuadUV(p, q00, q10, q01, q11);
```

**Edge feathering:**
```cpp
// Left edge fade
if (params.featherLeft > 0.0 && uv.x < params.featherLeft) {
    float t = uv.x / params.featherLeft;
    blendL = pow(t, params.power);
}
// Apply gamma correction
blend = pow(blend, 1.0 / params.gamma);
```

---

## Window Management

### DisplayOutput Window Creation (output_display.mm:256-329)

```cpp
// 1. Find NSScreen matching display ID
NSScreen* targetScreen = nil;
for (NSScreen* screen in [NSScreen screens]) {
    NSDictionary* desc = [screen deviceDescription];
    NSNumber* screenNum = desc[@"NSScreenNumber"];
    if ([screenNum unsignedIntValue] == displayId) {
        targetScreen = screen;
        break;
    }
}

// 2. Create borderless fullscreen window
window_ = [[NSWindow alloc] initWithContentRect:screenFrame
                                      styleMask:NSWindowStyleMaskBorderless
                                        backing:NSBackingStoreBuffered
                                          defer:NO
                                         screen:targetScreen];

// 3. Configure window level and behavior
[window_ setLevel:NSScreenSaverWindowLevel + 1000];
[window_ setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorIgnoresCycle];
[window_ setIgnoresMouseEvents:YES];

// 4. Create Metal layer
metal_layer_ = [CAMetalLayer layer];
metal_layer_.device = device_;
metal_layer_.pixelFormat = MTLPixelFormatBGRA8Unorm;

// 5. Layer-hosting view setup
[metal_view_ setLayer:metal_layer_];
[metal_view_ setWantsLayer:YES];
```

### Window Cleanup for Crash Prevention (output_display.mm:159-188)

```cpp
// Static storage for windows - prevents autorelease crashes
static NSMutableArray* sPendingWindows = nil;

DisplayOutput::~DisplayOutput() {
    stop();
    if (window_) {
        if (!sPendingWindows) {
            sPendingWindows = [[NSMutableArray alloc] init];
        }
        [window_ orderOut:nil];  // Hide, don't close
        [sPendingWindows addObject:window_];  // Keep alive
        window_ = nil;
        metal_view_ = nil;
        metal_layer_ = nil;
    }
}
```

---

## Coordinate Systems

| System | Origin | Range | Used By |
|--------|--------|-------|---------|
| NSWindow (Cocoa) | Bottom-left | Screen pixels | Window positioning |
| CAMetalLayer | Top-left | Drawable pixels | Metal rendering |
| Metal Clip Space | Center | (-1,-1) to (1,1) | Vertex shader |
| Texture UV | Top-left | (0,0) to (1,1) | Fragment shader |
| Crop Region | Top-left | (0,0) to (1,1) | Source selection |
| Warp Offsets | - | Pixels | EdgeBlendParams |

---

## Threading Model

### DisplayOutput
- **Frame rendering**: Protected by `render_mutex_`
- **Window ops**: Must be on main thread (dispatch_async/sync)
- **nextDrawable()**: Thread-safe but should complete quickly

### NDIOutput
- **Push thread**: Caller thread - GPU work (edge blend shader)
- **Send thread**: Background thread - NDI transmission
- **Synchronization**: `queue_mutex_`, `queue_cv_`
- **Queue depth**: 5 frames (configurable via `async_queue_size`)

---

## Configuration Parameters

### DisplayOutputConfig
```cpp
struct DisplayOutputConfig {
    uint32_t display_id = 0;     // CGDirectDisplayID (0 = main)
    bool fullscreen = true;
    bool vsync = true;
    bool show_safe_area = false;
    std::string label;
};
```

### NDIOutputConfig
```cpp
struct NDIOutputConfig {
    std::string source_name = "RocKontrol Switcher";
    std::string groups;           // Comma-separated
    std::string network_interface;
    bool clock_video = true;
    bool clock_audio = false;
    uint32_t async_queue_size = 5;
    bool legacy_mode = false;     // Sync sending
};
```

---

## API Call Chain

### Creating Display Output

```
Swift:                    Obj-C:                      C++:
─────────────────────────────────────────────────────────────────
let display = GDDisplayOutput(device: mtlDevice)
                          │
                          └─→ initWithDevice:
                              _impl = make_unique<DisplayOutput>(device)
                                                    │
                                                    └─→ DisplayOutput(device)
                                                        command_queue_ = [device newCommandQueue]

display.configure(displayId, fullscreen, vsync, label)
                          │
                          └─→ configureWithDisplayId:fullscreen:vsync:label:
                              config.display_id = displayId
                              _impl->configure(config)

display.start()
                          │
                          └─→ start
                              _impl->start()
                                    │
                                    └─→ start()
                                        ├─ Find display bounds
                                        ├─ Create NSWindow (main thread)
                                        ├─ Create CAMetalLayer
                                        ├─ Compile Metal shaders
                                        └─ Create render pipeline
```

### Pushing Frames

```
Swift:                    Obj-C:                      C++:
─────────────────────────────────────────────────────────────────
output.pushFrameWithTexture(texture, timestamp, fps)
                          │
                          └─→ pushFrameWithTexture:timestamp:frameRate:
                              frame.texture = texture
                              frame.timestamp_ns = timestamp
                              frame.valid = true
                              _impl->pushFrame(frame)
                                    │
                                    └─→ pushFrame(frame)
                                        lock(render_mutex_)
                                        renderFrame(frame)
                                            │
                                            └─→ [layer nextDrawable]
                                                [encoder setFragmentTexture:frame.texture]
                                                [encoder drawPrimitives:MTLPrimitiveTypeTriangle]
                                                [commandBuffer presentDrawable]
                                                [commandBuffer commit]
```

---

## Known Issues

1. **Display shader uses simple 4-point warp** - Only uses corner warp points (TL, TR, BL, BR), middle points ignored
2. **NDI shader has full 8-point warp** - Different capability between Display and NDI outputs
3. **No timestamp sync** - Multiple outputs may have slight timing differences
4. **Window on wrong Space** - `isOnActiveSpace=0` can occur if window created before Space switch

---

## Recommendations

1. **Unify shader capabilities** - Add full 8-point warp to display shader
2. **Add timestamp synchronization** - Use common clock for multi-output sync
3. **Improve Space handling** - Re-check window placement after creation
4. **Add render stats** - Frame timing, dropped frames, latency metrics

---

## File Locations Quick Reference

| Component | File | Key Lines |
|-----------|------|-----------|
| SwitcherFrame struct | switcher_frame.h | 17-43 |
| OutputSink base class | output_sink.h | 58-471 |
| EdgeBlendParams | output_sink.h | 305-346 |
| CropRegion | output_sink.h | 287-296 |
| DisplayOutput class | output_display.h | 27-95 |
| DisplayOutput impl | output_display.mm | 137-728 |
| Display shader | output_display.mm | 15-110 |
| pointInQuad function | output_display.mm | 65-76 |
| Window creation | output_display.mm | 256-329 |
| Window cleanup | output_display.mm | 159-188 |
| NDIOutput class | output_ndi.h | 30-140 |
| NDIOutput impl | output_ndi.mm | 504-1305 |
| NDI edge blend shader | output_ndi.mm | 54-502 |
| 8-point inverse warp | output_ndi.mm | 332-376 |
| GDDisplayOutput wrapper | OutputEngineWrapper.mm | 100-245 |
| GDNDIOutput wrapper | OutputEngineWrapper.mm | 249-426 |
| GDListDisplays | OutputEngineWrapper.mm | 430-447 |
