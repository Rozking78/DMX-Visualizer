# OutputEngine Architecture Documentation

## Overview
The OutputEngine handles rendering frames to physical displays and NDI network outputs.

## File Structure

| File | Purpose |
|------|---------|
| `output_sink.h` | Abstract base class for all outputs |
| `output_display.h/mm` | Physical display output via Metal |
| `output_ndi.h/mm` | NDI network streaming output |
| `switcher_frame.h` | Frame structure definition |
| `OutputEngineWrapper.h/mm` | Objective-C bridge for Swift |

## Class Hierarchy

```
OutputSink (Abstract Base)
├── DisplayOutput - Metal rendering to CAMetalLayer/NSWindow
└── NDIOutput - Async NDI encoder + network sender
```

## Frame Flow

### SwitcherFrame Structure
```cpp
struct SwitcherFrame {
    id<MTLTexture> texture;    // BGRA8Unorm GPU texture
    uint64_t timestamp_ns;     // Presentation timestamp
    uint32_t width, height;    // Dimensions
    float frame_rate;          // Source FPS
    bool valid;                // Validity flag
};
```

### DisplayOutput Path
1. `pushFrame(SwitcherFrame)` called from compositor
2. Validation: frame.valid && frame.texture != nil
3. Lock render_mutex_, call renderFrame()
4. Get drawable from CAMetalLayer.nextDrawable()
5. Create render pass with drawable texture as target
6. Bind input texture + sampler
7. Pass DisplayParams (crop + 8-point warp) to shader
8. Draw fullscreen triangle
9. Present drawable

### NDIOutput Path (Async)
1. `pushFrame(SwitcherFrame)` called
2. Apply edge blend shader if active (GPU)
3. Read pixels via MTLTexture.getBytes() (GPU→CPU)
4. Queue PixelFrame to async queue (max 5)
5. Send thread picks up frame, transmits via NDI SDK

## Metal Shader Pipeline

### Display Vertex Shader
- Generates fullscreen triangle (3 vertices)
- Maps to clip space (-1 to 1)

### Display Fragment Shader
1. Convert screen UV to clip space position
2. Define 8-point warped quad corners
3. Point-in-quad test (clockwise winding)
4. Apply crop to UV coordinates
5. Sample texture and return color

## Window Management

### Creation
1. Find NSScreen matching display ID
2. Create borderless NSWindow at screen frame
3. Set level to NSScreenSaverWindowLevel
4. Create CAMetalLayer with proper config
5. Set up layer-hosting view pattern

### Coordinate Systems
- **NSWindow**: Cocoa (Y=0 at bottom)
- **CAMetalLayer**: Top-left origin
- **Shader Clip Space**: (-1,-1) bottom-left to (1,1) top-right
- **Texture UV**: (0,0) top-left to (1,1) bottom-right

## Threading Model

### DisplayOutput
- Frame rendering: Safe via render_mutex_
- Window ops: Must be on main thread
- nextDrawable(): Thread-safe but should be fast

### NDIOutput
- Push thread: GPU-to-CPU conversion, queue
- Send thread: NDI transmission (background)
- Sync: queue_mutex_, queue_cv_

## Key Configuration

### CropRegion (0-1 normalized)
- x, y: Top-left corner in source
- w, h: Size as fraction of source

### EdgeBlendParams
- Feathering: Left/Right/Top/Bottom (pixels)
- Blend curve: gamma, power
- 8-point warp: TL, TM, TR, ML, MR, BL, BM, BR
- Lens distortion: K1, K2, center
- Curvature: spherical correction

## Known Issues

1. **DEBUG CODE**: Line 83 in output_display.mm has hardcoded magenta return
2. Warp coordinate systems inconsistent between Display/NDI
3. No timestamp synchronization between outputs
4. Window cleanup via static array (potential leak)
5. nextDrawable() inside mutex could deadlock

## Recommendations

1. Remove debug magenta return in shader
2. Standardize warp coordinates to 0-1 normalized
3. Add timestamp sync across outputs
4. Implement automatic window cleanup
5. Move nextDrawable() outside mutex
