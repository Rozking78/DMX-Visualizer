// output_ndi.h - NDI output sink for seamless switcher
// Encodes BGRA Metal textures to NDI and sends over network

#pragma once

#include "output_sink.h"
#include "switcher_frame.h"
#include <Processing.NDI.Lib.h>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <queue>
#include <string>

namespace RocKontrol {

// NDI output configuration
struct NDIOutputConfig {
    std::string source_name = "RocKontrol Switcher";
    std::string groups;                // NDI groups (comma-separated)
    std::string network_interface;     // Network interface to use (empty = default)
    bool clock_video = true;           // Use NDI for timing
    bool clock_audio = false;          // Use NDI for audio timing
    uint32_t async_queue_size = 5;     // Async send queue depth (5 for edge-blend stability)
    bool legacy_mode = false;          // Use synchronous sending (more compatible but slower)
};

// NDI Output Sink
class NDIOutput : public OutputSink {
public:
    NDIOutput(id<MTLDevice> device);
    ~NDIOutput() override;

    // Configure the output
    bool configure(const NDIOutputConfig& config);

    // OutputSink interface
    bool start() override;
    void stop() override;
    bool isRunning() const override { return running_.load(); }

    bool pushFrame(const SwitcherFrame& frame) override;

    // Push pre-rendered pixel data directly (for batch processing - no GPU work)
    // Data must be BGRA format, width*height*4 bytes
    bool pushPixelData(const uint8_t* data, uint32_t width, uint32_t height,
                       uint64_t timestamp_ns, float frameRate);

    OutputType type() const override { return OutputType::NDI; }
    std::string name() const override { return config_.source_name; }
    OutputStatus status() const override { return status_.load(); }

    uint32_t width() const override { return width_.load(); }
    uint32_t height() const override { return height_.load(); }
    float frameRate() const override { return frame_rate_.load(); }

    // Set target resolution for scaling output
    bool setResolution(uint32_t width, uint32_t height) override;

    // Set output name (renames the NDI source)
    bool setName(const std::string& name) override;

    bool requiresEncoding() const override { return true; }

    // Statistics
    uint64_t framesSent() const { return frames_sent_.load(); }
    uint64_t framesDropped() const { return frames_dropped_.load(); }

    // Legacy mode (synchronous sending, more compatible)
    void setLegacyMode(bool enabled);
    bool isLegacyMode() const { return legacy_mode_.load(); }

private:
    // Async send thread
    void sendLoop();

    // Convert Metal texture to NDI frame
    bool convertFromTexture(const SwitcherFrame& frame, NDIlib_video_frame_v2_t& ndi_frame);

private:
    // Metal resources
    id<MTLDevice> device_;
    id<MTLCommandQueue> command_queue_;
    id<MTLRenderPipelineState> edge_blend_pipeline_;
    id<MTLSamplerState> sampler_;
    id<MTLTexture> temp_texture_;  // For edge blend rendering
    uint32_t temp_texture_width_{0};
    uint32_t temp_texture_height_{0};

    // Edge blend shader and pipeline setup
    bool setupEdgeBlendPipeline();
    bool ensureTempTexture(uint32_t width, uint32_t height);
    bool renderWithEdgeBlend(id<MTLTexture> sourceTexture, uint32_t cropX, uint32_t cropY,
                              uint32_t cropW, uint32_t cropH);

    // NDI resources
    NDIlib_send_instance_t sender_;
    NDIOutputConfig config_;

    // State
    std::atomic<bool> running_{false};
    std::atomic<bool> should_stop_{false};
    std::atomic<OutputStatus> status_{OutputStatus::Stopped};
    std::atomic<bool> legacy_mode_{false};  // Synchronous sending mode

    // Frame info
    std::atomic<uint32_t> width_{0};
    std::atomic<uint32_t> height_{0};
    std::atomic<float> frame_rate_{0.0f};

    // Target resolution override (0 = use source resolution)
    std::atomic<uint32_t> target_width_{0};
    std::atomic<uint32_t> target_height_{0};

    // Pre-rendered frame data (for batch processing path)
    struct PixelFrame {
        std::vector<uint8_t> data;
        uint32_t width;
        uint32_t height;
        uint64_t timestamp_ns;
        float frame_rate;
        bool valid;

        PixelFrame() : width(0), height(0), timestamp_ns(0), frame_rate(0), valid(false) {}
    };

    // Async send queue - now uses pre-rendered pixel data
    std::thread send_thread_;
    std::queue<PixelFrame> pixel_queue_;
    std::mutex queue_mutex_;
    std::condition_variable queue_cv_;

    // Frame buffer for NDI (reused)
    std::vector<uint8_t> ndi_buffer_;

    // Statistics
    std::atomic<uint64_t> frames_sent_{0};
    std::atomic<uint64_t> frames_dropped_{0};
};

} // namespace RocKontrol
