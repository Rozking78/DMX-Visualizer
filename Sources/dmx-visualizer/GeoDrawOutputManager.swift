// GeoDrawOutputManager.swift - Manages all output destinations for GeoDraw
// Provides zero-latency output with display outputs and NDI support

import Foundation
@preconcurrency import Metal
import OutputEngine

// MARK: - Venue Configuration (for saving/loading separately from show files)

struct VenueConfig: Codable {
    var name: String
    var canvasWidth: Int
    var canvasHeight: Int
    var outputs: [OutputConfig]

    // Master Control DMX settings
    var masterControlEnabled: Bool
    var masterControlUniverse: Int
    var masterControlAddress: Int

    // Venue metadata
    var createdDate: Date?
    var modifiedDate: Date?
    var notes: String?

    init(name: String, canvasWidth: Int, canvasHeight: Int, outputs: [OutputConfig],
         masterControlEnabled: Bool = false, masterControlUniverse: Int = 0, masterControlAddress: Int = 1) {
        self.name = name
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.outputs = outputs
        self.masterControlEnabled = masterControlEnabled
        self.masterControlUniverse = masterControlUniverse
        self.masterControlAddress = masterControlAddress
        self.createdDate = Date()
        self.modifiedDate = Date()
    }

    // File extension for venue configs
    static let fileExtension = "geodrawvenue"
}

// Output configuration for persistence
struct OutputConfig: Codable {
    var id: UUID
    var type: String  // "display" or "ndi"
    var name: String
    var enabled: Bool
    var displayId: UInt32?
    var ndiWidth: UInt32?   // For NDI outputs
    var ndiHeight: UInt32?  // For NDI outputs
    var displayWidth: UInt32?   // For display outputs (nil = native)
    var displayHeight: UInt32?  // For display outputs (nil = native)

    // Canvas pixel positions (stored directly, not derived)
    var positionX: Int?
    var positionY: Int?
    var positionW: Int?
    var positionH: Int?

    var cropX: Float
    var cropY: Float
    var cropWidth: Float
    var cropHeight: Float
    var edgeBlendLeft: Float
    var edgeBlendRight: Float
    var edgeBlendTop: Float
    var edgeBlendBottom: Float
    var edgeBlendGamma: Float
    var edgeBlendPower: Float
    var edgeBlendBlackLevel: Float

    // 8-Point Warp (Keystone) - offsets in pixels from default position
    var warpTopLeftX: Float
    var warpTopLeftY: Float
    var warpTopMiddleX: Float    // Top edge middle point
    var warpTopMiddleY: Float
    var warpTopRightX: Float
    var warpTopRightY: Float
    var warpMiddleLeftX: Float   // Left edge middle point
    var warpMiddleLeftY: Float
    var warpMiddleRightX: Float  // Right edge middle point
    var warpMiddleRightY: Float
    var warpBottomLeftX: Float
    var warpBottomLeftY: Float
    var warpBottomMiddleX: Float // Bottom edge middle point
    var warpBottomMiddleY: Float
    var warpBottomRightX: Float
    var warpBottomRightY: Float

    // Pincushion/Barrel Correction
    var lensK1: Float  // Primary radial coefficient (+ = pincushion, - = barrel)
    var lensK2: Float  // Secondary radial coefficient
    var lensCenterX: Float  // Distortion center X (0.5 = center)
    var lensCenterY: Float  // Distortion center Y (0.5 = center)

    // Warp Curvature (for sphere/curved surface mapping)
    var warpCurvature: Float  // Curvature amount (0 = linear, + = convex/barrel, - = concave/pincushion)

    // Per-output DMX patch (universe and address for 27ch fixture)
    var dmxUniverse: Int  // 0 = disabled, 1+ = active universe
    var dmxAddress: Int   // 1-512 DMX address (1-based)

    // Per-output intensity from DMX (runtime, not persisted via DMX but set by DMX)
    var outputIntensity: Float  // 0-1.0, default 1.0

    // Per-output frame rate control (0 = unlimited/match source)
    var targetFrameRate: Float

    // Per-output shader processing toggles (for CPU/GPU optimization)
    var enableEdgeBlend: Bool       // Edge blend feathering
    var enableWarp: Bool            // 8-point warp (keystone)
    var enableLensCorrection: Bool  // Pincushion/barrel correction
    var enableCurveWarp: Bool       // Spherical curvature mapping

    static func defaultDisplay(displayId: UInt32, name: String, width: UInt32? = nil, height: UInt32? = nil) -> OutputConfig {
        OutputConfig(
            id: UUID(),
            type: "display",
            name: name,
            enabled: false,
            displayId: displayId,
            ndiWidth: nil,
            ndiHeight: nil,
            displayWidth: width,    // nil = use native resolution
            displayHeight: height,
            positionX: nil,  // Will be calculated when added to canvas
            positionY: nil,
            positionW: nil,
            positionH: nil,
            cropX: 0, cropY: 0, cropWidth: 1, cropHeight: 1,
            edgeBlendLeft: 0, edgeBlendRight: 0, edgeBlendTop: 0, edgeBlendBottom: 0,
            edgeBlendGamma: 2.2, edgeBlendPower: 1.0, edgeBlendBlackLevel: 0,
            warpTopLeftX: 0, warpTopLeftY: 0, warpTopMiddleX: 0, warpTopMiddleY: 0, warpTopRightX: 0, warpTopRightY: 0,
            warpMiddleLeftX: 0, warpMiddleLeftY: 0, warpMiddleRightX: 0, warpMiddleRightY: 0,
            warpBottomLeftX: 0, warpBottomLeftY: 0, warpBottomMiddleX: 0, warpBottomMiddleY: 0, warpBottomRightX: 0, warpBottomRightY: 0,
            lensK1: 0, lensK2: 0, lensCenterX: 0.5, lensCenterY: 0.5,
            warpCurvature: 0,
            dmxUniverse: 0,  // 0 = DMX control disabled
            dmxAddress: 1,   // Default address
            outputIntensity: 1.0,  // Full brightness by default
            targetFrameRate: 0,    // 0 = unlimited
            enableEdgeBlend: true,
            enableWarp: true,
            enableLensCorrection: true,
            enableCurveWarp: true
        )
    }

