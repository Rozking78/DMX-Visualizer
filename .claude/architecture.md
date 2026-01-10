# DMX Visualizer - Software Architecture

## 1. High-Level Overview

```
+-----------------------------------------------------------------------+
|                        DMX Visualizer                                  |
|                                                                        |
|  +---------------+    +---------------+    +-----------------------+   |
|  |  DMX Input    |--->|   Fixtures    |--->|   Metal Renderer      |   |
|  |  (OLA/sACN)   |    |  Processing   |    |   (GPU Pipeline)      |   |
|  +---------------+    +---------------+    +-----------+-----------+   |
|                                                        |               |
|  +---------------+    +---------------+                v               |
|  |  Web Server   |<---|   Outputs     |<---------------+               |
|  |  (HTTP API)   |    | Syphon/NDI    |    +-----------+-----------+   |
|  +---------------+    +---------------+    |   Display Output      |   |
|                                            |   (Fullscreen)        |   |
|                                            +-----------------------+   |
+-----------------------------------------------------------------------+
```

## 2. Layer Architecture

```
Swift Application Layer (main.swift, WebServer.swift)
        |
        v
Objective-C++ Bridge Layer (GeoDraw-Bridging-Header.h)
        |
        v
C++ Libraries (OLA, NDI SDK)
        |
        v
Metal GPU Rendering (Shaders.metal)
```

## 3. Core Components

### 3.1 DMX Input System
- **OLAClientWrapper** (`Sources/dmx-visualizer/OLAClientWrapper.mm`)
  - C++ wrapper for Open Lighting Architecture DMX library
  - Connects to OLA daemon for DMX universe data
  - Provides callback interface for Swift layer

- **DMXListener** (in `main.swift`)
  - Swift class receiving DMX values on 512-channel universe
  - Parses fixture blocks (25 channels each)
  - Updates fixture state array

- **sACN Support**
  - Network-based DMX input via streaming ACN protocol
  - Alternative to hardware DMX interfaces

### 3.2 Fixture System

Each fixture uses 25 DMX channels:

| Channel | Function | Range |
|---------|----------|-------|
| CH1 | Intensity | 0-255 (master dimmer) |
| CH2 | Red | 0-255 |
| CH3 | Green | 0-255 |
| CH4 | Blue | 0-255 |
| CH5 | White | 0-255 |
| CH6 | Gobo/Media Slot | 0-200 gobos, 201-255 media |
| CH7 | Shutter/Strobe | 0=closed, 1-127=strobe, 128-255=open |
| CH8 | X Position (coarse) | 0-255 |
| CH9 | X Position (fine) | 0-255 |
| CH10 | Y Position (coarse) | 0-255 |
| CH11 | Y Position (fine) | 0-255 |
| CH12 | Scale (coarse) | 0-255 |
| CH13 | Scale (fine) | 0-255 |
| CH14 | Rotation | 0-255 (0-360 degrees) |
| CH15 | Edge Softness | 0-255 |
| CH16 | Prism Effect | 0-255 |
| CH17 | Frost | 0-255 |
| CH18 | Zoom | 0-255 |
| CH19 | Focus | 0-255 |
| CH20 | Iris | 0-255 |
| CH21 | Playback Control | See playback states below |
| CH22 | Playback Speed | 0-255 (0.5x to 2x) |
| CH23 | Playback Position | 0-255 (goto position) |
| CH24 | Reserved | - |
| CH25 | Reserved | - |

**Playback States (CH21):**
- 0-15: Stop
- 16-31: Pause
- 32-79: Play once
- 80-127: Loop
- 128-175: Bounce (ping-pong)
- 176-223: Reverse
- 224-234: Restart
- 235-255: Go to position (uses CH23)

### 3.3 Media System

**MediaSlotConfig** (in `main.swift`)
- Singleton managing slot 201-255 assignments
- Maps slots to video files, images, or NDI sources
- Persists configuration

**VideoPlayer** (in `main.swift`, lines ~4325-4534)
- Double-buffered AVPlayer for smooth playback
- Background decode thread at ~120Hz
- Thread-safe buffer swapping with NSLock
- Supports play/pause/loop/bounce/reverse modes

