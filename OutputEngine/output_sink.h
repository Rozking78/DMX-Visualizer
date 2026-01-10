// output_sink.h - Abstract interface for all output sinks
// All outputs receive BGRA Metal textures and encode/display as needed

#pragma once

#include "switcher_frame.h"
#include <string>
#include <functional>

namespace RocKontrol {

// Output types
enum class OutputType {
    Display,        // Physical display (Metal layer)
    DeckLink,       // DeckLink SDI/HDMI output
    NDI,            // NDI network output (requires encoding)
    Recording,      // File recording (requires encoding)
    Stream,         // RTMP/SRT streaming (requires encoding)
    Preview,        // Low-res preview (for UI)
    Unknown
};

// Output status
enum class OutputStatus {
    Stopped,
    Starting,
    Running,
    Error
};

// Output mode (what feed this output receives) - LEGACY, kept for compatibility
enum class OutputMode {
    Program,    // Output the program (default)
    Preview     // Output the preview source
};

// Output source type - determines what this output displays
// This is the new system: outputs can be assigned to screens or direct inputs
enum class OutputSourceType {
    None,           // Output disabled / empty
    Screen,         // Assigned to a Screen (receives composited frame from screen's M/E)
    DirectInput,    // Direct input pass-through (raw feed, no compositing)
    LegacyBus       // Legacy mode: follows global program/preview bus (default for compatibility)
};

// Transition type for per-output transitions
enum class OutputTransitionType {
    Cut,        // Instant switch
    Dissolve,   // Crossfade
    Wipe,       // Directional wipe
    Dip         // Dip to color then reveal
};

// Callback for output status changes
using OutputStatusCallback = std::function<void(int outputId, OutputStatus status, const std::string& message)>;

// Abstract base class for all output sinks
class OutputSink {
public:
    virtual ~OutputSink() = default;

    // Lifecycle
    virtual bool start() = 0;
    virtual void stop() = 0;
    virtual bool isRunning() const = 0;

    // Frame delivery - push a frame to this output
    // Returns false if output not ready or error
    virtual bool pushFrame(const SwitcherFrame& frame) = 0;

    // Output properties
    virtual OutputType type() const = 0;
    virtual std::string name() const = 0;
    virtual OutputStatus status() const = 0;

    // Configuration
    virtual uint32_t width() const = 0;
    virtual uint32_t height() const = 0;
    virtual float frameRate() const = 0;

    // Set output resolution (optional - returns false if not supported)
    virtual bool setResolution(uint32_t width, uint32_t height) { return false; }

    // Set output name (optional - returns false if not supported)
    virtual bool setName(const std::string& name) { return false; }

    // Does this output require encoding? (false for direct display/SDI)
    virtual bool requiresEncoding() const = 0;

    // Optional: set callback for status changes
    virtual void setStatusCallback(OutputStatusCallback callback) {
        status_callback_ = callback;
    }

    // Output ID (assigned by switcher engine)
    int outputId() const { return output_id_; }
    void setOutputId(int id) { output_id_ = id; }

    // Output mode (program or preview feed) - LEGACY
    OutputMode outputMode() const { return output_mode_; }
    void setOutputMode(OutputMode mode) { output_mode_ = mode; }

    // Source assignment (new system)
    OutputSourceType sourceType() const { return source_type_; }
    void setSourceType(OutputSourceType type) { source_type_ = type; }

    // Screen assignment (when sourceType == Screen)
    int screenIndex() const { return screen_index_; }
    void setScreenIndex(int idx) {
        screen_index_ = idx;
        source_type_ = OutputSourceType::Screen;
    }

    // Direct input assignment (when sourceType == DirectInput)
    int directInputIndex() const { return direct_input_index_; }
    void setDirectInputIndex(int idx) {
        direct_input_index_ = idx;
        source_type_ = OutputSourceType::DirectInput;
    }