    static func defaultNDI(name: String, width: UInt32 = 1920, height: UInt32 = 1080) -> OutputConfig {
        OutputConfig(
            id: UUID(),
            type: "ndi",
            name: name,
            enabled: false,
            displayId: nil,
            ndiWidth: width,
            ndiHeight: height,
            displayWidth: nil,
            displayHeight: nil,
            positionX: nil,  // Will be calculated when added to canvas
            positionY: nil,
            positionW: nil,
            positionH: nil,
            cropX: 0, cropY: 0, cropWidth: 1, cropHeight: 1,
            edgeBlendLeft: 0, edgeBlendRight: 0, edgeBlendTop: 0, edgeBlendBottom: 0,
            edgeBlendGamma: 2.2, edgeBlendPower: 1.0, edgeBlendBlackLevel: 0,
            warpTopLeftX: 0, warpTopLeftY: 0, warpTopMiddleX: 0, warpTopMiddleY: 0, warpTopRightX: 0, warpTopRightY: 0,
            warpMiddleLeftX: 0, warpMiddleLeftY: 0, warpMiddleRightX: 0, warpMiddleRightY: 0,
            warpBottomLeftX: 0, warpBottomLeftY: 0, warpBottomMiddleX: 0, warpBottomMiddleY: 0, warpBottomRightX: 0, warpBottomRightY: 0,
            lensK1: 0, lensK2: 0, lensCenterX: 0.5, lensCenterY: 0.5,
            warpCurvature: 0,
            dmxUniverse: 0,  // 0 = DMX control disabled
            dmxAddress: 1,   // Default address
            outputIntensity: 1.0,  // Full brightness by default
            targetFrameRate: 0,    // 0 = unlimited
            enableEdgeBlend: true,
            enableWarp: true,
            enableLensCorrection: true,
            enableCurveWarp: true
        )
    }
}

// Wrapper for managed outputs
class ManagedOutput {
    let id: UUID
    let type: GDOutputType
    var config: OutputConfig
    var displayOutput: GDDisplayOutput?
    var ndiOutput: GDNDIOutput?
    var activeCorner: Int32 = 0  // 0=none, 1=TL, 2=TR, 3=BL, 4=BR (transient, not saved)

    init(id: UUID, type: GDOutputType, config: OutputConfig) {
        self.id = id
        self.type = type
        self.config = config
    }

    var isRunning: Bool {
        switch type {
        case .display:
            return displayOutput?.isRunning() ?? false
        case .NDI:
            return ndiOutput?.isRunning() ?? false
        default:
            return false
        }
    }

    var name: String {
        switch type {
        case .display:
            return displayOutput?.name ?? config.name
        case .NDI:
            return ndiOutput?.name ?? config.name
        default:
            return config.name
        }
    }

    var status: GDOutputStatus {
        switch type {
        case .display:
            return displayOutput?.status ?? .stopped
        case .NDI:
            return ndiOutput?.status ?? .stopped
        default:
            return .stopped
        }
    }

    var width: UInt32 {
        switch type {
        case .display:
            // Use config value if set, otherwise native display resolution
            return config.displayWidth ?? displayOutput?.width ?? 1920
        case .NDI:
            // Use config value for NDI (more reliable after resolution changes)
            return config.ndiWidth ?? ndiOutput?.width ?? 1920
        default:
            return 1920
        }
    }

    var height: UInt32 {
        switch type {
        case .display:
            // Use config value if set, otherwise native display resolution
            return config.displayHeight ?? displayOutput?.height ?? 1080
        case .NDI:
            // Use config value for NDI (more reliable after resolution changes)
            return config.ndiHeight ?? ndiOutput?.height ?? 1080
        default:
            return 1080
        }
    }

    // Native resolution from the actual display
    var nativeWidth: UInt32 {
        return displayOutput?.width ?? 1920
    }

    var nativeHeight: UInt32 {
        return displayOutput?.height ?? 1080
    }
}

// Main output manager singleton
final class OutputManager: @unchecked Sendable {
    static let shared = OutputManager()

    private var device: MTLDevice?
    private var outputs: [UUID: ManagedOutput] = [:]
    private let outputQueue = DispatchQueue(label: "com.geodraw.outputmanager", qos: .userInteractive)

    // NDI network interface (empty = use same as DMX, or all interfaces)
    private(set) var ndiNetworkInterface: String = ""

    private init() {
        // Load NDI network interface preference
        ndiNetworkInterface = UserDefaults.standard.string(forKey: "NDINetworkInterface") ?? ""
    }

    // MARK: - Setup

    func setup(device: MTLDevice) {
        self.device = device
        loadOutputConfigs()
        print("OutputManager: Initialized with Metal device")
    }

    // MARK: - Frame Push (called from performDraw)

    /// Push a frame to all enabled outputs
    /// This method is designed to be fast and non-blocking
    /// All outputs receive the same timestamp for sync
    func pushFrame(texture: MTLTexture, timestamp: UInt64, frameRate: Float) {
        // Push to all enabled outputs - simple loop is faster than concurrentPerform for small counts
        // Each output's pushFrame is non-blocking (queues work for async processing)
        for output in outputs.values where output.config.enabled {
            // Apply intensity before each frame push
            let intensity = output.config.outputIntensity

            switch output.type {
            case .display:
                output.displayOutput?.setIntensity(intensity)
                output.displayOutput?.pushFrame(with: texture, timestamp: timestamp, frameRate: frameRate)
            case .NDI:
                output.ndiOutput?.setIntensity(intensity)
                output.ndiOutput?.pushFrame(with: texture, timestamp: timestamp, frameRate: frameRate)
            default:
                break
            }
        }
    }

    // MARK: - DMX Patch Management

    /// Update DMX patch for an output (universe 0 = disabled)
    func updateDMXPatch(id: UUID, universe: Int, address: Int) {
        guard let output = outputs[id] else { return }
        output.config.dmxUniverse = universe
        output.config.dmxAddress = max(1, min(486, address))  // 27ch fixture, max start addr 486
        saveOutputConfigs()
        print("OutputManager: Set DMX patch for '\(output.config.name)' to Universe \(universe), Address \(address)")
    }

    /// Update output intensity (called from DMX processing)
    func updateOutputIntensity(id: UUID, intensity: Float) {
        guard let output = outputs[id] else { return }
        output.config.outputIntensity = intensity
    }

