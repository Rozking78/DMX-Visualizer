# DMX Visualizer - User Guide

## Overview

DMX Visualizer (GeoDraw) is a real-time graphics engine controlled via DMX protocols (Art-Net and sACN/E1.31). It renders shapes, gobos, and video content that can be output via Syphon or NDI for use in media servers, live production, and LED wall content.

**Key Features:**
- 33-channel fixtures with full control over position, scale, color, rotation, and effects
- Built-in geometric shapes (circle, triangle, square, hexagon, stars, etc.)
- 150 gobo slots for texture patterns
- 55 video/NDI input slots
- Framing shutters with 4-blade control
- Iris control
- Syphon and NDI output

---

## Quick Start

1. **Launch the application**
2. **Configure Settings** (⌘,):
   - Set the number of fixtures (1-60)
   - Choose your DMX protocol (Art-Net, sACN, or Both)
   - Select your network interface
   - Set start universe and address
3. **Send DMX** from your lighting console
4. **Enable output** via Output menu (Syphon or NDI)

---

## DMX Channel Layout

Each fixture uses **33 channels**. With 15 fixtures per universe, you get 495 channels used per universe.

### Channel Reference Table

| Channel | Function | Range | Notes |
|---------|----------|-------|-------|
| **CH1** | Shape/Gobo/Media | 0-255 | See Content Selection below |
| **CH2-3** | X Position | 16-bit | 0=left, 65535=right |
| **CH4-5** | Y Position | 16-bit | 0=top, 65535=bottom |
| **CH6** | Z-Index | 0-255 | Layer order (higher = front) |
| **CH7-8** | Scale | 16-bit | Overall size |
| **CH9-10** | H-Scale | 16-bit | Horizontal stretch |
| **CH11-12** | V-Scale | 16-bit | Vertical stretch |
| **CH13** | Softness | 0-255 | Edge blur amount |
| **CH14** | Opacity | 0-255 | Transparency |
| **CH15** | Intensity | 0-255 | Brightness multiplier |
| **CH16** | Red | 0-255 | Color component |
| **CH17** | Green | 0-255 | Color component |
| **CH18** | Blue | 0-255 | Color component |
| **CH19** | Rotation | 0-255 | 0=0°, 255=360° |
| **CH20** | Spin Speed | 0-255 | Continuous rotation speed |
| **CH21** | Video Playback | 0-255 | See Video Control below |
| **CH22** | Video Mode | 0-255 | 0-127=color, 128-255=mask |
| **CH23** | Video Volume | 0-255 | Audio level |
| **CH24** | Iris | 0-255 | 0=closed, 255=open |
| **CH25** | Blade 1 (Top) Insert | 0-255 | Insertion depth |
| **CH26** | Blade 1 (Top) Angle | 0-255 | 0=-45°, 128=0°, 255=+45° |
| **CH27** | Blade 2 (Bottom) Insert | 0-255 | Insertion depth |
| **CH28** | Blade 2 (Bottom) Angle | 0-255 | Angle adjustment |
| **CH29** | Blade 3 (Left) Insert | 0-255 | Insertion depth |
| **CH30** | Blade 3 (Left) Angle | 0-255 | Angle adjustment |
| **CH31** | Blade 4 (Right) Insert | 0-255 | Insertion depth |
| **CH32** | Blade 4 (Right) Angle | 0-255 | Angle adjustment |
| **CH33** | Shutter Rotation | 0-255 | Rotate all 4 blades together |

---

## Content Selection (CH1)

Channel 1 determines what content is displayed:

### Shapes (0-20)
| Value | Shape |
|-------|-------|
| 0 | Off/Black |
| 1 | Line |
| 2 | Circle |
| 3 | Triangle |
| 4 | Triangle Star |
| 5 | Square |
| 6 | Square Star |
| 7 | Pentagon |
| 8 | Pentagon Star |
| 9 | Hexagon |
| 10 | Hexagon Star |
| 11 | Septagon |
| 12 | Septagon Star |
| 13-20 | Reserved |

### Gobos (21-200)
| Range | Description |
|-------|-------------|
| 21-50 | Built-in gobos |
| 51-200 | Custom gobos (loaded from gobo folders) |

**Gobo Categories:**
- Breakups
- Geometric
- Nature
- Cosmic
- Textures
- Architectural
- Abstract
- Special