    // Convenience: assign to legacy bus mode
    void setLegacyBusMode() {
        source_type_ = OutputSourceType::LegacyBus;
        screen_index_ = -1;
        direct_input_index_ = -1;
    }

    // Convenience: disable output
    void disableSource() {
        source_type_ = OutputSourceType::None;
        screen_index_ = -1;
        direct_input_index_ = -1;
    }

    // ============================================
    // Per-output transition state (multi-output model)
    // Each output has its own M/E with independent transitions
    // ============================================

    // Current source being shown on this output
    int currentInput() const { return current_input_; }
    void setCurrentInput(int idx) {
        current_input_ = idx;
        source_type_ = OutputSourceType::DirectInput;
        direct_input_index_ = idx;
    }

    // Pending source (what we're transitioning TO)
    int pendingInput() const { return pending_input_; }
    void setPendingInput(int idx) { pending_input_ = idx; }

    // Transition state
    bool isTransitionInProgress() const { return transition_in_progress_; }
    float transitionProgress() const { return transition_progress_; }
    float transitionDurationFrames() const { return transition_duration_frames_; }
    OutputTransitionType transitionType() const { return transition_type_; }

    void setTransitionDuration(float frames) { transition_duration_frames_ = frames; }
    void setTransitionType(OutputTransitionType type) { transition_type_ = type; }

    // Start a transition to the pending source
    void startTransition(int toInput, OutputTransitionType type, float durationFrames) {
        if (type == OutputTransitionType::Cut || durationFrames <= 0) {
            // Instant cut - no transition
            current_input_ = toInput;
            direct_input_index_ = toInput;
            source_type_ = OutputSourceType::DirectInput;
            pending_input_ = -1;
            transition_in_progress_ = false;
            transition_progress_ = 0.0f;
        } else {
            // Start transition
            pending_input_ = toInput;
            transition_type_ = type;
            transition_duration_frames_ = durationFrames;
            transition_in_progress_ = true;
            transition_progress_ = 0.0f;
        }
    }

    // Advance transition by one frame (called by engine each frame)
    // Returns true if transition completed this frame
    bool advanceTransition() {
        if (!transition_in_progress_) return false;

        float step = 1.0f / transition_duration_frames_;
        transition_progress_ += step;

        if (transition_progress_ >= 1.0f) {
            // Transition complete - swap to new source, crop, and edge blend
            current_input_ = pending_input_;
            direct_input_index_ = pending_input_;
            source_type_ = OutputSourceType::DirectInput;
            current_crop_ = pending_crop_;  // Apply pending crop when transition completes
            current_edge_blend_ = pending_edge_blend_;  // Apply pending edge blend when transition completes
            pending_input_ = -1;
            transition_in_progress_ = false;
            transition_progress_ = 0.0f;
            return true;
        }
        return false;
    }

    // Cancel transition (revert to current source)
    void cancelTransition() {
        pending_input_ = -1;
        transition_in_progress_ = false;
        transition_progress_ = 0.0f;
    }

    // Set transition progress directly (for T-bar control)
    // Returns true if transition was set, false if no transition in progress
    bool setTransitionProgress(float progress) {
        if (!transition_in_progress_) {
            return false;
        }
        transition_progress_ = std::max(0.0f, std::min(1.0f, progress));

        // If we've reached the end, complete the transition
        if (transition_progress_ >= 1.0f) {
            current_input_ = pending_input_;
            direct_input_index_ = pending_input_;
            source_type_ = OutputSourceType::DirectInput;
            current_crop_ = pending_crop_;
            current_edge_blend_ = pending_edge_blend_;
            pending_input_ = -1;
            transition_in_progress_ = false;
            transition_progress_ = 0.0f;
        }
        return true;
    }

