// switcher_frame.h - Unified frame format for RocKontrol Switcher
// All inputs decode to this format, all outputs read from this format

#pragma once

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <vector>
#include <string>

namespace RocKontrol {

// Frame format - always BGRA8 on GPU
struct SwitcherFrame {
    id<MTLTexture> texture;          // GPU texture (BGRA8Unorm)
    uint64_t timestamp_ns;           // Presentation timestamp in nanoseconds
    uint64_t frame_number;           // Sequential frame ID from source
    uint32_t width;                  // Texture width
    uint32_t height;                 // Texture height
    float frame_rate;                // Source frame rate
    bool valid;                      // Frame contains valid data
    bool interlaced;                 // Is this an interlaced frame?
    bool top_field_first;            // For interlaced: TFF or BFF

    SwitcherFrame() : texture(nil), timestamp_ns(0), frame_number(0),
                      width(0), height(0), frame_rate(0),
                      valid(false), interlaced(false), top_field_first(true) {}

    void reset() {
        texture = nil;
        timestamp_ns = 0;
        frame_number = 0;
        width = 0;
        height = 0;
        frame_rate = 0;
        valid = false;
        interlaced = false;
        top_field_first = true;
    }
};

// Ring buffer for frame storage (thread-safe)
class FrameRingBuffer {
public:
    explicit FrameRingBuffer(size_t capacity = 5)
        : capacity_(capacity), frames_(capacity), write_idx_(0), read_idx_(0), count_(0) {}

    // Producer: push a new frame (may overwrite oldest if full)
    bool push(const SwitcherFrame& frame) {
        std::lock_guard<std::mutex> lock(mutex_);
        frames_[write_idx_] = frame;
        write_idx_ = (write_idx_ + 1) % capacity_;
        if (count_ < capacity_) {
            count_++;
        } else {
            // Buffer full, advance read pointer (drop oldest)
            read_idx_ = (read_idx_ + 1) % capacity_;
        }
        return true;
    }

    // Consumer: get the latest frame without removing it
    bool peekLatest(SwitcherFrame& out) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (count_ == 0) return false;
        size_t latest = (write_idx_ + capacity_ - 1) % capacity_;
        out = frames_[latest];
        return true;
    }

    // Consumer: pop the oldest frame
    bool pop(SwitcherFrame& out) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (count_ == 0) return false;
        out = frames_[read_idx_];
        read_idx_ = (read_idx_ + 1) % capacity_;
        count_--;
        return true;
    }

    size_t size() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return count_;
    }

    bool empty() const {
        return size() == 0;
    }

    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto& f : frames_) f.reset();
        write_idx_ = 0;
        read_idx_ = 0;
        count_ = 0;
    }

    void resize(size_t capacity) {
        std::lock_guard<std::mutex> lock(mutex_);
        capacity_ = capacity;
        frames_.resize(capacity);
        for (auto& f : frames_) f.reset();
        write_idx_ = 0;
        read_idx_ = 0;
        count_ = 0;
    }

private:
    size_t capacity_;
    std::vector<SwitcherFrame> frames_;
    size_t write_idx_;
    size_t read_idx_;
    size_t count_;
    mutable std::mutex mutex_;
};

// Texture pool for efficient GPU memory reuse
class TexturePool {
public:
    TexturePool(id<MTLDevice> device, uint32_t width, uint32_t height, size_t poolSize = 10)
        : device_(device), width_(width), height_(height) {
        // Pre-allocate textures
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        desc.storageMode = MTLStorageModeShared; // Unified memory on Apple Silicon

        for (size_t i = 0; i < poolSize; i++) {
            id<MTLTexture> tex = [device_ newTextureWithDescriptor:desc];
            if (tex) {
                available_.push_back(tex);
            }
        }
    }

    // Acquire a texture from the pool (or create new if empty)
    id<MTLTexture> acquire() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!available_.empty()) {
            id<MTLTexture> tex = available_.back();
            available_.pop_back();
            return tex;
        }
        // Pool exhausted, create new texture
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:width_
                                                                                       height:height_
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        desc.storageMode = MTLStorageModeShared;
        return [device_ newTextureWithDescriptor:desc];
    }

    // Release a texture back to the pool
    void release(id<MTLTexture> texture) {
        if (!texture) return;
        std::lock_guard<std::mutex> lock(mutex_);
        // Only return to pool if same dimensions
        if (texture.width == width_ && texture.height == height_) {
            available_.push_back(texture);
        }
        // Otherwise let ARC deallocate it
    }

    // Resize pool (for format changes)
    void resize(uint32_t width, uint32_t height) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (width == width_ && height == height_) return;
        available_.clear();
        width_ = width;
        height_ = height;
    }

private:
    id<MTLDevice> device_;
    uint32_t width_;
    uint32_t height_;
    std::vector<id<MTLTexture>> available_;
    std::mutex mutex_;
};

// Input source types
enum class SourceType {
    NDI,
    File,
    Image,
    Pattern,
    Syphon,
    DeckLink,
    ScreenCapture,
    Unknown
};

// Source status
enum class SourceStatus {
    Disconnected,
    Connecting,
    Connected,
    Error
};

// Convert source type to string
inline const char* sourceTypeToString(SourceType type) {
    switch (type) {
        case SourceType::NDI: return "NDI";
        case SourceType::File: return "File";
        case SourceType::Image: return "Image";
        case SourceType::Pattern: return "Pattern";
        case SourceType::Syphon: return "Syphon";
        case SourceType::DeckLink: return "DeckLink";
        case SourceType::ScreenCapture: return "ScreenCapture";
        default: return "Unknown";
    }
}

} // namespace RocKontrol
