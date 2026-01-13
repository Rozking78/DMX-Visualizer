# Output Configuration - Implementation Notes

This document outlines what has been implemented and what still needs to be done for the Steam Deck Output Configuration feature to fully work.

## Overview

The Output Config system allows remote configuration of video outputs from a Steam Deck, including:
- **8-point Keystone correction** (perspective warping)
- **Position controls** (X/Y offset, scale, rotation)
- **Edge blending/feathering** (for multi-projector setups)

---

## What Has Been Implemented

### 1. Web Interface (`/output-config`)

**File:** `src-tauri/web_remote/output-config.html`

A fully functional web UI accessible at `http://<host>:8080/output-config` with:
- [x] 8-point keystone canvas with draggable corners
- [x] Position, scale, rotation sliders
- [x] Output list/selection
- [x] Full Steam Deck gamepad support
- [x] Touch support for canvas interaction
- [x] WebSocket connection for real-time updates
- [x] Mode switching (Position / Keystone / Blend)

**Gamepad Control Scheme:**
| Control | Action |
|---------|--------|
| Left Stick | Move position / selected keystone corner |
| Right Stick | Scale (Y-axis) / Rotation (X-axis) |
| D-Pad | Navigate corners (keystone) / outputs |
| A | Apply configuration |
| X | Toggle Keystone mode |
| Y | Toggle Blend mode |
| LB/RB | Cycle through outputs |
| Select | Reset to defaults |

### 2. API Endpoints

**File:** `src-tauri/src/web_server.rs`

New REST API endpoints added:

```
GET  /api/outputs                 - List all outputs
GET  /api/output/:id              - Get single output config
POST /api/output/:id/config       - Update full config (keystone + position + blend)
POST /api/output/:id/keystone     - Update keystone only
POST /api/output/:id/position     - Update position only
POST /api/output/:id/blend        - Update blend only
POST /api/output/:id/reset        - Reset output to defaults
```

### 3. Data Structures

**File:** `src-tauri/src/web_server.rs`

```rust
OutputConfig {
    id: u32,
    name: String,
    output_type: String,  // "hdmi", "displayport", "ndi"
    keystone: KeystoneConfig,
    position: PositionConfig,
    blend: BlendConfig,
}

KeystoneConfig {
    top_left, top_mid, top_right,
    right_mid, bottom_right, bottom_mid,
    bottom_left, left_mid: Point2D  // normalized 0.0-1.0
}

PositionConfig {
    x: f64,        // pixel offset
    y: f64,        // pixel offset
    scale: f64,    // 1.0 = 100%
    rotation: f64  // degrees
}

BlendConfig {
    top, bottom, left, right: EdgeBlend {
        enabled: bool,
        width: f64,   // 0.0-0.5 (percentage of output)
        curve: f64,   // 0.0-1.0 (blend curve)
        gamma: f64    // 0.1-3.0 (gamma correction)
    }
}
```

### 4. Standalone Tauri App (Source Only)

**Location:** `/home/deck/steamdeck-output-config/`

A complete React/Tauri application ready for building on a system with GTK dev libraries:
- React components for all UI elements
- Zustand state management
- WebSocket client
- Full gamepad controller

**Cannot be built on SteamOS** due to missing development packages.

---

## What Still Needs To Be Done

### HIGH PRIORITY

#### 1. Video Rendering Pipeline Integration

The backend currently stores output configurations but does NOT apply them to actual video output.

**TODO in `src-tauri/src/main.rs` or new file `src-tauri/src/output_renderer.rs`:**

```rust
// Need to implement:
pub struct OutputRenderer {
    // GPU context for rendering
    // Shader programs for transforms
}

impl OutputRenderer {
    /// Apply keystone transformation to video frame
    pub fn apply_keystone(&self, frame: &VideoFrame, keystone: &KeystoneConfig) -> VideoFrame {
        // 1. Create perspective transformation matrix from 8 corner points
        // 2. Use GPU shader to warp the frame
        // 3. Return transformed frame
    }

    /// Apply position/scale/rotation
    pub fn apply_transform(&self, frame: &VideoFrame, position: &PositionConfig) -> VideoFrame {
        // 1. Create affine transformation matrix
        // 2. Apply to frame
    }

    /// Apply edge blending
    pub fn apply_blend(&self, frame: &VideoFrame, blend: &BlendConfig) -> VideoFrame {
        // 1. Generate gradient masks for each enabled edge
        // 2. Apply gamma correction to gradients
        // 3. Multiply frame alpha by gradient masks
    }
}
```

**Recommended approach:**
- Use `wgpu` or `glow` for GPU-accelerated rendering
- Create GLSL/WGSL shaders for perspective transform
- Integrate with existing NDI/video output pipeline

#### 2. Output Discovery & Management

Currently outputs are hardcoded. Need dynamic detection.

**TODO:**

```rust
// In web_server.rs or new output_manager.rs

pub async fn discover_outputs() -> Vec<OutputConfig> {
    let mut outputs = Vec::new();

    // 1. Detect physical displays
    // Use libdrm or xrandr to enumerate connected displays
    // outputs.push(OutputConfig::from_display(display));

    // 2. Include NDI outputs
    // For each configured NDI stream, create an output entry

    // 3. Load saved configurations from disk
    // Match saved configs to discovered outputs

    outputs
}
```