    // MARK: - Per-Output Frame Rate & Shader Control

    /// Set target frame rate for an output (0 = unlimited)
    func setOutputFrameRate(id: UUID, fps: Float) {
        guard let output = outputs[id] else { return }
        output.config.targetFrameRate = fps

        // Apply to NDI output if running
        if output.type == .NDI, let ndi = output.ndiOutput {
            ndi.setTargetFrameRate(fps)
        }

        saveOutputConfigs()
        let fpsStr = fps == 0 ? "unlimited" : "\(Int(fps)) fps"
        print("OutputManager: Set frame rate for '\(output.config.name)' to \(fpsStr)")
    }

    /// Toggle edge blend shader for an output
    func setEdgeBlendEnabled(id: UUID, enabled: Bool) {
        guard let output = outputs[id] else { return }
        output.config.enableEdgeBlend = enabled
        saveOutputConfigs()
        print("OutputManager: Edge blend \(enabled ? "enabled" : "disabled") for '\(output.config.name)'")
    }

    /// Toggle warp (8-point keystone) shader for an output
    func setWarpEnabled(id: UUID, enabled: Bool) {
        guard let output = outputs[id] else { return }
        output.config.enableWarp = enabled
        saveOutputConfigs()
        print("OutputManager: Warp \(enabled ? "enabled" : "disabled") for '\(output.config.name)'")
    }

    /// Toggle lens correction shader for an output
    func setLensCorrectionEnabled(id: UUID, enabled: Bool) {
        guard let output = outputs[id] else { return }
        output.config.enableLensCorrection = enabled
        saveOutputConfigs()
        print("OutputManager: Lens correction \(enabled ? "enabled" : "disabled") for '\(output.config.name)'")
    }

    /// Toggle curvature warp shader for an output
    func setCurveWarpEnabled(id: UUID, enabled: Bool) {
        guard let output = outputs[id] else { return }
        output.config.enableCurveWarp = enabled
        saveOutputConfigs()
        print("OutputManager: Curve warp \(enabled ? "enabled" : "disabled") for '\(output.config.name)'")
    }

    /// Get shader states for an output (for UI)
    func getShaderStates(id: UUID) -> (edgeBlend: Bool, warp: Bool, lens: Bool, curve: Bool)? {
        guard let output = outputs[id] else { return nil }
        return (
            edgeBlend: output.config.enableEdgeBlend,
            warp: output.config.enableWarp,
            lens: output.config.enableLensCorrection,
            curve: output.config.enableCurveWarp
        )
    }

    /// Get target frame rate for an output
    func getOutputFrameRate(id: UUID) -> Float? {
        guard let output = outputs[id] else { return nil }
        return output.config.targetFrameRate
    }

    // MARK: - Display Output Management

    func addDisplayOutput(displayId: UInt32, name: String) -> UUID? {
        guard let device = device else { return nil }

        let config = OutputConfig.defaultDisplay(displayId: displayId, name: name)
        let output = ManagedOutput(id: config.id, type: .display, config: config)

        let displayOutput = GDDisplayOutput(device: device)
        displayOutput.configure(withDisplayId: displayId, fullscreen: true, vsync: true, label: name)
        output.displayOutput = displayOutput

        // Apply crop
        let crop = GDCropRegion(x: config.cropX, y: config.cropY, width: config.cropWidth, height: config.cropHeight)
        displayOutput.setCrop(crop)

        // Apply edge blend
        let blend = GDEdgeBlendParams(left: config.edgeBlendLeft, right: config.edgeBlendRight,
                                       top: config.edgeBlendTop, bottom: config.edgeBlendBottom)
        blend.gamma = config.edgeBlendGamma
        blend.power = config.edgeBlendPower
        blend.blackLevel = config.edgeBlendBlackLevel
        blend.enableEdgeBlend = config.enableEdgeBlend
        blend.enableWarp = config.enableWarp
        blend.enableLensCorrection = config.enableLensCorrection
        blend.enableCurveWarp = config.enableCurveWarp
        displayOutput.setEdgeBlend(blend)

        outputs[config.id] = output
        saveOutputConfigs()

        print("OutputManager: Added display output '\(name)' (id: \(displayId))")
        return config.id
    }

    func addNDIOutput(sourceName: String) -> UUID? {
        guard let device = device else { return nil }

        let config = OutputConfig.defaultNDI(name: sourceName)
        let output = ManagedOutput(id: config.id, type: .NDI, config: config)

        let ndiOutput = GDNDIOutput(device: device)
        let netInterface = ndiNetworkInterface.isEmpty ? nil : ndiNetworkInterface
        ndiOutput.configure(withSourceName: sourceName, groups: nil, networkInterface: netInterface, clockVideo: true, asyncQueueSize: 5)

        // Apply legacy mode preference
        let legacyMode = UserDefaults.standard.bool(forKey: "NDILegacyMode")
        ndiOutput.setLegacyMode(legacyMode)

        output.ndiOutput = ndiOutput

        // Apply crop
        let crop = GDCropRegion(x: config.cropX, y: config.cropY, width: config.cropWidth, height: config.cropHeight)
        ndiOutput.setCrop(crop)

        outputs[config.id] = output
        saveOutputConfigs()

        print("OutputManager: Added NDI output '\(sourceName)' on interface: \(netInterface ?? "all")")
        return config.id
    }

    /// Set the network interface for NDI outputs
    func setNDINetworkInterface(_ interface: String) {
        ndiNetworkInterface = interface
        UserDefaults.standard.set(interface, forKey: "NDINetworkInterface")
        print("OutputManager: NDI network interface set to '\(interface.isEmpty ? "all" : interface)'")
    }

    // MARK: - Output Control

    func enableOutput(id: UUID, enabled: Bool) {
        guard let output = outputs[id] else { return }

        output.config.enabled = enabled

        if enabled {
            startOutput(output)
        } else {
            stopOutput(output)
        }

        saveOutputConfigs()
    }

    // Temporary storage for outputs pending deletion (prevents premature deallocation)
    // Keep GDDisplayOutput/GDNDIOutput references alive until autorelease pool drains
    private var pendingDisplayOutputs: [GDDisplayOutput] = []
    private var pendingNDIOutputs: [GDNDIOutput] = []

