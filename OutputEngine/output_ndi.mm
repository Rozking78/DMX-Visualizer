// output_ndi.mm - NDI output sink implementation
// Encodes BGRA Metal textures to NDI and sends over network

#import "output_ndi.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>

// NDI dynamic loading - the SDK is loaded at runtime
static const NDIlib_v5* ndi_lib = nullptr;
static void* ndi_handle = nullptr;

static bool loadNDI() {
    if (ndi_lib) return true;

    // Try to load NDI runtime library
    const char* ndi_paths[] = {
        "/usr/local/lib/libndi.dylib",
        "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
        "libndi.dylib"
    };

    for (const char* path : ndi_paths) {
        ndi_handle = dlopen(path, RTLD_LOCAL | RTLD_LAZY);
        if (ndi_handle) break;
    }

    if (!ndi_handle) {
        NSLog(@"NDIOutput: Failed to load NDI runtime library");
        return false;
    }

    // Get the load function
    typedef const NDIlib_v5* (*NDIlib_v5_load_fn)(void);
    NDIlib_v5_load_fn load_fn = (NDIlib_v5_load_fn)dlsym(ndi_handle, "NDIlib_v5_load");
    if (!load_fn) {
        NSLog(@"NDIOutput: Failed to find NDIlib_v5_load");
        dlclose(ndi_handle);
        ndi_handle = nullptr;
        return false;
    }

    ndi_lib = load_fn();
    if (!ndi_lib) {
        NSLog(@"NDIOutput: NDIlib_v5_load returned null");
        dlclose(ndi_handle);
        ndi_handle = nullptr;
        return false;
    }

    NSLog(@"NDIOutput: NDI library loaded successfully");
    return true;
}

// Edge blend shader source code with geometric correction
static NSString* const edgeBlendShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle vertex shader
vertex VertexOut edgeBlendVertex(uint vertexID [[vertex_id]]) {
    VertexOut out;
    // Generate fullscreen triangle
    float2 pos = float2((vertexID << 1) & 2, vertexID & 2);
    out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    out.texCoord = float2(pos.x, 1.0 - pos.y);
    return out;
}

struct EdgeBlendParams {
    float featherLeft;      // Feather width in normalized coords (0-1)
    float featherRight;
    float featherTop;
    float featherBottom;
    float gamma;            // Blend gamma (2.2 typical)
    float power;            // Blend power curve
    float blackLevel;       // Black level compensation
    float activeCorner;     // 0=none, 1=TL, 2=TR, 3=BL, 4=BR
    float2 cropOrigin;      // Crop origin in source texture (normalized)
    float2 cropSize;        // Crop size in source texture (normalized)

    // 8-point warp (offsets from default positions, normalized)
    float2 warpTopLeft;
    float2 warpTopMiddle;
    float2 warpTopRight;
    float2 warpMiddleLeft;
    float2 warpMiddleRight;
    float2 warpBottomLeft;
    float2 warpBottomMiddle;
    float2 warpBottomRight;

    // Lens distortion
    float lensK1;           // Primary radial coefficient
    float lensK2;           // Secondary radial coefficient
    float2 lensCenter;      // Distortion center (0.5, 0.5 = middle)

    // Warp curvature for curved surfaces (spheres, cylinders)
    float warpCurvature;    // 0 = linear, + = convex/barrel, - = concave/pincushion

    // Output intensity (0-1, DMX controlled)
    float intensity;        // Master intensity multiplier (1.0 = full brightness)
};

// Draw corner bracket marker overlay at the WARPED position
float4 drawCornerOverlay(float2 uv, float4 color, int activeCorner, float2 warpOffset) {
    if (activeCorner == 0) return color;

    float markerSize = 0.08;    // Size of corner bracket
    float lineWidth = 0.006;    // Line thickness
    float2 cornerPos;
    float2 inwardDir;  // Direction pointing inward from corner

    // Determine base corner position and inward direction
    // warpOffset represents source sampling offset, so negate for visual position
    float2 visualOffset = -warpOffset;

    if (activeCorner == 1) {
        cornerPos = float2(0.0, 0.0) + visualOffset;  // TL
        inwardDir = float2(1.0, 1.0);
    } else if (activeCorner == 2) {
        cornerPos = float2(1.0, 0.0) + visualOffset;  // TR
        inwardDir = float2(-1.0, 1.0);
    } else if (activeCorner == 3) {
        cornerPos = float2(0.0, 1.0) + visualOffset;  // BL
        inwardDir = float2(1.0, -1.0);
    } else if (activeCorner == 4) {
        cornerPos = float2(1.0, 1.0) + visualOffset;  // BR
        inwardDir = float2(-1.0, -1.0);
    } else {
        return color;
    }

    // Check if we're near the corner position
    float2 toCorner = uv - cornerPos;
    float distX = abs(toCorner.x);
    float distY = abs(toCorner.y);

    // Draw L-shaped bracket - horizontal arm with outline
    bool inHorizArm = (distY < lineWidth) &&
                      (toCorner.x * inwardDir.x >= 0.0) &&
                      (distX < markerSize);

    // Draw L-shaped bracket - vertical arm with outline
    bool inVertArm = (distX < lineWidth) &&
                     (toCorner.y * inwardDir.y >= 0.0) &&
                     (distY < markerSize);

    // Black outline (slightly larger)
    bool inHorizOutline = (distY < lineWidth * 1.5) &&
                          (toCorner.x * inwardDir.x >= -lineWidth) &&
                          (distX < markerSize + lineWidth);
    bool inVertOutline = (distX < lineWidth * 1.5) &&
                         (toCorner.y * inwardDir.y >= -lineWidth) &&
                         (distY < markerSize + lineWidth);

    if (inHorizOutline || inVertOutline) {
        if (inHorizArm || inVertArm) {
            return float4(0.0, 1.0, 1.0, 1.0);  // Cyan L-bracket
        }
        return float4(0.0, 0.0, 0.0, 1.0);  // Black outline
    }

    // Cyan dot at exact corner point with black outline
    float dist = length(toCorner);
    if (dist < 0.02) {
        if (dist < 0.012) {
            return float4(0.0, 1.0, 1.0, 1.0);  // Cyan dot
        }
        return float4(0.0, 0.0, 0.0, 1.0);  // Black outline
    }

    return color;
}

