// output_display.h - Display output sink for seamless switcher
// Renders directly to physical displays via Metal

#pragma once

#include "output_sink.h"
#include "switcher_frame.h"
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <atomic>
#include <mutex>
#include <string>

namespace RocKontrol {

// Display output configuration
struct DisplayOutputConfig {
    uint32_t display_id = 0;           // CGDirectDisplayID (0 = main display)
    bool fullscreen = true;            // Fullscreen exclusive mode
    bool vsync = true;                 // Sync to display refresh
    bool show_safe_area = false;       // Show title/action safe guides
    std::string label;                 // Optional label
};

// Display Output Sink
class DisplayOutput : public OutputSink {
public:
    DisplayOutput(id<MTLDevice> device);
    ~DisplayOutput() override;

    // Configure the output
    bool configure(const DisplayOutputConfig& config);

    // OutputSink interface
    bool start() override;
    void stop() override;
    bool isRunning() const override { return running_.load(); }

    bool pushFrame(const SwitcherFrame& frame) override;

    OutputType type() const override { return OutputType::Display; }
    std::string name() const override;
    OutputStatus status() const override { return status_.load(); }

    uint32_t width() const override { return width_.load(); }
    uint32_t height() const override { return height_.load(); }
    float frameRate() const override { return frame_rate_.load(); }

    bool requiresEncoding() const override { return false; } // Direct GPU output

    // Set display label/name
    bool setName(const std::string& name) override;

    // Set window resolution (resizes the output window)
    bool setResolution(uint32_t width, uint32_t height);

    // Display info
    uint32_t displayId() const { return config_.display_id; }
    uint32_t nativeWidth() const { return native_width_; }
    uint32_t nativeHeight() const { return native_height_; }

private:
    // Render frame to display
    void renderFrame(const SwitcherFrame& frame);

private:
    // Metal resources
    id<MTLDevice> device_;
    id<MTLCommandQueue> command_queue_;
    id<MTLRenderPipelineState> render_pipeline_;
    id<MTLSamplerState> sampler_;
    id<MTLBuffer> vertex_buffer_;
    id<MTLBuffer> index_buffer_;
    uint32_t index_count_;

    // Display resources
    DisplayOutputConfig config_;
    NSWindow* window_;
    NSView* metal_view_;
    CAMetalLayer* metal_layer_;

    // State
    std::atomic<bool> running_{false};
    std::atomic<OutputStatus> status_{OutputStatus::Stopped};

    // Display info
    std::atomic<uint32_t> width_{0};
    std::atomic<uint32_t> height_{0};
    std::atomic<float> frame_rate_{0.0f};
    uint32_t native_width_{0};
    uint32_t native_height_{0};

    std::mutex render_mutex_;
};

// List available displays
struct DisplayInfo {
    uint32_t display_id;
    std::string name;
    uint32_t width;
    uint32_t height;
    float refresh_rate;
    bool is_main;
};

std::vector<DisplayInfo> listDisplays();

} // namespace RocKontrol
