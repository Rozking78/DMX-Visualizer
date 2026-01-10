# DMX Visualizer - Beta Development Plan

## Overview
Roadmap to first beta release for external LD review.

**Principles:**
- Do it right - quality over speed
- Professional polish for external reviewers
- Regular source code backups with change notes
- Secure licensing for distribution
- **Optimized for Apple Silicon (M1+)**

---

## Phase 0: Apple Silicon Optimization
*First-class performance on M1/M2/M3/M4 Macs*

### 0.1 Metal Rendering Optimizations

**Unified Memory Architecture (UMA):**
- [ ] Use `MTLResourceStorageModeShared` for all buffers (zero-copy CPU↔GPU)
- [ ] Remove any unnecessary buffer copies
- [ ] Leverage shared memory for DMX data → GPU uniforms

**Tile-Based Deferred Rendering (TBDR):**
- [ ] Use memoryless textures for intermediate render targets
- [ ] Optimize load/store actions (`.clear`, `.dontCare`)
- [ ] Merge render passes where possible (single-pass G-buffer)
- [ ] Implement programmable blending for compositing

**Hidden Surface Removal (HSR):**
- [ ] Draw order: opaque → alpha-tested → translucent
- [ ] Add `[[early_fragment_tests]]` attribute where applicable
- [ ] Avoid depth pre-pass (not needed on Apple GPU)

### 0.2 Shader Optimizations

**Half-Precision Math:**
- [ ] Convert float → half for colors, UVs, positions where possible
- [ ] Use `h` suffix for literals (`0.5h` not `0.5`)
- [ ] Higher ALU occupancy = better performance

**Constant Address Space:**
- [ ] Use `constant` for uniform buffers (enables GPU preloading)
- [ ] Fixed-size arrays for object uniforms
- [ ] Avoid `device` address space for read-only data

**Memory Access Patterns:**
- [ ] Use signed types for loop indices (enables vectorization)
- [ ] Avoid runtime-sized stack arrays
- [ ] Batch adjacent memory accesses (SIMD-friendly structs)

### 0.3 Video/NDI Zero-Copy Pipeline

**IOSurface Integration:**
- [ ] Use `CVMetalTextureCache` for video frame → Metal texture (zero-copy)
- [ ] Leverage `IOSurface` for inter-framework memory sharing
- [ ] Proper `IOSurfaceUseCount` management for buffer pooling

**VideoToolbox Hardware Acceleration:**
- [ ] Use hardware ProRes decoder (M1 Pro/Max have extra engines)
- [ ] Hardware H.264/H.265 decode via `VTDecompressionSession`
- [ ] Direct Metal texture output from decoder

**NDI Output Optimization:**
- [ ] Use `MTLBlitCommandEncoder` for efficient texture readback
- [ ] Double-buffer capture to avoid GPU stalls
- [ ] Consider shared memory for NDI frame buffer

### 0.4 Profiling & Validation

**Tools:**
- [ ] Profile with Metal System Trace (Instruments)
- [ ] Use GPU Frame Debugger to verify load/store actions
- [ ] Check for GPU bubbles (cross-pass dependencies)
- [ ] Validate 16-byte alignment on all uniform structs

**Targets:**
- [ ] Maintain 60 FPS at 4K with 60 fixtures
- [ ] GPU utilization > 90% (no bubbles)
- [ ] Memory bandwidth < 50% of peak
- [ ] Power efficiency (cool and quiet operation)

---

## Phase 1: Foundation & Safety
*Protect the work before adding more*

### 1.1 Backup System
- [ ] Automated source backup script
- [ ] Timestamped backup folders
- [ ] Change notes log (CHANGELOG.md)
- [ ] Git repository setup (if not already)
- [ ] Remote backup (GitHub private repo)

### 1.2 Code Protection & Licensing
- [ ] Research licensing options (hardware ID, activation codes, time-limited)
- [ ] Implement license validation system
- [ ] Obfuscation/protection strategy
- [ ] Beta license key generation
- [ ] License check on startup

---

## Phase 2: DMX Mode System
*Flexible channel layouts for different use cases*

### 2.1 Mode Definitions

**Mode 1: Full (33 channels)** - Current default
| CH | Function |
|----|----------|
| 1-33 | All features (existing) |