// Apply pincushion/barrel distortion correction
float2 applyLensDistortion(float2 uv, float k1, float k2, float2 center) {
    if (k1 == 0.0 && k2 == 0.0) return uv;

    // Convert to centered coordinates
    float2 centered = uv - center;

    // Calculate radius from center
    float r = length(centered);
    float r2 = r * r;
    float r4 = r2 * r2;

    // Apply Brown-Conrady distortion model
    float distortion = 1.0 + k1 * r2 + k2 * r4;

    // Apply distortion and convert back
    float2 distorted = centered * distortion + center;

    return distorted;
}

// Apply spherical curvature distortion for dome/sphere projection
// Uses fisheye-style radial distortion based on Paul Bourke's dome projection math
// curvature > 0: CONVEX (barrel distortion - content curves outward like on a dome)
// curvature < 0: CONCAVE (pincushion distortion - content curves inward like in a bowl)
float2 applySphericalCurvature(float2 uv, float curvature) {
    if (abs(curvature) < 0.001) return uv;

    // Center at (0.5, 0.5)
    float2 center = float2(0.5, 0.5);
    float2 centered = uv - center;

    // Calculate radius from center (normalized so corners are at ~0.707)
    float r = length(centered);
    if (r < 0.001) return uv;  // Avoid division by zero at center

    // Normalize to max radius of 0.5 (edge of frame)
    float r_norm = r / 0.5;

    // Apply fisheye-style distortion using polynomial model
    // r_src = r_dest * (1 + k1*r^2 + k2*r^4)
    // For barrel (convex): negative k values push pixels outward
    // For pincushion (concave): positive k values pull pixels inward
    float k1 = -curvature * 0.5;   // Primary radial coefficient
    float k2 = -curvature * 0.25;  // Secondary (stronger at edges)

    float r2 = r_norm * r_norm;
    float r4 = r2 * r2;
    float distortion = 1.0 + k1 * r2 + k2 * r4;

    // Apply distortion - scale the centered coordinates
    float2 distorted = centered * distortion + center;

    return distorted;
}

// Check if point is inside a quadrilateral defined by 4 corners (clockwise order)
// UV space: (0,0) = top-left, (1,1) = bottom-right
bool pointInWarpQuad(float2 p, float2 tl, float2 tr, float2 br, float2 bl) {
    // Check if point is on the correct side of all 4 edges (clockwise winding)
    float2 edges[4] = { tr - tl, br - tr, bl - br, tl - bl };
    float2 corners[4] = { tl, tr, br, bl };

    for (int i = 0; i < 4; i++) {
        float2 toPoint = p - corners[i];
        float cross = edges[i].x * toPoint.y - edges[i].y * toPoint.x;
        if (cross < 0) return false;  // Outside this edge
    }
    return true;
}

// Check if warp is active (any corner offset is non-zero)
bool hasWarpActive(float2 tl, float2 tr, float2 bl, float2 br) {
    return length(tl) > 0.001 || length(tr) > 0.001 ||
           length(bl) > 0.001 || length(br) > 0.001;
}

// Inverse bilinear interpolation for a single quad
// Returns UV in (0,1) range, or (-1,-1) if outside
float2 inverseQuadUV(float2 p, float2 q00, float2 q10, float2 q01, float2 q11) {
    float2 a = q00;
    float2 b = q10 - q00;
    float2 c = q01 - q00;
    float2 d = q00 - q10 - q01 + q11;
    float2 e = p - a;

    float k1 = c.x * b.y - c.y * b.x;
    float k2 = d.x * b.y - d.y * b.x;
    float k3 = e.x * b.y - e.y * b.x;
    float k4 = b.x * c.y - b.y * c.x;
    float k5 = d.x * c.y - d.y * c.x;
    float k6 = e.x * c.y - e.y * c.x;

    float A = k1 * k5;
    float B = k1 * k4 + k2 * k6 - k3 * k5;
    float C = -k3 * k4;

    float v;
    if (abs(A) < 0.0001) {
        if (abs(B) < 0.0001) return float2(-1.0, -1.0);
        v = -C / B;
    } else {
        float discriminant = B * B - 4.0 * A * C;
        if (discriminant < 0.0) return float2(-1.0, -1.0);

        float sqrtD = sqrt(discriminant);
        float v1 = (-B + sqrtD) / (2.0 * A);
        float v2 = (-B - sqrtD) / (2.0 * A);

        if (v1 >= -0.01 && v1 <= 1.01) v = v1;
        else if (v2 >= -0.01 && v2 <= 1.01) v = v2;
        else return float2(-1.0, -1.0);
    }

    float denom = k4 + v * k5;
    if (abs(denom) < 0.0001) return float2(-1.0, -1.0);
    float u = k6 / denom;

    if (u < -0.01 || u > 1.01 || v < -0.01 || v > 1.01) {
        return float2(-1.0, -1.0);
    }

    return float2(clamp(u, 0.0, 1.0), clamp(v, 0.0, 1.0));
}

// Apply bezier-style curvature to a midpoint position
// curvature: 0 = linear, + = curve outward (convex), - = curve inward (concave)
// t: interpolation parameter (0-1) along the edge
// edgeNormal: direction to push the curve (perpendicular to edge)
float2 applyCurvature(float2 start, float2 mid, float2 end, float t, float curvature) {
    if (abs(curvature) < 0.001) {
        // Linear interpolation (no curvature)
        return mix(start, end, t);
    }

    // Quadratic bezier with the middle control point adjusted by curvature
    // The midpoint is pushed perpendicular to the edge by curvature amount
    float2 edgeDir = normalize(end - start);
    float2 edgeNormal = float2(-edgeDir.y, edgeDir.x);  // Perpendicular

    // Adjust midpoint by curvature (positive = outward)
    float2 adjustedMid = mid + edgeNormal * curvature * 0.25;

    // Quadratic bezier: B(t) = (1-t)^2 * P0 + 2(1-t)t * P1 + t^2 * P2
    float t2 = t * t;
    float mt = 1.0 - t;
    float mt2 = mt * mt;
    return mt2 * start + 2.0 * mt * t * adjustedMid + t2 * end;
}