    func removeOutput(id: UUID) {
        guard let output = outputs[id] else { return }

        // Remove from dictionary FIRST to prevent any other code from accessing it
        outputs.removeValue(forKey: id)
        saveOutputConfigs()

        // Stop the outputs first
        output.displayOutput?.stop()
        output.ndiOutput?.stop()

        // Move the output objects to pending arrays BEFORE clearing references
        // This keeps the underlying Objective-C/C++ objects alive
        if let displayOut = output.displayOutput {
            pendingDisplayOutputs.append(displayOut)
        }
        if let ndiOut = output.ndiOutput {
            pendingNDIOutputs.append(ndiOut)
        }

        // Now clear the references on ManagedOutput
        output.displayOutput = nil
        output.ndiOutput = nil

        // Clean up pending outputs on next run loop iteration (after autorelease pool drain)
        DispatchQueue.main.async { [weak self] in
            self?.pendingDisplayOutputs.removeAll()
            self?.pendingNDIOutputs.removeAll()
        }

        print("OutputManager: Removed output \(id)")
    }

    func renameOutput(id: UUID, name: String) {
        guard let output = outputs[id] else { return }

        // Update config
        output.config.name = name

        // Update underlying output
        switch output.type {
        case .display:
            _ = output.displayOutput?.setName(name)
        case .NDI:
            _ = output.ndiOutput?.setName(name)
        default:
            break
        }

        saveOutputConfigs()
        print("OutputManager: Renamed output \(id) to '\(name)'")
    }

    func setNDIResolution(id: UUID, width: UInt32, height: UInt32) {
        guard let output = outputs[id], output.type == .NDI else { return }

        // Update config with new resolution
        output.config.ndiWidth = width
        output.config.ndiHeight = height

        // Need to restart NDI output with new resolution
        output.ndiOutput?.stop()
        _ = output.ndiOutput?.setResolutionWidth(width, height: height)
        _ = output.ndiOutput?.start()

        saveOutputConfigs()
        print("OutputManager: Set NDI resolution to \(width)x\(height)")
    }

    func setDisplayResolution(id: UUID, width: UInt32, height: UInt32) {
        guard let output = outputs[id], output.type == .display else { return }

        // Update config
        output.config.displayWidth = width
        output.config.displayHeight = height

        // Actually resize the display window
        if let displayOutput = output.displayOutput {
            _ = displayOutput.setResolutionWidth(width, height: height)
        }

        saveOutputConfigs()
        print("OutputManager: Set display output size to \(width)x\(height)")
    }

    func resetDisplayToNative(id: UUID) {
        guard let output = outputs[id], output.type == .display else { return }

        // Clear custom resolution (use native)
        output.config.displayWidth = nil
        output.config.displayHeight = nil

        // Restart to apply native resolution
        output.displayOutput?.stop()
        if let displayId = output.config.displayId {
            _ = output.displayOutput?.configure(withDisplayId: displayId, fullscreen: true, vsync: true, label: output.config.name)
        }
        if output.config.enabled {
            _ = output.displayOutput?.start()
        }

        saveOutputConfigs()
        print("OutputManager: Reset display to native resolution")
    }

    func setDisplayId(id: UUID, displayId: UInt32) {
        guard let output = outputs[id], output.type == .display else { return }

        // Update config
        output.config.displayId = displayId

        // Need to restart with new display
        output.displayOutput?.stop()
        _ = output.displayOutput?.configure(withDisplayId: displayId, fullscreen: true, vsync: true, label: output.config.name)
        _ = output.displayOutput?.start()

        saveOutputConfigs()
        print("OutputManager: Set display to \(displayId)")
    }

    func startOutput(_ output: ManagedOutput) {
        switch output.type {
        case .display:
            _ = output.displayOutput?.start()
        case .NDI:
            _ = output.ndiOutput?.start()
        default:
            break
        }
    }

    func stopOutput(_ output: ManagedOutput) {
        switch output.type {
        case .display:
            output.displayOutput?.stop()
        case .NDI:
            output.ndiOutput?.stop()
        default:
            break
        }
    }

    // MARK: - Configuration

    func updateCrop(id: UUID, x: Float, y: Float, width: Float, height: Float) {
        guard let output = outputs[id] else { return }


        output.config.cropX = x
        output.config.cropY = y
        output.config.cropWidth = width
        output.config.cropHeight = height

        let crop = GDCropRegion(x: x, y: y, width: width, height: height)

        switch output.type {
        case .display:
            output.displayOutput?.setCrop(crop)
        case .NDI:
            output.ndiOutput?.setCrop(crop)
        default:
            break
        }

        saveOutputConfigs()
    }

    /// Update the canvas pixel position for an output (for UI persistence)
    /// Position x/y are OFFSETS from canvas center (0 = centered)
    func updatePosition(id: UUID, x: Int, y: Int, w: Int, h: Int) {
        guard let output = outputs[id] else { return }

        output.config.positionX = x
        output.config.positionY = y
        output.config.positionW = w
        output.config.positionH = h

        // Calculate normalized crop region from center-relative position offset
        // Position x/y are offsets from center: posX=0 means centered on canvas
        let canvasW = Float(UserDefaults.standard.integer(forKey: "canvasWidth"))
        let canvasH = Float(UserDefaults.standard.integer(forKey: "canvasHeight"))
        if canvasW > 0 && canvasH > 0 {
            // Convert center-relative offset to left-edge pixel position
            // Left edge = canvas_center + position_offset - half_output_width
            let leftEdge = (canvasW / 2.0) + Float(x) - (Float(w) / 2.0)
            let topEdge = (canvasH / 2.0) + Float(y) - (Float(h) / 2.0)

            // Normalize to 0-1 range for crop region
            let cropX = max(0, min(1, leftEdge / canvasW))
            let cropY = max(0, min(1, topEdge / canvasH))
            let cropW = Float(w) / canvasW
            let cropH = Float(h) / canvasH

            output.config.cropX = cropX
            output.config.cropY = cropY
            output.config.cropWidth = cropW
            output.config.cropHeight = cropH

            let crop = GDCropRegion(x: cropX, y: cropY, width: cropW, height: cropH)
            switch output.type {
            case .display:
                output.displayOutput?.setCrop(crop)
            case .NDI:
                output.ndiOutput?.setCrop(crop)
            default:
                break
            }
        }

        saveOutputConfigs()
    }