### Media Slots (201-255)
| Range | Description |
|-------|-------------|
| 201-255 | Video files or NDI sources |

Each of the 55 slots can be assigned to a video file or NDI source via Media → Media Slots (⌘M).

---

## Video Playback Control (CH21)

| Value | Function |
|-------|----------|
| 0 | Stop (output black) |
| 1-10 | Pause (freeze current frame) |
| 11-40 | Play (normal playback) |
| 41-55 | Play Hold (play once, freeze on last frame) |
| 56-70 | Play Loop (loop at end) |
| 71-85 | Play Bounce (ping-pong playback) |
| 86-100 | Reverse (play backwards) |
| 101-115 | Restart (jump to start + play) |
| 116-235 | Goto Position (scrub 0-100%) |
| 236-255 | Reserved |

### Video Mode (CH22)
| Value | Function |
|-------|----------|
| 0-127 | Full color output |
| 128-255 | Grayscale mask mode (for compositing) |

---

## Framing Shutters (CH25-33)

The 4-blade framing shutter system works like professional moving lights:

### Blade Control
Each blade has two channels:
- **Insertion** (0-255): How far the blade extends into the beam (0=retracted, 255=fully inserted)
- **Angle** (0-255): Blade rotation (0=-45°, 128=0°, 255=+45°)

### Blade Positions
| Blade | Insert CH | Angle CH | Direction |
|-------|-----------|----------|-----------|
| Top | CH25 | CH26 | Cuts from top |
| Bottom | CH27 | CH28 | Cuts from bottom |
| Left | CH29 | CH30 | Cuts from left |
| Right | CH31 | CH32 | Cuts from right |

### Assembly Rotation (CH33)
Rotates all 4 blades together as a unit:
- 0 = -45°
- 128 = 0° (no rotation)
- 255 = +45°

---

## Iris Control (CH24)

| Value | Result |
|-------|--------|
| 0 | Fully closed (no output) |
| 128 | Half open |
| 255 | Fully open |

The iris provides a soft circular mask that closes from the edges toward the center.

---

## Menu Reference

### Application Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| About DMX Visualizer | | Version info |
| Settings... | ⌘, | Configure fixtures, protocol, network |
| Quit | ⌘Q | Exit application |

### File Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| New Show | ⌘N | Reset to defaults |
| Open Show... | ⌘O | Load .geodraw show file |
| Save Show | ⌘S | Save current show |
| Save Show As... | ⇧⌘S | Save to new file |

### Media Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Media Slots... | ⌘M | Configure video/NDI sources |
| Refresh Gobos | ⌘G | Reload gobo textures |
| Refresh NDI Sources | ⌘R | Scan for NDI sources |

### Output Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Syphon Output | ⌘Y | Toggle Syphon server |
| NDI Output | ⇧⌘N | Toggle NDI sender |

### View Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Enter Full Screen | ⌘F | Toggle fullscreen mode |

### Window Menu
| Item | Shortcut | Description |
|------|----------|-------------|
| Minimize | ⌘M | Minimize window |
| Zoom | | Maximize window |

---

## Settings

Access via **⌘,** or Application Menu → Settings

### DMX Tab
- **Fixture Count**: Number of fixtures to control (1-60)
- **Start Universe**: First DMX universe (1-63999)
- **Start Address**: First DMX address (1-512)
- **Protocol**: Art-Net, sACN (E1.31), or Both
- **Network Interface**: Select network adapter

### Display Tab
- **Resolution Preset**: 720p, 1080p, 1440p, 4K, or Custom
- **Width/Height**: Custom resolution dimensions

**Note:** Resolution changes require an application restart.

---

## Media Slots Configuration

Access via **⌘M** or Media Menu → Media Slots

### Assigning Video Files
1. Select a slot (201-255)
2. Click "Choose Video..."
3. Select a video file (.mp4, .mov, .m4v)

### Assigning NDI Sources
1. Click "Refresh NDI" to scan the network
2. Select a slot
3. Choose an NDI source from the dropdown

### Supported Formats
- **Video**: H.264, H.265, ProRes (.mp4, .mov, .m4v)
- **NDI**: Any NDI source on the network

---

## Output Options

### Syphon Output
Syphon allows real-time frame sharing with other macOS applications.

**To enable:**
1. Output → Syphon Output (⌘Y)
2. Server appears as "GeoDraw"