**Mode 2: Standard (23 channels)** - No shutters/iris
| CH | Function |
|----|----------|
| 1 | Content |
| 2-3 | X Position (16-bit) |
| 4-5 | Y Position (16-bit) |
| 6 | Z-Index |
| 7-8 | Scale (16-bit) |
| 9-10 | H-Scale (16-bit) |
| 11-12 | V-Scale (16-bit) |
| 13 | Softness |
| 14 | Opacity |
| 15 | Intensity |
| 16 | Red |
| 17 | Green |
| 18 | Blue |
| 19 | Rotation |
| 20 | Spin |
| 21 | Video Playback |
| 22 | Video Mode |
| 23 | Video Volume |

**Mode 3: Compact (10 channels)** - Flash & trash
| CH | Function |
|----|----------|
| 1 | Content |
| 2 | X Position (8-bit) |
| 3 | Y Position (8-bit) |
| 4 | Scale |
| 5 | Opacity |
| 6 | Red |
| 7 | Green |
| 8 | Blue |
| 9 | Softness |
| 10 | Spin |

**Fixtures per universe:**
- Mode 1: 15 fixtures (495 ch)
- Mode 2: 22 fixtures (506 ch)
- Mode 3: 51 fixtures (510 ch)

### 2.2 Implementation Tasks
- [x] Create DMXMode enum (full, standard, compact)
- [x] Refactor channel parsing to use mode
- [x] Update SceneController for variable channel count
- [x] Create mode-specific parsing functions
- [ ] Test all three modes with console

---

## Phase 3: Console-Style Patch System
*Professional patching workflow*

### 3.1 New Patch UI
- [x] Redesign Settings → DMX tab as Patch interface
- [x] Fields: Fixture Count, Mode (dropdown), Universe, Address
- [x] Default mode: 33ch Full
- [x] Live patch info display (fixtures × channels, universes needed)
- [ ] Validation (address + channels ≤ 512)

### 3.2 Multi-Mode Support
- [x] Store mode selection in show file
- [x] Apply mode on show load
- [ ] Update help/documentation for modes

---

## Phase 4: Layout System (App GUI)
*Grid positioning tool - foundation for MA3 plugin*

### 4.1 Layout Window
- [x] New menu: View → Layout Editor (Cmd+L)
- [x] Visual grid preview
- [x] Fixture count input (reads from patch)

### 4.2 Layout Types
- [x] Full Grid (rows × columns)
- [x] Perimeter (edges only)
- [x] Line (single row or column)
- [x] Rows (multiple horizontal lines)

### 4.3 Layout Options
- [x] Direction: Across / Down
- [ ] Sections/Parts (fixture ranges)
- [x] Spacing (pixels or percentage)
- [x] Margins (anchor from edges)
- [x] Preview before apply

### 4.4 Position Output
- [x] Calculate X/Y for each fixture
- [x] Apply to current DMX state (live preview)
- [ ] Option to output via Art-Net/sACN
- [ ] Store as preset data (for MA3 recording)

---

## Phase 5: Web GUI
*Remote media management*

### 5.1 Web Server
- [ ] Built-in HTTP server (port 8080)
- [ ] Accessible from any device on network
- [ ] Responsive design (tablet-friendly)

### 5.2 Media Management Pages
- [ ] **Gobos**: Drag & drop upload, grid view, delete
- [ ] **Videos**: Drag & drop upload, assign to slots
- [ ] **NDI Sources**: List available, assign to slots
- [ ] **Syphon Sources**: List available, assign to slots

### 5.3 Status & Control
- [ ] Current output preview (thumbnail)
- [ ] Active sources display
- [ ] Basic settings access

---

## Phase 6: MA3 Lua Plugin
*Console integration for layout control*

### 6.1 Plugin Development
- [x] Create GeoDraw.lua plugin
- [x] Read patch context (fixture count, selection)
- [x] Layout command interface

### 6.2 Layout Commands
```lua
-- Actual usage (select fixtures first)
Plugin "GeoDraw" "Grid" "4" "4"       -- 4x4 grid
Plugin "GeoDraw" "Grid" "auto"        -- Auto-calculate optimal
Plugin "GeoDraw" "Perimeter" "4" "4"  -- Edge layout
Plugin "GeoDraw" "Line" "h"           -- Horizontal line
Plugin "GeoDraw" "Line" "v"           -- Vertical line
Plugin "GeoDraw" "Rows" "3"           -- 3 rows
```

### 6.3 Control Fixture (Optional)
- [ ] Design control fixture channel layout
- [ ] Layout type selection channel
- [ ] Rows/columns parameter channels
- [ ] Trigger/apply channel
- [ ] Create fixture profile XML