```swift
// Double buffering structure
private var displayBuffer: CVPixelBuffer?   // Frame ready for display
private var pendingBuffer: CVPixelBuffer?   // Frame being prepared
private let bufferLock = NSLock()
private var decodeQueue: DispatchQueue      // Background decode
```

**VideoSlotManager** (in `main.swift`)
- Manages active video textures for GPU rendering
- CVMetalTextureCache for efficient GPU texture creation
- Returns MTLTexture for each active video slot

**NDIReceiver** (`Sources/dmx-visualizer/NDIWrapper.swift`)
- Network video input via NDI protocol
- Discovers NDI sources on network
- Provides frames as textures

**GoboLibrary** (in `main.swift`)
- Texture library for gobo slots 0-200
- Scans configured folders for PNG images
- Caches loaded textures

### 3.4 Rendering Pipeline

**DMXRenderer** (in `main.swift`)
Main Swift class orchestrating the render loop:

1. **beginFrame()** - Start Metal command buffer
2. **render()** - Process all fixtures
3. **renderObject()** - Render individual fixture (~line 2985)
4. **endFrame()** - Submit to GPU, apply playback states

**Metal Pipeline States:**
- `goboPipelineState` - For static gobo textures
- `videoPipelineState` - For video/media textures with YCbCr conversion

**Native Resolution Scaling** (lines 2989-2995):
```swift
// Calculate scale to render at native resolution
let nativeScaleX = Float(videoTexture.width) / 240.0
let nativeScaleY = Float(videoTexture.height) / 240.0
uniforms.scale.x = nativeScaleX * Float(obj.scale.width)
uniforms.scale.y = nativeScaleY * Float(obj.scale.height)
```

**Shaders** (`Sources/dmx-visualizer/Shaders.metal`):
- Vertex shader: Position, rotation, scale transforms
- Fragment shader: Color tinting, edge softness, effects

### 3.5 Output System

**DisplayOutput** (in `main.swift`)
- Fullscreen Metal view on secondary display
- CVDisplayLink for vsync
- Manages display enumeration and selection

**SyphonServer** (uses Syphon.framework)
- macOS texture sharing protocol
- Allows other apps to receive video output
- Requires framework in @rpath

**NDIOutput** (`Sources/dmx-visualizer/NDIWrapper.swift`)
- Network video output via NDI protocol
- Broadcasts rendered frames on network

**GeoDrawOutputManager** (`Sources/dmx-visualizer/GeoDrawOutputManager.swift`)
- Manages multiple output destinations
- Coordinates Syphon and NDI outputs

### 3.6 Web Server

**WebServer** (`Sources/dmx-visualizer/WebServer.swift`)
- NWListener-based HTTP server on port 8080
- Serves control UI and REST API

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| GET | / | Control UI (HTML/CSS/JS) |
| GET | /api/v1/status | System status JSON |
| GET | /api/v1/status/preview | JPEG preview (10fps, 960px wide) |
| POST | /api/v1/fixtures | Update fixture DMX values |
| POST | /api/v1/media/slots | Configure media slot assignments |
| GET | /api/v1/displays | List available displays |
| POST | /api/v1/display/select | Select output display |

## 4. Data Flow

```
DMX Universe (512 bytes)
        |
        v
+-------------------+
|  DMXListener      |  Parses 25-ch fixture blocks
+---------+---------+
          |
          v
+-------------------+
|  Fixture Array    |  20 fixtures x 25 channels
+---------+---------+
          |
    +-----+-----+
    |           |
    v           v
+--------+  +----------+
| Gobos  |  |  Media   |  Based on CH6 value
| 0-200  |  | 201-255  |
+----+---+  +----+-----+
     |           |
     +-----+-----+
           |
           v
+-------------------+
|  Metal Renderer   |  GPU compositing @ 60fps
+---------+---------+
          |
    +-----+-----+-----+-----------+
    v     v     v     v           v
Display Syphon NDI Preview    WebServer
(1080p) (tex)  (net) (JPEG)   (API)
```

## 5. Threading Model