    func updateEdgeBlend(id: UUID, left: Float, right: Float, top: Float, bottom: Float,
                         gamma: Float = 2.2, power: Float = 1.0, blackLevel: Float = 0) {
        guard let output = outputs[id] else { return }


        output.config.edgeBlendLeft = left
        output.config.edgeBlendRight = right
        output.config.edgeBlendTop = top
        output.config.edgeBlendBottom = bottom
        output.config.edgeBlendGamma = gamma
        output.config.edgeBlendPower = power
        output.config.edgeBlendBlackLevel = blackLevel

        // Create edge blend params (includes warp and lens from config)
        let blend = GDEdgeBlendParams(left: left, right: right, top: top, bottom: bottom)
        blend.gamma = gamma
        blend.power = power
        blend.blackLevel = blackLevel
        // Include 8-point warp parameters from config
        blend.warpTopLeftX = output.config.warpTopLeftX
        blend.warpTopLeftY = output.config.warpTopLeftY
        blend.warpTopMiddleX = output.config.warpTopMiddleX
        blend.warpTopMiddleY = output.config.warpTopMiddleY
        blend.warpTopRightX = output.config.warpTopRightX
        blend.warpTopRightY = output.config.warpTopRightY
        blend.warpMiddleLeftX = output.config.warpMiddleLeftX
        blend.warpMiddleLeftY = output.config.warpMiddleLeftY
        blend.warpMiddleRightX = output.config.warpMiddleRightX
        blend.warpMiddleRightY = output.config.warpMiddleRightY
        blend.warpBottomLeftX = output.config.warpBottomLeftX
        blend.warpBottomLeftY = output.config.warpBottomLeftY
        blend.warpBottomMiddleX = output.config.warpBottomMiddleX
        blend.warpBottomMiddleY = output.config.warpBottomMiddleY
        blend.warpBottomRightX = output.config.warpBottomRightX
        blend.warpBottomRightY = output.config.warpBottomRightY
        // Include warp curvature from config
        blend.warpCurvature = output.config.warpCurvature
        // Include lens parameters from config
        blend.lensK1 = output.config.lensK1
        blend.lensK2 = output.config.lensK2
        blend.lensCenterX = output.config.lensCenterX
        blend.lensCenterY = output.config.lensCenterY
        // Preserve activeCorner overlay setting
        blend.activeCorner = output.activeCorner
        // Apply shader toggle flags from config
        blend.enableEdgeBlend = output.config.enableEdgeBlend
        blend.enableWarp = output.config.enableWarp
        blend.enableLensCorrection = output.config.enableLensCorrection
        blend.enableCurveWarp = output.config.enableCurveWarp

        // Apply to the appropriate output type
        if output.type == .display, let displayOutput = output.displayOutput {
            displayOutput.setEdgeBlend(blend)
        } else if output.type == .NDI, let ndiOutput = output.ndiOutput {
            ndiOutput.setEdgeBlend(blend)
        }

        saveOutputConfigs()
    }

    /// Update 8-point warp (keystone) parameters for an output
    func updateQuadWarp(id: UUID,
                        topLeftX: Float, topLeftY: Float,
                        topMiddleX: Float, topMiddleY: Float,
                        topRightX: Float, topRightY: Float,
                        middleLeftX: Float, middleLeftY: Float,
                        middleRightX: Float, middleRightY: Float,
                        bottomLeftX: Float, bottomLeftY: Float,
                        bottomMiddleX: Float, bottomMiddleY: Float,
                        bottomRightX: Float, bottomRightY: Float) {
        guard let output = outputs[id] else { return }

        output.config.warpTopLeftX = topLeftX
        output.config.warpTopLeftY = topLeftY
        output.config.warpTopMiddleX = topMiddleX
        output.config.warpTopMiddleY = topMiddleY
        output.config.warpTopRightX = topRightX
        output.config.warpTopRightY = topRightY
        output.config.warpMiddleLeftX = middleLeftX
        output.config.warpMiddleLeftY = middleLeftY
        output.config.warpMiddleRightX = middleRightX
        output.config.warpMiddleRightY = middleRightY
        output.config.warpBottomLeftX = bottomLeftX
        output.config.warpBottomLeftY = bottomLeftY
        output.config.warpBottomMiddleX = bottomMiddleX
        output.config.warpBottomMiddleY = bottomMiddleY
        output.config.warpBottomRightX = bottomRightX
        output.config.warpBottomRightY = bottomRightY

        // Re-apply edge blend (which now includes warp)
        updateEdgeBlend(id: id, left: output.config.edgeBlendLeft, right: output.config.edgeBlendRight,
                        top: output.config.edgeBlendTop, bottom: output.config.edgeBlendBottom,
                        gamma: output.config.edgeBlendGamma, power: output.config.edgeBlendPower,
                        blackLevel: output.config.edgeBlendBlackLevel)
    }

    /// Update lens distortion (pincushion/barrel) parameters for an output
    func updateLensCorrection(id: UUID, k1: Float, k2: Float, centerX: Float = 0.5, centerY: Float = 0.5) {
        guard let output = outputs[id] else { return }

        output.config.lensK1 = k1
        output.config.lensK2 = k2
        output.config.lensCenterX = centerX
        output.config.lensCenterY = centerY

        // Re-apply edge blend (which now includes lens)
        updateEdgeBlend(id: id, left: output.config.edgeBlendLeft, right: output.config.edgeBlendRight,
                        top: output.config.edgeBlendTop, bottom: output.config.edgeBlendBottom,
                        gamma: output.config.edgeBlendGamma, power: output.config.edgeBlendPower,
                        blackLevel: output.config.edgeBlendBlackLevel)
    }

    /// Reset quad warp to no distortion
    func resetQuadWarp(id: UUID) {
        updateQuadWarp(id: id,
                       topLeftX: 0, topLeftY: 0, topMiddleX: 0, topMiddleY: 0, topRightX: 0, topRightY: 0,
                       middleLeftX: 0, middleLeftY: 0, middleRightX: 0, middleRightY: 0,
                       bottomLeftX: 0, bottomLeftY: 0, bottomMiddleX: 0, bottomMiddleY: 0, bottomRightX: 0, bottomRightY: 0)
    }