// 8-point warp using 3x3 grid (9 points with interpolated center)
// Splits into 4 quadrants for better curved surface mapping
// curvature: 0 = linear edges, + = convex (barrel), - = concave (pincushion)
float2 inverse8PointWarpUV(float2 p,
                            float2 tl, float2 tm, float2 tr,
                            float2 ml, float2 mr,
                            float2 bl, float2 bm, float2 br,
                            float curvature) {
    // Calculate center point by averaging the 4 middle edge points
    float2 center = (tm + ml + mr + bm) * 0.25;

    // When curvature is active, adjust the center point to create curved quadrants
    // This pushes the center outward (+) or inward (-) to create spherical mapping
    if (abs(curvature) > 0.001) {
        // Calculate ideal center (0.5, 0.5) vs actual center
        float2 idealCenter = float2(0.5, 0.5);
        // Push center away from or toward the ideal center
        center = center + (center - idealCenter) * curvature * 0.5;
    }

    // Try each quadrant and return if point is inside
    // Top-left quadrant: maps to UV (0,0)-(0.5,0.5)
    float2 uv = inverseQuadUV(p, tl, tm, ml, center);
    if (uv.x >= 0.0) {
        return uv * 0.5;  // Scale to top-left of output
    }

    // Top-right quadrant: maps to UV (0.5,0)-(1,0.5)
    uv = inverseQuadUV(p, tm, tr, center, mr);
    if (uv.x >= 0.0) {
        return float2(0.5 + uv.x * 0.5, uv.y * 0.5);
    }

    // Bottom-left quadrant: maps to UV (0,0.5)-(0.5,1)
    uv = inverseQuadUV(p, ml, center, bl, bm);
    if (uv.x >= 0.0) {
        return float2(uv.x * 0.5, 0.5 + uv.y * 0.5);
    }

    // Bottom-right quadrant: maps to UV (0.5,0.5)-(1,1)
    uv = inverseQuadUV(p, center, mr, bm, br);
    if (uv.x >= 0.0) {
        return float2(0.5 + uv.x * 0.5, 0.5 + uv.y * 0.5);
    }

    // Outside all quadrants
    return float2(-1.0, -1.0);
}

// Check if any of the 8 warp points are active
bool has8PointWarpActive(float2 tl, float2 tm, float2 tr,
                          float2 ml, float2 mr,
                          float2 bl, float2 bm, float2 br) {
    return length(tl) > 0.001 || length(tm) > 0.001 || length(tr) > 0.001 ||
           length(ml) > 0.001 || length(mr) > 0.001 ||
           length(bl) > 0.001 || length(bm) > 0.001 || length(br) > 0.001;
}

fragment float4 edgeBlendFragment(VertexOut in [[stage_in]],
                                   texture2d<float> sourceTexture [[texture(0)]],
                                   sampler textureSampler [[sampler(0)]],
                                   constant EdgeBlendParams& params [[buffer(0)]]) {
    float2 uv = in.texCoord;

    // Calculate all 8 warped control point positions (3x3 grid without center)
    float2 warpedTL = float2(0.0, 0.0) + params.warpTopLeft;
    float2 warpedTM = float2(0.5, 0.0) + params.warpTopMiddle;
    float2 warpedTR = float2(1.0, 0.0) + params.warpTopRight;
    float2 warpedML = float2(0.0, 0.5) + params.warpMiddleLeft;
    float2 warpedMR = float2(1.0, 0.5) + params.warpMiddleRight;
    float2 warpedBL = float2(0.0, 1.0) + params.warpBottomLeft;
    float2 warpedBM = float2(0.5, 1.0) + params.warpBottomMiddle;
    float2 warpedBR = float2(1.0, 1.0) + params.warpBottomRight;

    // Curvature is now applied via radial distortion after inverse warp (see below)

    // Check if 8-point warp is active
    bool warpActive = has8PointWarpActive(params.warpTopLeft, params.warpTopMiddle, params.warpTopRight,
                                           params.warpMiddleLeft, params.warpMiddleRight,
                                           params.warpBottomLeft, params.warpBottomMiddle, params.warpBottomRight);

    float2 sampleUV = uv;

    // Check if curvature is active (even without point warp, curvature alone can create effect)
    bool curvatureActive = abs(params.warpCurvature) > 0.001;

    if (warpActive || curvatureActive) {
        // Use 8-point inverse warp with curvature (splits into 4 quadrants for curved surfaces)
        float2 invUV = inverse8PointWarpUV(uv,
                                            warpedTL, warpedTM, warpedTR,
                                            warpedML, warpedMR,
                                            warpedBL, warpedBM, warpedBR,
                                            params.warpCurvature);

        if (invUV.x < 0.0) {
            // Outside the warped region - render black (keystone border)
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        // Use inverse-mapped UV for texture sampling
        sampleUV = invUV;
    }

    // 2. Apply spherical curvature distortion (for dome/sphere projection)
    // This curves the content radially - applied BEFORE lens correction
    sampleUV = applySphericalCurvature(sampleUV, params.warpCurvature);

    // 3. Apply lens distortion correction (for projector lens characteristics)
    sampleUV = applyLensDistortion(sampleUV, params.lensK1, params.lensK2, params.lensCenter);

    // 3. Sample from cropped region of source texture
    float2 sourceCoord = params.cropOrigin + sampleUV * params.cropSize;

    // Clamp to valid texture coordinates
    sourceCoord = clamp(sourceCoord, float2(0.0), float2(1.0));

    float4 color = sourceTexture.sample(textureSampler, sourceCoord);

    // 4. Calculate edge blend factors
    float blendL = 1.0, blendR = 1.0, blendT = 1.0, blendB = 1.0;

    // Left edge fade
    if (params.featherLeft > 0.0 && in.texCoord.x < params.featherLeft) {
        float t = in.texCoord.x / params.featherLeft;
        blendL = pow(t, params.power);
    }

    // Right edge fade
    if (params.featherRight > 0.0 && in.texCoord.x > (1.0 - params.featherRight)) {
        float t = (1.0 - in.texCoord.x) / params.featherRight;
        blendR = pow(t, params.power);
    }

    // Top edge fade
    if (params.featherTop > 0.0 && in.texCoord.y < params.featherTop) {
        float t = in.texCoord.y / params.featherTop;
        blendT = pow(t, params.power);
    }

    // Bottom edge fade
    if (params.featherBottom > 0.0 && in.texCoord.y > (1.0 - params.featherBottom)) {
        float t = (1.0 - in.texCoord.y) / params.featherBottom;
        blendB = pow(t, params.power);
    }

    // Combine blend factors
    float blend = blendL * blendR * blendT * blendB;

    // Apply gamma correction to blend
    blend = pow(blend, 1.0 / params.gamma);

    // Apply black level compensation
    float3 rgb = color.rgb * blend;
    rgb = max(rgb, float3(params.blackLevel));

    // Apply output intensity (DMX controlled)
    rgb *= params.intensity;

    float4 result = float4(rgb, color.a);

    // Draw corner overlay if active
    int corner = int(params.activeCorner);
    if (corner > 0) {
        float2 warpOffset = float2(0.0);
        if (corner == 1) warpOffset = params.warpTopLeft;
        else if (corner == 2) warpOffset = params.warpTopRight;
        else if (corner == 3) warpOffset = params.warpBottomLeft;
        else if (corner == 4) warpOffset = params.warpBottomRight;
        result = drawCornerOverlay(in.texCoord, result, corner, warpOffset);
    }

    return result;
}
)";