**Compatible applications:**
- Resolume Arena/Avenue
- MadMapper
- VDMX
- OBS (with Syphon plugin)
- Any Syphon client

### NDI Output
NDI (Network Device Interface) streams video over your network.

**To enable:**
1. Output → NDI Output (⇧⌘N)
2. Sender appears as "GeoDraw"

**Requirements:**
- NDI SDK installed at `/Library/NDI SDK for Apple/`

**Compatible applications:**
- NDI Studio Monitor
- OBS (with NDI plugin)
- vMix
- Wirecast
- Any NDI receiver

---

## Gobo System

### Gobo Folders
Gobos are loaded from two locations:
1. `DMX Visualizer/gobos/` (built-in)
2. `~/Documents/GoboCreator/Library/` (custom)

### File Naming Convention
```
gobo_[ID]_[name].png
```
Example: `gobo_051_leaves_sparse.png`

### Creating Custom Gobos
1. Create a PNG image (recommended: 512x512 or 1024x1024)
2. Use white for light areas, black for blocked areas
3. Save with the naming convention above
4. Place in one of the gobo folders
5. Refresh with ⌘G

### GoboCreator Integration
Gobos created in GoboCreator are automatically available in DMX Visualizer. Use ⌘G to refresh after creating new gobos.

---

## Show Files

Show files (.geodraw) save your complete configuration:
- Fixture count
- Start universe and address
- Protocol and interface settings
- Resolution settings

### Saving a Show
1. File → Save Show (⌘S) or Save Show As (⇧⌘S)
2. Choose location and filename
3. File saves as JSON with .geodraw extension

### Loading a Show
1. File → Open Show (⌘O)
2. Select a .geodraw file
3. Settings are applied immediately

---

## Network Configuration

### Art-Net
- Default port: 6454
- Supports universes 0-32767
- Broadcasts on selected interface

### sACN (E1.31)
- Default port: 5568
- Supports universes 1-63999
- Uses multicast addressing

### Multi-Universe Patching
With 33 channels per fixture and 15 fixtures per universe:
- Universe 1: Fixtures 1-15 (channels 1-495)
- Universe 2: Fixtures 16-30 (channels 1-495)
- etc.

---

## Troubleshooting

### No DMX Response
1. Check network interface selection in Settings
2. Verify protocol matches your console
3. Ensure correct universe/address
4. Check firewall settings

### Gobos Not Appearing
1. Verify file naming: `gobo_[ID]_[name].png`
2. Check file location (gobos folder)
3. Use ⌘G to refresh

### Video Not Playing
1. Confirm slot assignment in Media Slots (⌘M)
2. Check video format compatibility
3. Verify CH21 playback value (11-40 for play)

### NDI Not Working
1. Install NDI SDK from ndi.tv
2. Check sender/receiver are on same network
3. Verify NDI source name in Media Slots

### Syphon Not Visible
1. Ensure Syphon Output is enabled (⌘Y)
2. Check receiving application for "GeoDraw" server
3. Both apps must be on same machine

---

## Keyboard Shortcuts Reference

| Shortcut | Action |
|----------|--------|
| ⌘, | Settings |
| ⌘N | New Show |
| ⌘O | Open Show |
| ⌘S | Save Show |
| ⇧⌘S | Save Show As |
| ⌘M | Media Slots |
| ⌘G | Refresh Gobos |
| ⌘R | Refresh NDI Sources |
| ⌘Y | Toggle Syphon |
| ⇧⌘N | Toggle NDI |
| ⌘F | Full Screen |
| ⌘Q | Quit |

---

## Technical Specifications

- **Render Engine**: Metal (GPU accelerated)
- **Frame Rate**: 60 FPS
- **Max Fixtures**: 60 (4 universes)
- **Channels per Fixture**: 33
- **Supported Resolutions**: 720p to 4K
- **Color Depth**: 8-bit per channel (BGRA)
- **Protocols**: Art-Net, sACN (E1.31)

---

## Version History

### Version 1.2
- Added Syphon output
- Added NDI output
- Custom resolution support
- Framing shutters (4-blade)
- Iris control
- GoboCreator integration

### Version 1.1
- 55 media slots (video + NDI)
- Video playback control
- Video mask mode

### Version 1.0
- Initial release
- Shapes and gobos
- Art-Net and sACN support

---

*DMX Visualizer - Professional DMX-controlled graphics for live production*