---

## Phase 7: CITP/MSEX Integration
*Thumbnail exchange with consoles*

### 7.0 Research (Prior to Implementation)
- [ ] Research CITP as a patching method (some consoles use CITP for fixture patching)
- [ ] Document which consoles support CITP patch vs thumbnail-only
- [ ] Determine if we need to implement CITP patch receive capability

### 7.1 CITP Server
- [ ] UDP discovery (port 4809)
- [ ] TCP connection handling
- [ ] PINF (peer info) messages
- [ ] MSEX (media server extensions)

### 7.2 Thumbnail Generation
- [ ] Generate gobo thumbnails (all 150+)
- [ ] Capture video slot thumbnails
- [ ] NDI source preview frames
- [ ] Cache management

### 7.3 MSEX Features
- [ ] ELin (Element Library info)
- [ ] EThn (Element Thumbnails)
- [ ] LSta (Layer Status)
- [ ] MEIn (Media Element Info)

### 7.4 Console Testing
- [ ] Test with MA3
- [ ] Test with Hog4 (if available)
- [ ] Test with Chamsys (if available)

---

## Phase 8: Polish & Packaging
*Beta-ready presentation*

### 8.1 UI Polish
- [ ] Consistent styling across all windows
- [ ] Professional icons
- [ ] About dialog with version/credits
- [ ] Error messages (user-friendly)

### 8.2 Documentation
- [x] User Guide (created)
- [x] In-app help system (created)
- [ ] MA3 plugin documentation
- [ ] Quick reference card (PDF)
- [ ] Video tutorial (optional)

### 8.3 Installer Package
- [ ] Create .app bundle
- [ ] Sign with Developer ID
- [ ] Create DMG installer
- [ ] Include documentation
- [ ] Include sample gobos
- [ ] Include MA3 plugin files

### 8.4 Beta Distribution
- [ ] Generate beta license keys
- [ ] Create download page
- [ ] Feedback collection method
- [ ] Bug reporting process

---

## Development Workflow

### Before Each Session
1. Pull latest from backup/git
2. Note what you're working on

### After Each Session
1. Test changes
2. Update CHANGELOG.md
3. Backup source code
4. Commit to git with descriptive message

### Backup Schedule
- After every significant change
- Before any major refactor
- Before ending work session
- Weekly full backup to external location

---

## Priority Order

| Priority | Phase | Effort | Why |
|----------|-------|--------|-----|
| 0 | Phase 0: Apple Silicon | Ongoing | Performance foundation |
| 1 | Phase 1.1: Backup System | 0.5 day | **Protect work first** |
| 2 | Phase 2: DMX Modes | 1 day | Core feature |
| 3 | Phase 3: Patch System | 0.5 day | UI for modes |
| 4 | Phase 4: Layout GUI | 2-3 days | Key workflow feature |
| 5 | Phase 5: Web GUI | 2 days | Remote management |
| 6 | Phase 6: MA3 Plugin | 2-3 days | Console integration |
| 7 | Phase 7: CITP | 3-4 days | Console thumbnails |
| 8 | Phase 8: Polish | 2-3 days | Beta-ready |
| 9 | Phase 1.2: Licensing | 1 day | **Last before release** |

**Note:** Phase 0 (Apple Silicon) is ongoing throughout development - apply optimizations as each feature is built.

**Estimated Total: 2-3 weeks** (working steadily, doing it right)

---

## Changelog Template

```markdown
## [Version] - YYYY-MM-DD

### Added
- New feature description

### Changed
- Modified behavior

### Fixed
- Bug fix description

### Removed
- Deprecated feature
```

---

## File Locations

| Item | Path |
|------|------|
| Source Code | `/Users/roswellking/Desktop/DMX Visualizer/dmx visualizer/` |
| Backups | `/Users/roswellking/Desktop/DMX Visualizer Source Backup/` |
| Documentation | `.../dmx visualizer/docs/` |
| Gobos | `.../dmx visualizer/gobos/` |
| Build Output | `.../dmx visualizer/.build/debug/` |

---

*Plan created: 2025-12-21*
*Target: Beta release for LD review*

---

## Post-Beta Features

*Features deferred until after initial beta release*

### Per-Fixture Mode Support
- Allow each fixture to have its own mode (33ch/23ch/10ch)
- Variable channel count addressing
- Mode column in patch table with per-fixture editing
- Show file saves per-fixture modes
- **Complexity:** High - affects DMX parsing, patch system, addressing calculation