namespace RocKontrol {

NDIOutput::NDIOutput(id<MTLDevice> device)
    : device_(device)
    , command_queue_(nil)
    , edge_blend_pipeline_(nil)
    , sampler_(nil)
    , temp_texture_(nil)
    , sender_(nullptr) {
    // Create command queue for edge blend rendering
    command_queue_ = [device_ newCommandQueue];
    if (!command_queue_) {
        NSLog(@"NDIOutput: Failed to create command queue");
    }

    // Setup edge blend pipeline
    if (!setupEdgeBlendPipeline()) {
        NSLog(@"NDIOutput: Failed to setup edge blend pipeline");
    }
}

NDIOutput::~NDIOutput() {
    stop();
}

bool NDIOutput::configure(const NDIOutputConfig& config) {
    if (running_.load()) {
        return false;
    }

    config_ = config;
    return true;
}

bool NDIOutput::setResolution(uint32_t width, uint32_t height) {
    // Validate resolution
    if (width < 320 || height < 240 || width > 7680 || height > 4320) {
        NSLog(@"NDIOutput: Invalid resolution %ux%u", width, height);
        return false;
    }

    target_width_.store(width);
    target_height_.store(height);

    // Also update the reported width/height
    width_.store(width);
    height_.store(height);

    NSLog(@"NDIOutput: Resolution set to %ux%u", width, height);
    return true;
}

bool NDIOutput::setName(const std::string& name) {
    if (name.empty()) {
        NSLog(@"NDIOutput: Cannot set empty name");
        return false;
    }

    // Update the config name (this is what name() returns)
    config_.source_name = name;

    // Note: NDI doesn't support renaming a live sender
    // The new name will take effect if the output is stopped and restarted
    // For now, we just update the stored name for UI purposes
    NSLog(@"NDIOutput: Name set to '%s'", name.c_str());
    return true;
}

void NDIOutput::setLegacyMode(bool enabled) {
    legacy_mode_.store(enabled);
    config_.legacy_mode = enabled;
    // In legacy mode, disable clock_video for maximum compatibility
    if (enabled) {
        config_.clock_video = false;
    }
    NSLog(@"NDIOutput: Legacy mode %s", enabled ? "ENABLED (sync send, no clock)" : "DISABLED (async send)");
}

bool NDIOutput::start() {
    if (running_.load()) {
        return true;
    }

    status_.store(OutputStatus::Starting);
    notifyStatus(OutputStatus::Starting, "Starting NDI sender...");

    // Load NDI library if not already loaded
    if (!loadNDI()) {
        status_.store(OutputStatus::Error);
        notifyStatus(OutputStatus::Error, "Failed to load NDI library");
        return false;
    }

    // Set network interface if specified
    if (!config_.network_interface.empty()) {
        setenv("NDI_NETWORK_INTERFACE", config_.network_interface.c_str(), 1);
        NSLog(@"NDIOutput: Using network interface %s", config_.network_interface.c_str());
    }

    // Create NDI sender
    NDIlib_send_create_t send_create;
    send_create.p_ndi_name = config_.source_name.c_str();
    send_create.p_groups = config_.groups.empty() ? nullptr : config_.groups.c_str();
    send_create.clock_video = config_.clock_video;
    send_create.clock_audio = config_.clock_audio;

    sender_ = ndi_lib->send_create(&send_create);
    if (!sender_) {
        status_.store(OutputStatus::Error);
        notifyStatus(OutputStatus::Error, "Failed to create NDI sender");
        return false;
    }

    // Start async send thread
    should_stop_.store(false);
    running_.store(true);
    send_thread_ = std::thread(&NDIOutput::sendLoop, this);

    status_.store(OutputStatus::Running);
    notifyStatus(OutputStatus::Running, "NDI sender started: " + config_.source_name);

    NSLog(@"NDIOutput: Started sender '%s'", config_.source_name.c_str());
    return true;
}

void NDIOutput::stop() {
    if (!running_.load()) {
        return;
    }

    should_stop_.store(true);

    // Wake up send thread
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        queue_cv_.notify_all();
    }

    if (send_thread_.joinable()) {
        send_thread_.join();
    }

    running_.store(false);

    // Clean up NDI sender
    if (sender_ && ndi_lib) {
        ndi_lib->send_destroy(sender_);
        sender_ = nullptr;
    }

    // Clear queue
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        while (!pixel_queue_.empty()) {
            pixel_queue_.pop();
        }
    }

    status_.store(OutputStatus::Stopped);
    notifyStatus(OutputStatus::Stopped, "NDI sender stopped");

    NSLog(@"NDIOutput: Stopped sender");
}

