# GeoDraw MA3 Lua Plugin

## Overview

Calculates and applies layout positions/scales to GeoDraw fixtures directly from the MA3 console. Use this to quickly arrange fixtures in grids, lines, or perimeter layouts, then record to presets.

## Installation

1. Copy `GeoDraw.lua` and `GeoDraw.xml` to:
   ```
   MALightingTechnology/gma3_library/datapools/plugins/
   ```

2. In MA3, go to **Plugins** pool

3. Click empty slot and **Import** the GeoDraw plugin

## Usage

### Basic Commands

Select your GeoDraw fixtures first, then run:

```
Plugin "GeoDraw" "Grid" "4" "4"       -- 4 rows x 4 columns grid
Plugin "GeoDraw" "Grid" "auto"        -- Auto-calculate optimal grid
Plugin "GeoDraw" "Line" "h"           -- Horizontal line (fills width)
Plugin "GeoDraw" "Line" "v"           -- Vertical line (fills height)
Plugin "GeoDraw" "Rows" "3"           -- 3 horizontal rows
Plugin "GeoDraw" "Perimeter" "4" "4"  -- 4x4 perimeter (edges only)
```

### Workflow

1. **Patch** GeoDraw fixtures in MA3
2. **Select** the fixtures you want to layout
3. **Run** the plugin with your desired layout
4. **Store** to a cue to save the positions

### Example: Create a 4x4 Grid

```
Fixture 1 Thru 16               -- Select 16 fixtures
Plugin "GeoDraw" "Grid" "auto"  -- Auto-calculate 4x4 grid
Store Cue 1                     -- Save to cue
```

## Layout Types

| Type | Description | Parameters |
|------|-------------|------------|
| Grid | Rows x Columns | rows, cols (or "auto") |
| Line | Single row/column | "h" or "v" |
| Rows | Multiple horizontal rows | number of rows |
| Perimeter | Edges only | rows, cols |

## How It Works

The plugin:
1. Gets the selected fixture count
2. Calculates positions for edge-to-edge tiling (height perfect, width fills)
3. Sets Pan (X), Tilt (Y), and Zoom (Scale) attributes on each fixture
4. Values are calculated for 1920x1080 canvas

## Configuration

Edit the CONFIG section in GeoDraw.lua to change:
- Canvas dimensions (default: 1920x1080)
- Attribute names (default: Pan, Tilt, Zoom)

## Troubleshooting

**"No fixtures selected"**
- Make sure to select fixtures before running the plugin

**Positions not updating**
- Check that your fixtures have Pan, Tilt, Zoom attributes
- Verify the attribute names match your fixture profile

**Wrong scale**
- Scale is calculated for baseRadius=120 (240px diameter at scale 1.0)
- Adjust CONFIG.baseSize if using different fixture profile
