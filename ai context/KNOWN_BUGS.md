# Known Bugs and Issues

## Display Output Not Working (CRITICAL - UNRESOLVED)

**Status:** Investigating
**Date:** 2026-01-10

### Symptoms
- User assigns a display output to a physical monitor
- Output shows as enabled and running in logs
- Frames are being pushed and rendered (logs confirm)
- Nothing appears on the physical monitor

### What We Know
1. The display output **worked on first build** (original code in commit `7f45c83`)
2. Something changed that broke it
3. Logs show `onScreen=0` (isOnActiveSpace) even with `NSWindowCollectionBehaviorCanJoinAllSpaces`
4. Metal rendering IS happening (drawables obtained, frames pushed)
5. Window IS created at correct position for second monitor

### Attempted Fixes (All Failed)
1. Changed from `CGDisplayBounds` to `NSScreen frame` - No effect
2. Added `NSWindowCollectionBehaviorStationary` - No effect
3. Increased window level to `NSScreenSaverWindowLevel + 1000` - No effect
4. Added `makeKeyAndOrderFront` + `orderFrontRegardless` - No effect
5. Fixed Retina drawable size calculation - No effect
6. Changed layer setup order (setLayer before setWantsLayer) - No effect

### Root Cause (Suspected)
The original working code used:
- `CGDisplayBounds` directly for window positioning
- `setWantsLayer:YES` BEFORE `setLayer:` (layer-backed, not layer-hosting)
- `NSWindowCollectionBehaviorFullScreenAuxiliary`
- `NSScreenSaverWindowLevel` (not +1000)
- `makeKeyAndOrderFront:nil` only

Current code diverged from this pattern during "improvements" that broke it.

### Current State
Reverted to original `7f45c83` code with only the crash fix applied (store windows in static array instead of closing).

### To Reproduce
1. Run DMX Visualizer
2. Add display output for second monitor
3. Enable the output
4. Observe: nothing appears on second monitor despite logs showing successful rendering

### Original Working Code Pattern
```objc
NSRect frame = NSMakeRect(displayBounds.origin.x, displayBounds.origin.y,
                          displayBounds.size.width, displayBounds.size.height);

window_ = [[NSWindow alloc] initWithContentRect:frame
                                      styleMask:NSWindowStyleMaskBorderless
                                        backing:NSBackingStoreBuffered
                                          defer:NO];

[window_ setLevel:NSScreenSaverWindowLevel];
[window_ setOpaque:YES];
[window_ setBackgroundColor:[NSColor blackColor]];
[window_ setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary];

metal_view_ = [[NSView alloc] initWithFrame:...];
[metal_view_ setWantsLayer:YES];  // FIRST

metal_layer_ = [CAMetalLayer layer];
// ... configure layer ...

[metal_view_ setLayer:metal_layer_];  // SECOND
[window_ setContentView:metal_view_];
[window_ makeKeyAndOrderFront:nil];
```

### Next Steps to Try
1. Check if user has "Displays have separate Spaces" enabled in System Preferences
2. Try `CGDisplayCapture` to take exclusive control of the display
3. Check if another app/window is covering the output
4. Test on a different Mac/monitor setup
5. Add visible debug indicator (bright color fill) to confirm Metal IS rendering

---

## Delete Output Crash (FIXED)

**Status:** Fixed
**Date:** 2026-01-10

### Symptoms
- Deleting an output caused `EXC_BAD_ACCESS` crash
- Crash occurred in `objc_release` during autorelease pool drain

### Root Cause
Calling `[window_ close]` during output deletion triggered autorelease of objects that were already freed.

### Fix Applied
Instead of closing windows, store them in a static `NSMutableArray` and just hide with `orderOut:nil`. Windows are kept alive until app exit.

```objc
static NSMutableArray* sPendingWindows = nil;

// In stop():
[window_ orderOut:nil];  // Hide, don't close
if (!sPendingWindows) {
    sPendingWindows = [[NSMutableArray alloc] init];
}
[sPendingWindows addObject:window_];  // Keep alive
window_ = nil;
```

**Location:** `OutputEngine/output_display.mm` lines 350-393