// Setup the edge blend render pipeline
bool NDIOutput::setupEdgeBlendPipeline() {
    if (!device_) return false;

    @autoreleasepool {
        NSError* error = nil;

        // Compile shader from source
        id<MTLLibrary> library = [device_ newLibraryWithSource:edgeBlendShaderSource
                                                       options:nil
                                                         error:&error];
        if (!library) {
            NSLog(@"NDIOutput: Failed to compile edge blend shader: %@", error);
            return false;
        }

        id<MTLFunction> vertexFunc = [library newFunctionWithName:@"edgeBlendVertex"];
        id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"edgeBlendFragment"];

        if (!vertexFunc || !fragmentFunc) {
            NSLog(@"NDIOutput: Failed to find shader functions");
            return false;
        }

        // Create pipeline descriptor
        MTLRenderPipelineDescriptor* pipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
        pipelineDesc.vertexFunction = vertexFunc;
        pipelineDesc.fragmentFunction = fragmentFunc;
        pipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        edge_blend_pipeline_ = [device_ newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
        if (!edge_blend_pipeline_) {
            NSLog(@"NDIOutput: Failed to create edge blend pipeline: %@", error);
            return false;
        }

        // Create sampler
        MTLSamplerDescriptor* samplerDesc = [[MTLSamplerDescriptor alloc] init];
        samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
        samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
        samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;

        sampler_ = [device_ newSamplerStateWithDescriptor:samplerDesc];
        if (!sampler_) {
            NSLog(@"NDIOutput: Failed to create sampler");
            return false;
        }

        NSLog(@"NDIOutput: Edge blend pipeline setup complete");
        return true;
    }
}

// Ensure temp texture exists with required size
bool NDIOutput::ensureTempTexture(uint32_t width, uint32_t height) {
    if (temp_texture_ && temp_texture_width_ == width && temp_texture_height_ == height) {
        return true;
    }

    @autoreleasepool {
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;  // Allows CPU access for getBytes

        temp_texture_ = [device_ newTextureWithDescriptor:desc];
        if (!temp_texture_) {
            NSLog(@"NDIOutput: Failed to create temp texture %ux%u", width, height);
            return false;
        }

        temp_texture_width_ = width;
        temp_texture_height_ = height;
        return true;
    }
}

// Render source texture with edge blend to temp texture
bool NDIOutput::renderWithEdgeBlend(id<MTLTexture> sourceTexture, uint32_t cropX, uint32_t cropY,
                                     uint32_t cropW, uint32_t cropH) {
    if (!edge_blend_pipeline_ || !command_queue_ || !sampler_ || !temp_texture_) {
        return false;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = [command_queue_ commandBuffer];
        if (!commandBuffer) return false;

        // Create render pass to draw to temp texture
        MTLRenderPassDescriptor* passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        passDesc.colorAttachments[0].texture = temp_texture_;
        passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];
        if (!encoder) return false;

        // Get edge blend params
        const auto& blend = currentEdgeBlend();
        float texW = (float)sourceTexture.width;
        float texH = (float)sourceTexture.height;

        // Convert feather from pixels to normalized (0-1) relative to output size
        float outW = (float)cropW;
        float outH = (float)cropH;

        // Edge blend params structure (must match shader)
        struct {
            float featherLeft;
            float featherRight;
            float featherTop;
            float featherBottom;
            float gamma;
            float power;
            float blackLevel;
            float activeCorner;  // 0=none, 1=TL, 2=TR, 3=BL, 4=BR
            float cropOriginX;
            float cropOriginY;
            float cropSizeX;
            float cropSizeY;
            // 8-point warp
            float warpTopLeftX;
            float warpTopLeftY;
            float warpTopMiddleX;
            float warpTopMiddleY;
            float warpTopRightX;
            float warpTopRightY;
            float warpMiddleLeftX;
            float warpMiddleLeftY;
            float warpMiddleRightX;
            float warpMiddleRightY;
            float warpBottomLeftX;
            float warpBottomLeftY;
            float warpBottomMiddleX;
            float warpBottomMiddleY;
            float warpBottomRightX;
            float warpBottomRightY;
            // Lens distortion
            float lensK1;
            float lensK2;
            float lensCenterX;
            float lensCenterY;
            // Warp curvature
            float warpCurvature;
            // Output intensity
            float intensity;
        } params;

        params.featherLeft = blend.featherLeft / outW;
        params.featherRight = blend.featherRight / outW;
        params.featherTop = blend.featherTop / outH;
        params.featherBottom = blend.featherBottom / outH;
        params.gamma = blend.blendGamma;
        params.power = blend.blendPower;
        params.blackLevel = blend.blackLevel;
        params.activeCorner = (float)blend.activeCorner;
        params.cropOriginX = (float)cropX / texW;
        params.cropOriginY = (float)cropY / texH;
        params.cropSizeX = (float)cropW / texW;
        params.cropSizeY = (float)cropH / texH;
        // 8-point warp (normalize from pixels to 0-1 range)
        params.warpTopLeftX = blend.warpTopLeftX / outW;
        params.warpTopLeftY = blend.warpTopLeftY / outH;
        params.warpTopMiddleX = blend.warpTopMiddleX / outW;
        params.warpTopMiddleY = blend.warpTopMiddleY / outH;

        // Debug: log normalized warp values
        static int paramLogCounter = 0;
        if (++paramLogCounter % 300 == 0 && (params.warpTopMiddleX != 0 || params.warpTopMiddleY != 0)) {
            NSLog(@"NDIOutput: Shader params - TM(%.4f,%.4f) normalized, outW=%.0f outH=%.0f",
                  params.warpTopMiddleX, params.warpTopMiddleY, outW, outH);
        }
        params.warpTopRightX = blend.warpTopRightX / outW;
        params.warpTopRightY = blend.warpTopRightY / outH;
        params.warpMiddleLeftX = blend.warpMiddleLeftX / outW;
        params.warpMiddleLeftY = blend.warpMiddleLeftY / outH;
        params.warpMiddleRightX = blend.warpMiddleRightX / outW;
        params.warpMiddleRightY = blend.warpMiddleRightY / outH;
        params.warpBottomLeftX = blend.warpBottomLeftX / outW;
        params.warpBottomLeftY = blend.warpBottomLeftY / outH;
        params.warpBottomMiddleX = blend.warpBottomMiddleX / outW;
        params.warpBottomMiddleY = blend.warpBottomMiddleY / outH;
        params.warpBottomRightX = blend.warpBottomRightX / outW;
        params.warpBottomRightY = blend.warpBottomRightY / outH;
        // Lens distortion
        params.lensK1 = blend.lensK1;
        params.lensK2 = blend.lensK2;
        params.lensCenterX = blend.lensCenterX;
        params.lensCenterY = blend.lensCenterY;
        // Warp curvature for curved surfaces
        params.warpCurvature = blend.warpCurvature;
        // Output intensity from DMX
        params.intensity = intensity_;

        [encoder setRenderPipelineState:edge_blend_pipeline_];
        [encoder setFragmentTexture:sourceTexture atIndex:0];
        [encoder setFragmentSamplerState:sampler_ atIndex:0];
        [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];

        // Draw fullscreen triangle
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];

        // Wait for completion (needed before getBytes)
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        return true;
    }
}

