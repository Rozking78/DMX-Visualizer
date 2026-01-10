# MA3 Profiles – GeoDraw DMX Visualizer

GeoDraw uses two separate fixture types for DMX control:
1. **GeoDraw Master (3ch)** – Global master controls
2. **GeoDraw Output (27ch)** – Per-output control (one fixture per output)

---

## GeoDraw Master (3ch)

Patch one instance for global control. This controls master intensity and diagnostic overlays.

| Ch | Attribute        | Default | Range / Notes                        |
|----|------------------|---------|--------------------------------------|
| 1  | Master Intensity | 255     | 0-255 = 0-100% (multiplies all)      |
| 2  | Test Pattern     | 0       | 0-127=off, 128-255=on (grid overlay) |
| 3  | Show Borders     | 0       | 0-127=off, 128-255=on (output edges) |

---

## GeoDraw Output (27ch)

Patch one instance per output. Each output has its own universe/address configured in the Output Settings panel.

| Ch  | Attribute           | Default | Range / Notes                           |
|-----|---------------------|---------|-----------------------------------------|
| 1   | Intensity           | 255     | 0-255 = 0-100% output brightness        |
| 2   | Auto Blend          | 0       | 0-127=off, 128-255=on (future feature)  |
| 3   | Edge Blend Left     | 0       | 0-255 = 0-500px feather                 |
| 4   | Edge Blend Right    | 0       | 0-255 = 0-500px feather                 |
| 5   | Edge Blend Top      | 0       | 0-255 = 0-500px feather                 |
| 6   | Edge Blend Bottom   | 0       | 0-255 = 0-500px feather                 |
| 7   | Warp TL X Coarse    | 128     | 16-bit, ±500px (32768=center)           |
| 8   | Warp TL X Fine      | 0       |                                         |
| 9   | Warp TL Y Coarse    | 128     |                                         |
| 10  | Warp TL Y Fine      | 0       |                                         |
| 11  | Warp TR X Coarse    | 128     |                                         |
| 12  | Warp TR X Fine      | 0       |                                         |
| 13  | Warp TR Y Coarse    | 128     |                                         |
| 14  | Warp TR Y Fine      | 0       |                                         |
| 15  | Warp BL X Coarse    | 128     |                                         |
| 16  | Warp BL X Fine      | 0       |                                         |
| 17  | Warp BL Y Coarse    | 128     |                                         |
| 18  | Warp BL Y Fine      | 0       |                                         |
| 19  | Warp BR X Coarse    | 128     |                                         |
| 20  | Warp BR X Fine      | 0       |                                         |
| 21  | Warp BR Y Coarse    | 128     |                                         |
| 22  | Warp BR Y Fine      | 0       |                                         |
| 23  | Curvature           | 128     | 0=-1.0 (concave), 128=flat, 255=+1.0    |
| 24  | Position X Coarse   | 128     | 16-bit, canvas TL origin (32768=center) |
| 25  | Position X Fine     | 0       | ±10000px range                          |
| 26  | Position Y Coarse   | 128     |                                         |
| 27  | Position Y Fine     | 0       |                                         |

---

## Setup in MA3

### 1. Import Fixture Types
The fixture type files are located in:
- `MA3_Profiles/geodraw@master_3ch.xml` – Master fixture
- `MA3_Profiles/geodraw@output_27ch.xml` – Output fixture

Copy these to your MA3 library:
```
~/MALightingTechnology/gma3_library/fixturetypes/
```

### 2. Patch Master Control
1. Open Patch in MA3
2. Add fixture: **GeoDraw Master** (mode: 3ch)
3. Assign to desired Universe and Address
4. In GeoDraw app: Settings > Master Control > Enable and set Universe/Address to match

### 3. Patch Outputs
For each output (NDI or Display):
1. In MA3: Add fixture **GeoDraw Output** (mode: 27ch)
2. Assign to desired Universe and Address
3. In GeoDraw app: Output Settings > Select output > Set DMX Patch (Universe/Address)

### Example Patching
| Fixture             | Universe | Address |
|---------------------|----------|---------|
| GeoDraw Master      | 10       | 1       |
| GeoDraw Output 1    | 10       | 10      |
| GeoDraw Output 2    | 10       | 40      |
| GeoDraw Output 3    | 10       | 70      |

**Note:** Universe 0 = DMX control disabled for that output.

---

## Warp Usage Notes

- All warp corner values use 16-bit precision for fine control
- Default 32768 (coarse=128, fine=0) = no offset
- Range: ±500px per corner
- Adjust corners to correct keystone/perspective distortion
- Use Curvature for spherical/dome projection:
  - Values < 128: Concave (bowl/dish shaped surface)
  - Values > 128: Convex (dome/sphere shaped surface)

## Position Usage Notes

- Position X/Y defines where the output starts reading from the canvas
- Default 32768 = canvas origin (0,0)
- Use for soft-edge blending where outputs need overlapping regions
- Range: ±10000px from canvas center