    // Start a transition without auto-advance (for T-bar control)
    // This begins a transition that will be controlled manually via setTransitionProgress
    void startTBarTransition(int toInput, OutputTransitionType type) {
        pending_input_ = toInput;
        transition_type_ = type;
        transition_duration_frames_ = 0.0f;  // 0 = manual control
        transition_in_progress_ = true;
        transition_progress_ = 0.0f;
    }

    // Start T-bar transition with crop and edge blend settings
    void startTBarTransitionWithCropAndBlend(int toInput, OutputTransitionType type,
                                              float cropX, float cropY, float cropW, float cropH,
                                              float featherL, float featherR, float featherT, float featherB,
                                              float blendGamma = 2.2f, float blendPower = 1.0f,
                                              float blackLevel = 0.0f, float gammaR = 1.0f, float gammaG = 1.0f, float gammaB = 1.0f) {
        pending_input_ = toInput;
        pending_crop_ = {cropX, cropY, cropW, cropH};
        pending_edge_blend_ = {featherL, featherR, featherT, featherB, blendGamma, blendPower, blackLevel, gammaR, gammaG, gammaB};
        transition_type_ = type;
        transition_duration_frames_ = 0.0f;  // 0 = manual control
        transition_in_progress_ = true;
        transition_progress_ = 0.0f;
    }

protected:
    void notifyStatus(OutputStatus status, const std::string& message = "") {
        if (status_callback_) {
            status_callback_(output_id_, status, message);
        }
    }

    int output_id_ = -1;
    OutputMode output_mode_ = OutputMode::Program;
    OutputStatusCallback status_callback_;

    // New source assignment system
    OutputSourceType source_type_ = OutputSourceType::LegacyBus;  // Default: legacy behavior
    int screen_index_ = -1;           // Which screen when source_type_ == Screen
    int direct_input_index_ = -1;     // Which input when source_type_ == DirectInput

    // Per-output transition state (multi-output model)
    int current_input_ = -1;          // Currently displayed input
    int pending_input_ = -1;          // Input we're transitioning TO
    bool transition_in_progress_ = false;
    float transition_progress_ = 0.0f;
    float transition_duration_frames_ = 30.0f;
    OutputTransitionType transition_type_ = OutputTransitionType::Dissolve;

    // ============================================
    // Per-output crop region (for destination spanning)
    // Normalized coordinates (0-1) specifying which region of the source to display
    // Default: full source (0,0,1,1)
    // ============================================
    struct CropRegion {
        float x = 0.0f;   // Start X (0-1)
        float y = 0.0f;   // Start Y (0-1)
        float w = 1.0f;   // Width (0-1)
        float h = 1.0f;   // Height (0-1)

        bool isFullFrame() const {
            return x == 0.0f && y == 0.0f && w == 1.0f && h == 1.0f;
        }
    };

    CropRegion current_crop_;         // Crop for current source
    CropRegion pending_crop_;         // Crop for pending source (during transition)