#### 3. Configuration Persistence

Configurations are lost on restart.

**TODO:**

```rust
// Save/load output configs to JSON file
const CONFIG_FILE: &str = "output_configs.json";

pub fn save_output_configs(configs: &HashMap<u32, OutputConfig>) -> Result<()> {
    let json = serde_json::to_string_pretty(configs)?;
    fs::write(CONFIG_FILE, json)?;
    Ok(())
}

pub fn load_output_configs() -> Result<HashMap<u32, OutputConfig>> {
    let json = fs::read_to_string(CONFIG_FILE)?;
    let configs = serde_json::from_str(&json)?;
    Ok(configs)
}
```

### MEDIUM PRIORITY

#### 4. Real-time Preview

Send preview frames to the web UI via WebSocket.

**TODO:**

```rust
// In web_server.rs, extend WebSocket handler

// Send preview frames as base64 JPEG
async fn send_preview_frame(tx: &broadcast::Sender<String>, output_id: u32) {
    let frame = capture_output_preview(output_id);
    let jpeg = encode_jpeg(&frame, 50); // 50% quality for speed
    let base64 = base64::encode(&jpeg);
    let _ = tx.send(format!("preview:{}:{}", output_id, base64));
}
```

**Web UI changes needed in `output-config.html`:**
```javascript
// Handle preview frames
if (data.startsWith('preview:')) {
    const [_, outputId, base64] = data.split(':');
    // Update canvas background with preview image
}
```

#### 5. Test Pattern Generator

Add test patterns for alignment.

**TODO:**

```rust
pub enum TestPattern {
    Grid,
    Crosshatch,
    ColorBars,
    White,
    Black,
    Gradient,
}

pub fn generate_test_pattern(pattern: TestPattern, width: u32, height: u32) -> VideoFrame {
    // Generate pattern
}
```

**API endpoint:**
```
POST /api/output/:id/test-pattern
Body: { "pattern": "grid" }
```

#### 6. Multi-Output Alignment Tools

For edge-blending multiple projectors:

- Grid overlay toggle
- Edge alignment guides
- Overlap region visualization
- Brightness matching tools

### LOW PRIORITY

#### 7. Preset System

Save/recall output configuration presets.

```
POST /api/output-presets              - Save current config as preset
GET  /api/output-presets              - List presets
POST /api/output-presets/:name/apply  - Apply preset
```

#### 8. Undo/Redo

Track configuration history for undo support.

#### 9. Native App Build Pipeline

Set up GitHub Actions to build the standalone Tauri app:

```yaml
# .github/workflows/build-output-config.yml
name: Build Output Config App
on:
  push:
    paths:
      - 'steamdeck-output-config/**'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y libgtk-3-dev libwebkit2gtk-4.0-dev
      - name: Build AppImage
        run: |
          cd steamdeck-output-config
          npm install
          npm run tauri build
      - uses: actions/upload-artifact@v3
        with:
          name: output-config-appimage
          path: steamdeck-output-config/src-tauri/target/release/bundle/appimage/*.AppImage
```

---

## File Structure

```
steamdeck-dmx-controller/
├── src-tauri/
│   ├── src/
│   │   ├── web_server.rs        # API endpoints + output config handlers
│   │   ├── output_renderer.rs   # TODO: Implement rendering pipeline
│   │   └── output_manager.rs    # TODO: Output discovery & persistence
│   └── web_remote/
│       ├── index.html           # Main web remote
│       └── output-config.html   # Output configuration UI
└── OUTPUT_CONFIG_IMPLEMENTATION.md  # This file

steamdeck-output-config/          # Standalone app (build on full Linux)
├── src/
│   ├── App.jsx
│   ├── components/
│   │   └── output-config/
│   │       ├── GamepadController.jsx
│   │       ├── KeystoneCanvas.jsx
│   │       ├── BlendEditor.jsx
│   │       └── PositionControls.jsx
│   └── utils/
│       ├── store.js
│       └── websocket.js
└── src-tauri/
    └── ...
```

---

## Testing Checklist

- [ ] Web UI loads at `/output-config`
- [ ] Outputs list populated from API
- [ ] Keystone corners draggable on canvas
- [ ] Position sliders update config
- [ ] Gamepad detected and functional
- [ ] WebSocket connection established
- [ ] Config persists after restart
- [ ] Keystone actually affects video output
- [ ] Edge blending renders correctly
- [ ] Multi-output alignment works

---

## Dependencies to Add (for rendering)

```toml
# Cargo.toml additions for GPU rendering
wgpu = "0.18"           # WebGPU for cross-platform GPU
image = "0.24"          # Image processing
nalgebra = "0.32"       # Matrix math for transforms
```

---

## Contact / Questions

For questions about this implementation, refer to the conversation where this was designed, or check the standalone app source at `/home/deck/steamdeck-output-config/` for reference implementations of the UI components.
