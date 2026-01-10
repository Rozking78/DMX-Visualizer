# NDI Output Troubleshooting & Future Improvements

## Current Configuration

- **Queue Size:** 5 frames (increased from 3 for edge-blend stability)
- **Clock Video:** true (keeps all NDI receivers in sync - essential for edge blending)
- **Format:** BGRA (native Metal format)
- **Network Interface:** Configurable per-output in Media settings

## Known Issue: Outputs 2 and 4 Dropping

Pattern observed: Outputs 1 and 3 stable, outputs 2 and 4 have issues.

### Possible Causes

1. **Resource contention** - Alternating outputs compete for same GPU/CPU resources
2. **Timing offset** - Frame timing differences in push sequence
3. **Queue ordering** - Later outputs in push sequence behave differently
4. **Render time** - Different crop/blend settings may take longer

### Troubleshooting Steps

1. Restart application (clears any accumulated state)
2. Check if specific outputs have more complex edge blend settings
3. Monitor NDI bandwidth usage
4. Try disabling edge blend on problem outputs to isolate cause

---

## Future Improvements (Priority Order)

### 1. UYVY Format Conversion (Medium Risk)
Convert BGRA to UYVY (native NDI format) for 50% bandwidth reduction.

**Implementation:**
- Add Metal compute shader for BGRA → UYVY conversion
- Convert before getBytes() call
- Reduces CPU memory bandwidth significantly

**Reference:**
- NDI SDK recommends UYVY for best performance
- BGRA has "performance penalty" per SDK docs

### 2. Async Send with Double Buffering (Low Risk)
Already have background thread, but could improve GPU readback timing.

**Implementation:**
- Use two buffers alternating
- Start next frame readback while previous sends
- Reduces latency spikes

### 3. Frame Metadata (Low Risk)
Add timecode and session info for receiver sync.

**Implementation:**
```cpp
ndi_frame.timecode = calculateTimecode();
ndi_frame.p_metadata = "<ndi_metadata>...</ndi_metadata>";
```

### 4. Connection Monitoring (Low Risk)
Track receiver count and log disconnects for debugging.

**Implementation:**
```cpp
int receivers = ndi_lib->send_get_no_connections(sender_, 0);
```

### 5. Adaptive Quality (Medium Risk)
Reduce resolution if receivers report lag.

---

## Edge Blending Considerations

**Why clock_video=true matters:**
- Ensures all NDI receivers get frames at the same time
- Prevents visible stepping/tearing in overlap zones
- NDI paces frame delivery across network

**Do NOT change:**
- Disabling clock_video would break multi-output sync
- Edge blend seams would show frame timing differences

---

## Resource References

### NDI SDK Documentation
- NDI SDK for Apple: `/Library/NDI SDK for Apple/`
- Processing.NDI.Lib.h - Main API header

### Research Sources
- [NDI SDK Best Practices](https://ndi.video/developers/)
- UYVY vs BGRA performance: Native format reduces conversion overhead
- clock_video timing: SDK handles frame pacing for receivers

### Code Locations
- `OutputEngine/output_ndi.mm` - NDI output implementation
- `OutputEngine/output_ndi.h` - Configuration struct
- `Sources/dmx-visualizer/GeoDrawOutputManager.swift` - Output management

---

## Change Log

### 2024-12-26
- Increased async_queue_size from 3 to 5 for stability
- Added NDI network interface selection in Media settings
- Fixed warp corner normalization (pixels to 0-1)
- Added lens correction steppers (K1/K2)