bool NDIOutput::pushFrame(const SwitcherFrame& frame) {
    if (!running_.load() || !frame.valid || !frame.texture) {
        return false;
    }

    // Update frame info
    width_.store(frame.width);
    height_.store(frame.height);
    frame_rate_.store(frame.frame_rate);

    // Convert texture to pixel data immediately (on caller's thread)
    // This moves GPU work OUT of the send thread
    id<MTLTexture> texture = frame.texture;
    uint32_t texW = (uint32_t)texture.width;
    uint32_t texH = (uint32_t)texture.height;

    // Apply crop region
    const auto& crop = currentCrop();
    uint32_t cropX = (uint32_t)(crop.x * texW);
    uint32_t cropY = (uint32_t)(crop.y * texH);
    uint32_t cropW = (uint32_t)(crop.w * texW);
    uint32_t cropH = (uint32_t)(crop.h * texH);

    // Clamp to texture bounds
    if (cropX >= texW) cropX = 0;
    if (cropY >= texH) cropY = 0;
    if (cropW == 0 || cropX + cropW > texW) cropW = texW - cropX;
    if (cropH == 0 || cropY + cropH > texH) cropH = texH - cropY;

    uint32_t w = cropW;
    uint32_t h = cropH;

    // Check if edge blending is needed
    const auto& blend = currentEdgeBlend();

    // Debug: log warp values periodically
    static int logCounter = 0;
    if (++logCounter % 300 == 0) {  // Log every 5 seconds at 60fps
        if (blend.warpTopMiddleX != 0 || blend.warpTopMiddleY != 0 ||
            blend.warpMiddleLeftX != 0 || blend.warpMiddleRightX != 0) {
            NSLog(@"NDIOutput: Middle warp values - TM(%.1f,%.1f) ML(%.1f,%.1f) MR(%.1f,%.1f) BM(%.1f,%.1f)",
                  blend.warpTopMiddleX, blend.warpTopMiddleY,
                  blend.warpMiddleLeftX, blend.warpMiddleLeftY,
                  blend.warpMiddleRightX, blend.warpMiddleRightY,
                  blend.warpBottomMiddleX, blend.warpBottomMiddleY);
        }
    }

    bool hasGeometricCorrection = (blend.warpTopLeftX != 0 || blend.warpTopLeftY != 0 ||
                                   blend.warpTopMiddleX != 0 || blend.warpTopMiddleY != 0 ||
                                   blend.warpTopRightX != 0 || blend.warpTopRightY != 0 ||
                                   blend.warpMiddleLeftX != 0 || blend.warpMiddleLeftY != 0 ||
                                   blend.warpMiddleRightX != 0 || blend.warpMiddleRightY != 0 ||
                                   blend.warpBottomLeftX != 0 || blend.warpBottomLeftY != 0 ||
                                   blend.warpBottomMiddleX != 0 || blend.warpBottomMiddleY != 0 ||
                                   blend.warpBottomRightX != 0 || blend.warpBottomRightY != 0 ||
                                   blend.warpCurvature != 0 ||
                                   blend.lensK1 != 0 || blend.lensK2 != 0);
    bool needsEdgeBlend = (blend.hasBlending() || hasGeometricCorrection || blend.activeCorner > 0) && edge_blend_pipeline_;

    // Debug: log when edge blend is active due to geometric correction
    static int blendLogCounter = 0;
    if (++blendLogCounter % 300 == 0 && hasGeometricCorrection) {
        NSLog(@"NDIOutput: Edge blend ACTIVE - needsEdgeBlend=%d, hasGeometricCorrection=%d, curvature=%.2f, pipeline=%p",
              needsEdgeBlend, hasGeometricCorrection, blend.warpCurvature, edge_blend_pipeline_);
    }

    // Create pixel frame
    PixelFrame pixelFrame;
    pixelFrame.width = w;
    pixelFrame.height = h;
    pixelFrame.timestamp_ns = frame.timestamp_ns;
    pixelFrame.frame_rate = frame.frame_rate;
    pixelFrame.valid = true;

    size_t required_size = w * h * 4;
    pixelFrame.data.resize(required_size);

    if (needsEdgeBlend) {
        // Ensure temp texture exists
        if (ensureTempTexture(w, h)) {
            // Render through edge blend shader
            if (renderWithEdgeBlend(texture, cropX, cropY, cropW, cropH)) {
                // Read from edge-blended temp texture
                MTLRegion region = MTLRegionMake2D(0, 0, w, h);
                [temp_texture_ getBytes:pixelFrame.data.data()
                            bytesPerRow:w * 4
                             fromRegion:region
                            mipmapLevel:0];
            } else {
                // Fallback to direct read
                MTLRegion region = MTLRegionMake2D(cropX, cropY, w, h);
                [texture getBytes:pixelFrame.data.data()
                      bytesPerRow:w * 4
                       fromRegion:region
                      mipmapLevel:0];
            }
        } else {
            // Fallback to direct read
            MTLRegion region = MTLRegionMake2D(cropX, cropY, w, h);
            [texture getBytes:pixelFrame.data.data()
                  bytesPerRow:w * 4
                   fromRegion:region
                  mipmapLevel:0];
        }
    } else {
        // Direct read from source texture
        MTLRegion region = MTLRegionMake2D(cropX, cropY, w, h);
        [texture getBytes:pixelFrame.data.data()
              bytesPerRow:w * 4
               fromRegion:region
              mipmapLevel:0];
    }

    // Legacy mode: send synchronously on caller's thread (more compatible)
    if (legacy_mode_.load()) {
        NDIlib_send_instance_t sender = sender_;
        if (!sender || !ndi_lib) {
            return false;
        }

        // Setup NDI frame
        NDIlib_video_frame_v2_t ndi_frame;
        ndi_frame.xres = pixelFrame.width;
        ndi_frame.yres = pixelFrame.height;
        ndi_frame.FourCC = NDIlib_FourCC_type_BGRA;
        ndi_frame.line_stride_in_bytes = pixelFrame.width * 4;
        ndi_frame.p_data = pixelFrame.data.data();

        // Use simple frame rate
        float fps = pixelFrame.frame_rate > 0 ? pixelFrame.frame_rate : 60.0f;
        ndi_frame.frame_rate_N = (int)(fps * 1000);
        ndi_frame.frame_rate_D = 1000;

        ndi_frame.frame_format_type = NDIlib_frame_format_type_progressive;
        ndi_frame.timecode = NDIlib_send_timecode_synthesize;  // Let NDI handle timing
        ndi_frame.picture_aspect_ratio = (float)pixelFrame.width / pixelFrame.height;
        ndi_frame.p_metadata = nullptr;

        // Send synchronously
        ndi_lib->send_send_video_v2(sender, &ndi_frame);
        frames_sent_.fetch_add(1);
        return true;
    }

    // Normal mode: Add to async queue
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);

        // Drop oldest frame if queue is full
        if (pixel_queue_.size() >= config_.async_queue_size) {
            pixel_queue_.pop();
            frames_dropped_.fetch_add(1);
        }

        pixel_queue_.push(std::move(pixelFrame));
    }

    queue_cv_.notify_one();
    return true;
}

