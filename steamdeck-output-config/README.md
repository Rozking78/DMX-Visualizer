# SteamDeck Output Config

A standalone Steam Deck application for remotely configuring video output settings (keystone, position, blend) for the DMX Visualizer.

## Features

- **8-point Keystone Correction** - Perspective warping with draggable corners
- **Position Controls** - X/Y offset, scale, rotation
- **Edge Blending** - Soft edge feathering for multi-projector setups
- **Full Gamepad Support** - Steam Deck controller with analog sticks
- **WebSocket Sync** - Real-time connection to DMX Visualizer

## Gamepad Controls

| Control | Action |
|---------|--------|
| Left Stick | Move position / keystone corner |
| Right Stick | Scale (Y) / Rotation (X) |
| D-Pad | Navigate corners / outputs |
| A | Apply configuration |
| X | Toggle Keystone mode |
| Y | Toggle Blend mode |
| LB/RB | Cycle through outputs |
| Select | Reset to defaults |

## Building

**Note:** Cannot be built directly on SteamOS due to missing GTK development packages. Build on a full Linux system (Ubuntu/Arch) or use GitHub Actions.

### Prerequisites

```bash
# Ubuntu/Debian
sudo apt-get install libgtk-3-dev libwebkit2gtk-4.0-dev

# Arch Linux
sudo pacman -S gtk3 webkit2gtk
```

### Build Commands

```bash
npm install
npm run tauri build
```

The AppImage will be in `src-tauri/target/release/bundle/appimage/`

## Alternative: Web Version

A web-based version is included in the main DMX Visualizer at `/output-config`. This works immediately without building a native app.

## Project Structure

```
steamdeck-output-config/
├── src/
│   ├── App.jsx                 # Main application
│   ├── components/
│   │   └── output-config/
│   │       ├── GamepadController.jsx  # Full gamepad support
│   │       ├── KeystoneCanvas.jsx     # 8-point warping
│   │       ├── BlendEditor.jsx        # Edge blending
│   │       └── PositionControls.jsx   # Position/scale/rotation
│   ├── utils/
│   │   ├── store.js            # Zustand state management
│   │   └── websocket.js        # WebSocket client
│   └── styles/
│       └── global.css
├── src-tauri/
│   ├── src/
│   │   └── main.rs             # Tauri backend
│   ├── tauri.conf.json
│   └── Cargo.toml
└── package.json
```

## Configuration

Edit the WebSocket URL in the app settings to connect to your DMX Visualizer instance:

```
ws://<visualizer-ip>:8080/ws
```

## See Also

- `../sessions/OUTPUT_CONFIG_IMPLEMENTATION.md` - Full implementation status and TODOs
