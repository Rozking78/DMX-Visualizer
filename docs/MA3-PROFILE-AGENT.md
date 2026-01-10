# MA3 XML Profile Creation Agent Guide

## Overview

This document serves as a comprehensive guide for creating and editing MA Lighting grandMA3 XML fixture profiles for the GeoDraw/DMX Visualizer system. All Claude sessions should reference this when working with MA3 profiles.

## Profile Locations

- **Source profiles**: `/Users/roswellking/Desktop/DMX Visualizer/dmx visualizer/MA3_Profiles/`
- **MA3 library**: `/Users/roswellking/MALightingTechnology/gma3_library/fixturetypes/`

After creating/editing a profile, copy it to BOTH locations.

## Current GeoDraw Profiles

### 1. GeoDraw Master 3ch (`geodraw@master_3ch.xml`)
Global master control fixture.

| Channel | Name | Type | Range | Default | Description |
|---------|------|------|-------|---------|-------------|
| 1 | Master Intensity | 8-bit | 0-100% | 255 (full) | Global brightness multiplier |
| 2 | Test Pattern | Switch | Off/On | 0 | 0-127=Off, 128+=On |
| 3 | Show Borders | Switch | Off/On | 0 | 0-127=Off, 128+=On |

### 2. GeoDraw Output 27ch (`geodraw@output_27ch.xml`)
Per-output control fixture (patch one per NDI/Display output).

| Channel | Name | Type | Range | Default | Description |
|---------|------|------|-------|---------|-------------|
| 1 | Intensity | 8-bit | 0-100% | 255 | Output brightness |
| 2 | Auto Blend | Switch | Off/On | 0 | Reserved for auto-blend |
| 3 | Edge Blend L | 8-bit | 0-500px | 0 | Left edge blend width |
| 4 | Edge Blend R | 8-bit | 0-500px | 0 | Right edge blend width |
| 5 | Edge Blend T | 8-bit | 0-500px | 0 | Top edge blend width |
| 6 | Edge Blend B | 8-bit | 0-500px | 0 | Bottom edge blend width |
| 7-8 | Warp TL X | 16-bit | -500 to +500px | 128/128 | Top-left corner X offset |
| 9-10 | Warp TL Y | 16-bit | -500 to +500px | 128/128 | Top-left corner Y offset |
| 11-12 | Warp TR X | 16-bit | -500 to +500px | 128/128 | Top-right corner X offset |
| 13-14 | Warp TR Y | 16-bit | -500 to +500px | 128/128 | Top-right corner Y offset |
| 15-16 | Warp BL X | 16-bit | -500 to +500px | 128/128 | Bottom-left corner X offset |
| 17-18 | Warp BL Y | 16-bit | -500 to +500px | 128/128 | Bottom-left corner Y offset |
| 19-20 | Warp BR X | 16-bit | -500 to +500px | 128/128 | Bottom-right corner X offset |
| 21-22 | Warp BR Y | 16-bit | -500 to +500px | 128/128 | Bottom-right corner Y offset |
| 23 | Curvature | 8-bit | -1.0 to +1.0 | 128 | Surface curvature correction |
| 24-25 | Position X | 16-bit | -10000 to +10000px | 128/128 | Canvas X position |
| 26-27 | Position Y | 16-bit | -10000 to +10000px | 128/128 | Canvas Y position |

## MA3 XML Format Reference

### Root Structure
```xml
<?xml version="1.0" encoding="UTF-8"?>
<GMA3 DataVersion="1.7.0.0">
    <FixtureType Name="..." Guid="..." Color="..." ShortName="..." Description="..." Manufacturer="GeoDraw" CanHaveChildren="No">
        <AttributeDefinitions>...</AttributeDefinitions>
        <Wheels />
        <PhysicalDescriptions>
            <Emitters />
            <CRIs />
        </PhysicalDescriptions>
        <Models />
        <Geometries>
            <Geometry Name="Body" />
        </Geometries>
        <DMXModes>...</DMXModes>
    </FixtureType>
</GMA3>
```

### GUID Format
Use format: `11 22 33 44 55 66 77 88 99 AA BB CC DD EE XX YY`
- XX = fixture type identifier (01=fixture, 02=output, 03=master)
- YY = channel count (hex)

### Color Format
RGBA float values: `"R.RRRRR,G.GGGGG,B.BBBBB,1.000000"`
- Master: Magenta `"1.000000,0.400000,0.800000,1.000000"`
- Output: Cyan `"0.200000,0.800000,1.000000,1.000000"`
- Fixture: Blue `"0.200000,0.400000,1.000000,1.000000"`

### Attribute Definitions
```xml
<AttributeDefinitions>
    <ActivationGroups>
        <ActivationGroup Name="GroupName" />
    </ActivationGroups>
    <FeatureGroups>
        <FeatureGroup Name="Dimmer">
            <Feature Name="Dimmer" />
        </FeatureGroup>
        <FeatureGroup Name="Position">
            <Feature Name="PanTilt" />
        </FeatureGroup>
        <FeatureGroup Name="Beam">
            <Feature Name="Beam" />
        </FeatureGroup>
        <FeatureGroup Name="Control">
            <Feature Name="Control" />
        </FeatureGroup>
    </FeatureGroups>
    <Attributes>
        <Attribute Name="Dimmer" Pretty="DisplayName" ActivationGroup="GroupName" Feature="Dimmer.Dimmer" PhysicalUnit="LuminousIntensity" />
        <Attribute Name="Pan" Pretty="PanLabel" ActivationGroup="GroupName" Feature="Position.PanTilt" />
        <Attribute Name="Shaper1" Pretty="EdgeL" ActivationGroup="GroupName" Feature="Beam.Beam" />
        <Attribute Name="Control1" Pretty="CtrlLabel" ActivationGroup="GroupName" Feature="Control.Control" />
    </Attributes>
</AttributeDefinitions>
```