bool NDIOutput::pushPixelData(const uint8_t* data, uint32_t width, uint32_t height,
                               uint64_t timestamp_ns, float frameRate) {
    if (!running_.load() || !data || width == 0 || height == 0) {
        return false;
    }

    // Update frame info
    width_.store(width);
    height_.store(height);
    frame_rate_.store(frameRate);

    // Create pixel frame with copy of data
    PixelFrame pixelFrame;
    pixelFrame.width = width;
    pixelFrame.height = height;
    pixelFrame.timestamp_ns = timestamp_ns;
    pixelFrame.frame_rate = frameRate;
    pixelFrame.valid = true;

    size_t dataSize = width * height * 4;
    pixelFrame.data.resize(dataSize);
    memcpy(pixelFrame.data.data(), data, dataSize);

    // Add to async queue
    {
        std::lock_guard<std::mutex> lock(queue_mutex_);

        // Drop oldest frame if queue is full
        if (pixel_queue_.size() >= config_.async_queue_size) {
            pixel_queue_.pop();
            frames_dropped_.fetch_add(1);
        }

        pixel_queue_.push(std::move(pixelFrame));
    }

    queue_cv_.notify_one();
    return true;
}

void NDIOutput::sendLoop() {
    NSLog(@"NDIOutput: Send loop started");

    while (!should_stop_.load()) {
        PixelFrame pixelFrame;

        // Wait for frame
        {
            std::unique_lock<std::mutex> lock(queue_mutex_);
            queue_cv_.wait(lock, [this] {
                return !pixel_queue_.empty() || should_stop_.load();
            });

            if (should_stop_.load()) {
                break;
            }

            if (!pixel_queue_.empty()) {
                pixelFrame = std::move(pixel_queue_.front());
                pixel_queue_.pop();
            }
        }

        if (!pixelFrame.valid || pixelFrame.data.empty()) {
            continue;
        }

        // Thread-safe capture of sender
        NDIlib_send_instance_t sender = sender_;
        if (!sender) {
            continue;
        }

        // Setup NDI frame from pre-rendered pixel data (NO GPU WORK HERE)
        NDIlib_video_frame_v2_t ndi_frame;
        ndi_frame.xres = pixelFrame.width;
        ndi_frame.yres = pixelFrame.height;
        ndi_frame.FourCC = NDIlib_FourCC_type_BGRA;
        ndi_frame.line_stride_in_bytes = pixelFrame.width * 4;
        ndi_frame.p_data = pixelFrame.data.data();

        // Calculate frame rate
        float fps = pixelFrame.frame_rate > 0 ? pixelFrame.frame_rate : 59.94f;
        if (fps > 59.9f && fps < 60.1f) {
            ndi_frame.frame_rate_N = 60000;
            ndi_frame.frame_rate_D = 1001;
        } else if (fps > 29.9f && fps < 30.1f) {
            ndi_frame.frame_rate_N = 30000;
            ndi_frame.frame_rate_D = 1001;
        } else if (fps > 23.9f && fps < 24.1f) {
            ndi_frame.frame_rate_N = 24000;
            ndi_frame.frame_rate_D = 1001;
        } else {
            ndi_frame.frame_rate_N = (int)(fps * 1000);
            ndi_frame.frame_rate_D = 1000;
        }

        ndi_frame.frame_format_type = NDIlib_frame_format_type_progressive;
        ndi_frame.timecode = (pixelFrame.timestamp_ns > 0) ?
            (int64_t)(pixelFrame.timestamp_ns / 100) : NDIlib_send_timecode_synthesize;
        ndi_frame.picture_aspect_ratio = (float)pixelFrame.width / pixelFrame.height;
        ndi_frame.p_metadata = nullptr;

        // Send frame (NDI handles timing if clock_video is true)
        if (ndi_lib) {
            ndi_lib->send_send_video_v2(sender, &ndi_frame);
            frames_sent_.fetch_add(1);
        }
    }

    NSLog(@"NDIOutput: Send loop ended");
}