    // ============================================
    // Per-output edge blending (for video wall soft edge feathering)
    // Feather widths in pixels, gamma curve parameters
    // ============================================
    struct EdgeBlendParams {
        float featherLeft = 0.0f;      // Feather width in pixels (left edge)
        float featherRight = 0.0f;     // Feather width in pixels (right edge)
        float featherTop = 0.0f;       // Feather width in pixels (top edge)
        float featherBottom = 0.0f;    // Feather width in pixels (bottom edge)
        float blendGamma = 2.2f;       // Gamma curve for blend (2.2 = standard)
        float blendPower = 1.0f;       // Power/slope of blend curve (1.0 = linear)
        float blackLevel = 0.0f;       // Black level compensation (0-1)
        float gammaR = 1.0f;           // Per-channel red gamma
        float gammaG = 1.0f;           // Per-channel green gamma
        float gammaB = 1.0f;           // Per-channel blue gamma
        // 8-point warp (pixel offsets)
        float warpTopLeftX = 0.0f;
        float warpTopLeftY = 0.0f;
        float warpTopMiddleX = 0.0f;
        float warpTopMiddleY = 0.0f;
        float warpTopRightX = 0.0f;
        float warpTopRightY = 0.0f;
        float warpMiddleLeftX = 0.0f;
        float warpMiddleLeftY = 0.0f;
        float warpMiddleRightX = 0.0f;
        float warpMiddleRightY = 0.0f;
        float warpBottomLeftX = 0.0f;
        float warpBottomLeftY = 0.0f;
        float warpBottomMiddleX = 0.0f;
        float warpBottomMiddleY = 0.0f;
        float warpBottomRightX = 0.0f;
        float warpBottomRightY = 0.0f;
        // Warp curvature (for curved/spherical surfaces)
        float warpCurvature = 0.0f;    // Curvature amount (0 = linear, + = convex, - = concave)
        // Lens distortion
        float lensK1 = 0.0f;           // Primary radial coefficient
        float lensK2 = 0.0f;           // Secondary radial coefficient
        float lensCenterX = 0.5f;      // Distortion center X
        float lensCenterY = 0.5f;      // Distortion center Y
        // Corner overlay (0=none, 1=TL, 2=TR, 3=BL, 4=BR)
        int activeCorner = 0;

        bool hasBlending() const {
            return featherLeft > 0 || featherRight > 0 || featherTop > 0 || featherBottom > 0;
        }
    };

    EdgeBlendParams current_edge_blend_;  // Edge blend for current frame
    EdgeBlendParams pending_edge_blend_;  // Edge blend to apply after transition

    // Output intensity (0-1, default 1.0 = full brightness)
    float intensity_ = 1.0f;

public:
    // Intensity control (0-1)
    float intensity() const { return intensity_; }
    void setIntensity(float intensity) { intensity_ = std::max(0.0f, std::min(1.0f, intensity)); }
    // Crop region accessors
    const CropRegion& currentCrop() const { return current_crop_; }
    const CropRegion& pendingCrop() const { return pending_crop_; }

    void setCrop(float x, float y, float w, float h) {
        current_crop_ = {x, y, w, h};
    }

    void setPendingCrop(float x, float y, float w, float h) {
        pending_crop_ = {x, y, w, h};
    }

    // Edge blend accessors
    const EdgeBlendParams& currentEdgeBlend() const { return current_edge_blend_; }
    const EdgeBlendParams& pendingEdgeBlend() const { return pending_edge_blend_; }

    void setEdgeBlend(float featherL, float featherR, float featherT, float featherB,
                      float gamma = 2.2f, float power = 1.0f,
                      float blackLevel = 0.0f, float gammaR = 1.0f, float gammaG = 1.0f, float gammaB = 1.0f,
                      float warpTLX = 0.0f, float warpTLY = 0.0f, float warpTMX = 0.0f, float warpTMY = 0.0f,
                      float warpTRX = 0.0f, float warpTRY = 0.0f,
                      float warpMLX = 0.0f, float warpMLY = 0.0f, float warpMRX = 0.0f, float warpMRY = 0.0f,
                      float warpBLX = 0.0f, float warpBLY = 0.0f, float warpBMX = 0.0f, float warpBMY = 0.0f,
                      float warpBRX = 0.0f, float warpBRY = 0.0f,
                      float warpCurvature = 0.0f,
                      float lensK1 = 0.0f, float lensK2 = 0.0f, float lensCX = 0.5f, float lensCY = 0.5f,
                      int activeCorner = 0) {
        current_edge_blend_ = {featherL, featherR, featherT, featherB, gamma, power, blackLevel, gammaR, gammaG, gammaB,
                               warpTLX, warpTLY, warpTMX, warpTMY, warpTRX, warpTRY,
                               warpMLX, warpMLY, warpMRX, warpMRY,
                               warpBLX, warpBLY, warpBMX, warpBMY, warpBRX, warpBRY,
                               warpCurvature,
                               lensK1, lensK2, lensCX, lensCY, activeCorner};
    }