    /// Reset lens correction to no distortion
    func resetLensCorrection(id: UUID) {
        updateLensCorrection(id: id, k1: 0, k2: 0, centerX: 0.5, centerY: 0.5)
    }

    /// Reset all edge blend values to zero for an output
    func resetEdgeBlend(id: UUID) {
        updateEdgeBlend(id: id, left: 0, right: 0, top: 0, bottom: 0)
    }

    /// Reset all edge blend values for all outputs
    func resetAllEdgeBlend() {
        for id in outputs.keys {
            resetEdgeBlend(id: id)
        }
    }

    /// Set the active corner overlay for an output (0=none, 1=TL, 2=TR, 3=BL, 4=BR)
    func setActiveCorner(id: UUID, corner: Int32) {
        guard let output = outputs[id] else { return }
        output.activeCorner = corner

        // Immediately update the edge blend to show/hide the overlay
        let blend = GDEdgeBlendParams(left: output.config.edgeBlendLeft, right: output.config.edgeBlendRight,
                                       top: output.config.edgeBlendTop, bottom: output.config.edgeBlendBottom)
        blend.gamma = output.config.edgeBlendGamma
        blend.power = output.config.edgeBlendPower
        blend.blackLevel = output.config.edgeBlendBlackLevel
        blend.warpTopLeftX = output.config.warpTopLeftX
        blend.warpTopLeftY = output.config.warpTopLeftY
        blend.warpTopMiddleX = output.config.warpTopMiddleX
        blend.warpTopMiddleY = output.config.warpTopMiddleY
        blend.warpTopRightX = output.config.warpTopRightX
        blend.warpTopRightY = output.config.warpTopRightY
        blend.warpMiddleLeftX = output.config.warpMiddleLeftX
        blend.warpMiddleLeftY = output.config.warpMiddleLeftY
        blend.warpMiddleRightX = output.config.warpMiddleRightX
        blend.warpMiddleRightY = output.config.warpMiddleRightY
        blend.warpBottomLeftX = output.config.warpBottomLeftX
        blend.warpBottomLeftY = output.config.warpBottomLeftY
        blend.warpBottomMiddleX = output.config.warpBottomMiddleX
        blend.warpBottomMiddleY = output.config.warpBottomMiddleY
        blend.warpBottomRightX = output.config.warpBottomRightX
        blend.warpBottomRightY = output.config.warpBottomRightY
        // Include warp curvature from config
        blend.warpCurvature = output.config.warpCurvature
        blend.lensK1 = output.config.lensK1
        blend.lensK2 = output.config.lensK2
        blend.lensCenterX = output.config.lensCenterX
        blend.lensCenterY = output.config.lensCenterY
        blend.activeCorner = corner
        blend.enableEdgeBlend = output.config.enableEdgeBlend
        blend.enableWarp = output.config.enableWarp
        blend.enableLensCorrection = output.config.enableLensCorrection
        blend.enableCurveWarp = output.config.enableCurveWarp

        if output.type == .display, let displayOutput = output.displayOutput {
            displayOutput.setEdgeBlend(blend)
        } else if output.type == .NDI, let ndiOutput = output.ndiOutput {
            ndiOutput.setEdgeBlend(blend)
        }
    }

    /// Clear all active corner overlays
    func clearAllActiveCorners() {
        for id in outputs.keys {
            setActiveCorner(id: id, corner: 0)
        }
    }

    // MARK: - Discovery

    func getAvailableDisplays() -> [GDDisplayInfo] {
        return GDListDisplays() ?? []
    }

    func getAllOutputs() -> [ManagedOutput] {
        // Sort by name for consistent display order
        return Array(outputs.values).sorted { $0.config.name < $1.config.name }
    }

    func getOutput(id: UUID) -> ManagedOutput? {
        return outputs[id]
    }

    /// Get the highest universe number used by any output DMX patch
    /// Returns 0 if no outputs have DMX patches configured
    func getMaxOutputUniverse() -> Int {
        return outputs.values.map { $0.config.dmxUniverse }.max() ?? 0
    }

    // MARK: - Persistence