bool NDIOutput::convertFromTexture(const SwitcherFrame& frame, NDIlib_video_frame_v2_t& ndi_frame) {
    if (!frame.texture) {
        NSLog(@"NDIOutput: convertFromTexture called with nil texture");
        return false;
    }

    id<MTLTexture> texture = frame.texture;
    uint32_t texW = (uint32_t)texture.width;
    uint32_t texH = (uint32_t)texture.height;

    // Validate texture dimensions
    if (texW == 0 || texH == 0 || texW > 7680 || texH > 4320) {
        NSLog(@"NDIOutput: Invalid texture dimensions %ux%u", texW, texH);
        return false;
    }

    // Apply crop region (normalized 0-1 coordinates)
    const auto& crop = currentCrop();
    uint32_t cropX = (uint32_t)(crop.x * texW);
    uint32_t cropY = (uint32_t)(crop.y * texH);
    uint32_t cropW = (uint32_t)(crop.w * texW);
    uint32_t cropH = (uint32_t)(crop.h * texH);

    // Clamp to texture bounds
    if (cropX >= texW) cropX = 0;
    if (cropY >= texH) cropY = 0;
    if (cropW == 0 || cropX + cropW > texW) cropW = texW - cropX;
    if (cropH == 0 || cropY + cropH > texH) cropH = texH - cropY;

    // Use configured output resolution, or cropped size if not set
    uint32_t outputW = width_.load();
    uint32_t outputH = height_.load();
    if (outputW == 0) outputW = cropW;
    if (outputH == 0) outputH = cropH;

    // For now, use the cropped region size directly (no scaling)
    uint32_t w = cropW;
    uint32_t h = cropH;

    // Ensure buffer is large enough for cropped region
    size_t required_size = w * h * 4;
    if (ndi_buffer_.size() < required_size) {
        try {
            ndi_buffer_.resize(required_size);
        } catch (const std::exception& e) {
            NSLog(@"NDIOutput: Failed to allocate buffer of size %zu: %s", required_size, e.what());
            return false;
        }
    }

    // Check if edge blending is needed
    const auto& blend = currentEdgeBlend();
    // Run edge blend shader if any blending, warp, lens correction, curvature, or corner overlay is active
    bool hasGeometricCorrection = (blend.warpTopLeftX != 0 || blend.warpTopLeftY != 0 ||
                                   blend.warpTopMiddleX != 0 || blend.warpTopMiddleY != 0 ||
                                   blend.warpTopRightX != 0 || blend.warpTopRightY != 0 ||
                                   blend.warpMiddleLeftX != 0 || blend.warpMiddleLeftY != 0 ||
                                   blend.warpMiddleRightX != 0 || blend.warpMiddleRightY != 0 ||
                                   blend.warpBottomLeftX != 0 || blend.warpBottomLeftY != 0 ||
                                   blend.warpBottomMiddleX != 0 || blend.warpBottomMiddleY != 0 ||
                                   blend.warpBottomRightX != 0 || blend.warpBottomRightY != 0 ||
                                   blend.warpCurvature != 0 ||
                                   blend.lensK1 != 0 || blend.lensK2 != 0);
    bool needsEdgeBlend = (blend.hasBlending() || hasGeometricCorrection || blend.activeCorner > 0) && edge_blend_pipeline_;

    if (needsEdgeBlend) {
        // Ensure temp texture exists
        if (!ensureTempTexture(w, h)) {
            NSLog(@"NDIOutput: Failed to create temp texture for edge blend");
            needsEdgeBlend = false;  // Fall back to direct read
        }
    }

    if (needsEdgeBlend) {
        // Render through edge blend shader to temp texture
        if (!renderWithEdgeBlend(texture, cropX, cropY, cropW, cropH)) {
            NSLog(@"NDIOutput: Edge blend render failed, falling back to direct");
            needsEdgeBlend = false;
        }
    }

    // Read from appropriate texture
    @try {
        if (needsEdgeBlend && temp_texture_) {
            // Read from edge-blended temp texture (full texture, not cropped)
            MTLRegion region = MTLRegionMake2D(0, 0, w, h);
            [temp_texture_ getBytes:ndi_buffer_.data()
                        bytesPerRow:w * 4
                         fromRegion:region
                        mipmapLevel:0];
        } else {
            // Read cropped region directly from source texture
            MTLRegion region = MTLRegionMake2D(cropX, cropY, w, h);
            [texture getBytes:ndi_buffer_.data()
                  bytesPerRow:w * 4
                   fromRegion:region
                  mipmapLevel:0];
        }
    } @catch (NSException* e) {
        NSLog(@"NDIOutput: Failed to read texture data: %@", e.reason);
        return false;
    }

    // Setup NDI frame with cropped dimensions
    ndi_frame.xres = w;
    ndi_frame.yres = h;
    ndi_frame.FourCC = NDIlib_FourCC_type_BGRA;
    ndi_frame.line_stride_in_bytes = w * 4;
    ndi_frame.p_data = ndi_buffer_.data();

    // Calculate frame rate
    float fps = frame.frame_rate > 0 ? frame.frame_rate : 59.94f;
    if (fps > 59.9f && fps < 60.1f) {
        // 59.94 fps (60000/1001)
        ndi_frame.frame_rate_N = 60000;
        ndi_frame.frame_rate_D = 1001;
    } else if (fps > 29.9f && fps < 30.1f) {
        // 29.97 fps (30000/1001)
        ndi_frame.frame_rate_N = 30000;
        ndi_frame.frame_rate_D = 1001;
    } else if (fps > 23.9f && fps < 24.1f) {
        // 23.976 fps (24000/1001)
        ndi_frame.frame_rate_N = 24000;
        ndi_frame.frame_rate_D = 1001;
    } else {
        // Generic rate
        ndi_frame.frame_rate_N = (int)(fps * 1000);
        ndi_frame.frame_rate_D = 1000;
    }

    // Frame format
    ndi_frame.frame_format_type = frame.interlaced ?
        (frame.top_field_first ? NDIlib_frame_format_type_interleaved : NDIlib_frame_format_type_field_1) :
        NDIlib_frame_format_type_progressive;

    // Timing - use frame timestamp for sync across multiple outputs
    // NDI timecode is in 100ns units since Unix epoch
    // frame.timestamp_ns is in nanoseconds, divide by 100 to get 100ns units
    ndi_frame.timecode = (frame.timestamp_ns > 0) ? (int64_t)(frame.timestamp_ns / 100) : NDIlib_send_timecode_synthesize;
    ndi_frame.picture_aspect_ratio = (float)w / h;

    // Metadata (optional)
    ndi_frame.p_metadata = nullptr;

    return true;
}

} // namespace RocKontrol