| Thread | Purpose | QoS |
|--------|---------|-----|
| Main | UI, DMX listener, Metal render loop | userInteractive |
| Video Decode | Background ~120Hz frame decode per video | userInteractive |
| Web Server | HTTP request handling | utility |
| NDI Receive | Network video capture | userInteractive |
| NDI Send | Network video output | userInteractive |
| Syphon | Texture publishing | default |

**Thread Safety:**
- Video buffers protected by NSLock
- MediaSlotConfig uses serial queue
- Renderer state accessed only from main thread

## 6. File Structure

```
dmx-test/
├── Package.swift                 # Swift package manifest
├── Sources/
│   └── dmx-visualizer/
│       ├── main.swift            # ~5000 lines - core application
│       │   ├── DMXListener
│       │   ├── Fixture/RenderableObject
│       │   ├── DMXRenderer
│       │   ├── VideoPlayer (double-buffered)
│       │   ├── VideoSlotManager
│       │   ├── MediaSlotConfig
│       │   ├── GoboLibrary
│       │   └── DisplayOutput
│       ├── WebServer.swift       # HTTP API and web UI
│       ├── Shaders.metal         # GPU shaders
│       ├── OLAClientWrapper.h    # C++ bridge header
│       ├── OLAClientWrapper.mm   # OLA DMX implementation
│       ├── NDIWrapper.swift      # NDI input/output
│       ├── GeoDrawOutputManager.swift
│       ├── OutputSettingsWindowController.swift
│       └── GeoDraw-Bridging-Header.h
├── .build/                       # Build output
│   └── arm64-apple-macosx/
│       └── release/
│           ├── dmx-visualizer    # Executable
│           └── Syphon.framework/ # Required framework
└── .claude/
    └── architecture.md          # This file
```

## 7. Key Classes and Structs

### RenderableObject
```swift
struct RenderableObject {
    var position: CGPoint      // Screen position
    var scale: CGSize          // Scale factor
    var rotation: CGFloat      // Rotation in degrees
    var color: NSColor         // RGBW color
    var intensity: CGFloat     // Master dimmer
    var goboSlot: Int          // 0-200 or 201-255
    var isVideo: Bool          // True if slot > 200
    var videoSlot: Int?        // Video slot index
    var edgeSoftness: CGFloat  // Edge blur
    var effects: EffectParams  // Prism, frost, etc.
}
```

### MetalObjectUniforms
```swift
struct MetalObjectUniforms {
    var position: SIMD2<Float>
    var scale: SIMD2<Float>
    var rotation: Float
    var color: SIMD4<Float>
    var intensity: Float
    var edgeSoftness: Float
}
```

### VideoPlaybackState
```swift
enum VideoPlaybackState: Int {
    case stop = 0
    case pause = 16
    case play = 32
    case loop = 80
    case bounce = 128
    case reverse = 176
    case restart = 224
    case gotoPosition = 235
}
```

## 8. Build and Run

### Requirements
- macOS 12+
- Xcode Command Line Tools / Swift toolchain
- OLA library: `brew install ola`
- Syphon.framework (copy to .build/release/)
- NDI SDK (optional, for NDI support)

### Build
```bash
cd /path/to/dmx-test
swift build -c release
```

### Run
```bash
# Copy Syphon framework first
cp -R /path/to/Syphon.framework .build/arm64-apple-macosx/release/

# Run
.build/arm64-apple-macosx/release/dmx-visualizer
```

### Web Interface
Open http://localhost:8080 in browser for control UI

## 9. Configuration

### Gobo Folders
Default scan locations:
- `~/Documents/GeoDraw/gobos`
- `~/Documents/GoboCreator/Library`

### Media Slots
Configure via web API or directly in MediaSlotConfig:
```json
{
  "slot": 201,
  "type": "video",
  "path": "/path/to/video.mp4"
}
```

### Display Output
Select via web interface or OutputSettingsWindowController

## 10. External Dependencies

| Dependency | Purpose | Installation |
|------------|---------|--------------|
| OLA | DMX input | `brew install ola` |
| Syphon | Video output sharing | Copy framework |
| NDI SDK | Network video I/O | Download from NDI |
| Metal | GPU rendering | Built into macOS |
| AVFoundation | Video playback | Built into macOS |
| Network.framework | Web server | Built into macOS |