### Channel Types

#### 8-bit Continuous (Dimmer/Fader)
```xml
<DMXChannel Coarse="1" Default="FFFFFF" Geometry="Body">
    <LogicalChannel Attribute="Dimmer">
        <ChannelFunction Attribute="Dimmer" PhysicalFrom="0.0000" PhysicalTo="100.0000" />
    </LogicalChannel>
</DMXChannel>
```

#### 8-bit Switch (On/Off)
```xml
<DMXChannel Coarse="2" Geometry="Body">
    <LogicalChannel Attribute="Control1" Snap="Yes">
        <ChannelFunction Attribute="Control1">
            <ChannelSet Name="Off" DMXFrom="000000" />
            <ChannelSet Name="On" DMXFrom="808080" />
        </ChannelFunction>
    </LogicalChannel>
</DMXChannel>
```

#### 16-bit (Coarse/Fine)
```xml
<DMXChannel Coarse="7" Fine="8" Default="808080" Geometry="Body">
    <LogicalChannel Attribute="Pan">
        <ChannelFunction Attribute="Pan" PhysicalFrom="-500.0000" PhysicalTo="500.0000" />
    </LogicalChannel>
</DMXChannel>
```

### Default Values
- `FFFFFF` = 255 (full brightness for dimmers)
- `808080` = 128 (center position for signed values)
- `000000` = 0 (off/minimum)

### Key Rules

1. **Channel numbering is 1-based** in `Coarse` and `Fine` attributes
2. **16-bit channels**: `Coarse` is MSB channel, `Fine` is LSB channel
3. **Comments**: Use `<!-- CH1: Description -->` before each DMXChannel
4. **Snap="Yes"**: Use for discrete/switch channels
5. **PhysicalUnit**: Use `LuminousIntensity` for dimmers only
6. **Required empty sections**: Always include `<Wheels />`, `<PhysicalDescriptions>`, `<Models />`

## Creating a New Profile

### Step 1: Define the channel layout
List all channels with their names, types, and ranges.

### Step 2: Generate unique GUID
Use format with unique XX YY bytes for fixture type and channel count.

### Step 3: Create AttributeDefinitions
Map each channel to an appropriate MA3 attribute:
- Dimmers → `Dimmer`
- Position → `Pan`, `Tilt`, `Pan2`, `Tilt2`, etc.
- Edge blend → `Shaper1`, `Shaper2`, `Shaper3`, `Shaper4`
- Controls → `Control1`, `Control2`, etc.
- Zoom/Curve → `Zoom`
- Color → `ColorAdd_R`, `ColorAdd_G`, `ColorAdd_B`

### Step 4: Build DMXChannels
Create one DMXChannel per logical channel (16-bit = 1 DMXChannel with Coarse+Fine).

### Step 5: Validate
- Channel numbers sequential and correct
- All attributes defined in AttributeDefinitions
- Defaults appropriate for each channel type
- XML is well-formed

## Deployment

After creating/modifying a profile:

```bash
# Copy to both locations
cp "/Users/roswellking/Desktop/DMX Visualizer/dmx visualizer/MA3_Profiles/geodraw@newprofile.xml" \
   "/Users/roswellking/MALightingTechnology/gma3_library/fixturetypes/"
```

Then in MA3:
1. Menu → Patch → Add Fixture
2. Search for "GeoDraw"
3. Select the new fixture profile

## DMX Value Mappings

### 8-bit Signed (-X to +X)
```
DMX 0   = -X (minimum)
DMX 128 = 0 (center)
DMX 255 = +X (maximum)
```

### 16-bit Signed (-X to +X)
```
DMX 0/0     = -X (minimum)
DMX 128/128 = 0 (center)
DMX 255/255 = +X (maximum)
Formula: value = (raw - 32768) / 32767 * X
```

### 8-bit Unsigned (0 to X)
```
DMX 0   = 0
DMX 255 = X
Formula: value = raw / 255 * X
```

## Software Channel Constants (main.swift)

When adding new profiles, ensure corresponding channel constants exist in SceneController:

```swift
// Master Control (3ch)
static let chMasterIntensity = 0   // Ch 1
static let chTestPattern = 1       // Ch 2
static let chShowBorders = 2       // Ch 3

// Output Control (27ch)
static let chOutIntensity = 0      // Ch 1
static let chOutAutoBlend = 1      // Ch 2
static let chOutEdgeL = 2          // Ch 3
static let chOutEdgeR = 3          // Ch 4
static let chOutEdgeT = 4          // Ch 5
static let chOutEdgeB = 5          // Ch 6
static let chOutWarpTLXCoarse = 6  // Ch 7
static let chOutWarpTLXFine = 7    // Ch 8
// ... etc
```

## Troubleshooting

### Profile not appearing in MA3
- Check XML syntax (no unclosed tags)
- Verify file is in correct location
- Restart MA3 software

### Channels not responding
- Verify channel numbers match between profile and software
- Check DMX universe/address configuration
- Ensure 16-bit channels use correct Coarse/Fine pairing

### Values seem inverted
- Check PhysicalFrom/PhysicalTo order
- Verify Default value is appropriate for channel type