    void setPendingEdgeBlend(float featherL, float featherR, float featherT, float featherB,
                             float gamma = 2.2f, float power = 1.0f,
                             float blackLevel = 0.0f, float gammaR = 1.0f, float gammaG = 1.0f, float gammaB = 1.0f) {
        pending_edge_blend_ = {featherL, featherR, featherT, featherB, gamma, power, blackLevel, gammaR, gammaG, gammaB};
    }

    // Extended startTransition with crop support
    void startTransitionWithCrop(int toInput, OutputTransitionType type, float durationFrames,
                                  float cropX, float cropY, float cropW, float cropH) {
        pending_crop_ = {cropX, cropY, cropW, cropH};
        if (type == OutputTransitionType::Cut || durationFrames <= 0) {
            // Instant cut - apply crop immediately
            current_input_ = toInput;
            direct_input_index_ = toInput;
            source_type_ = OutputSourceType::DirectInput;
            current_crop_ = pending_crop_;
            pending_input_ = -1;
            transition_in_progress_ = false;
            transition_progress_ = 0.0f;
        } else {
            // Start transition
            pending_input_ = toInput;
            transition_type_ = type;
            transition_duration_frames_ = durationFrames;
            transition_in_progress_ = true;
            transition_progress_ = 0.0f;
        }
    }

    // Extended startTransition with crop and edge blend support
    void startTransitionWithCropAndBlend(int toInput, OutputTransitionType type, float durationFrames,
                                          float cropX, float cropY, float cropW, float cropH,
                                          float featherL, float featherR, float featherT, float featherB,
                                          float blendGamma = 2.2f, float blendPower = 1.0f,
                                          float blackLevel = 0.0f, float gammaR = 1.0f, float gammaG = 1.0f, float gammaB = 1.0f) {
        pending_crop_ = {cropX, cropY, cropW, cropH};
        pending_edge_blend_ = {featherL, featherR, featherT, featherB, blendGamma, blendPower, blackLevel, gammaR, gammaG, gammaB};
        if (type == OutputTransitionType::Cut || durationFrames <= 0) {
            // Instant cut - apply crop and blend immediately
            current_input_ = toInput;
            direct_input_index_ = toInput;
            source_type_ = OutputSourceType::DirectInput;
            current_crop_ = pending_crop_;
            current_edge_blend_ = pending_edge_blend_;
            pending_input_ = -1;
            transition_in_progress_ = false;
            transition_progress_ = 0.0f;
        } else {
            // Start transition
            pending_input_ = toInput;
            transition_type_ = type;
            transition_duration_frames_ = durationFrames;
            transition_in_progress_ = true;
            transition_progress_ = 0.0f;
        }
    }

    // Override advanceTransition to handle crop and edge blend
    bool advanceTransitionWithCrop() {
        if (!transition_in_progress_) return false;

        float step = 1.0f / transition_duration_frames_;
        transition_progress_ += step;

        if (transition_progress_ >= 1.0f) {
            // Transition complete - swap to new source, crop, and edge blend
            current_input_ = pending_input_;
            direct_input_index_ = pending_input_;
            source_type_ = OutputSourceType::DirectInput;
            current_crop_ = pending_crop_;
            current_edge_blend_ = pending_edge_blend_;
            pending_input_ = -1;
            transition_in_progress_ = false;
            transition_progress_ = 0.0f;
            return true;
        }
        return false;
    }
};

// Convert output type to string
inline const char* outputTypeToString(OutputType type) {
    switch (type) {
        case OutputType::Display: return "Display";
        case OutputType::DeckLink: return "DeckLink";
        case OutputType::NDI: return "NDI";
        case OutputType::Recording: return "Recording";
        case OutputType::Stream: return "Stream";
        case OutputType::Preview: return "Preview";
        default: return "Unknown";
    }
}

} // namespace RocKontrol