    private func saveOutputConfigs() {
        let configs = outputs.values.map { $0.config }
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: "GeoDrawOutputConfigs")
        }
    }

    private func loadOutputConfigs() {
        guard let data = UserDefaults.standard.data(forKey: "GeoDrawOutputConfigs"),
              let configs = try? JSONDecoder().decode([OutputConfig].self, from: data),
              let device = device else { return }

        for config in configs {
            let output = ManagedOutput(id: config.id, type: config.type == "display" ? .display : .NDI, config: config)

            switch config.type {
            case "display":
                guard let displayId = config.displayId else { continue }
                let displayOutput = GDDisplayOutput(device: device)
                displayOutput.configure(withDisplayId: displayId, fullscreen: true, vsync: true, label: config.name)

                let crop = GDCropRegion(x: config.cropX, y: config.cropY, width: config.cropWidth, height: config.cropHeight)
                displayOutput.setCrop(crop)

                let blend = GDEdgeBlendParams(left: config.edgeBlendLeft, right: config.edgeBlendRight,
                                               top: config.edgeBlendTop, bottom: config.edgeBlendBottom)
                blend.gamma = config.edgeBlendGamma
                blend.power = config.edgeBlendPower
                blend.blackLevel = config.edgeBlendBlackLevel
                // Include 8-point warp parameters from config
                blend.warpTopLeftX = config.warpTopLeftX
                blend.warpTopLeftY = config.warpTopLeftY
                blend.warpTopMiddleX = config.warpTopMiddleX
                blend.warpTopMiddleY = config.warpTopMiddleY
                blend.warpTopRightX = config.warpTopRightX
                blend.warpTopRightY = config.warpTopRightY
                blend.warpMiddleLeftX = config.warpMiddleLeftX
                blend.warpMiddleLeftY = config.warpMiddleLeftY
                blend.warpMiddleRightX = config.warpMiddleRightX
                blend.warpMiddleRightY = config.warpMiddleRightY
                blend.warpBottomLeftX = config.warpBottomLeftX
                blend.warpBottomLeftY = config.warpBottomLeftY
                blend.warpBottomMiddleX = config.warpBottomMiddleX
                blend.warpBottomMiddleY = config.warpBottomMiddleY
                blend.warpBottomRightX = config.warpBottomRightX
                blend.warpBottomRightY = config.warpBottomRightY
                // Include warp curvature from config
                blend.warpCurvature = config.warpCurvature
                // Include lens parameters from config
                blend.lensK1 = config.lensK1
                blend.lensK2 = config.lensK2
                blend.lensCenterX = config.lensCenterX
                blend.lensCenterY = config.lensCenterY
                blend.enableEdgeBlend = config.enableEdgeBlend
                blend.enableWarp = config.enableWarp
                blend.enableLensCorrection = config.enableLensCorrection
                blend.enableCurveWarp = config.enableCurveWarp
                displayOutput.setEdgeBlend(blend)

                output.displayOutput = displayOutput

                if config.enabled {
                    _ = displayOutput.start()
                }

            case "ndi":
                let ndiOutput = GDNDIOutput(device: device)
                let netInterface = ndiNetworkInterface.isEmpty ? nil : ndiNetworkInterface
                ndiOutput.configure(withSourceName: config.name, groups: nil, networkInterface: netInterface, clockVideo: true, asyncQueueSize: 3)

                // Apply legacy mode preference
                let legacyMode = UserDefaults.standard.bool(forKey: "NDILegacyMode")
                ndiOutput.setLegacyMode(legacyMode)

                // Restore resolution from config
                if let width = config.ndiWidth, let height = config.ndiHeight {
                    _ = ndiOutput.setResolutionWidth(width, height: height)
                }

                let crop = GDCropRegion(x: config.cropX, y: config.cropY, width: config.cropWidth, height: config.cropHeight)
                ndiOutput.setCrop(crop)

                // Restore edge blend from config (including all warp and lens parameters)
                let blend = GDEdgeBlendParams(left: config.edgeBlendLeft, right: config.edgeBlendRight,
                                               top: config.edgeBlendTop, bottom: config.edgeBlendBottom)
                blend.gamma = config.edgeBlendGamma
                blend.power = config.edgeBlendPower
                blend.blackLevel = config.edgeBlendBlackLevel
                // Include 8-point warp parameters from config
                blend.warpTopLeftX = config.warpTopLeftX
                blend.warpTopLeftY = config.warpTopLeftY
                blend.warpTopMiddleX = config.warpTopMiddleX
                blend.warpTopMiddleY = config.warpTopMiddleY
                blend.warpTopRightX = config.warpTopRightX
                blend.warpTopRightY = config.warpTopRightY
                blend.warpMiddleLeftX = config.warpMiddleLeftX
                blend.warpMiddleLeftY = config.warpMiddleLeftY
                blend.warpMiddleRightX = config.warpMiddleRightX
                blend.warpMiddleRightY = config.warpMiddleRightY
                blend.warpBottomLeftX = config.warpBottomLeftX
                blend.warpBottomLeftY = config.warpBottomLeftY
                blend.warpBottomMiddleX = config.warpBottomMiddleX
                blend.warpBottomMiddleY = config.warpBottomMiddleY
                blend.warpBottomRightX = config.warpBottomRightX
                blend.warpBottomRightY = config.warpBottomRightY
                // Include warp curvature from config
                blend.warpCurvature = config.warpCurvature
                // Include lens parameters from config
                blend.lensK1 = config.lensK1
                blend.lensK2 = config.lensK2
                blend.lensCenterX = config.lensCenterX
                blend.lensCenterY = config.lensCenterY
                blend.enableEdgeBlend = config.enableEdgeBlend
                blend.enableWarp = config.enableWarp
                blend.enableLensCorrection = config.enableLensCorrection
                blend.enableCurveWarp = config.enableCurveWarp
                ndiOutput.setEdgeBlend(blend)

                output.ndiOutput = ndiOutput

                if config.enabled {
                    _ = ndiOutput.start()
                }

            default:
                continue
            }

            outputs[config.id] = output
        }

        print("OutputManager: Loaded \(outputs.count) output configurations")
    }

    // MARK: - Venue Configuration Save/Load

    /// Create a venue config from current state
    func createVenueConfig(name: String) -> VenueConfig {
        let canvasW = UserDefaults.standard.integer(forKey: "canvasWidth")
        let canvasH = UserDefaults.standard.integer(forKey: "canvasHeight")
        let configs = outputs.values.map { $0.config }

        // Get master control settings
        let masterEnabled = UserDefaults.standard.bool(forKey: "masterControlEnabled")
        let masterUniverse = UserDefaults.standard.integer(forKey: "masterControlUniverse")
        let masterAddress = UserDefaults.standard.integer(forKey: "masterControlAddress")

        return VenueConfig(
            name: name,
            canvasWidth: canvasW > 0 ? canvasW : 7680,
            canvasHeight: canvasH > 0 ? canvasH : 1080,
            outputs: Array(configs),
            masterControlEnabled: masterEnabled,
            masterControlUniverse: masterUniverse,
            masterControlAddress: masterAddress > 0 ? masterAddress : 1
        )
    }

    /// Save venue config to file
    func saveVenueConfig(_ config: VenueConfig, to url: URL) throws {
        var venueConfig = config
        venueConfig.modifiedDate = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(venueConfig)
        try data.write(to: url)

        print("OutputManager: Saved venue config '\(config.name)' to \(url.path)")
    }

    /// Load venue config from file
    func loadVenueConfig(from url: URL) throws -> VenueConfig {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let venueConfig = try decoder.decode(VenueConfig.self, from: data)
        print("OutputManager: Loaded venue config '\(venueConfig.name)' from \(url.path)")
        return venueConfig
    }

    /// Apply a venue config (replaces current outputs)
    func applyVenueConfig(_ venueConfig: VenueConfig) {
        guard let device = device else { return }

        // Stop and remove all current outputs
        for (_, output) in outputs {
            stopOutput(output)
        }
        outputs.removeAll()

        // Update canvas size
        UserDefaults.standard.set(venueConfig.canvasWidth, forKey: "canvasWidth")
        UserDefaults.standard.set(venueConfig.canvasHeight, forKey: "canvasHeight")

        // Update master control settings
        UserDefaults.standard.set(venueConfig.masterControlEnabled, forKey: "masterControlEnabled")
        UserDefaults.standard.set(venueConfig.masterControlUniverse, forKey: "masterControlUniverse")
        UserDefaults.standard.set(venueConfig.masterControlAddress, forKey: "masterControlAddress")

        // Create outputs from venue config
        for config in venueConfig.outputs {
            let output = ManagedOutput(id: config.id, type: config.type == "display" ? .display : .NDI, config: config)

            switch config.type {
            case "display":
                guard let displayId = config.displayId else { continue }
                let displayOutput = GDDisplayOutput(device: device)
                displayOutput.configure(withDisplayId: displayId, fullscreen: true, vsync: true, label: config.name)

                let crop = GDCropRegion(x: config.cropX, y: config.cropY, width: config.cropWidth, height: config.cropHeight)
                displayOutput.setCrop(crop)

                let blend = GDEdgeBlendParams(left: config.edgeBlendLeft, right: config.edgeBlendRight,
                                               top: config.edgeBlendTop, bottom: config.edgeBlendBottom)
                blend.gamma = config.edgeBlendGamma
                blend.power = config.edgeBlendPower
                blend.blackLevel = config.edgeBlendBlackLevel
                // Include 8-point warp parameters from config
                blend.warpTopLeftX = config.warpTopLeftX
                blend.warpTopLeftY = config.warpTopLeftY
                blend.warpTopMiddleX = config.warpTopMiddleX
                blend.warpTopMiddleY = config.warpTopMiddleY
                blend.warpTopRightX = config.warpTopRightX
                blend.warpTopRightY = config.warpTopRightY
                blend.warpMiddleLeftX = config.warpMiddleLeftX
                blend.warpMiddleLeftY = config.warpMiddleLeftY
                blend.warpMiddleRightX = config.warpMiddleRightX
                blend.warpMiddleRightY = config.warpMiddleRightY
                blend.warpBottomLeftX = config.warpBottomLeftX
                blend.warpBottomLeftY = config.warpBottomLeftY
                blend.warpBottomMiddleX = config.warpBottomMiddleX
                blend.warpBottomMiddleY = config.warpBottomMiddleY
                blend.warpBottomRightX = config.warpBottomRightX
                blend.warpBottomRightY = config.warpBottomRightY
                // Include warp curvature from config
                blend.warpCurvature = config.warpCurvature
                // Include lens parameters from config
                blend.lensK1 = config.lensK1
                blend.lensK2 = config.lensK2
                blend.lensCenterX = config.lensCenterX
                blend.lensCenterY = config.lensCenterY
                blend.enableEdgeBlend = config.enableEdgeBlend
                blend.enableWarp = config.enableWarp
                blend.enableLensCorrection = config.enableLensCorrection
                blend.enableCurveWarp = config.enableCurveWarp
                displayOutput.setEdgeBlend(blend)

                output.displayOutput = displayOutput

                if config.enabled {
                    _ = displayOutput.start()
                }

            case "ndi":
                let ndiOutput = GDNDIOutput(device: device)
                let netInterface = ndiNetworkInterface.isEmpty ? nil : ndiNetworkInterface
                ndiOutput.configure(withSourceName: config.name, groups: nil, networkInterface: netInterface, clockVideo: true, asyncQueueSize: 3)

                // Apply legacy mode preference
                let legacyMode = UserDefaults.standard.bool(forKey: "NDILegacyMode")
                ndiOutput.setLegacyMode(legacyMode)

                if let width = config.ndiWidth, let height = config.ndiHeight {
                    _ = ndiOutput.setResolutionWidth(width, height: height)
                }

                let crop = GDCropRegion(x: config.cropX, y: config.cropY, width: config.cropWidth, height: config.cropHeight)
                ndiOutput.setCrop(crop)

                // Restore edge blend from config (including all warp and lens parameters)
                let blend = GDEdgeBlendParams(left: config.edgeBlendLeft, right: config.edgeBlendRight,
                                               top: config.edgeBlendTop, bottom: config.edgeBlendBottom)
                blend.gamma = config.edgeBlendGamma
                blend.power = config.edgeBlendPower
                blend.blackLevel = config.edgeBlendBlackLevel
                // Include 8-point warp parameters from config
                blend.warpTopLeftX = config.warpTopLeftX
                blend.warpTopLeftY = config.warpTopLeftY
                blend.warpTopMiddleX = config.warpTopMiddleX
                blend.warpTopMiddleY = config.warpTopMiddleY
                blend.warpTopRightX = config.warpTopRightX
                blend.warpTopRightY = config.warpTopRightY
                blend.warpMiddleLeftX = config.warpMiddleLeftX
                blend.warpMiddleLeftY = config.warpMiddleLeftY
                blend.warpMiddleRightX = config.warpMiddleRightX
                blend.warpMiddleRightY = config.warpMiddleRightY
                blend.warpBottomLeftX = config.warpBottomLeftX
                blend.warpBottomLeftY = config.warpBottomLeftY
                blend.warpBottomMiddleX = config.warpBottomMiddleX
                blend.warpBottomMiddleY = config.warpBottomMiddleY
                blend.warpBottomRightX = config.warpBottomRightX
                blend.warpBottomRightY = config.warpBottomRightY
                // Include warp curvature from config
                blend.warpCurvature = config.warpCurvature
                // Include lens parameters from config
                blend.lensK1 = config.lensK1
                blend.lensK2 = config.lensK2
                blend.lensCenterX = config.lensCenterX
                blend.lensCenterY = config.lensCenterY
                blend.enableEdgeBlend = config.enableEdgeBlend
                blend.enableWarp = config.enableWarp
                blend.enableLensCorrection = config.enableLensCorrection
                blend.enableCurveWarp = config.enableCurveWarp
                ndiOutput.setEdgeBlend(blend)

                output.ndiOutput = ndiOutput

                if config.enabled {
                    _ = ndiOutput.start()
                }

            default:
                continue
            }

            outputs[config.id] = output
        }

        saveOutputConfigs()
        print("OutputManager: Applied venue config '\(venueConfig.name)' with \(outputs.count) outputs")
    }

    // MARK: - Cleanup

    func shutdown() {
        for (_, output) in outputs {
            stopOutput(output)
        }
        outputs.removeAll()
        print("OutputManager: Shutdown complete")
    }
}
