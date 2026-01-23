import AppKit
import Foundation
import Darwin
import QuartzCore
import CoreVideo
@preconcurrency import Metal
import MetalKit
import simd
import AVFoundation
import SwiftUI
import Combine
import UniformTypeIdentifiers
import OutputEngine

// MARK: - App Version
struct AppVersion {
    static let major = 1
    static let minor = 3
    static let patch = 0
    static let build = 1
    static let stage = "beta"  // "alpha", "beta", "rc", "" for release

    static var string: String {
        let base = "\(major).\(minor).\(patch)"
        if stage.isEmpty {
            return base
        }
        return "\(base)-\(stage).\(build)"
    }

    static var full: String {
        return "v\(string) (Build \(build))"
    }
}

// Global reference to the render view for live preview access
nonisolated(unsafe) var sharedMetalRenderView: MetalRenderView?

// Canvas resolution - can be changed in Settings, loaded from UserDefaults
nonisolated(unsafe) private var canvasSize: CGSize = {
    let savedWidth = UserDefaults.standard.integer(forKey: "canvasWidth")
    let savedHeight = UserDefaults.standard.integer(forKey: "canvasHeight")
    if savedWidth > 0 && savedHeight > 0 {
        return CGSize(width: savedWidth, height: savedHeight)
    }
    return CGSize(width: 1920, height: 1080)  // Default
}()

// Common resolution presets
enum ResolutionPreset: String, CaseIterable {
    case hd720 = "720p (1280x720)"
    case hd1080 = "1080p (1920x1080)"
    case hd1440 = "1440p (2560x1440)"
    case uhd4k = "4K (3840x2160)"
    case custom = "Custom"

    var size: CGSize? {
        switch self {
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .hd1440: return CGSize(width: 2560, height: 1440)
        case .uhd4k: return CGSize(width: 3840, height: 2160)
        case .custom: return nil
        }
    }

    static func from(size: CGSize) -> ResolutionPreset {
        for preset in allCases {
            if let presetSize = preset.size,
               presetSize.width == size.width && presetSize.height == size.height {
                return preset
            }
        }
        return .custom
    }
}

// MARK: - Gobo File Watcher (Live Sync)

/// Notification posted when a gobo file changes
extension Notification.Name {
    static let goboFileChanged = Notification.Name("goboFileChanged")
}

/// Watches multiple gobo folders for changes and notifies when gobos are updated
/// Note: Not @MainActor because dispatch sources run on their own queue
final class GoboFileWatcher: @unchecked Sendable {
    static let shared = GoboFileWatcher()

    private var folderMonitors: [DispatchSourceFileSystemObject] = []
    private var fileMonitors: [String: DispatchSourceFileSystemObject] = [:]
    private let queue = DispatchQueue(label: "gobo.file.watcher")
    private var lastModTimes: [String: Date] = [:]
    private var watchedFolders: [URL] = []
    private let lock = NSLock()  // Protect mutable state

    private init() {}

    func startWatching() {
        // Watch multiple folders for gobos (portable paths)
        let folders = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GeoDraw/gobos"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GoboCreator/Library")
        ]

        for folder in folders {
            watchFolder(folder)
        }
    }

    private func watchFolder(_ folderURL: URL) {
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            print("GoboWatcher: Folder not found at \(folderURL.path)")
            return
        }

        print("GoboWatcher: Monitoring \(folderURL.path) for changes")
        watchedFolders.append(folderURL)

        // Watch the folder for new files
        let folderFD = open(folderURL.path, O_EVTONLY)
        guard folderFD >= 0 else { return }

        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: folderFD,
            eventMask: [.write, .extend, .rename],
            queue: queue
        )

        monitor.setEventHandler { [weak self] in
            self?.scanForChanges(in: folderURL)
        }

        monitor.setCancelHandler {
            close(folderFD)
        }

        monitor.resume()
        folderMonitors.append(monitor)

        // Initial scan to get file modification times
        scanForChanges(in: folderURL)
    }

    private func scanForChanges(in folder: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }

        for file in files where file.pathExtension == "png" {
            let filename = file.lastPathComponent
            // Use full path as key to avoid collisions between folders
            let fileKey = file.path

            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modDate = attrs[.modificationDate] as? Date {

                // Thread-safe access to lastModTimes
                lock.lock()
                let lastMod = lastModTimes[fileKey]
                let isModified = lastMod != nil && modDate > lastMod!
                lastModTimes[fileKey] = modDate
                lock.unlock()

                if isModified {
                    // File was modified
                    if let goboId = extractGoboId(from: filename) {
                        print("GoboWatcher: Detected change in gobo \(goboId) (\(filename)) from \(folder.lastPathComponent)")
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(
                                name: .goboFileChanged,
                                object: nil,
                                userInfo: ["goboId": goboId, "filename": filename, "path": file.path]
                            )
                        }
                    }
                }
            }
        }
    }

    private func extractGoboId(from filename: String) -> Int? {
        // Parse gobo_XXX_name.png format
        let pattern = #"gobo_(\d{3})"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
           let range = Range(match.range(at: 1), in: filename) {
            return Int(filename[range])
        }
        return nil
    }

    /// Get all watched folder URLs
    func getWatchedFolders() -> [URL] {
        return watchedFolders
    }

    func stopWatching() {
        folderMonitors.forEach { $0.cancel() }
        folderMonitors.removeAll()
        fileMonitors.values.forEach { $0.cancel() }
        fileMonitors.removeAll()
        watchedFolders.removeAll()
    }
}

// MARK: - NDI Output Support

// Simple file logger for debugging
func ndiLog(_ message: String) {
    let logPath = "/tmp/geodraw_ndi.log"
    let timestamp = Date()
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data, attributes: nil)
        }
    }
    print(message) // Also print to console
}

/// NDI source structure (matches NDIlib_source_t)
struct NDISourceStruct {
    var p_ndi_name: UnsafePointer<CChar>?
    var p_url_address: UnsafePointer<CChar>?
}

/// NDI video frame structure (matches NDIlib_video_frame_v2_t)
struct NDIVideoFrameV2 {
    var xres: Int32 = 0
    var yres: Int32 = 0
    var fourCC: UInt32 = 0
    var frame_rate_N: Int32 = 60000
    var frame_rate_D: Int32 = 1000
    var picture_aspect_ratio: Float = 0
    var frame_format_type: Int32 = 1  // progressive
    var timecode: Int64 = 0
    var p_data: UnsafeMutablePointer<UInt8>?
    var line_stride_in_bytes: Int32 = 0
    var p_metadata: UnsafePointer<CChar>?
    var timestamp: Int64 = 0
}

/// NDI Library wrapper using dynamic loading
final class NDILibrary: @unchecked Sendable {
    static let shared = NDILibrary()
    private let lock = NSLock()

    private var handle: UnsafeMutableRawPointer?
    private(set) var isLoaded = false

    // Function pointer types using raw pointers for C compatibility
    typealias InitFn = @convention(c) () -> Bool
    typealias DestroyFn = @convention(c) () -> Void
    typealias VersionFn = @convention(c) () -> UnsafePointer<CChar>?
    // Send functions
    typealias SendCreateFn = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias SendDestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias SendVideoFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void
    typealias SendGetConnFn = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Int32
    // Find functions (for discovering NDI sources)
    typealias FindCreateFn = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias FindDestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FindGetSourcesFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?, UInt32) -> UnsafeRawPointer?
    // Receive functions
    typealias RecvCreateFn = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias RecvDestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias RecvCaptureFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Int32
    typealias RecvFreeVideoFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias RecvConnectFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void

    private var _initialize: InitFn?
    private var _destroy: DestroyFn?
    private var _version: VersionFn?
    private var _send_create: SendCreateFn?
    private var _send_destroy: SendDestroyFn?
    private var _send_send_video: SendVideoFn?
    private var _send_get_no_connections: SendGetConnFn?
    // Find
    private var _find_create: FindCreateFn?
    private var _find_destroy: FindDestroyFn?
    private var _find_get_sources: FindGetSourcesFn?
    // Receive
    private var _recv_create: RecvCreateFn?
    private var _recv_destroy: RecvDestroyFn?
    private var _recv_capture: RecvCaptureFn?
    private var _recv_free_video: RecvFreeVideoFn?
    private var _recv_connect: RecvConnectFn?

    private init() {
        loadLibrary()
    }

    private func loadLibrary() {
        // Try standard NDI SDK location
        let paths = [
            "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
            "/usr/local/lib/libndi.dylib",
            "libndi.dylib"
        ]

        for path in paths {
            handle = dlopen(path, RTLD_NOW)
            if handle != nil {
                ndiLog("NDI: Loaded library from \(path)")
                break
            }
        }

        guard handle != nil else {
            ndiLog("NDI: Failed to load library - NDI output disabled")
            return
        }

        // Load function pointers - Core
        _initialize = loadSymbol("NDIlib_initialize")
        _destroy = loadSymbol("NDIlib_destroy")
        _version = loadSymbol("NDIlib_version")

        // Load function pointers - Send
        _send_create = loadSymbol("NDIlib_send_create")
        _send_destroy = loadSymbol("NDIlib_send_destroy")
        _send_send_video = loadSymbol("NDIlib_send_send_video_v2")
        _send_get_no_connections = loadSymbol("NDIlib_send_get_no_connections")

        // Load function pointers - Find (for discovering sources)
        _find_create = loadSymbol("NDIlib_find_create_v2")
        _find_destroy = loadSymbol("NDIlib_find_destroy")
        _find_get_sources = loadSymbol("NDIlib_find_get_current_sources")

        // Load function pointers - Receive
        _recv_create = loadSymbol("NDIlib_recv_create_v3")
        _recv_destroy = loadSymbol("NDIlib_recv_destroy")
        _recv_capture = loadSymbol("NDIlib_recv_capture_v2")
        _recv_free_video = loadSymbol("NDIlib_recv_free_video_v2")
        _recv_connect = loadSymbol("NDIlib_recv_connect")

        // Initialize NDI
        if let init_fn = _initialize, init_fn() {
            isLoaded = true
            if let ver_fn = _version, let ver = ver_fn() {
                ndiLog("NDI: Initialized, version \(String(cString: ver))")
            }
        } else {
            ndiLog("NDI: Failed to initialize")
        }
    }

    private func loadSymbol<T>(_ name: String) -> T? {
        guard let handle = handle else { return nil }
        guard let sym = dlsym(handle, name) else {
            ndiLog("NDI: Failed to load symbol \(name)")
            return nil
        }
        return unsafeBitCast(sym, to: T.self)
    }

    func createSender(name: String) -> UnsafeMutableRawPointer? {
        guard isLoaded, let create_fn = _send_create else { return nil }

        // Create settings struct in memory
        // NDI send_create_t layout: const char* p_ndi_name, const char* p_groups, bool clock_video, bool clock_audio
        let nameBytes = name.utf8CString
        return nameBytes.withUnsafeBufferPointer { namePtr in
            // Allocate and set up the struct
            let structSize = MemoryLayout<UnsafePointer<CChar>?>.size * 2 + 2 // 2 pointers + 2 bools
            let settingsPtr = UnsafeMutableRawPointer.allocate(byteCount: structSize, alignment: 8)
            defer { settingsPtr.deallocate() }

            // Set p_ndi_name
            settingsPtr.storeBytes(of: namePtr.baseAddress, as: UnsafePointer<CChar>?.self)
            // Set p_groups (nil)
            settingsPtr.storeBytes(of: nil as UnsafePointer<CChar>?, toByteOffset: 8, as: UnsafePointer<CChar>?.self)
            // Set clock_video = true
            settingsPtr.storeBytes(of: true, toByteOffset: 16, as: Bool.self)
            // Set clock_audio = true
            settingsPtr.storeBytes(of: true, toByteOffset: 17, as: Bool.self)

            return create_fn(settingsPtr)
        }
    }

    func destroySender(_ sender: UnsafeMutableRawPointer) {
        lock.lock()
        defer { lock.unlock() }
        _send_destroy?(sender)
    }

    func sendVideo(_ sender: UnsafeMutableRawPointer, width: Int, height: Int, data: UnsafeMutablePointer<UInt8>, stride: Int) {
        guard let send_fn = _send_send_video else { return }

        // Build video frame struct in memory
        // NDIlib_video_frame_v2_t layout (with proper alignment):
        // Offset 0:  int32 xres
        // Offset 4:  int32 yres
        // Offset 8:  uint32 FourCC
        // Offset 12: int32 frame_rate_N
        // Offset 16: int32 frame_rate_D
        // Offset 20: float picture_aspect_ratio
        // Offset 24: int32 frame_format_type
        // Offset 28: (4 bytes padding for 8-byte alignment)
        // Offset 32: int64 timecode
        // Offset 40: uint8* p_data
        // Offset 48: int32 line_stride_in_bytes
        // Offset 52: (4 bytes padding for 8-byte alignment)
        // Offset 56: const char* p_metadata
        // Offset 64: int64 timestamp
        // Total: 72 bytes

        let frameSize = 72
        let framePtr = UnsafeMutableRawPointer.allocate(byteCount: frameSize, alignment: 8)
        defer { framePtr.deallocate() }

        // Zero the entire struct first
        memset(framePtr, 0, frameSize)

        // xres (int32) at offset 0
        framePtr.storeBytes(of: Int32(width), toByteOffset: 0, as: Int32.self)
        // yres (int32) at offset 4
        framePtr.storeBytes(of: Int32(height), toByteOffset: 4, as: Int32.self)
        // FourCC - BGRA = 'BGRA' at offset 8
        framePtr.storeBytes(of: UInt32(0x41524742), toByteOffset: 8, as: UInt32.self)
        // frame_rate_N (int32) at offset 12
        framePtr.storeBytes(of: Int32(60000), toByteOffset: 12, as: Int32.self)
        // frame_rate_D (int32) at offset 16
        framePtr.storeBytes(of: Int32(1000), toByteOffset: 16, as: Int32.self)
        // picture_aspect_ratio (float) at offset 20
        framePtr.storeBytes(of: Float(0), toByteOffset: 20, as: Float.self)
        // frame_format_type (int32) - progressive = 1, at offset 24
        framePtr.storeBytes(of: Int32(1), toByteOffset: 24, as: Int32.self)
        // (padding at offset 28)
        // timecode (int64) - synthesize = INT64_MAX, at offset 32
        framePtr.storeBytes(of: Int64.max, toByteOffset: 32, as: Int64.self)
        // p_data (pointer) at offset 40
        framePtr.storeBytes(of: data, toByteOffset: 40, as: UnsafeMutablePointer<UInt8>.self)
        // line_stride_in_bytes (int32) at offset 48
        framePtr.storeBytes(of: Int32(stride), toByteOffset: 48, as: Int32.self)
        // (padding at offset 52)
        // p_metadata (pointer) - nil, at offset 56
        framePtr.storeBytes(of: nil as UnsafePointer<CChar>?, toByteOffset: 56, as: UnsafePointer<CChar>?.self)
        // timestamp (int64) at offset 64
        framePtr.storeBytes(of: Int64(0), toByteOffset: 64, as: Int64.self)

        send_fn(sender, framePtr)
    }

    func getConnectionCount(_ sender: UnsafeMutableRawPointer) -> Int32 {
        return _send_get_no_connections?(sender, 0) ?? 0
    }

    // MARK: - NDI Find (Source Discovery)

    func createFinder() -> UnsafeMutableRawPointer? {
        guard isLoaded, let create_fn = _find_create else { return nil }
        // Create with default settings (nil = show all sources)
        return create_fn(nil)
    }

    func destroyFinder(_ finder: UnsafeMutableRawPointer) {
        _find_destroy?(finder)
    }

    func getSources(finder: UnsafeMutableRawPointer) -> [(name: String, url: String)] {
        guard let get_fn = _find_get_sources else { return [] }

        var numSources: UInt32 = 0
        guard let sourcesRawPtr = get_fn(finder, &numSources, 0) else { return [] }

        // Bind raw pointer to NDISourceStruct array
        let sourcesPtr = sourcesRawPtr.assumingMemoryBound(to: NDISourceStruct.self)

        var sources: [(name: String, url: String)] = []
        for i in 0..<Int(numSources) {
            let source = sourcesPtr.advanced(by: i).pointee
            if let namePtr = source.p_ndi_name {
                let name = String(cString: namePtr)
                let url = source.p_url_address.map { String(cString: $0) } ?? ""
                sources.append((name: name, url: url))
            }
        }
        return sources
    }

    // MARK: - NDI Receive

    func createReceiver(source: NDISourceStruct) -> UnsafeMutableRawPointer? {
        guard isLoaded, let create_fn = _recv_create else { return nil }

        // Create receiver settings struct
        // NDIlib_recv_create_v3_t: source_to_connect_to, color_format, bandwidth, allow_video_fields, p_ndi_recv_name
        let structSize = 64
        let settingsPtr = UnsafeMutableRawPointer.allocate(byteCount: structSize, alignment: 8)

        // Store source struct at offset 0 (16 bytes for 2 pointers)
        settingsPtr.storeBytes(of: source.p_ndi_name, as: UnsafePointer<CChar>?.self)
        settingsPtr.storeBytes(of: source.p_url_address, toByteOffset: 8, as: UnsafePointer<CChar>?.self)

        // color_format = BGRX_BGRA (0) forces NDI to convert to BGRA format
        // Format 100 (UYVY_BGRA) may return UYVY which has 2 bytes/pixel and causes doubled width
        settingsPtr.storeBytes(of: Int32(0), toByteOffset: 16, as: Int32.self)
        // bandwidth = highest (100) at offset 20
        settingsPtr.storeBytes(of: Int32(100), toByteOffset: 20, as: Int32.self)
        // allow_video_fields = false at offset 24
        settingsPtr.storeBytes(of: false, toByteOffset: 24, as: Bool.self)
        // p_ndi_recv_name = nil at offset 32
        settingsPtr.storeBytes(of: nil as UnsafePointer<CChar>?, toByteOffset: 32, as: UnsafePointer<CChar>?.self)

        let receiver = create_fn(settingsPtr)
        settingsPtr.deallocate()

        return receiver
    }

    func destroyReceiver(_ receiver: UnsafeMutableRawPointer) {
        lock.lock()
        defer { lock.unlock() }
        _recv_destroy?(receiver)
    }

    func connectReceiver(_ receiver: UnsafeMutableRawPointer, to source: NDISourceStruct) {
        guard let connect_fn = _recv_connect else { return }

        // Build source struct
        let sourcePtr = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
        sourcePtr.storeBytes(of: source.p_ndi_name, as: UnsafePointer<CChar>?.self)
        sourcePtr.storeBytes(of: source.p_url_address, toByteOffset: 8, as: UnsafePointer<CChar>?.self)

        connect_fn(receiver, sourcePtr)
        sourcePtr.deallocate()
    }

    /// Capture a video frame. Returns frame info if available.
    /// Caller must call freeVideoFrame when done with the frame.
    func captureVideoFrame(_ receiver: UnsafeMutableRawPointer, timeout: UInt32 = 0) -> NDIVideoFrameV2? {
        guard let capture_fn = _recv_capture else { return nil }

        var frame = NDIVideoFrameV2()
        let result = withUnsafeMutableBytes(of: &frame) { framePtr in
            capture_fn(receiver, framePtr.baseAddress, nil, nil, timeout)
        }

        // result: 0 = nothing, 1 = video, 2 = audio, 3 = metadata
        if result == 1 && frame.p_data != nil {
            return frame
        }
        return nil
    }

    func freeVideoFrame(_ receiver: UnsafeMutableRawPointer, frame: inout NDIVideoFrameV2) {
        guard let free_fn = _recv_free_video else { return }
        withUnsafeMutableBytes(of: &frame) { framePtr in
            free_fn(receiver, framePtr.baseAddress)
        }
    }

    deinit {
        _destroy?()
        if let handle = handle {
            dlclose(handle)
        }
    }
}

/// NDI Sender wrapper
final class NDISender {
    private var sender: UnsafeMutableRawPointer?
    private var frameBuffer: UnsafeMutablePointer<UInt8>?
    private var bufferSize: Int = 0
    let name: String
    let width: Int
    let height: Int

    var isActive: Bool { sender != nil }
    var connectionCount: Int32 {
        guard let sender = sender else { return 0 }
        return NDILibrary.shared.getConnectionCount(sender)
    }

    init(name: String, width: Int, height: Int) {
        self.name = name
        self.width = width
        self.height = height

        guard NDILibrary.shared.isLoaded else {
            ndiLog("NDI: Library not loaded, sender disabled")
            return
        }

        // Allocate frame buffer (BGRA = 4 bytes per pixel)
        bufferSize = width * height * 4
        frameBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)

        // Create sender
        sender = NDILibrary.shared.createSender(name: name)

        if sender != nil {
            ndiLog("NDI: Created sender '\(name)' (\(width)x\(height))")
        } else {
            ndiLog("NDI: Failed to create sender")
        }
    }

    func sendFrame(bitmap: NSBitmapImageRep) {
        guard let sender = sender, let frameBuffer = frameBuffer else { return }
        guard let data = bitmap.bitmapData else { return }

        let stride = bitmap.bytesPerRow

        // Copy with vertical flip (NDI expects top-to-bottom, NSBitmapImageRep is bottom-to-top)
        for y in 0..<height {
            let srcRow = data.advanced(by: (height - 1 - y) * stride)
            let dstRow = frameBuffer.advanced(by: y * width * 4)
            memcpy(dstRow, srcRow, min(width * 4, stride))
        }

        NDILibrary.shared.sendVideo(sender, width: width, height: height, data: frameBuffer, stride: width * 4)
    }

    /// Send raw pixel data (BGRA format, top-to-bottom order)
    func send(width: Int, height: Int, data: UnsafeMutablePointer<UInt8>) {
        guard let sender = sender else { return }
        NDILibrary.shared.sendVideo(sender, width: width, height: height, data: data, stride: width * 4)
    }

    deinit {
        if let sender = sender {
            NDILibrary.shared.destroySender(sender)
        }
        frameBuffer?.deallocate()
    }
}

/// NDI Receiver wrapper - receives video from an NDI source
final class NDIReceiver {
    private var receiver: UnsafeMutableRawPointer?
    private var sourceName: String = ""
    private var lastFrame: NDIVideoFrameV2?
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var hasFrame: Bool = false

    var isConnected: Bool { receiver != nil }

    init() {}

    func connect(to source: NDISourceStruct) {
        disconnect()

        if let namePtr = source.p_ndi_name {
            sourceName = String(cString: namePtr)
        }

        receiver = NDILibrary.shared.createReceiver(source: source)
        if receiver != nil {
            ndiLog("NDI Receiver: Connected to '\(sourceName)'")
        } else {
            ndiLog("NDI Receiver: Failed to connect to '\(sourceName)'")
        }
    }

    func disconnect() {
        if let receiver = receiver {
            if var frame = lastFrame {
                NDILibrary.shared.freeVideoFrame(receiver, frame: &frame)
            }
            NDILibrary.shared.destroyReceiver(receiver)
        }
        receiver = nil
        lastFrame = nil
        hasFrame = false
    }

    /// Capture a frame. Returns pixel data pointer and stride if available.
    func captureFrame() -> (data: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int)? {
        guard let receiver = receiver else { return nil }

        // Free previous frame
        if var frame = lastFrame {
            NDILibrary.shared.freeVideoFrame(receiver, frame: &frame)
            lastFrame = nil
        }

        // Try to capture new frame
        if var frame = NDILibrary.shared.captureVideoFrame(receiver, timeout: 0) {
            if let data = frame.p_data {
                width = Int(frame.xres)
                height = Int(frame.yres)
                hasFrame = true
                lastFrame = frame
                return (data: data, width: width, height: height, stride: Int(frame.line_stride_in_bytes))
            }
        }

        return nil
    }

    deinit {
        disconnect()
    }
}

/// NDI Source Manager - discovers sources and manages receivers by name
@MainActor
final class NDISourceManager {
    static let shared = NDISourceManager()

    private var finder: UnsafeMutableRawPointer?
    private(set) var availableSources: [(name: String, url: String)] = []
    private var receivers: [String: NDIReceiver] = [:]  // Source name -> receiver
    private var device: MTLDevice?
    private var lastTextures: [String: MTLTexture] = [:]

    private init() {
        startDiscovery()
    }

    func setDevice(_ device: MTLDevice) {
        self.device = device
    }

    func startDiscovery() {
        guard NDILibrary.shared.isLoaded else { return }

        if finder == nil {
            finder = NDILibrary.shared.createFinder()
            if finder != nil {
                ndiLog("NDI: Source discovery started")
            }
        }
    }

    func refreshSources() {
        guard let finder = finder else { return }
        availableSources = NDILibrary.shared.getSources(finder: finder)
        ndiLog("NDI: Found \(availableSources.count) sources: \(availableSources.map { $0.name })")
    }

    /// Get list of available NDI source names
    func getAvailableSourceNames() -> [String] {
        refreshSources()
        return availableSources.map { $0.name }
    }

    /// Connect to an NDI source by name
    func connectToSource(named sourceName: String) -> Bool {
        // Already connected?
        if receivers[sourceName] != nil {
            return true
        }

        // Find the source in available sources
        refreshSources()
        guard let source = availableSources.first(where: { $0.name == sourceName }) else {
            ndiLog("NDI: Source '\(sourceName)' not found")
            return false
        }

        // Create receiver
        let receiver = NDIReceiver()
        var sourceStruct = NDISourceStruct()

        // Create persistent C strings
        source.name.withCString { namePtr in
            source.url.withCString { urlPtr in
                sourceStruct.p_ndi_name = UnsafePointer(strdup(namePtr))
                sourceStruct.p_url_address = UnsafePointer(strdup(urlPtr))
            }
        }

        receiver.connect(to: sourceStruct)
        receivers[sourceName] = receiver

        // Free the strdup'd strings
        if let namePtr = sourceStruct.p_ndi_name {
            free(UnsafeMutablePointer(mutating: namePtr))
        }
        if let urlPtr = sourceStruct.p_url_address {
            free(UnsafeMutablePointer(mutating: urlPtr))
        }

        ndiLog("NDI: Connected to '\(sourceName)'")
        return true
    }

    /// Get texture for an NDI source by name
    func getTexture(forSourceName sourceName: String) -> MTLTexture? {
        guard let device = device else { return nil }

        // Connect if not already connected
        if receivers[sourceName] == nil {
            if !connectToSource(named: sourceName) {
                return lastTextures[sourceName]
            }
        }

        guard let receiver = receivers[sourceName] else {
            return lastTextures[sourceName]
        }

        // Capture frame
        guard let frame = receiver.captureFrame() else {
            return lastTextures[sourceName]
        }

        // Validate frame dimensions
        guard frame.width > 0 && frame.height > 0 else {
            ndiLog("NDI: Invalid frame dimensions \(frame.width)x\(frame.height)")
            return lastTextures[sourceName]
        }

        // Calculate expected stride (BGRA = 4 bytes per pixel)
        let expectedStride = frame.width * 4
        let actualStride = max(frame.stride, expectedStride)

        // Create texture from frame data
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            ndiLog("NDI: Failed to create texture")
            return lastTextures[sourceName]
        }

        // Copy frame data to texture
        texture.replace(
            region: MTLRegionMake2D(0, 0, frame.width, frame.height),
            mipmapLevel: 0,
            withBytes: frame.data,
            bytesPerRow: actualStride
        )

        lastTextures[sourceName] = texture
        return texture
    }

    /// Disconnect from an NDI source
    func disconnectSource(named sourceName: String) {
        receivers[sourceName]?.disconnect()
        receivers.removeValue(forKey: sourceName)
        ndiLog("NDI: Disconnected from '\(sourceName)'")
    }

    /// Cleanup all receivers and finder
    func cleanup() {
        for (_, receiver) in receivers {
            receiver.disconnect()
        }
        receivers.removeAll()
        lastTextures.removeAll()
        if let finder = finder {
            NDILibrary.shared.destroyFinder(finder)
            self.finder = nil
        }
    }
}

// MARK: - Metal Rendering Engine

/// Metal shader source code (embedded for single-file deployment)
private let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

// Vertex input/output structures
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float2 localPos;
};

// Per-object uniforms (16-byte aligned for float4)
struct ObjectUniforms {
    float2 position;      // World position (pixels) - offset 0
    float2 scale;         // Width/height scale - offset 8
    float rotation;       // Rotation in radians - offset 16
    float padding1;       // Alignment padding - offset 20
    float2 padding2;      // Alignment padding - offset 24
    float4 color;         // RGBA with intensity applied - offset 32 (16-byte aligned)
    float opacity;        // offset 48
    float softness;       // Blur radius - offset 52
    int shapeType;        // 0-11 for shapes - offset 56
    int goboIndex;        // Gobo texture index (0 = none) - offset 60
    float baseRadius;     // Base shape radius - offset 64
    float iris;           // Iris aperture: 1.0 = open, 0.0 = closed - offset 68
    float2 shutterTop;    // (insertion, angle) - offset 72
    float2 shutterBottom; // (insertion, angle) - offset 80
    float2 shutterLeft;   // (insertion, angle) - offset 88
    float2 shutterRight;  // (insertion, angle) - offset 96
    float shutterRotation;// Assembly rotation - offset 104
    float shutterEdgeWidth;// Soft edge width (2.0 = soft, 0.1 = hard) - offset 108
    int prismaticPattern; // 0=off, 1-7=pattern types - offset 112
    int prismaticColorCount; // Number of colors in palette - offset 116
    float prismaticPhase; // Animation phase - offset 120
    float prismaticPadding; // Padding - offset 124
    float4 paletteColor0; // offset 128
    float4 paletteColor1; // offset 144
    float4 paletteColor2; // offset 160
    float4 paletteColor3; // offset 176
    float4 paletteColor4; // offset 192
    float4 paletteColor5; // offset 208
    float4 paletteColor6; // offset 224
    float4 paletteColor7; // offset 240
    int animationType;    // offset 256: 0=none, 1-10=animation types
    float animationPhase; // offset 260: current animation phase
    float animationSpeed; // offset 264: rotation speed from CH36
    int animPrismaticFill;// offset 268: 1=fill dark areas with prismatic colors
};

// Canvas uniforms
struct CanvasUniforms {
    float2 canvasSize;
    float time;
};

// SDF helper functions
float sdCircle(float2 p, float r) {
    return length(p) - r;
}

float sdLine(float2 p, float2 a, float2 b, float w) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - w;
}

// Regular polygon SDF (n sides) with rotation offset
float sdPolygon(float2 p, int n, float r, float angleOffset) {
    float PI = 3.14159265;
    float angle = atan2(p.y, p.x) + angleOffset;
    float radius = length(p);

    // Angle of one segment
    float segmentAngle = 2.0 * PI / float(n);

    // Find the angle to the nearest edge
    float a = fmod(angle + PI, segmentAngle) - segmentAngle * 0.5;

    // Distance to edge
    return radius * cos(a) - r * cos(segmentAngle * 0.5);
}

// Star polygon SDF (n points) - straight edges
float sdStar(float2 p, int n, float r, float innerRatio) {
    float PI = 3.14159265;
    float angle = atan2(p.y, p.x);
    float radius = length(p);

    // Full segment = outer point to inner valley to next outer point
    float segmentAngle = PI / float(n);

    // Wrap angle to one segment (half of full star segment)
    float a = fmod(abs(angle) + segmentAngle, segmentAngle * 2.0);
    if (a > segmentAngle) a = segmentAngle * 2.0 - a;

    // Outer and inner radii
    float outerR = r;
    float innerR = r * innerRatio;

    // Calculate the two vertices of this edge
    float2 outer = float2(cos(0.0), sin(0.0)) * outerR;
    float2 inner = float2(cos(segmentAngle), sin(segmentAngle)) * innerR;

    // Point in local rotated space
    float2 q = float2(cos(a), sin(a)) * radius;

    // Distance to line segment from outer to inner
    float2 edge = inner - outer;
    float t = clamp(dot(q - outer, edge) / dot(edge, edge), 0.0, 1.0);
    float2 closest = outer + edge * t;

    // Signed distance (negative inside, positive outside)
    float dist = length(q - closest);
    float cross = edge.x * (q.y - outer.y) - edge.y * (q.x - outer.x);
    return cross > 0.0 ? -dist : dist;  // Flip sign for correct fill
}

// Iris mask - radial aperture that closes from edges toward center
float applyIris(float2 localPos, float irisOpen, float baseRadius, float edgeWidth) {
    if (irisOpen >= 1.0) return 1.0;  // Fully open, no masking
    if (irisOpen <= 0.0) return 0.0;  // Fully closed

    float dist = length(localPos);
    float irisRadius = baseRadius * irisOpen;
    // Soft edge using smoothstep
    return smoothstep(irisRadius + edgeWidth, irisRadius - edgeWidth, dist);
}

// Single shutter blade mask
float applyShutterBlade(float2 localPos, float insertion, float angle, float2 bladeDir, float baseRadius, float edgeWidth) {
    if (insertion <= 0.0) return 1.0;  // Blade fully retracted

    // Apply blade angle rotation to the local position
    // This effectively tilts the blade edge
    float c = cos(angle);
    float s = sin(angle);
    float2 rotatedPos = float2(c * localPos.x - s * localPos.y,
                               s * localPos.x + c * localPos.y);

    // Project rotated position onto blade direction
    float bladePos = dot(rotatedPos, bladeDir);

    // Calculate threshold based on insertion
    // insertion=0 -> threshold=baseRadius (nothing masked)
    // insertion=0.5 -> threshold=0 (50% masked)
    // insertion=1 -> threshold=-baseRadius (fully masked)
    float threshold = baseRadius * (1.0 - 2.0 * insertion);

    // Soft edge mask using smoothstep (like iris)
    // bladePos > threshold means we're past the blade edge (masked area)
    // smoothstep creates a soft transition around the threshold
    return smoothstep(threshold + edgeWidth, threshold - edgeWidth, bladePos);
}

// All 4 framing shutters with assembly rotation
float applyFramingShutters(float2 localPos, constant ObjectUniforms &obj) {
    float mask = 1.0;

    // Apply assembly rotation to localPos (rotates all blades together)
    float c = cos(obj.shutterRotation);
    float s = sin(obj.shutterRotation);
    float2 rotatedPos = float2(c * localPos.x - s * localPos.y,
                               s * localPos.x + c * localPos.y);

    // Direction vectors point INTO the shape from each edge
    // (0,1) = TOP: masks positive Y (top portion)
    // (0,-1) = BOTTOM: masks negative Y (bottom portion)
    // (-1,0) = LEFT: masks negative X (left portion)
    // (1,0) = RIGHT: masks positive X (right portion)
    mask *= applyShutterBlade(rotatedPos, obj.shutterTop.x, obj.shutterTop.y, float2(0.0, 1.0), obj.baseRadius, obj.shutterEdgeWidth);
    mask *= applyShutterBlade(rotatedPos, obj.shutterBottom.x, obj.shutterBottom.y, float2(0.0, -1.0), obj.baseRadius, obj.shutterEdgeWidth);
    mask *= applyShutterBlade(rotatedPos, obj.shutterLeft.x, obj.shutterLeft.y, float2(-1.0, 0.0), obj.baseRadius, obj.shutterEdgeWidth);
    mask *= applyShutterBlade(rotatedPos, obj.shutterRight.x, obj.shutterRight.y, float2(1.0, 0.0), obj.baseRadius, obj.shutterEdgeWidth);

    return mask;
}

// Combined iris and shutter mask
float applyMasks(float2 localPos, constant ObjectUniforms &obj) {
    float mask = 1.0;
    mask *= applyIris(localPos, obj.iris, obj.baseRadius, obj.shutterEdgeWidth);
    mask *= applyFramingShutters(localPos, obj);
    return mask;
}

// =============================================
// PRISMATIC EFFECTS - Multi-color patterns
// =============================================

// Get palette color by index (0-7)
float4 getPaletteColor(constant ObjectUniforms &obj, int index) {
    switch (index) {
        case 0: return obj.paletteColor0;
        case 1: return obj.paletteColor1;
        case 2: return obj.paletteColor2;
        case 3: return obj.paletteColor3;
        case 4: return obj.paletteColor4;
        case 5: return obj.paletteColor5;
        case 6: return obj.paletteColor6;
        case 7: return obj.paletteColor7;
        default: return obj.paletteColor0;
    }
}

// Interpolate between palette colors at position t (0-1)
float4 samplePalette(constant ObjectUniforms &obj, float t) {
    if (obj.prismaticColorCount <= 1) {
        return getPaletteColor(obj, 0);
    }

    // Wrap t to 0-1 range
    t = fract(t);

    // Scale to color count
    float scaledT = t * float(obj.prismaticColorCount);
    int index0 = int(scaledT) % obj.prismaticColorCount;
    int index1 = (index0 + 1) % obj.prismaticColorCount;
    float blend = fract(scaledT);

    return mix(getPaletteColor(obj, index0), getPaletteColor(obj, index1), blend);
}

// Pattern 1: Radial - colors radiate from center outward
float4 prismaticRadial(float2 pos, constant ObjectUniforms &obj) {
    float dist = length(pos / obj.baseRadius);
    float t = dist + obj.prismaticPhase;
    return samplePalette(obj, t);
}

// Pattern 2: Linear - horizontal gradient
float4 prismaticLinear(float2 pos, constant ObjectUniforms &obj) {
    float t = (pos.x / obj.baseRadius + 1.0) * 0.5 + obj.prismaticPhase;
    return samplePalette(obj, t);
}

// Pattern 3: Spiral - rotating spiral pattern
float4 prismaticSpiral(float2 pos, constant ObjectUniforms &obj) {
    float angle = atan2(pos.y, pos.x);
    float dist = length(pos / obj.baseRadius);
    float t = (angle / 6.28318) + dist * 2.0 + obj.prismaticPhase;
    return samplePalette(obj, t);
}

// Pattern 4: Segments - pie slice segments
float4 prismaticSegments(float2 pos, constant ObjectUniforms &obj) {
    float angle = atan2(pos.y, pos.x);
    float t = (angle / 6.28318) + 0.5 + obj.prismaticPhase;
    // Quantize to segments
    int segments = max(obj.prismaticColorCount, 2);
    t = floor(t * float(segments)) / float(segments);
    return samplePalette(obj, t);
}

// Pattern 5: Voronoi/Dichroic - shattered glass chip effect
float4 prismaticVoronoi(float2 pos, constant ObjectUniforms &obj) {
    // Create a pseudo-random cell pattern
    float2 uv = pos / obj.baseRadius * 3.0;
    float2 cell = floor(uv);
    float2 local = fract(uv);

    float minDist = 10.0;
    float2 closestCell = cell;

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 neighbor = cell + float2(x, y);
            // Pseudo-random point in cell
            float2 point = fract(sin(neighbor * float2(127.1, 311.7) + obj.prismaticPhase * 0.1) * 43758.5453);
            float2 diff = neighbor + point - uv;
            float dist = length(diff);
            if (dist < minDist) {
                minDist = dist;
                closestCell = neighbor;
            }
        }
    }

    // Use cell position to pick color
    float t = fract(sin(dot(closestCell, float2(12.9898, 78.233))) * 43758.5453);
    return samplePalette(obj, t);
}

// Pattern 6: Wave - animated sine wave
float4 prismaticWave(float2 pos, constant ObjectUniforms &obj) {
    float wave = sin(pos.x / obj.baseRadius * 6.28318 * 2.0 + obj.prismaticPhase * 6.0);
    float t = (wave + 1.0) * 0.5;
    return samplePalette(obj, t);
}

// Pattern 7: Kaleidoscope - mirrored radial segments
float4 prismaticKaleidoscope(float2 pos, constant ObjectUniforms &obj) {
    float angle = atan2(pos.y, pos.x) + obj.prismaticPhase;
    int numFolds = max(obj.prismaticColorCount, 3);
    float segmentAngle = 6.28318 / float(numFolds);

    // Fold angle into segment
    angle = abs(fmod(angle, segmentAngle * 2.0) - segmentAngle);
    float dist = length(pos / obj.baseRadius);

    float t = angle / segmentAngle + dist;
    return samplePalette(obj, t);
}

// =============================================
// MARK: - Animation Wheel Functions
// =============================================

// Simple noise function for procedural effects
float animNoise(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

// Smooth noise with interpolation
float animSmoothNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);  // Smoothstep

    float a = animNoise(i);
    float b = animNoise(i + float2(1.0, 0.0));
    float c = animNoise(i + float2(0.0, 1.0));
    float d = animNoise(i + float2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Fractal brownian motion for organic patterns
float animFBM(float2 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;

    for (int i = 0; i < octaves; i++) {
        value += amplitude * animSmoothNoise(p * frequency);
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

// ANIMATION WHEELS - Beam is a window looking at a portion of a rotating wheel
// The gobo sees ~1 quadrant of the wheel as it rotates past
// Wheel center is offset so we see a section, not the whole radial pattern

// Helper: Get position on wheel given UV (small window) and rotation
float2 wheelPosition(float2 uv, float phase, float speed) {
    // UV is -1 to 1, scale to represent small portion of wheel
    float2 windowPos = uv * 0.3;  // Window sees ~30% of wheel diameter
    // Offset window to edge of wheel (not centered)
    float2 wheelCenter = float2(0.6, 0.0);  // Window is offset from wheel center
    // Rotate the wheel (window stays still, wheel rotates behind it)
    float rot = phase * speed;
    float2 rotatedCenter = float2(
        wheelCenter.x * cos(rot) - wheelCenter.y * sin(rot),
        wheelCenter.x * sin(rot) + wheelCenter.y * cos(rot)
    );
    return windowPos + rotatedCenter;
}

// Animation 1: Fire - tangential breakup (flames pattern)
float animationFire(float2 uv, float phase, float speed) {
    float2 wp = wheelPosition(uv, phase, speed);
    float angle = atan2(wp.y, wp.x);
    float radius = length(wp);

    // Tangential flame pattern
    float flames = sin(angle * 16.0 + radius * 20.0) * 0.5 + 0.5;
    flames += sin(angle * 24.0 - radius * 12.0) * 0.3;
    flames += sin(angle * 8.0 + radius * 30.0) * 0.2;

    return clamp(flames, 0.0, 1.0);
}

// Animation 2: Water - ripple pattern
float animationWater(float2 uv, float phase, float speed) {
    float2 wp = wheelPosition(uv, phase, speed);
    float angle = atan2(wp.y, wp.x);
    float radius = length(wp);

    // Concentric ripples with angular variation
    float wave1 = sin(radius * 40.0 + angle * 4.0) * 0.5 + 0.5;
    float wave2 = sin(radius * 50.0 - angle * 6.0) * 0.3 + 0.5;
    float wave3 = sin(radius * 30.0 + angle * 3.0) * 0.25 + 0.5;

    float water = (wave1 + wave2 + wave3) / 3.0;
    return clamp(water, 0.0, 1.0);
}

// Animation 3: Clouds - soft breakup
float animationClouds(float2 uv, float phase, float speed) {
    float2 wp = wheelPosition(uv, phase, speed * 0.5);
    float angle = atan2(wp.y, wp.x);
    float radius = length(wp);

    // Soft cloud pattern
    float clouds = sin(angle * 12.0 + radius * 16.0) * 0.4 + 0.4;
    clouds += sin(angle * 18.0 - radius * 10.0) * 0.25;
    clouds += sin(angle * 6.0 + radius * 24.0) * 0.15;
    clouds += sin((angle + radius * 2.0) * 10.0) * 0.2;

    clouds = smoothstep(0.3, 0.7, clouds);
    return clouds;
}

// Animation 4: Radial Breakup - spoke pattern
float animationRadialBreakup(float2 uv, float phase, float speed) {
    float2 wp = wheelPosition(uv, phase, speed);
    float angle = atan2(wp.y, wp.x);
    float radius = length(wp);

    // Radial spokes
    float breakup = sin(angle * 24.0) * 0.4;
    breakup += sin(angle * 36.0 + radius * 15.0) * 0.3;
    breakup += sin(angle * 12.0 - radius * 20.0) * 0.3;

    breakup = breakup * 0.5 + 0.5;
    breakup = smoothstep(0.3, 0.55, breakup);
    return breakup;
}

// Animation 5: Elliptical Breakup - irregular pattern
float animationEllipticalBreakup(float2 uv, float phase, float speed) {
    float2 wp = wheelPosition(uv, phase, speed);
    // Stretch for elliptical feel
    wp.x *= 1.3;
    float angle = atan2(wp.y, wp.x);
    float radius = length(wp);

    // Irregular segments
    float pattern = sin(angle * 14.0 + radius * 18.0) * 0.5;
    pattern += sin(angle * 22.0 - radius * 12.0) * 0.3;
    pattern += sin(angle * 10.0 + radius * 25.0) * 0.2;

    pattern = pattern * 0.5 + 0.5;
    return smoothstep(0.25, 0.6, pattern);
}

// Animation 6: Bubbles - dot pattern
float animationBubbles(float2 uv, float phase, float speed) {
    float2 wp = wheelPosition(uv, -phase, speed);  // Reverse for rising feel
    float angle = atan2(wp.y, wp.x);
    float radius = length(wp);

    // Multiple dot layers
    float bubbles = 0.0;

    float dots1 = sin(angle * 16.0) * sin(radius * 25.0);
    bubbles += smoothstep(0.5, 0.9, dots1 * 0.5 + 0.5) * 0.5;

    float dots2 = sin(angle * 24.0 + 1.0) * sin(radius * 35.0 + 2.0);
    bubbles += smoothstep(0.55, 0.92, dots2 * 0.5 + 0.5) * 0.4;

    float dots3 = sin(angle * 32.0 + 2.0) * sin(radius * 45.0 + 4.0);
    bubbles += smoothstep(0.6, 0.95, dots3 * 0.5 + 0.5) * 0.3;

    return clamp(bubbles, 0.0, 1.0);
}

// Animation 7: Snow - scattered flakes
float animationSnow(float2 uv, float phase, float speed) {
    float2 wp = wheelPosition(uv, phase, speed * 0.7);
    float angle = atan2(wp.y, wp.x);
    float radius = length(wp);

    // Scattered flake pattern
    float snow = 0.0;

    float flakes1 = sin(angle * 10.0 + radius * 15.0) * sin(angle * 14.0 - radius * 10.0);
    snow += smoothstep(0.6, 0.9, flakes1 * 0.5 + 0.5) * 0.4;

    float flakes2 = sin(angle * 18.0 + radius * 22.0) * sin(angle * 22.0 - radius * 14.0);
    snow += smoothstep(0.65, 0.92, flakes2 * 0.5 + 0.5) * 0.35;

    float flakes3 = sin(angle * 28.0 + radius * 30.0) * sin(angle * 32.0 - radius * 18.0);
    snow += smoothstep(0.7, 0.95, flakes3 * 0.5 + 0.5) * 0.3;

    return clamp(snow, 0.0, 1.0);
}

// Animation 8: Lightning - jagged arcs
float animationLightning(float2 uv, float phase, float speed) {
    float2 wp = wheelPosition(uv, phase, speed);
    float angle = atan2(wp.y, wp.x);
    float radius = length(wp);

    // Jagged bolt pattern
    float lightning = 0.0;

    float jag = sin(angle * 40.0 + radius * 50.0) * 0.15;
    jag += sin(angle * 60.0 - radius * 35.0) * 0.1;
    float bolt = smoothstep(0.12, 0.0, abs(sin(angle * 8.0) * 0.3 - jag));
    lightning += bolt;

    float jag2 = sin(angle * 50.0 + radius * 45.0) * 0.12;
    float bolt2 = smoothstep(0.08, 0.0, abs(sin(angle * 12.0 + 1.0) * 0.25 - jag2));
    lightning += bolt2 * 0.6;

    return clamp(lightning, 0.0, 1.0);
}

// Animation 9: Plasma - organic flow
float animationPlasma(float2 uv, float phase, float speed) {
    float2 wp = wheelPosition(uv, phase, speed);
    float angle = atan2(wp.y, wp.x);
    float radius = length(wp);

    // Organic plasma
    float plasma = sin(angle * 6.0 + radius * 15.0);
    plasma += sin(angle * 10.0 - radius * 20.0);
    plasma += sin(angle * 14.0 + radius * 12.0);
    plasma += sin(radius * 30.0 - angle * 4.0);

    plasma = plasma * 0.25 + 0.5;
    return clamp(plasma, 0.0, 1.0);
}

// Animation 10: Spiral - vortex arms
float animationSpiral(float2 uv, float phase, float speed) {
    float2 wp = wheelPosition(uv, phase, speed);
    float angle = atan2(wp.y, wp.x);
    float radius = length(wp);

    // Spiral arms
    float spiral = sin(angle * 8.0 - radius * 35.0) * 0.5 + 0.5;
    spiral += sin(angle * 16.0 - radius * 20.0) * 0.2;

    return clamp(spiral, 0.0, 1.0);
}

// Apply animation wheel effect as brightness modulation (pass-through overlay, not mask)
float4 applyAnimationWheel(float2 localPos, constant ObjectUniforms &obj, float4 baseColor) {
    if (obj.animationType == 0) {
        return baseColor;  // No animation
    }

    // Normalize position to -1 to 1 range
    float2 uv = localPos / obj.baseRadius;

    float effect = 1.0;

    switch (obj.animationType) {
        case 1:  // Fire
            effect = animationFire(uv, obj.animationPhase, obj.animationSpeed);
            break;
        case 2:  // Water
            effect = animationWater(uv, obj.animationPhase, obj.animationSpeed);
            break;
        case 3:  // Clouds
            effect = animationClouds(uv, obj.animationPhase, obj.animationSpeed);
            break;
        case 4:  // Radial Breakup
            effect = animationRadialBreakup(uv, obj.animationPhase, obj.animationSpeed);
            break;
        case 5:  // Elliptical Breakup
            effect = animationEllipticalBreakup(uv, obj.animationPhase, obj.animationSpeed);
            break;
        case 6:  // Bubbles
            effect = animationBubbles(uv, obj.animationPhase, obj.animationSpeed);
            break;
        case 7:  // Snow
            effect = animationSnow(uv, obj.animationPhase, obj.animationSpeed);
            break;
        case 8:  // Lightning
            effect = animationLightning(uv, obj.animationPhase, obj.animationSpeed);
            break;
        case 9:  // Plasma
            effect = animationPlasma(uv, obj.animationPhase, obj.animationSpeed);
            break;
        case 10: // Spiral
            effect = animationSpiral(uv, obj.animationPhase, obj.animationSpeed);
            break;
        default:
            effect = 1.0;
    }

    // Animation effect: bright areas show gobo, dark areas show either black or prismatic
    // effect=1 means animation is "on" (show gobo), effect=0 means "off" (show fill)
    float4 result = baseColor;

    if (obj.animPrismaticFill == 1 && obj.prismaticColorCount > 0) {
        // Range 2: Prismatic fill mode
        // Bright areas (high effect) = gobo color ONLY
        // Dark areas (low effect) = prismatic color ONLY
        float4 prismaticColor = samplePalette(obj, length(uv) + obj.prismaticPhase);

        // Use smoothstep for a clean transition
        float mask = smoothstep(0.3, 0.7, effect);

        if (mask > 0.5) {
            // Bright area: gobo only, no prismatic
            result.rgb = baseColor.rgb;
        } else {
            // Dark area: prismatic only, no gobo
            result.rgb = prismaticColor.rgb;
        }
    } else {
        // Range 1: Standard mode
        // Bright areas = gobo color, Dark areas = black/dim
        float brightness = 0.1 + effect * 0.9;  // 10% in dark, 100% in bright
        result.rgb *= brightness;
    }

    return result;
}

// Main prismatic color function
float4 applyPrismatic(float2 localPos, constant ObjectUniforms &obj, float4 baseColor) {
    if (obj.prismaticPattern == 0 || obj.prismaticColorCount == 0) {
        return baseColor;
    }

    float4 prismaticColor;

    switch (obj.prismaticPattern) {
        case 1: prismaticColor = prismaticRadial(localPos, obj); break;
        case 2: prismaticColor = prismaticLinear(localPos, obj); break;
        case 3: prismaticColor = prismaticSpiral(localPos, obj); break;
        case 4: prismaticColor = prismaticSegments(localPos, obj); break;
        case 5: prismaticColor = prismaticVoronoi(localPos, obj); break;
        case 6: prismaticColor = prismaticWave(localPos, obj); break;
        case 7: prismaticColor = prismaticKaleidoscope(localPos, obj); break;
        default: return baseColor;
    }

    // Multiply prismatic color by base intensity
    float intensity = (baseColor.r + baseColor.g + baseColor.b) / 3.0;
    prismaticColor.rgb *= max(intensity, 0.3);
    prismaticColor.a = baseColor.a;

    return prismaticColor;
}

// Vertex shader - transforms quad to object space
vertex VertexOut vertexShader(
    VertexIn in [[stage_in]],
    constant ObjectUniforms &object [[buffer(1)]],
    constant CanvasUniforms &canvas [[buffer(2)]]
) {
    VertexOut out;

    // Apply scale
    float2 scaled = in.position * object.scale * object.baseRadius;

    // Apply rotation
    float c = cos(object.rotation);
    float s = sin(object.rotation);
    float2x2 rotMat = float2x2(c, -s, s, c);
    float2 rotated = rotMat * scaled;

    // Translate to world position
    float2 worldPos = rotated + object.position;

    // Convert to normalized device coordinates
    float2 ndc = (worldPos / canvas.canvasSize) * 2.0 - 1.0;
    ndc.y = -ndc.y;  // Flip Y for Metal coordinate system

    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.localPos = in.position * object.baseRadius;  // For SDF calculations

    return out;
}

// Fragment shader - SDF shape rendering
fragment float4 shapeFragment(
    VertexOut in [[stage_in]],
    constant ObjectUniforms &object [[buffer(1)]]
) {
    // Normalize local position to -1..1 range for SDF
    float2 p = in.localPos / object.baseRadius;
    float d;

    // Check if this is a bezel shape (types 11-20 are bezel versions of 1-10)
    // DMX 1-10 = solid shapes, DMX 11-20 = bezel/outline versions
    int baseShape = object.shapeType;
    bool isBezel = object.shapeType >= 11 && object.shapeType <= 20;
    if (isBezel) {
        baseShape = object.shapeType - 10;  // 11->1, 12->2, etc.
    }

    // Calculate SDF based on base shape type
    switch (baseShape) {
        case 0:  // Line
            d = sdLine(p * object.baseRadius, float2(-object.baseRadius * 0.8, 0), float2(object.baseRadius * 0.8, 0), 8.0) / object.baseRadius;
            break;
        case 1:  // Circle
            d = length(p) - 0.8;
            break;
        case 2:  // Triangle (flat edge at bottom)
            d = sdPolygon(p, 3, 0.8, 0.0);
            break;
        case 3:  // Triangle Star
            d = sdStar(p, 3, 0.8, 0.4);
            break;
        case 4:  // Square (flat edge at top/bottom) - rotate 45°
            d = sdPolygon(p, 4, 0.8, 0.785398);  // π/4
            break;
        case 5:  // Square Star
            d = sdStar(p, 4, 0.8, 0.4);
            break;
        case 6:  // Pentagon
            d = sdPolygon(p, 5, 0.8, 0.0);
            break;
        case 7:  // Pentagon Star
            d = sdStar(p, 5, 0.8, 0.4);
            break;
        case 8:  // Hexagon (flat edge at top/bottom) - rotate 30°
            d = sdPolygon(p, 6, 0.8, 0.523599);  // π/6
            break;
        case 9:  // Hexagon Star
            d = sdStar(p, 6, 0.8, 0.4);
            break;
        case 10: // Septagon
            d = sdPolygon(p, 7, 0.8, 0.0);
            break;
        case 11: // Septagon Star
            d = sdStar(p, 7, 0.8, 0.4);
            break;
        default:
            d = length(p) - 0.8;
            break;
    }

    // Softness controls the edge blur width (limited for fine control)
    float softWidth = object.softness * 0.005;
    float baseEdge = fwidth(d) * 1.5;
    float blurWidth = baseEdge + softWidth;

    float alpha;
    if (isBezel) {
        // Bezel/outline mode: only draw a 5% width ring at the edge
        float bezelWidth = 0.04;  // 5% of 0.8 radius
        float outerAlpha = 1.0 - smoothstep(-blurWidth, blurWidth, d);
        float innerAlpha = 1.0 - smoothstep(-bezelWidth - blurWidth, -bezelWidth + blurWidth, d);
        alpha = outerAlpha - innerAlpha;
    } else {
        // Solid shape mode
        alpha = 1.0 - smoothstep(-blurWidth, blurWidth, d);
    }

    // Apply iris and shutter masks
    float maskAlpha = applyMasks(in.localPos, object);

    // Start with base color
    float4 result = object.color;

    // Apply prismatic ONLY if no animation is active
    // When animation is active, applyAnimationWheel handles prismatic for Mode 2
    if (object.animationType == 0) {
        result = applyPrismatic(in.localPos, object, result);
    }

    // Apply animation wheel effect
    result = applyAnimationWheel(in.localPos, object, result);

    result.a = alpha * object.opacity * maskAlpha;

    return result;
}

// Fragment shader for gobo textures (supports both grayscale and color/glass gobos)
fragment float4 goboFragment(
    VertexOut in [[stage_in]],
    constant ObjectUniforms &object [[buffer(1)]],
    texture2d<float> goboTexture [[texture(0)]],
    sampler texSampler [[sampler(0)]]
) {
    // Sample gobo texture
    float2 uv = in.texCoord;
    float4 goboSample = goboTexture.sample(texSampler, uv);

    // Detect if gobo is color (glass) or grayscale (metal)
    // Glass gobos have varying RGB values; metal gobos are grayscale (R=G=B)
    float colorVariance = abs(goboSample.r - goboSample.g) + abs(goboSample.g - goboSample.b);
    bool isColorGobo = colorVariance > 0.05 || goboSample.a < 0.99;

    float4 result;

    if (isColorGobo) {
        // Color/Glass gobo: use texture colors directly
        // The gobo's RGB is the stained glass color, alpha is transparency
        float3 glassColor = goboSample.rgb;

        // Multiply glass color by fixture intensity (object.color acts as tint/intensity)
        float intensity = (object.color.r + object.color.g + object.color.b) / 3.0;
        float3 outputColor = glassColor * max(intensity, 0.5);  // Ensure visibility

        // Use gobo alpha for transparency
        float alpha = goboSample.a * object.opacity;

        result = float4(outputColor, alpha);
    } else {
        // Grayscale/Metal gobo: use as mask, apply fixture color
        float mask = goboSample.r;
        result = object.color * mask;
        result.a *= object.opacity;
    }

    // Apply softness
    if (object.softness > 0.0) {
        float2 offset = float2(object.softness / 256.0);
        float4 s1 = goboTexture.sample(texSampler, uv + float2(offset.x, 0));
        float4 s2 = goboTexture.sample(texSampler, uv - float2(offset.x, 0));
        float4 s3 = goboTexture.sample(texSampler, uv + float2(0, offset.y));
        float4 s4 = goboTexture.sample(texSampler, uv - float2(0, offset.y));

        if (isColorGobo) {
            // Blur the color gobo
            float4 avgSample = (s1 + s2 + s3 + s4 + goboSample) / 5.0;
            float intensity = (object.color.r + object.color.g + object.color.b) / 3.0;
            float3 outputColor = avgSample.rgb * max(intensity, 0.5);
            result = float4(outputColor, avgSample.a * object.opacity);
        } else {
            float avgMask = (s1.r + s2.r + s3.r + s4.r + goboSample.r) / 5.0;
            result = object.color * avgMask;
            result.a *= object.opacity;
        }
    }

    // Apply iris and shutter masks
    float maskAlpha = applyMasks(in.localPos, object);
    result.a *= maskAlpha;

    // Apply prismatic ONLY if no animation is active
    // When animation is active, applyAnimationWheel handles everything:
    // - Mode 1 (dark): dims dark areas, NO prismatic
    // - Mode 2 (prismatic fill): fills dark areas with prismatic
    if (object.animationType == 0) {
        result = applyPrismatic(in.localPos, object, result);
    }

    // Apply animation wheel effect
    result = applyAnimationWheel(in.localPos, object, result);

    return result;
}

// Fragment shader for video textures (full color with crossfade to mask)
fragment float4 videoFragment(
    VertexOut in [[stage_in]],
    constant ObjectUniforms &object [[buffer(1)]],
    texture2d<float> videoTexture [[texture(0)]],
    sampler texSampler [[sampler(0)]]
) {
    // Sample video texture - flip V to correct for coordinate system
    float2 uv = float2(in.texCoord.x, 1.0 - in.texCoord.y);
    float4 videoSample = videoTexture.sample(texSampler, uv);

    // Calculate grayscale (luminance)
    float gray = dot(videoSample.rgb, float3(0.299, 0.587, 0.114));

    // Mask blend factor from goboIndex (0 = full color, 255 = full mask)
    float maskBlend = float(object.goboIndex) / 255.0;

    // Full color mode: video tinted by DMX color
    float3 colorMode = videoSample.rgb * object.color.rgb;

    // Mask mode: grayscale used as alpha, tinted by DMX color
    float3 maskMode = object.color.rgb * gray;

    // Blend between modes
    float4 result;
    result.rgb = mix(colorMode, maskMode, maskBlend);
    result.a = mix(videoSample.a, gray, maskBlend) * object.opacity;

    // Apply intensity (dimmer)
    result.rgb *= object.color.a;

    // Apply iris and shutter masks
    float maskAlpha = applyMasks(in.localPos, object);
    result.a *= maskAlpha;

    return result;
}

// Clear screen fragment shader
fragment float4 clearFragment(VertexOut in [[stage_in]]) {
    return float4(0.0, 0.0, 0.0, 1.0);
}
"""

/// Uniform structures matching Metal shader layout (16-byte aligned for float4)
struct MetalObjectUniforms {
    var position: SIMD2<Float> = .zero      // offset 0
    var scale: SIMD2<Float> = .one          // offset 8
    var rotation: Float = 0                  // offset 16
    var padding1: Float = 0                  // offset 20
    var padding2: SIMD2<Float> = .zero       // offset 24
    var color: SIMD4<Float> = .one           // offset 32 (16-byte aligned)
    var opacity: Float = 1                   // offset 48
    var softness: Float = 0                  // offset 52
    var shapeType: Int32 = 1                 // offset 56
    var goboIndex: Int32 = 0                 // offset 60
    var baseRadius: Float = 120              // offset 64
    var iris: Float = 1.0                    // offset 68: 1.0 = open, 0.0 = closed
    var shutterTop: SIMD2<Float> = .zero     // offset 72: (insertion, angle)
    var shutterBottom: SIMD2<Float> = .zero  // offset 80: (insertion, angle)
    var shutterLeft: SIMD2<Float> = .zero    // offset 88: (insertion, angle)
    var shutterRight: SIMD2<Float> = .zero   // offset 96: (insertion, angle)
    var shutterRotation: Float = 0           // offset 104: assembly rotation
    var shutterEdgeWidth: Float = 2.0        // offset 108: soft edge width (2.0 = soft, 0.1 = hard)
    var prismaticPattern: Int32 = 0          // offset 112: 0=off, 1-7=pattern types
    var prismaticColorCount: Int32 = 0       // offset 116: number of colors in palette
    var prismaticPhase: Float = 0            // offset 120: animation phase
    var prismaticPadding: Float = 0          // offset 124: padding for alignment
    // Prismatic palette colors (up to 8 colors) - offset 128
    var paletteColor0: SIMD4<Float> = .zero  // offset 128
    var paletteColor1: SIMD4<Float> = .zero  // offset 144
    var paletteColor2: SIMD4<Float> = .zero  // offset 160
    var paletteColor3: SIMD4<Float> = .zero  // offset 176
    var paletteColor4: SIMD4<Float> = .zero  // offset 192
    var paletteColor5: SIMD4<Float> = .zero  // offset 208
    var paletteColor6: SIMD4<Float> = .zero  // offset 224
    var paletteColor7: SIMD4<Float> = .zero  // offset 240
    var animationType: Int32 = 0             // offset 256: 0=none, 1-10=animation types
    var animationPhase: Float = 0            // offset 260: current animation phase
    var animationSpeed: Float = 0            // offset 264: rotation speed from CH36
    var animPrismaticFill: Int32 = 0         // offset 268: 1=fill dark areas with prismatic colors
}

struct MetalCanvasUniforms {
    var canvasSize: SIMD2<Float> = .zero
    var time: Float = 0
    var padding: Float = 0
}

/// Metal Renderer - GPU-accelerated rendering engine
@MainActor
final class MetalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private(set) var shapePipelineState: MTLRenderPipelineState?
    private(set) var goboPipelineState: MTLRenderPipelineState?
    private(set) var videoPipelineState: MTLRenderPipelineState?
    private var clearPipelineState: MTLRenderPipelineState?

    private var quadVertexBuffer: MTLBuffer?
    private var quadIndexBuffer: MTLBuffer?
    private var objectUniformsBuffer: MTLBuffer?
    private var canvasUniformsBuffer: MTLBuffer?

    private var goboTextures: [Int: MTLTexture] = [:]
    private(set) var samplerState: MTLSamplerState?

    private var library: MTLLibrary?

    let canvasWidth: Int
    let canvasHeight: Int

    init?(width: Int, height: Int) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal: Failed to create device")
            return nil
        }

        guard let queue = device.makeCommandQueue() else {
            print("Metal: Failed to create command queue")
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.canvasWidth = width
        self.canvasHeight = height

        // Compile shaders
        do {
            library = try device.makeLibrary(source: metalShaderSource, options: nil)
        } catch {
            print("Metal: Failed to compile shaders: \(error)")
            return nil
        }

        // Create pipeline states
        if !createPipelineStates() {
            return nil
        }

        // Create buffers
        createBuffers()

        // Create sampler
        createSampler()

        // Initialize video slot manager with Metal device
        VideoSlotManager.shared.setup(device: device)

        print("Metal: Initialized successfully (\(width)x\(height))")
    }

    private func createPipelineStates() -> Bool {
        guard let library = library else { return false }

        let vertexFunc = library.makeFunction(name: "vertexShader")
        let shapeFragFunc = library.makeFunction(name: "shapeFragment")
        let goboFragFunc = library.makeFunction(name: "goboFragment")
        let videoFragFunc = library.makeFunction(name: "videoFragment")
        _ = library.makeFunction(name: "clearFragment")  // Reserved for future use

        guard let vertexFunc = vertexFunc else {
            print("Metal: Failed to load vertex shader")
            return false
        }

        // Vertex descriptor for quad
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride * 2

        // Shape pipeline
        let shapePipelineDescriptor = MTLRenderPipelineDescriptor()
        shapePipelineDescriptor.vertexFunction = vertexFunc
        shapePipelineDescriptor.fragmentFunction = shapeFragFunc
        shapePipelineDescriptor.vertexDescriptor = vertexDescriptor
        shapePipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        shapePipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        shapePipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        shapePipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        shapePipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        shapePipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        shapePipelineDescriptor.sampleCount = 1

        do {
            shapePipelineState = try device.makeRenderPipelineState(descriptor: shapePipelineDescriptor)
        } catch {
            print("Metal: Failed to create shape pipeline: \(error)")
            return false
        }

        // Gobo pipeline
        let goboPipelineDescriptor = MTLRenderPipelineDescriptor()
        goboPipelineDescriptor.vertexFunction = vertexFunc
        goboPipelineDescriptor.fragmentFunction = goboFragFunc
        goboPipelineDescriptor.vertexDescriptor = vertexDescriptor
        goboPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        goboPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        goboPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        goboPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        goboPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        goboPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        goboPipelineDescriptor.sampleCount = 1

        do {
            goboPipelineState = try device.makeRenderPipelineState(descriptor: goboPipelineDescriptor)
        } catch {
            print("Metal: Failed to create gobo pipeline: \(error)")
            return false
        }

        // Video pipeline (full color)
        let videoPipelineDescriptor = MTLRenderPipelineDescriptor()
        videoPipelineDescriptor.vertexFunction = vertexFunc
        videoPipelineDescriptor.fragmentFunction = videoFragFunc
        videoPipelineDescriptor.vertexDescriptor = vertexDescriptor
        videoPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        videoPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        videoPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        videoPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        videoPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        videoPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        videoPipelineDescriptor.sampleCount = 1

        do {
            videoPipelineState = try device.makeRenderPipelineState(descriptor: videoPipelineDescriptor)
        } catch {
            print("Metal: Failed to create video pipeline: \(error)")
            return false
        }

        print("Metal: Pipeline states created successfully")
        return true
    }

    private func createBuffers() {
        // Quad vertices (position + texCoord)
        let vertices: [Float] = [
            // Position    TexCoord
            -1,  1,        0, 0,  // Top-left
             1,  1,        1, 0,  // Top-right
            -1, -1,        0, 1,  // Bottom-left
             1, -1,        1, 1   // Bottom-right
        ]

        quadVertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )

        // Indices for two triangles
        let indices: [UInt16] = [0, 1, 2, 2, 1, 3]
        quadIndexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        )

        // Uniform buffers (allocate for max objects)
        let maxObjects = 512 / 20  // 25 objects max
        objectUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<MetalObjectUniforms>.stride * maxObjects,
            options: .storageModeShared
        )

        canvasUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<MetalCanvasUniforms>.stride,
            options: .storageModeShared
        )

        print("Metal: Buffers created")
    }

    private func createSampler() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped  // No mipmaps used
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: descriptor)
    }

    /// Load a gobo texture from CGImage
    func loadGoboTexture(id: Int, image: CGImage) {
        let width = image.width
        let height = image.height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false  // Disable mipmaps - they were causing fade to black on zoom
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            print("Metal: Failed to create texture for gobo \(id)")
            return
        }

        // Copy image data to texture
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var imageData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &imageData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Flip vertically to match Metal's coordinate system (origin at top-left)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: imageData,
            bytesPerRow: bytesPerRow
        )

        goboTextures[id] = texture
    }

    /// Get or create gobo texture
    func getGoboTexture(id: Int) -> MTLTexture? {
        if let texture = goboTextures[id] {
            return texture
        }

        // Try to load from GoboLibrary
        if let cgImage = GoboLibrary.shared.getOrGenerateImage(for: id) {
            loadGoboTexture(id: id, image: cgImage)
            return goboTextures[id]
        }

        return nil
    }

    /// Invalidate and reload a gobo texture (called when file changes)
    func reloadGoboTexture(id: Int) {
        goboTextures.removeValue(forKey: id)
        // Reload from disk
        if let cgImage = GoboLibrary.shared.reloadGobo(id: id) {
            loadGoboTexture(id: id, image: cgImage)
            print("MetalRenderer: Reloaded texture for gobo \(id)")
        }
    }

    /// Reload all gobo textures (called on manual refresh)
    func reloadGoboTextures() {
        let ids = Array(goboTextures.keys)
        goboTextures.removeAll()
        print("MetalRenderer: Clearing \(ids.count) cached gobo textures")

        // Pre-load commonly used gobos
        for id in 21...200 {
            if let cgImage = GoboLibrary.shared.image(for: id) {
                loadGoboTexture(id: id, image: cgImage)
            }
        }
        print("MetalRenderer: Reloaded gobo textures")
    }

    /// Create an offscreen render target texture (for NDI output)
    func createRenderTarget() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: canvasWidth,
            height: canvasHeight,
            mipmapped: false
        )
        descriptor.storageMode = .shared  // CPU-accessible for NDI
        descriptor.usage = [.renderTarget, .shaderRead]

        return device.makeTexture(descriptor: descriptor)
    }

    /// Create MSAA texture for anti-aliased rendering
    func createMSAATexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DMultisample
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = canvasWidth
        descriptor.height = canvasHeight
        descriptor.sampleCount = 4
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget]

        return device.makeTexture(descriptor: descriptor)
    }
}

/// Metal Render View - MTKView subclass for GPU-accelerated rendering
@MainActor
final class MetalRenderView: MTKView {
    private let controller: SceneController
    private let renderer: MetalRenderer
    private var lastTimestamp: CFTimeInterval = CACurrentMediaTime()

    // MSAA and render targets
    private var msaaTexture: MTLTexture?
    private var resolveTexture: MTLTexture?

    // Offscreen canvas texture for full-resolution Syphon/NDI output
    private var offscreenTexture: MTLTexture?
    private var blitPipelineState: MTLRenderPipelineState?

    // Test pattern text texture
    private var testPatternTextTexture: MTLTexture?
    private var lastTestPatternText: String = ""

    // Legacy flags kept for compatibility but don't control anything
    // All outputs now managed via OutputManager
    var syphonEnabled: Bool = false  // Syphon removed - use NDI instead
    var ndiEnabled: Bool = false

    // Live preview optimization - reusable buffers and busy flag
    private var previewBuffer: [UInt8]?
    private var previewFullBuffer: [UInt8]?
    private var previewBusy: Bool = false
    private let previewScale: Int = 4  // Capture at 1/4 resolution (480x270 for 1920x1080)

    // Web server helper properties
    var fixtureCount: Int {
        return controller.objects.count
    }

    var activeFixtureCount: Int {
        return controller.objects.filter { $0.opacity > 0 }.count
    }

    init?(frame: CGRect, controller: SceneController) {
        guard let renderer = MetalRenderer(width: Int(frame.width), height: Int(frame.height)) else {
            return nil
        }

        self.controller = controller
        self.renderer = renderer

        super.init(frame: frame, device: renderer.device)

        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.sampleCount = 1  // Shader AA via fwidth()
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 60

        // Create offscreen texture at full canvas resolution for Syphon/NDI
        createOffscreenTexture()

        // Subscribe to gobo file change notifications for live sync
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGoboFileChanged(_:)),
            name: .goboFileChanged,
            object: nil
        )

        // Start watching for gobo file changes and load initial gobos
        GoboFileWatcher.shared.startWatching()
        GoboLibrary.shared.refreshGobos()

        print("Metal: MetalRenderView initialized at \(Int(canvasSize.width))x\(Int(canvasSize.height)) with live gobo sync")

        // Initialize OutputManager for display and async NDI outputs
        OutputManager.shared.setup(device: renderer.device)

        // NDI outputs are now handled by OutputManager (restored from saved config)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleGoboFileChanged(_ notification: Notification) {
        guard let goboId = notification.userInfo?["goboId"] as? Int else { return }
        print("MetalRenderView: Reloading gobo \(goboId) from file change")
        renderer.reloadGoboTexture(id: goboId)
    }

    /// Reload all gobo textures (called from menu)
    func reloadAllGobos() {
        renderer.reloadGoboTextures()
    }

    /// Capture current render as NSImage for live preview
    func captureCurrentFrame() -> NSImage? {
        guard let texture = offscreenTexture else { return nil }

        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height

        var data = [UInt8](repeating: 0, count: dataSize)
        texture.getBytes(&data, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)

        // Create CGImage from pixel data (BGRA format)
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Optimized capture for live preview - uses reusable buffer and reduced resolution
    func capturePreviewFrame() -> NSImage? {
        // Skip if already busy capturing
        guard !previewBusy else { return nil }
        guard let texture = offscreenTexture else { return nil }

        previewBusy = true
        defer { previewBusy = false }

        // Capture at reduced resolution (1/4 scale)
        let width = texture.width / previewScale
        let height = texture.height / previewScale
        let bytesPerRow = width * 4
        let dataSize = bytesPerRow * height

        // Reuse buffer if correct size, otherwise allocate once
        if previewBuffer == nil || previewBuffer!.count != dataSize {
            previewBuffer = [UInt8](repeating: 0, count: dataSize)
        }

        // Read scaled region from texture
        // Note: Metal getBytes doesn't scale, so we read full texture and scale via CGImage
        // For efficiency, we create a scaled blit - but simplest approach is to read a smaller region
        // Since the texture is the canvas, we sample from top-left corner at reduced stride
        let fullBytesPerRow = texture.width * 4
        let fullDataSize = fullBytesPerRow * texture.height

        // Reuse full buffer if correct size, otherwise allocate once
        if previewFullBuffer == nil || previewFullBuffer!.count != fullDataSize {
            previewFullBuffer = [UInt8](repeating: 0, count: fullDataSize)
        }
        texture.getBytes(&previewFullBuffer!, bytesPerRow: fullBytesPerRow,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                         mipmapLevel: 0)

        // Downsample by picking every Nth pixel
        for y in 0..<height {
            for x in 0..<width {
                let srcX = x * previewScale
                let srcY = y * previewScale
                let srcIdx = srcY * fullBytesPerRow + srcX * 4
                let dstIdx = y * bytesPerRow + x * 4
                previewBuffer![dstIdx] = previewFullBuffer![srcIdx]
                previewBuffer![dstIdx + 1] = previewFullBuffer![srcIdx + 1]
                previewBuffer![dstIdx + 2] = previewFullBuffer![srcIdx + 2]
                previewBuffer![dstIdx + 3] = previewFullBuffer![srcIdx + 3]
            }
        }

        // Create CGImage from scaled pixel data
        guard let provider = CGDataProvider(data: Data(previewBuffer!) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    var isNDIActive: Bool { false }
    var ndiConnectionCount: Int32 { 0 }

    /// Create offscreen texture at full canvas resolution for Syphon/NDI output
    private func createOffscreenTexture() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            mipmapped: false
        )
        descriptor.storageMode = .shared  // CPU-accessible for NDI readback
        descriptor.usage = [.renderTarget, .shaderRead]

        offscreenTexture = renderer.device.makeTexture(descriptor: descriptor)
        print("Created offscreen texture: \(Int(canvasSize.width))x\(Int(canvasSize.height))")
    }

    /// Render scene to offscreen texture at full canvas resolution
    private func renderToOffscreen(commandBuffer: MTLCommandBuffer, time: CFTimeInterval) {
        guard let offscreen = offscreenTexture else { return }

        // Create render pass for offscreen texture
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = offscreen
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // Set canvas uniforms for full resolution
        var canvasUniforms = MetalCanvasUniforms(
            canvasSize: SIMD2<Float>(Float(canvasSize.width), Float(canvasSize.height)),
            time: Float(time),
            padding: 0
        )
        renderEncoder.setVertexBytes(&canvasUniforms, length: MemoryLayout<MetalCanvasUniforms>.stride, index: 2)

        // If test pattern is active, ONLY draw test pattern (no fixtures)
        if OutputSettingsWindowController.testPatternActive {
            drawTestPattern(encoder: renderEncoder)
        } else {
            // Render each object (fixtures)
            for obj in controller.objects {
                if obj.prismType != .off && obj.prismFacets > 0 {
                    renderPrismCopies(obj, encoder: renderEncoder)
                } else {
                    renderObject(obj, encoder: renderEncoder, positionOffset: .zero)
                }
            }
        }

        // Draw output borders when Show Borders is enabled
        if OutputSettingsWindowController.showBordersActive {
            drawOutputBorders(encoder: renderEncoder)
        }

        renderEncoder.endEncoding()
    }

    /// Draw colored output regions like the canvas preview
    private func drawOutputBorders(encoder: MTLRenderCommandEncoder) {
        let outputs = OutputManager.shared.getAllOutputs()
        let colors: [SIMD4<Float>] = [
            SIMD4<Float>(0, 0.6, 1, 1),     // Blue
            SIMD4<Float>(0.6, 0, 1, 1),     // Purple
            SIMD4<Float>(0.2, 1, 0.4, 1),   // Green
            SIMD4<Float>(1, 0.4, 0, 1),     // Orange
            SIMD4<Float>(1, 0.1, 0.3, 1),   // Red
            SIMD4<Float>(1, 1, 0, 1),       // Yellow
            SIMD4<Float>(0, 1, 1, 1),       // Cyan
            SIMD4<Float>(1, 0, 0.8, 1)      // Magenta
        ]

        // Set the shape pipeline for solid color rendering
        encoder.setRenderPipelineState(renderer.shapePipelineState!)

        for (i, output) in outputs.enumerated() {
            guard output.config.enabled else { continue }

            // Get position from config
            let x = CGFloat(output.config.positionX ?? 0)
            let y = CGFloat(output.config.positionY ?? 0)
            let w = CGFloat(output.config.positionW ?? 1920)
            let h = CGFloat(output.config.positionH ?? 1080)
            let color = colors[i % colors.count]

            // Draw solid border lines on the edges only (no fill)
            let borderWidth: CGFloat = 4.0
            // Top border
            drawSolidRect(encoder: encoder, x: x, y: y, w: w, h: borderWidth, color: color)
            // Bottom border
            drawSolidRect(encoder: encoder, x: x, y: y + h - borderWidth, w: w, h: borderWidth, color: color)
            // Left border
            drawSolidRect(encoder: encoder, x: x, y: y, w: borderWidth, h: h, color: color)
            // Right border
            drawSolidRect(encoder: encoder, x: x + w - borderWidth, y: y, w: borderWidth, h: h, color: color)

            // Draw output name/number in center using simple block letters
            drawOutputLabel(encoder: encoder, x: x, y: y, w: w, h: h, index: i, color: color)
        }
    }

    /// Draw output label (index number) in center of output area
    private func drawOutputLabel(encoder: MTLRenderCommandEncoder, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, index: Int, color: SIMD4<Float>) {
        let centerX = x + w / 2
        let centerY = y + h / 2
        let digitHeight: CGFloat = min(80, h * 0.3)  // Scale to output size
        let digitWidth = digitHeight * 0.6
        let strokeWidth = digitHeight * 0.15

        // Draw the digit (0-9) or two digits for index >= 10
        let displayNum = index + 1  // 1-indexed for user display

        if displayNum < 10 {
            drawDigit(encoder: encoder, digit: displayNum, centerX: centerX, centerY: centerY,
                     width: digitWidth, height: digitHeight, stroke: strokeWidth, color: color)
        } else {
            // Two digits
            let tens = displayNum / 10
            let ones = displayNum % 10
            let spacing = digitWidth * 0.6
            drawDigit(encoder: encoder, digit: tens, centerX: centerX - spacing, centerY: centerY,
                     width: digitWidth, height: digitHeight, stroke: strokeWidth, color: color)
            drawDigit(encoder: encoder, digit: ones, centerX: centerX + spacing, centerY: centerY,
                     width: digitWidth, height: digitHeight, stroke: strokeWidth, color: color)
        }
    }

    /// Draw a single digit using 7-segment style rectangles
    private func drawDigit(encoder: MTLRenderCommandEncoder, digit: Int, centerX: CGFloat, centerY: CGFloat,
                          width: CGFloat, height: CGFloat, stroke: CGFloat, color: SIMD4<Float>) {
        let halfW = width / 2
        let halfH = height / 2

        // 7-segment layout: top, topLeft, topRight, middle, bottomLeft, bottomRight, bottom
        // Segments for each digit (true = on)
        let segments: [[Bool]] = [
            [true, true, true, false, true, true, true],    // 0
            [false, false, true, false, false, true, false], // 1
            [true, false, true, true, true, false, true],   // 2
            [true, false, true, true, false, true, true],   // 3
            [false, true, true, true, false, true, false],  // 4
            [true, true, false, true, false, true, true],   // 5
            [true, true, false, true, true, true, true],    // 6
            [true, false, true, false, false, true, false], // 7
            [true, true, true, true, true, true, true],     // 8
            [true, true, true, true, false, true, true]     // 9
        ]

        guard digit >= 0 && digit <= 9 else { return }
        let segs = segments[digit]

        // Top horizontal
        if segs[0] {
            drawSolidRect(encoder: encoder, x: centerX - halfW + stroke, y: centerY - halfH,
                         w: width - stroke * 2, h: stroke, color: color)
        }
        // Top-left vertical
        if segs[1] {
            drawSolidRect(encoder: encoder, x: centerX - halfW, y: centerY - halfH,
                         w: stroke, h: halfH, color: color)
        }
        // Top-right vertical
        if segs[2] {
            drawSolidRect(encoder: encoder, x: centerX + halfW - stroke, y: centerY - halfH,
                         w: stroke, h: halfH, color: color)
        }
        // Middle horizontal
        if segs[3] {
            drawSolidRect(encoder: encoder, x: centerX - halfW + stroke, y: centerY - stroke / 2,
                         w: width - stroke * 2, h: stroke, color: color)
        }
        // Bottom-left vertical
        if segs[4] {
            drawSolidRect(encoder: encoder, x: centerX - halfW, y: centerY,
                         w: stroke, h: halfH, color: color)
        }
        // Bottom-right vertical
        if segs[5] {
            drawSolidRect(encoder: encoder, x: centerX + halfW - stroke, y: centerY,
                         w: stroke, h: halfH, color: color)
        }
        // Bottom horizontal
        if segs[6] {
            drawSolidRect(encoder: encoder, x: centerX - halfW + stroke, y: centerY + halfH - stroke,
                         w: width - stroke * 2, h: stroke, color: color)
        }
    }

    /// Draw a solid colored rectangle at canvas pixel coordinates
    private func drawSolidRect(encoder: MTLRenderCommandEncoder, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: SIMD4<Float>) {
        var uniforms = MetalObjectUniforms()
        uniforms.position = SIMD2<Float>(Float(x + w/2), Float(y + h/2))
        uniforms.scale = SIMD2<Float>(Float(w/2), Float(h/2))
        uniforms.rotation = 0
        uniforms.color = SIMD4<Float>(color.x, color.y, color.z, 1.0)
        uniforms.opacity = color.w
        uniforms.softness = 0
        uniforms.shapeType = 1  // Rectangle
        uniforms.goboIndex = 0
        uniforms.baseRadius = 1  // Must be non-zero (shader divides by this)
        uniforms.iris = 1.0
        uniforms.shutterTop = SIMD2<Float>(0, 0)
        uniforms.shutterBottom = SIMD2<Float>(0, 0)
        uniforms.shutterLeft = SIMD2<Float>(0, 0)
        uniforms.shutterRight = SIMD2<Float>(0, 0)
        uniforms.shutterRotation = 0
        uniforms.shutterEdgeWidth = 0
        uniforms.prismaticPattern = 0
        uniforms.prismaticPhase = 0
        uniforms.prismaticColorCount = 0
        uniforms.animationType = 0

        let vertices: [SIMD2<Float>] = [
            SIMD2<Float>(-1, 1), SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 1), SIMD2<Float>(1, 0),
            SIMD2<Float>(-1, -1), SIMD2<Float>(0, 1),
            SIMD2<Float>(1, -1), SIMD2<Float>(1, 1)
        ]

        encoder.setVertexBuffer(renderer.commandQueue.device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<SIMD2<Float>>.stride * 8,
            options: .storageModeShared
        ), offset: 0, index: 0)

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Draw a colored quad at canvas pixel coordinates (legacy - kept for test pattern)
    private func drawColoredQuad(encoder: MTLRenderCommandEncoder, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: SIMD4<Float>) {
        drawSolidRect(encoder: encoder, x: x, y: y, w: w, h: h, color: color)
    }

    // MARK: - Test Pattern Generator

    /// Draw calibration test pattern - red grid with white circles on black background
    private func drawTestPattern(encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(renderer.shapePipelineState!)

        let canvasW = CGFloat(canvasSize.width)
        let canvasH = CGFloat(canvasSize.height)

        // BLACK background - covers everything
        let black = SIMD4<Float>(0.0, 0.0, 0.0, 1.0)
        drawColoredQuad(encoder: encoder, x: 0, y: 0, w: canvasW, h: canvasH, color: black)

        // Colors
        let red = SIMD4<Float>(1.0, 0.0, 0.0, 1.0)
        let white = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
        let green = SIMD4<Float>(0.0, 1.0, 0.0, 1.0)

        // Center of canvas
        let centerX = canvasW / 2
        let centerY = canvasH / 2

        // Grid lines every 100 pixels from center
        let gridSpacing: CGFloat = 100.0
        let gridLineWidth: CGFloat = 2.0

        // Draw vertical grid lines from center going left and right
        var offset: CGFloat = gridSpacing
        while offset < max(centerX, canvasW - centerX) {
            // Lines to the right of center
            if centerX + offset <= canvasW {
                drawColoredQuad(encoder: encoder, x: centerX + offset - gridLineWidth/2, y: 0, w: gridLineWidth, h: canvasH, color: white)
            }
            // Lines to the left of center
            if centerX - offset >= 0 {
                drawColoredQuad(encoder: encoder, x: centerX - offset - gridLineWidth/2, y: 0, w: gridLineWidth, h: canvasH, color: white)
            }
            offset += gridSpacing
        }

        // Draw horizontal grid lines from center going up and down
        offset = gridSpacing
        while offset < max(centerY, canvasH - centerY) {
            // Lines above center
            if centerY + offset <= canvasH {
                drawColoredQuad(encoder: encoder, x: 0, y: centerY + offset - gridLineWidth/2, w: canvasW, h: gridLineWidth, color: white)
            }
            // Lines below center
            if centerY - offset >= 0 {
                drawColoredQuad(encoder: encoder, x: 0, y: centerY - offset - gridLineWidth/2, w: canvasW, h: gridLineWidth, color: white)
            }
            offset += gridSpacing
        }

        // Draw thick center lines (on top of grid)
        let centerLineWidth: CGFloat = 8.0
        drawColoredQuad(encoder: encoder, x: 0, y: centerY - centerLineWidth/2, w: canvasW, h: centerLineWidth, color: red)
        drawColoredQuad(encoder: encoder, x: centerX - centerLineWidth/2, y: 0, w: centerLineWidth, h: canvasH, color: red)

        // Draw WHITE circles - 3 large circles spanning the height
        let circleRadius = canvasH / 2 - 20
        let ringWidth: CGFloat = 6.0

        // Left circle
        drawCircleOutline(encoder: encoder, cx: circleRadius + 10, cy: centerY, radius: circleRadius, thickness: ringWidth, color: white)
        // Center circle
        drawCircleOutline(encoder: encoder, cx: centerX, cy: centerY, radius: circleRadius, thickness: ringWidth, color: white)
        // Right circle
        drawCircleOutline(encoder: encoder, cx: canvasW - circleRadius - 10, cy: centerY, radius: circleRadius, thickness: ringWidth, color: white)

        // Draw GREEN border around entire canvas
        // Draw at edge AND inside the edge blend zone (at ~360px inset) so it's visible
        let edgeBorderWidth: CGFloat = 20.0
        let innerBorderOffset: CGFloat = 360.0  // Just inside typical edge blend feather
        let innerBorderWidth: CGFloat = 10.0

        // Outer border at canvas edges (may be faded by edge blend)
        drawColoredQuad(encoder: encoder, x: 0, y: 0, w: edgeBorderWidth, h: canvasH, color: green)
        drawColoredQuad(encoder: encoder, x: canvasW - edgeBorderWidth, y: 0, w: edgeBorderWidth, h: canvasH, color: green)
        drawColoredQuad(encoder: encoder, x: 0, y: 0, w: canvasW, h: edgeBorderWidth, color: green)
        drawColoredQuad(encoder: encoder, x: 0, y: canvasH - edgeBorderWidth, w: canvasW, h: edgeBorderWidth, color: green)

        // Inner border lines (visible inside edge blend zone)
        drawColoredQuad(encoder: encoder, x: innerBorderOffset, y: 0, w: innerBorderWidth, h: canvasH, color: green)
        drawColoredQuad(encoder: encoder, x: canvasW - innerBorderOffset - innerBorderWidth, y: 0, w: innerBorderWidth, h: canvasH, color: green)
        drawColoredQuad(encoder: encoder, x: 0, y: innerBorderOffset, w: canvasW, h: innerBorderWidth, color: green)
        drawColoredQuad(encoder: encoder, x: 0, y: canvasH - innerBorderOffset - innerBorderWidth, w: canvasW, h: innerBorderWidth, color: green)

        // Draw custom text in center if set
        let patternText = OutputSettingsWindowController.testPatternText
        if !patternText.isEmpty {
            // Update texture if text changed
            if patternText != lastTestPatternText {
                testPatternTextTexture = createTextTexture(text: patternText, fontSize: 150)
                lastTestPatternText = patternText
            }

            // Draw text texture centered on canvas
            if let textTexture = testPatternTextTexture {
                let textW = CGFloat(textTexture.width)
                let textH = CGFloat(textTexture.height)
                let textX = (canvasW - textW) / 2
                let textY = (canvasH - textH) / 2
                drawTexturedQuad(encoder: encoder, texture: textTexture, x: textX, y: textY, w: textW, h: textH)
            }
        }
    }

    /// Draw a smooth circle outline using small quads
    private func drawCircleOutline(encoder: MTLRenderCommandEncoder, cx: CGFloat, cy: CGFloat, radius: CGFloat, thickness: CGFloat, color: SIMD4<Float>) {
        let segments = 120
        for i in 0..<segments {
            let angle1 = CGFloat(i) * (2.0 * CGFloat.pi) / CGFloat(segments)
            let angle2 = CGFloat(i + 1) * (2.0 * CGFloat.pi) / CGFloat(segments)

            let x1 = cx + radius * cos(angle1)
            let y1 = cy + radius * sin(angle1)
            let x2 = cx + radius * cos(angle2)
            let y2 = cy + radius * sin(angle2)

            let minX = min(x1, x2) - thickness/2
            let minY = min(y1, y2) - thickness/2
            let w = abs(x2 - x1) + thickness
            let h = abs(y2 - y1) + thickness
            drawColoredQuad(encoder: encoder, x: minX, y: minY, w: max(w, thickness), h: max(h, thickness), color: color)
        }
    }

    /// Create a texture from text for test pattern display
    private func createTextTexture(text: String, fontSize: CGFloat = 120) -> MTLTexture? {
        guard !text.isEmpty else { return nil }
        let device = renderer.device

        // Create attributed string with white text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)

        // Calculate size
        let size = attrString.size()
        let width = Int(ceil(size.width)) + 20
        let height = Int(ceil(size.height)) + 20

        guard width > 0 && height > 0 else { return nil }

        // Create bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Clear to transparent
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        // Flip for text drawing
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        // Draw text
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        attrString.draw(at: NSPoint(x: 10, y: 10))
        NSGraphicsContext.restoreGraphicsState()

        // Create Metal texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor),
              let data = context.data else { return nil }

        texture.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: width * 4
        )

        return texture
    }

    /// Draw a textured quad for test pattern text
    private func drawTexturedQuad(encoder: MTLRenderCommandEncoder, texture: MTLTexture, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        guard let pipelineState = renderer.videoPipelineState else { return }

        var uniforms = MetalObjectUniforms()
        uniforms.position = SIMD2<Float>(Float(x + w/2), Float(y + h/2))
        uniforms.scale = SIMD2<Float>(Float(w/2), Float(h/2))
        uniforms.rotation = 0
        uniforms.color = SIMD4<Float>(1, 1, 1, 1)
        uniforms.opacity = 1.0
        uniforms.softness = 0
        uniforms.shapeType = 1
        uniforms.goboIndex = 0
        uniforms.baseRadius = 1
        uniforms.iris = 1.0
        uniforms.shutterTop = SIMD2<Float>(0, 0)
        uniforms.shutterBottom = SIMD2<Float>(0, 0)
        uniforms.shutterLeft = SIMD2<Float>(0, 0)
        uniforms.shutterRight = SIMD2<Float>(0, 0)
        uniforms.shutterRotation = 0
        uniforms.shutterEdgeWidth = 0
        uniforms.prismaticPattern = 0
        uniforms.prismaticPhase = 0
        uniforms.prismaticColorCount = 0
        uniforms.animationType = 0

        let vertices: [SIMD2<Float>] = [
            SIMD2<Float>(-1, 1), SIMD2<Float>(0, 0),
            SIMD2<Float>(1, 1), SIMD2<Float>(1, 0),
            SIMD2<Float>(-1, -1), SIMD2<Float>(0, 1),
            SIMD2<Float>(1, -1), SIMD2<Float>(1, 1)
        ]

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(vertices, length: vertices.count * MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(renderer.samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Blit offscreen texture to drawable with scaling
    private func blitToDrawable(commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable) {
        guard let offscreen = offscreenTexture else { return }

        let blitEncoder = commandBuffer.makeBlitCommandEncoder()!

        // Calculate scaling - fit offscreen into drawable
        let srcWidth = offscreen.width
        let srcHeight = offscreen.height
        let dstWidth = drawable.texture.width
        let dstHeight = drawable.texture.height

        // Scale to fit while maintaining aspect ratio
        let srcAspect = Float(srcWidth) / Float(srcHeight)
        let dstAspect = Float(dstWidth) / Float(dstHeight)

        var copyWidth: Int
        var copyHeight: Int
        var dstX: Int = 0
        var dstY: Int = 0

        if srcAspect > dstAspect {
            // Source is wider - fit to width
            copyWidth = dstWidth
            copyHeight = Int(Float(dstWidth) / srcAspect)
            dstY = (dstHeight - copyHeight) / 2
        } else {
            // Source is taller - fit to height
            copyHeight = dstHeight
            copyWidth = Int(Float(dstHeight) * srcAspect)
            dstX = (dstWidth - copyWidth) / 2
        }

        // For blit, we need to copy at matching sizes, so we'll just copy what fits
        // Use the minimum of source and destination dimensions
        let actualCopyWidth = min(srcWidth, dstWidth)
        let actualCopyHeight = min(srcHeight, dstHeight)

        blitEncoder.copy(
            from: offscreen,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: actualCopyWidth, height: actualCopyHeight, depth: 1),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )

        blitEncoder.endEncoding()
    }
}

extension MetalRenderView: MTKViewDelegate {
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle resize if needed
    }

    nonisolated func draw(in view: MTKView) {
        // Dispatch to main actor for rendering
        Task { @MainActor in
            self.performDraw()
        }
    }

    private func performDraw() {
        let now = CACurrentMediaTime()
        let delta = CGFloat(now - lastTimestamp)
        lastTimestamp = now

        // Reset per-frame video caches (texture created once, shared across fixtures)
        VideoSlotManager.shared.beginFrame()

        // Update scene - use actual canvas size, not view bounds
        controller.tick(deltaTime: delta, canvasSize: canvasSize)

        guard let drawable = currentDrawable,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            return
        }

        // If OutputManager has enabled outputs, render to offscreen texture at full canvas resolution
        let hasEnabledOutputs = !OutputManager.shared.getAllOutputs().filter { $0.config.enabled }.isEmpty
        let needsOffscreen = hasEnabledOutputs && offscreenTexture != nil
        if needsOffscreen {
            renderToOffscreen(commandBuffer: commandBuffer, time: now)
        }

        // Render to view's drawable for display
        guard let renderPassDescriptor = currentRenderPassDescriptor else {
            return
        }

        // Clear to black
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // Set canvas uniforms for display (using full canvas coordinates)
        var canvasUniforms = MetalCanvasUniforms(
            canvasSize: SIMD2<Float>(Float(canvasSize.width), Float(canvasSize.height)),
            time: Float(now),
            padding: 0
        )
        renderEncoder.setVertexBytes(&canvasUniforms, length: MemoryLayout<MetalCanvasUniforms>.stride, index: 2)

        // Render each object to drawable for display
        for obj in controller.objects {
            if obj.prismType != .off && obj.prismFacets > 0 {
                renderPrismCopies(obj, encoder: renderEncoder)
            } else {
                renderObject(obj, encoder: renderEncoder, positionOffset: .zero)
            }
        }

        renderEncoder.endEncoding()

        // Apply all collected video playback states (after rendering collected them)
        VideoSlotManager.shared.applyCollectedStates()

        // Push frame to OutputManager (display outputs, NDI)
        // This is non-blocking - display uses GPU→GPU path, NDI uses async queue
        if let offscreen = offscreenTexture {
            // Use absolute time (Unix epoch) for NDI sync - all outputs get same timecode
            let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
            OutputManager.shared.pushFrame(texture: offscreen, timestamp: timestamp, frameRate: 60.0)
        }

        // NOTE: Legacy NDI capture removed - OutputManager handles all NDI outputs now
        // This eliminates the synchronous waitUntilCompleted() that was blocking the render loop

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func renderObject(_ obj: VisualObject, encoder: MTLRenderCommandEncoder, positionOffset: SIMD2<Float>) {
        // Set up object uniforms
        var uniforms = MetalObjectUniforms()
        uniforms.position = SIMD2<Float>(Float(obj.position.x) + positionOffset.x, Float(obj.position.y) + positionOffset.y)
        uniforms.scale = SIMD2<Float>(Float(obj.scale.width), Float(obj.scale.height))
        // Videos render level by default - shapes and gobos use rotation
        uniforms.rotation = obj.isVideo ? 0.0 : Float(obj.totalRotation)
        uniforms.color = SIMD4<Float>(
            Float(obj.color.redComponent * obj.intensity),
            Float(obj.color.greenComponent * obj.intensity),
            Float(obj.color.blueComponent * obj.intensity),
            1.0
        )
        uniforms.opacity = Float(obj.opacity)
        uniforms.softness = Float(obj.softness)
        // Use raw shapeIndex for shapes 0-20 (0-10 solid, 11-20 bezel)
        if obj.shapeIndex >= 0 && obj.shapeIndex <= 20 {
            uniforms.shapeType = Int32(obj.shapeIndex)
        } else {
            uniforms.shapeType = Int32(obj.shape.rawValue)
        }
        uniforms.goboIndex = Int32(obj.goboId ?? 0)
        uniforms.baseRadius = 120

        // Iris and Framing Shutter uniforms
        uniforms.iris = obj.iris
        uniforms.shutterTop = SIMD2<Float>(obj.shutterTopInsertion, obj.shutterTopAngle)
        uniforms.shutterBottom = SIMD2<Float>(obj.shutterBottomInsertion, obj.shutterBottomAngle)
        uniforms.shutterLeft = SIMD2<Float>(obj.shutterLeftInsertion, obj.shutterLeftAngle)
        uniforms.shutterRight = SIMD2<Float>(obj.shutterRightInsertion, obj.shutterRightAngle)
        uniforms.shutterRotation = obj.shutterRotation
        uniforms.shutterEdgeWidth = 2.0  // Soft edge by default (TODO: add setting for hard edge = 0.1)

        // Prismatic uniforms
        uniforms.prismaticPattern = Int32(obj.prismaticPattern)
        uniforms.prismaticPhase = obj.prismaticPhase

        // Get palette colors if prismatic is active
        if obj.prismaticPattern > 0 && obj.prismaticPaletteIndex < PaletteManager.shared.palettes.count {
            let palette = PaletteManager.shared.palettes[obj.prismaticPaletteIndex]
            let colors = palette.getShaderColors()
            uniforms.prismaticColorCount = Int32(palette.colors.count)
            uniforms.paletteColor0 = colors[0]
            uniforms.paletteColor1 = colors[1]
            uniforms.paletteColor2 = colors[2]
            uniforms.paletteColor3 = colors[3]
            uniforms.paletteColor4 = colors[4]
            uniforms.paletteColor5 = colors[5]
            uniforms.paletteColor6 = colors[6]
            uniforms.paletteColor7 = colors[7]
        } else {
            uniforms.prismaticColorCount = 0
        }

        // Animation wheel uniforms (10 animation types)
        // Now separate from prism - both can be active simultaneously
        if obj.animationType > 0 {
            uniforms.animationType = Int32(obj.animationType)  // 1-10 for shader
            uniforms.animationPhase = obj.prismRotationAccum / 360.0 * Float.pi * 2.0  // Convert to radians for animation
            uniforms.animationSpeed = max(0.5, abs(obj.prismRotationSpeed) * 2.0)  // Animation speed from CH37
            uniforms.animPrismaticFill = obj.animPrismaticFill ? 1 : 0  // Fill dark areas with prismatic colors
        } else {
            uniforms.animationType = 0
            uniforms.animationPhase = 0
            uniforms.animationSpeed = 0
            uniforms.animPrismaticFill = 0
        }

        // Set vertex buffer
        encoder.setVertexBuffer(renderer.commandQueue.device.makeBuffer(
            bytes: [
                SIMD2<Float>(-1, 1), SIMD2<Float>(0, 0),
                SIMD2<Float>(1, 1), SIMD2<Float>(1, 0),
                SIMD2<Float>(-1, -1), SIMD2<Float>(0, 1),
                SIMD2<Float>(1, -1), SIMD2<Float>(1, 1)
            ] as [SIMD2<Float>],
            length: MemoryLayout<SIMD2<Float>>.stride * 8,
            options: .storageModeShared
        ), offset: 0, index: 0)

        // Choose pipeline based on object type
        if obj.isVideo, let slotIndex = obj.videoSlot {
            // Collect video playback state - will be applied after all objects processed
            VideoSlotManager.shared.collectPlaybackState(
                forSlot: slotIndex,
                state: obj.videoPlaybackState,
                gotoPercent: obj.videoGotoPercent,
                volume: obj.videoVolume
            )

            // Pass mask blend value via goboIndex (shader reads it as blend factor)
            uniforms.goboIndex = Int32(obj.videoMaskBlend * 255.0)

            // Use video texture with crossfadable color/mask blend
            if let videoTexture = VideoSlotManager.shared.getTexture(forSlot: slotIndex) {
                // Calculate scale to render at native resolution
                // baseRadius * 2 = 240 pixels at scale 1.0
                // To get native pixels: nativeWidth / 240 = required scale
                let nativeScaleX = Float(videoTexture.width) / 240.0
                let nativeScaleY = Float(videoTexture.height) / 240.0

                // Apply native scale, then multiply by DMX scale factor
                // At DMX scale=1.0, media renders at native resolution
                uniforms.scale.x = nativeScaleX * Float(obj.scale.width)
                uniforms.scale.y = nativeScaleY * Float(obj.scale.height)

                // Set uniforms with native-resolution scale
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)

                encoder.setRenderPipelineState(renderer.videoPipelineState!)
                encoder.setFragmentTexture(videoTexture, index: 0)
                encoder.setFragmentSamplerState(renderer.samplerState, index: 0)
            } else {
                // No video frame available - render as shape (placeholder)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)
                encoder.setRenderPipelineState(renderer.shapePipelineState!)
            }
        } else if obj.isGobo, let goboId = obj.goboId {
            // Gobos use 1:1 aspect ratio (square)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)
            // Use gobo pipeline
            if let goboTexture = renderer.getGoboTexture(id: goboId) {
                encoder.setRenderPipelineState(renderer.goboPipelineState!)
                encoder.setFragmentTexture(goboTexture, index: 0)
                encoder.setFragmentSamplerState(renderer.samplerState, index: 0)
            } else {
                // Fallback to shape rendering
                encoder.setRenderPipelineState(renderer.shapePipelineState!)
            }
        } else {
            // Use shape pipeline (shapes use 1:1 aspect)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalObjectUniforms>.stride, index: 1)
            encoder.setRenderPipelineState(renderer.shapePipelineState!)
        }

        // Draw quad
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Renders an object multiple times at offset positions to simulate prism beam multiplication
    private func renderPrismCopies(_ obj: VisualObject, encoder: MTLRenderCommandEncoder) {
        // Calculate current prism angle
        let prismAngle: Float
        if obj.prismRotationMode == .index {
            prismAngle = obj.prismIndexAngle
        } else {
            prismAngle = obj.prismRotationAccum
        }
        let prismAngleRad = prismAngle * .pi / 180.0

        // Handle animation wheels differently - no beam multiplication
        if obj.prismType.isAnimation {
            // Animation wheels overlay a texture, just render once for now
            // TODO: Add animation wheel texture overlays
            renderObject(obj, encoder: encoder, positionOffset: .zero)
            return
        }

        let facetCount = obj.prismFacets
        guard facetCount > 0 else {
            renderObject(obj, encoder: encoder, positionOffset: .zero)
            return
        }

        // Calculate base offset distance based on object scale and prism spread
        // Scale is a multiplier (0-6), baseRadius is 120, so actual pixel size = scale * 120
        // prismSpread goes from 0.2 (tight) to 1.0 (wide) based on DMX value
        let baseRadius: Float = 120.0
        let objectPixelSize = Float(max(obj.scale.width, obj.scale.height)) * baseRadius
        let spreadRadius = objectPixelSize * obj.prismSpread  // Spread controlled by CH34 DMX value

        if obj.prismType.isCircular {
            // Circular prism: arrange copies in a circle around the center
            let angleStep = (2.0 * .pi) / Float(facetCount)

            for i in 0..<facetCount {
                let angle = Float(i) * angleStep + prismAngleRad
                let offsetX = cos(angle) * spreadRadius
                let offsetY = sin(angle) * spreadRadius
                renderObject(obj, encoder: encoder, positionOffset: SIMD2<Float>(offsetX, offsetY))
            }
        } else if obj.prismType.isLinear {
            // Linear prism: arrange copies in a row
            let totalWidth = spreadRadius * 2.0
            let spacing = totalWidth / Float(facetCount - 1)
            let startX = -spreadRadius

            // Rotate the linear arrangement by prism angle
            let cosA = cos(prismAngleRad)
            let sinA = sin(prismAngleRad)

            for i in 0..<facetCount {
                // Calculate position along line
                let localX = startX + Float(i) * spacing
                let localY: Float = 0

                // Rotate by prism angle
                let offsetX = localX * cosA - localY * sinA
                let offsetY = localX * sinA + localY * cosA

                renderObject(obj, encoder: encoder, positionOffset: SIMD2<Float>(offsetX, offsetY))
            }
        } else {
            // Unknown prism type - render once
            renderObject(obj, encoder: encoder, positionOffset: .zero)
        }
    }
}

private let maxDMXChannels = 512

// MARK: - DMX Mode

enum DMXMode: Int, CaseIterable {
    case full = 0       // 37 channels - all features
    case standard = 1   // 23 channels - no shutters/iris
    case compact = 2    // 10 channels - basic control

    var channelsPerFixture: Int {
        switch self {
        case .full: return 37      // All features including prism, animation, prismatics
        case .standard: return 23  // No shutters/iris/prismatics
        case .compact: return 10   // Basic control only
        }
    }

    var fixturesPerUniverse: Int {
        return 512 / channelsPerFixture
    }

    var displayName: String {
        switch self {
        case .full: return "Full (37ch)"
        case .standard: return "Standard (23ch)"
        case .compact: return "Compact (10ch)"
        }
    }

    var shortName: String {
        switch self {
        case .full: return "37ch"
        case .standard: return "23ch"
        case .compact: return "10ch"
        }
    }
}

// MARK: - Protocol Type

enum DMXProtocol: Int, CaseIterable {
    case artNet = 0
    case sACN = 1
    case both = 2

    var displayName: String {
        switch self {
        case .artNet: return "Art-Net"
        case .sACN: return "sACN (E1.31)"
        case .both: return "Both"
        }
    }
}

// MARK: - Prismatics Color Palettes

/// A named color palette for prismatic effects
struct ColorPalette: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var colors: [PaletteColor]

    struct PaletteColor: Codable, Equatable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat

        var nsColor: NSColor {
            return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1.0)
        }

        init(color: NSColor) {
            self.red = color.redComponent
            self.green = color.greenComponent
            self.blue = color.blueComponent
        }

        init(red: CGFloat, green: CGFloat, blue: CGFloat) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// Get SIMD4 colors for shader (up to 8 colors, padded with black)
    func getShaderColors() -> [SIMD4<Float>] {
        var result: [SIMD4<Float>] = []
        for i in 0..<8 {
            if i < colors.count {
                let c = colors[i]
                result.append(SIMD4<Float>(Float(c.red), Float(c.green), Float(c.blue), 1.0))
            } else {
                result.append(SIMD4<Float>(0, 0, 0, 0))
            }
        }
        return result
    }
}

/// Prism beam multiplication types (CH34)
enum PrismType: Int, CaseIterable {
    case off = 0
    case circular3 = 1   // 3-facet circular
    case circular5 = 2   // 5-facet circular
    case circular6 = 3   // 6-facet circular
    case circular8 = 4   // 8-facet circular
    case circular16 = 5  // 16-facet circular
    case circular18 = 6  // 18-facet circular
    case linear3 = 7     // 3-facet linear
    case linear4 = 8     // 4-facet linear
    case linear6 = 9     // 6-facet linear
    case linear24 = 10   // 24-facet linear
    // Animation wheels (10 types)
    case animFire = 11        // Animation 1: Fire
    case animWater = 12       // Animation 2: Water
    case animClouds = 13      // Animation 3: Clouds
    case animRadialBreakup = 14   // Animation 4: Radial Breakup
    case animEllipticalBreakup = 15 // Animation 5: Elliptical Breakup
    case animBubbles = 16     // Animation 6: Bubbles
    case animSnow = 17        // Animation 7: Snow
    case animLightning = 18   // Animation 8: Lightning
    case animPlasma = 19      // Animation 9: Plasma
    case animSpiral = 20      // Animation 10: Spiral

    var facetCount: Int {
        switch self {
        case .off: return 0
        case .circular3, .linear3: return 3
        case .linear4: return 4
        case .circular5: return 5
        case .circular6, .linear6: return 6
        case .circular8: return 8
        case .circular16: return 16
        case .circular18: return 18
        case .linear24: return 24
        default: return 0  // Animation wheels don't multiply
        }
    }

    var isCircular: Bool {
        switch self {
        case .circular3, .circular5, .circular6, .circular8, .circular16, .circular18: return true
        default: return false
        }
    }

    var isLinear: Bool {
        switch self {
        case .linear3, .linear4, .linear6, .linear24: return true
        default: return false
        }
    }

    var isAnimation: Bool {
        return self.rawValue >= 11 && self.rawValue <= 20
    }

    /// Returns the animation type index (1-10) for shader use
    var animationIndex: Int {
        guard isAnimation else { return 0 }
        return self.rawValue - 10  // animFire(11)->1, animWater(12)->2, etc.
    }
}

/// Prism rotation mode (CH36)
enum PrismRotationMode: Int {
    case index = 0   // Static position (0-127 = 0-360°)
    case ccw = 1     // Counter-clockwise rotation
    case cw = 2      // Clockwise rotation
}

/// Prismatic dichroic color pattern types (CH35)
enum PrismaticPattern: Int, CaseIterable {
    case off = 0
    case radial = 1      // Colors radiate from center
    case linear = 2      // Linear gradient across shape
    case spiral = 3      // Spiral/rotating pattern
    case segments = 4    // Pie-slice segments
    case voronoi = 5     // Dichroic chip-like pattern
    case wave = 6        // Animated wave pattern
    case kaleidoscope = 7 // Kaleidoscope effect

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .radial: return "Radial"
        case .linear: return "Linear"
        case .spiral: return "Spiral"
        case .segments: return "Segments"
        case .voronoi: return "Dichroic"
        case .wave: return "Wave"
        case .kaleidoscope: return "Kaleidoscope"
        }
    }
}

/// Manages color palettes - stores in UserDefaults
/// Thread-safe using lock for cross-thread access
final class PaletteManager: @unchecked Sendable {
    static let shared = PaletteManager()

    private let userDefaultsKey = "ColorPalettes"
    private let lock = NSLock()
    private var _palettes: [ColorPalette] = []

    var palettes: [ColorPalette] {
        lock.lock()
        defer { lock.unlock() }
        return _palettes
    }

    private init() {
        loadPalettes()
        if _palettes.isEmpty {
            createDefaultPalettes()
        }
    }

    private func loadPalettes() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([ColorPalette].self, from: data) else {
            return
        }
        _palettes = decoded
    }

    func savePalettes() {
        lock.lock()
        let data = try? JSONEncoder().encode(_palettes)
        lock.unlock()
        if let data = data {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func createDefaultPalettes() {
        // Rainbow
        _palettes.append(ColorPalette(name: "Rainbow", colors: [
            ColorPalette.PaletteColor(red: 1.0, green: 0.0, blue: 0.0),   // Red
            ColorPalette.PaletteColor(red: 1.0, green: 0.5, blue: 0.0),   // Orange
            ColorPalette.PaletteColor(red: 1.0, green: 1.0, blue: 0.0),   // Yellow
            ColorPalette.PaletteColor(red: 0.0, green: 1.0, blue: 0.0),   // Green
            ColorPalette.PaletteColor(red: 0.0, green: 0.5, blue: 1.0),   // Cyan
            ColorPalette.PaletteColor(red: 0.0, green: 0.0, blue: 1.0),   // Blue
            ColorPalette.PaletteColor(red: 0.5, green: 0.0, blue: 1.0),   // Purple
            ColorPalette.PaletteColor(red: 1.0, green: 0.0, blue: 0.5),   // Magenta
        ]))

        // Warm
        _palettes.append(ColorPalette(name: "Warm", colors: [
            ColorPalette.PaletteColor(red: 1.0, green: 0.2, blue: 0.0),   // Red-Orange
            ColorPalette.PaletteColor(red: 1.0, green: 0.6, blue: 0.0),   // Orange
            ColorPalette.PaletteColor(red: 1.0, green: 0.8, blue: 0.2),   // Yellow-Orange
            ColorPalette.PaletteColor(red: 1.0, green: 1.0, blue: 0.4),   // Yellow
        ]))

        // Cool
        _palettes.append(ColorPalette(name: "Cool", colors: [
            ColorPalette.PaletteColor(red: 0.0, green: 0.8, blue: 1.0),   // Cyan
            ColorPalette.PaletteColor(red: 0.0, green: 0.4, blue: 1.0),   // Blue
            ColorPalette.PaletteColor(red: 0.4, green: 0.0, blue: 1.0),   // Indigo
            ColorPalette.PaletteColor(red: 0.8, green: 0.0, blue: 1.0),   // Purple
        ]))

        // Fire
        _palettes.append(ColorPalette(name: "Fire", colors: [
            ColorPalette.PaletteColor(red: 1.0, green: 1.0, blue: 0.8),   // White-yellow
            ColorPalette.PaletteColor(red: 1.0, green: 0.9, blue: 0.0),   // Yellow
            ColorPalette.PaletteColor(red: 1.0, green: 0.5, blue: 0.0),   // Orange
            ColorPalette.PaletteColor(red: 1.0, green: 0.2, blue: 0.0),   // Red-orange
            ColorPalette.PaletteColor(red: 0.8, green: 0.0, blue: 0.0),   // Red
        ]))

        // Ocean
        _palettes.append(ColorPalette(name: "Ocean", colors: [
            ColorPalette.PaletteColor(red: 0.0, green: 0.8, blue: 0.6),   // Teal
            ColorPalette.PaletteColor(red: 0.0, green: 0.6, blue: 0.8),   // Cyan
            ColorPalette.PaletteColor(red: 0.0, green: 0.4, blue: 0.9),   // Blue
            ColorPalette.PaletteColor(red: 0.1, green: 0.2, blue: 0.6),   // Deep blue
        ]))

        // Dichroic Glass (Apollo-style)
        _palettes.append(ColorPalette(name: "Dichroic", colors: [
            ColorPalette.PaletteColor(red: 0.0, green: 0.8, blue: 1.0),   // Cyan
            ColorPalette.PaletteColor(red: 1.0, green: 0.0, blue: 0.8),   // Magenta
            ColorPalette.PaletteColor(red: 0.0, green: 1.0, blue: 0.4),   // Green
            ColorPalette.PaletteColor(red: 1.0, green: 0.8, blue: 0.0),   // Gold
            ColorPalette.PaletteColor(red: 0.4, green: 0.0, blue: 1.0),   // Violet
        ]))

        savePalettes()
    }

    func addPalette(_ palette: ColorPalette) {
        lock.lock()
        _palettes.append(palette)
        lock.unlock()
        savePalettes()
    }

    func updatePalette(_ palette: ColorPalette) {
        lock.lock()
        if let index = _palettes.firstIndex(where: { $0.id == palette.id }) {
            _palettes[index] = palette
        }
        lock.unlock()
        savePalettes()
    }

    func deletePalette(at index: Int) {
        lock.lock()
        guard index >= 0 && index < _palettes.count else {
            lock.unlock()
            return
        }
        _palettes.remove(at: index)
        lock.unlock()
        savePalettes()
    }

    func getPalette(at index: Int) -> ColorPalette? {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0 && index < _palettes.count else { return nil }
        return _palettes[index]
    }
}

// MARK: - Network Interface

struct NetworkInterface: Hashable {
    let name: String
    let ip: String
    let displayName: String
    let isLoopback: Bool

    static func all() -> [NetworkInterface] {
        var interfaces: [NetworkInterface] = []

        // Add loopback first for local testing (MA3 onPC, etc.)
        interfaces.append(NetworkInterface(name: "lo0", ip: "127.0.0.1", displayName: "Loopback (127.0.0.1)", isLoopback: true))

        // Add "all interfaces" option
        interfaces.append(NetworkInterface(name: "any", ip: "0.0.0.0", displayName: "All Interfaces (0.0.0.0)", isLoopback: false))

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return interfaces
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopbackFlag = (flags & IFF_LOOPBACK) != 0

            if isUp && isRunning && !isLoopbackFlag {
                let family = ptr.pointee.ifa_addr.pointee.sa_family
                if family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let name = String(cString: ptr.pointee.ifa_name)
                        let ip = String(cString: hostname)
                        // Skip virtual/system interfaces
                        if !name.hasPrefix("utun") && !name.hasPrefix("awdl") && !name.hasPrefix("llw") &&
                           !name.hasPrefix("anpi") && !name.hasPrefix("bridge") && !name.hasPrefix("ap") &&
                           !name.hasPrefix("gif") && !name.hasPrefix("stf") {
                            interfaces.append(NetworkInterface(name: name, ip: ip, displayName: "\(name) - \(ip)", isLoopback: false))
                        }
                    }
                }
            }

            if let next = ptr.pointee.ifa_next {
                ptr = next
            } else {
                break
            }
        }

        return interfaces
    }
}

// MARK: - DMX / Art-Net / sACN

final class DMXState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dmx.state.queue", qos: .userInteractive)
    private var universes: [Int: UniverseData] = [:]
    private(set) var lastPacketTime: Date = .distantPast
    private(set) var packetCount: Int = 0

    struct UniverseData {
        var values: [UInt8] = Array(repeating: 0, count: maxDMXChannels)
        var lastUpdated: Date = .distantPast
    }

    func values(for universe: Int) -> [UInt8] {
        queue.sync {
            universes[universe]?.values ?? Array(repeating: 0, count: maxDMXChannels)
        }
    }

    func update(universe: Int, dmx: [UInt8]) {
        queue.async {
            var data = self.universes[universe] ?? UniverseData()
            let count = min(maxDMXChannels, dmx.count)
            if count > 0 {
                data.values.replaceSubrange(0..<count, with: dmx[0..<count])
            }
            data.lastUpdated = Date()
            self.universes[universe] = data
            self.lastPacketTime = Date()
            self.packetCount += 1
        }
    }

    func getStats() -> (lastPacket: Date, count: Int) {
        queue.sync {
            (lastPacketTime, packetCount)
        }
    }

    /// Check if a universe has received any data
    func hasReceivedData(for universe: Int) -> Bool {
        queue.sync {
            universes[universe] != nil
        }
    }
}

final class DMXReceiver {
    private let state: DMXState
    private(set) var startUniverse: Int
    private(set) var universeCount: Int
    private(set) var protocolType: DMXProtocol
    private(set) var networkInterface: NetworkInterface
    private var sources: [DispatchSourceRead] = []
    private let queue = DispatchQueue(label: "dmx.receiver.queue", qos: .userInteractive)

    init(state: DMXState, startUniverse: Int, universeCount: Int = 1, protocolType: DMXProtocol = .both, networkInterface: NetworkInterface? = nil) {
        self.state = state
        self.startUniverse = startUniverse
        self.universeCount = universeCount
        self.protocolType = protocolType
        // Default to loopback for local testing
        self.networkInterface = networkInterface ?? NetworkInterface(name: "lo0", ip: "127.0.0.1", displayName: "Loopback (127.0.0.1)", isLoopback: true)
    }

    func start() {
        switch protocolType {
        case .artNet:
            setupArtNet()
        case .sACN:
            setupSACN()
        case .both:
            setupArtNet()
            setupSACN()
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    func restart(startUniverse: Int, universeCount: Int, protocolType: DMXProtocol, networkInterface: NetworkInterface) {
        stop()
        self.startUniverse = startUniverse
        self.universeCount = universeCount
        self.protocolType = protocolType
        self.networkInterface = networkInterface
        start()
    }

    private func setupArtNet() {
        guard let fd = bindUDP(port: 6454, joinMulticast: nil) else {
            print("Failed to bind Art-Net port 6454")
            return
        }
        print("Art-Net listening on port 6454, interface: \(networkInterface.displayName)")
        listen(fd: fd) { [weak self] data in
            self?.handleArtNet(data: data)
        }
    }

    private func setupSACN() {
        // sACN uses per-universe multicast groups
        // For multi-universe, we need to join all relevant multicast groups

        // Calculate first multicast group for binding
        let firstUniverse = max(1, startUniverse)
        let hi = UInt8((firstUniverse >> 8) & 0xFF)
        let lo = UInt8(firstUniverse & 0xFF)
        let firstMulticast = "239.255.\(hi).\(lo)"

        // For loopback, skip multicast join (unicast only)
        let joinGroup: String? = networkInterface.isLoopback ? nil : firstMulticast

        guard let fd = bindUDP(port: 5568, joinMulticast: joinGroup) else {
            print("Failed to bind sACN port 5568")
            return
        }

        // Join additional multicast groups for remaining universes
        if !networkInterface.isLoopback && universeCount > 1 {
            for offset in 1..<universeCount {
                let universe = startUniverse + offset
                let uhi = UInt8((universe >> 8) & 0xFF)
                let ulo = UInt8(universe & 0xFF)
                let multicast = "239.255.\(uhi).\(ulo)"
                joinMulticastGroup(fd: fd, group: multicast)
            }
            print("sACN listening on port 5568, multicast groups for U\(startUniverse)-\(startUniverse + universeCount - 1), interface: \(networkInterface.displayName)")
        } else if networkInterface.isLoopback {
            print("sACN listening on port 5568 (unicast mode for loopback), interface: \(networkInterface.displayName)")
        } else {
            print("sACN listening on port 5568, multicast: \(firstMulticast), interface: \(networkInterface.displayName)")
        }

        listen(fd: fd) { [weak self] data in
            self?.handleSACN(data: data)
        }
    }

    private func joinMulticastGroup(fd: Int32, group: String) {
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = inet_addr(group)

        // Use specific interface if not loopback
        if networkInterface.ip != "0.0.0.0" {
            mreq.imr_interface.s_addr = inet_addr(networkInterface.ip)
        } else {
            mreq.imr_interface.s_addr = INADDR_ANY
        }

        let result = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
        if result < 0 {
            print("Failed to join multicast group \(group): \(errno)")
        } else {
            print("Joined multicast group \(group)")
        }
    }

    private func handleArtNet(data: Data) {
        // Spec: https://art-net.org.uk/
        guard data.count >= 18 else { return }
        let magic = "Art-Net\u{0}".utf8.map { $0 }
        for (idx, byte) in magic.enumerated() where data[idx] != byte { return }

        let opcode = UInt16(data[8]) | (UInt16(data[9]) << 8)
        let opDmx: UInt16 = 0x5000
        guard opcode == opDmx else { return }

        let length = Int(data[17]) | (Int(data[16]) << 8)
        guard length > 0, data.count >= 18 + length else { return }
        // Universe is little-endian, zero-based in Art-Net. Store also as 1-based for convenience.
        let artUniverseRaw = Int(UInt16(data[14]) | (UInt16(data[15]) << 8))
        let artUniverse = artUniverseRaw + 1
        let payload = Array(data[18..<(18 + length)])
        state.update(universe: artUniverse, dmx: payload)
        state.update(universe: artUniverseRaw, dmx: payload) // also store raw
    }

    private func handleSACN(data: Data) {
        // Minimal E1.31 DMX data packet parsing
        guard data.count >= 126 else { return }
        // ACN Packet Identifier "ASC-E1.17\0\0\0"
        let acnPID: [UInt8] = [0x41, 0x53, 0x43, 0x2d, 0x45, 0x31, 0x2e, 0x31, 0x37, 0x00, 0x00, 0x00]
        for i in 0..<acnPID.count where data[i + 4] != acnPID[i] { return }

        // Universe lives in framing layer at bytes 113-114 (0-based)
        let universeOffset = 113
        let universe = Int(UInt16(data[universeOffset]) << 8 | UInt16(data[universeOffset + 1]))
        guard universe > 0 else { return }

        // DMX data starts after DMP header; property value count is at bytes 123-124
        let propertyCount = Int(UInt16(data[123]) << 8 | UInt16(data[124]))
        let dmxStart = 125
        guard propertyCount > 0, dmxStart < data.count else { return }
        let available = min(propertyCount, data.count - dmxStart)
        guard available > 1 else { return } // includes start code
        let payload = Array(data[(dmxStart + 1)..<(dmxStart + available)]) // skip start code
        state.update(universe: universe, dmx: payload)
    }

    private func bindUDP(port: UInt16, joinMulticast: String?) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            print("Failed to create socket: \(errno)")
            return nil
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        // Enable broadcast for Art-Net
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian

        // For multicast (sACN), always bind to INADDR_ANY - interface is selected via IP_ADD_MEMBERSHIP
        // For unicast (Art-Net), can bind to specific interface
        if joinMulticast != nil {
            // Multicast requires binding to INADDR_ANY
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        } else if networkInterface.ip == "0.0.0.0" {
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        } else {
            addr.sin_addr.s_addr = inet_addr(networkInterface.ip)
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 {
            print("Bind failed on port \(port): \(errno) - \(String(cString: strerror(errno)))")
            close(fd)
            return nil
        }

        if let group = joinMulticast {
            var mreq = ip_mreq()
            mreq.imr_multiaddr.s_addr = inet_addr(group)
            // For multicast, bind interface specifically
            if networkInterface.ip == "0.0.0.0" {
                mreq.imr_interface.s_addr = INADDR_ANY
            } else {
                mreq.imr_interface.s_addr = inet_addr(networkInterface.ip)
            }
            let mcastResult = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
            if mcastResult != 0 {
                print("Multicast join failed for \(group): \(errno) - \(String(cString: strerror(errno)))")
                // Not fatal; continue without multicast
            } else {
                print("Joined multicast group \(group)")
            }
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return fd
    }

    private func listen(fd: Int32, handler: @escaping (Data) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let _ = self else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            let len = recv(fd, &buffer, buffer.count, 0)
            if len > 0 {
                handler(Data(buffer[0..<len]))
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        sources.append(source)
        source.resume()
    }
}

// MARK: - Rendering models

enum ShapeType: Int, CaseIterable {
    case line
    case circle
    case triangle
    case triangleStar
    case square
    case squareStar
    case pentagon
    case pentagonStar
    case hexagon
    case hexagonStar
    case septagon
    case septagonStar
}

// MARK: - Gobo System

struct GoboDefinition {
    let id: Int
    let name: String
    let category: GoboCategory
    let filename: String  // e.g., "gobo_051_leaves_sparse.png"
}

enum GoboCategory: String, CaseIterable {
    case breakups = "Breakups"
    case geometric = "Geometric"
    case nature = "Nature"
    case cosmic = "Cosmic"
    case textures = "Textures"
    case architectural = "Architectural"
    case abstract = "Abstract"
    case special = "Special"
}

// MARK: - Media Slot System (201-255)
// All 55 slots can be assigned to any video file or NDI source

/// Media source types that can be assigned to any slot 201-255
enum MediaSourceType: Codable, Equatable {
    case video(path: String)         // Video file path
    case ndi(sourceName: String)     // NDI source by name
    case image(path: String)         // Static image file path (PNG, JPG, etc.)
    case none                        // Unassigned

    var displayName: String {
        switch self {
        case .video(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .ndi(let name):
            return "NDI: \(name)"
        case .image(let path):
            return "IMG: \(URL(fileURLWithPath: path).lastPathComponent)"
        case .none:
            return "Empty"
        }
    }

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }

    var isNDI: Bool {
        if case .ndi = self { return true }
        return false
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

/// Configuration manager for media slot assignments
/// Allows any slot 201-255 to be assigned to video files or NDI sources
@MainActor
final class MediaSlotConfig: ObservableObject {
    static let shared = MediaSlotConfig()

    /// Slot assignments: DMX value (201-255) -> source type
    @Published private(set) var assignments: [Int: MediaSourceType] = [:]

    /// Available NDI sources (refreshed periodically)
    @Published private(set) var availableNDISources: [String] = []

    private let configPath: URL

    private init() {
        // Config file location
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let mediaPath = documentsPath.appendingPathComponent("DMXMedia")
        try? FileManager.default.createDirectory(at: mediaPath, withIntermediateDirectories: true)
        configPath = mediaPath.appendingPathComponent("slot_config.json")

        // Load saved config
        loadConfig()
    }

    /// Assign a video file to a slot
    func assignVideo(path: String, toSlot slot: Int) {
        guard slot >= 201 && slot <= 255 else { return }
        assignments[slot] = .video(path: path)
        saveConfig()
        print("MediaSlotConfig: Slot \(slot) assigned to '\(URL(fileURLWithPath: path).lastPathComponent)'")
    }

    /// Assign an NDI source to a slot
    func assignNDI(sourceName: String, toSlot slot: Int) {
        guard slot >= 201 && slot <= 255 else { return }
        assignments[slot] = .ndi(sourceName: sourceName)
        saveConfig()
        print("MediaSlotConfig: Slot \(slot) assigned to NDI '\(sourceName)'")
    }

    /// Assign a static image to a slot
    func assignImage(path: String, toSlot slot: Int) {
        guard slot >= 201 && slot <= 255 else { return }
        assignments[slot] = .image(path: path)
        saveConfig()
        print("MediaSlotConfig: Slot \(slot) assigned to image '\(URL(fileURLWithPath: path).lastPathComponent)'")
    }

    /// Clear assignment for a slot
    func clearSlot(_ slot: Int) {
        guard slot >= 201 && slot <= 255 else { return }
        assignments.removeValue(forKey: slot)
        saveConfig()
        print("MediaSlotConfig: Slot \(slot) cleared")
    }

    /// Get the source assigned to a slot
    func getSource(forSlot slot: Int) -> MediaSourceType {
        return assignments[slot] ?? .none
    }

    /// Refresh available NDI sources
    func refreshNDISources() {
        NDISourceManager.shared.refreshSources()
        availableNDISources = NDISourceManager.shared.availableSources.map { $0.name }
        print("MediaSlotConfig: Found \(availableNDISources.count) NDI sources")
    }

    private func loadConfig() {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            print("MediaSlotConfig: No config file, starting empty")
            return
        }

        do {
            let data = try Data(contentsOf: configPath)
            let decoded = try JSONDecoder().decode([String: MediaSourceType].self, from: data)
            assignments = [:]
            for (key, value) in decoded {
                if let slot = Int(key) {
                    assignments[slot] = value
                }
            }
            print("MediaSlotConfig: Loaded \(assignments.count) slot assignments")
        } catch {
            print("MediaSlotConfig: Failed to load config - \(error)")
        }
    }

    private func saveConfig() {
        var stringKeyed: [String: MediaSourceType] = [:]
        for (key, value) in assignments {
            stringKeyed[String(key)] = value
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(stringKeyed)
            try data.write(to: configPath)
        } catch {
            print("MediaSlotConfig: Failed to save config - \(error)")
        }
    }
}

// MARK: - Media Slot Configuration Window

struct MediaSlotConfigView: View {
    @ObservedObject var config = MediaSlotConfig.shared
    @State private var selectedSlot: Int = 201
    @State private var showingFilePicker = false
    @State private var showingNDIPicker = false

    var body: some View {
        HSplitView {
            // Left: Slot list
            VStack(alignment: .leading, spacing: 0) {
                Text("Media Slots (201-255)")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(201...255, id: \.self) { slot in
                            SlotRowView(
                                slot: slot,
                                source: config.getSource(forSlot: slot),
                                isSelected: selectedSlot == slot
                            )
                            .onTapGesture { selectedSlot = slot }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .frame(minWidth: 250, maxWidth: 300)
            .background(Color(NSColor.controlBackgroundColor))

            // Right: Selected slot details
            VStack(spacing: 20) {
                Text("Slot \(selectedSlot)")
                    .font(.title)
                    .fontWeight(.bold)

                let source = config.getSource(forSlot: selectedSlot)

                // Current assignment
                GroupBox("Current Assignment") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            switch source {
                            case .video(let path):
                                Image(systemName: "film")
                                    .foregroundColor(.blue)
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                            case .image(let path):
                                Image(systemName: "photo")
                                    .foregroundColor(.purple)
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                            case .ndi(let name):
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundColor(.green)
                                Text(name)
                            case .none:
                                Image(systemName: "questionmark.circle")
                                    .foregroundColor(.gray)
                                Text("Not assigned")
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .font(.system(size: 14))
                        .padding(8)
                    }
                }

                // Actions
                GroupBox("Assign Source") {
                    VStack(spacing: 12) {
                        // Video file
                        HStack {
                            Button(action: { showingFilePicker = true }) {
                                HStack {
                                    Image(systemName: "film")
                                    Text("Browse Video File...")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        // NDI source
                        HStack {
                            Button(action: {
                                config.refreshNDISources()
                                showingNDIPicker = true
                            }) {
                                HStack {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text("Select NDI Source...")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        Divider()

                        // Clear
                        Button(action: { config.clearSlot(selectedSlot) }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Clear Slot")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(source == .none)
                    }
                    .padding(8)
                }

                // Drop zone
                GroupBox("Drag & Drop") {
                    DropZoneView(slot: selectedSlot)
                        .frame(height: 100)
                }

                Spacer()
            }
            .padding(20)
            .frame(minWidth: 300)
        }
        .frame(minWidth: 600, minHeight: 500)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                // Start accessing the security-scoped resource
                if url.startAccessingSecurityScopedResource() {
                    config.assignVideo(path: url.path, toSlot: selectedSlot)
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }
        .sheet(isPresented: $showingNDIPicker) {
            NDIPickerView(slot: selectedSlot, isPresented: $showingNDIPicker)
        }
    }
}

struct SlotRowView: View {
    let slot: Int
    let source: MediaSourceType
    let isSelected: Bool

    var body: some View {
        HStack {
            Text("\(slot)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 35, alignment: .trailing)

            switch source {
            case .video:
                Image(systemName: "film.fill")
                    .foregroundColor(.blue)
                    .frame(width: 20)
            case .image:
                Image(systemName: "photo.fill")
                    .foregroundColor(.purple)
                    .frame(width: 20)
            case .ndi:
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.green)
                    .frame(width: 20)
            case .none:
                Image(systemName: "circle.dashed")
                    .foregroundColor(.gray.opacity(0.5))
                    .frame(width: 20)
            }

            Text(source.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(4)
    }
}

struct DropZoneView: View {
    let slot: Int
    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundColor(isTargeted ? .accentColor : .gray.opacity(0.5))
            .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
            .overlay(
                VStack {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 24))
                        .foregroundColor(isTargeted ? .accentColor : .gray)
                    Text("Drop video file here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv"]
                        if videoExtensions.contains(url.pathExtension.lowercased()) {
                            DispatchQueue.main.async {
                                MediaSlotConfig.shared.assignVideo(path: url.path, toSlot: slot)
                            }
                        }
                    }
                }
                return true
            }
    }
}

struct NDIPickerView: View {
    let slot: Int
    @Binding var isPresented: Bool
    @ObservedObject var config = MediaSlotConfig.shared
    @State private var selectedSource: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Select NDI Source")
                .font(.headline)

            if config.availableNDISources.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No NDI sources found")
                        .foregroundColor(.secondary)
                    Button("Refresh") {
                        config.refreshNDISources()
                    }
                }
                .frame(height: 150)
            } else {
                List(config.availableNDISources, id: \.self, selection: $selectedSource) { source in
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.green)
                        Text(source)
                    }
                    .tag(source)
                }
                .frame(height: 200)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Refresh Sources") {
                    config.refreshNDISources()
                }

                Button("Assign") {
                    if let source = selectedSource {
                        config.assignNDI(sourceName: source, toSlot: slot)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSource == nil)
            }
        }
        .padding(20)
        .frame(width: 400, height: 320)
        .onAppear {
            config.refreshNDISources()
        }
    }
}

// MARK: - Media Slot Config Window Controller

class MediaSlotConfigWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 550),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "◈ MEDIA SLOT CONFIGURATION ◈"
        RetroTheme.styleWindow(window)
        window.contentView = NSHostingView(rootView: MediaSlotConfigView())
        window.center()
        self.init(window: window)
    }
}

@MainActor
var mediaSlotConfigWindow: MediaSlotConfigWindowController?

@MainActor
func showMediaSlotConfig() {
    if mediaSlotConfigWindow == nil {
        mediaSlotConfigWindow = MediaSlotConfigWindowController()
    }
    mediaSlotConfigWindow?.showWindow(nil)
    mediaSlotConfigWindow?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

enum VideoPlaybackState: Int {
    case stop = 0           // 0: Output black
    case pause = 1          // 1-10: Freeze current frame
    case play = 11          // 11-40: Normal playback
    case playHold = 41      // 41-55: Play once, freeze last frame
    case playLoop = 56      // 56-70: Loop at end
    case playBounce = 71    // 71-85: Ping-pong playback
    case reverse = 86       // 86-100: Play backwards
    case restart = 101      // 101-115: Jump to start + play
    case gotoPosition = 116 // 116-235: Scrub position (0-100%)

    static func from(dmxValue: UInt8) -> (state: VideoPlaybackState, gotoPercent: Float?) {
        switch dmxValue {
        case 0:
            return (.stop, nil)
        case 1...10:
            return (.pause, nil)
        case 11...40:
            return (.play, nil)
        case 41...55:
            return (.playHold, nil)
        case 56...70:
            return (.playLoop, nil)
        case 71...85:
            return (.playBounce, nil)
        case 86...100:
            return (.reverse, nil)
        case 101...115:
            return (.restart, nil)
        case 116...235:
            // 116 = 0%, 235 = 100% (120 steps)
            let percent = Float(dmxValue - 116) / 119.0 * 100.0
            return (.gotoPosition, percent)
        default:
            return (.stop, nil) // Reserved values default to stop
        }
    }
}

// MARK: - Video Player

final class VideoPlayer {
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var currentURL: URL?
    private var isLooping: Bool = false
    private var isBouncing: Bool = false
    private var isReversed: Bool = false
    private var didReachEnd: Bool = false
    private var bounceDirection: Float = 1.0

    // Double buffering for smooth playback
    private var displayBuffer: CVPixelBuffer?   // Frame ready for display
    private var pendingBuffer: CVPixelBuffer?   // Frame being prepared
    private let bufferLock = NSLock()
    private var decodeQueue: DispatchQueue
    private var isDecoding: Bool = false
    private var shouldDecode: Bool = false

    private let videoOutputSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    init() {
        decodeQueue = DispatchQueue(label: "com.dmx.videodecode", qos: .userInteractive)
    }

    func load(url: URL) {
        guard url != currentURL else { return }

        // Clean up previous player
        stop()

        currentURL = url
        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)

        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: videoOutputSettings)
        playerItem?.add(videoOutput!)

        player = AVPlayer(playerItem: playerItem)
        player?.actionAtItemEnd = .pause

        // Add observer for end of playback
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        // Start background decode loop
        shouldDecode = true
        startDecodeLoop()

        print("VideoPlayer: Loaded \(url.lastPathComponent)")
    }

    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        didReachEnd = true
        if isLooping {
            player?.seek(to: .zero)
            player?.play()
            didReachEnd = false
        } else if isBouncing {
            // Reverse direction
            bounceDirection = -bounceDirection
            if bounceDirection < 0 {
                // Play backwards - need to seek to just before end and step back
                player?.seek(to: .zero)
            }
            player?.play()
            didReachEnd = false
        }
    }

    func setVolume(_ volume: Float) {
        player?.volume = max(0, min(1, volume))
    }

    func applyState(_ state: VideoPlaybackState, gotoPercent: Float? = nil) {
        guard let player = player, let item = playerItem else { return }

        isLooping = false
        isBouncing = false
        isReversed = false

        switch state {
        case .stop:
            player.volume = 0  // Mute immediately on stop
            player.pause()
            player.seek(to: .zero)

        case .pause:
            player.pause()

        case .play:
            player.rate = 1.0
            if didReachEnd {
                player.seek(to: .zero)
                didReachEnd = false
            }
            player.play()

        case .playHold:
            // Play once, stay on last frame when done
            player.rate = 1.0
            if didReachEnd {
                // Already at end, stay there
            } else {
                player.play()
            }

        case .playLoop:
            isLooping = true
            player.rate = 1.0
            player.play()

        case .playBounce:
            isBouncing = true
            bounceDirection = 1.0
            player.rate = 1.0
            player.play()

        case .reverse:
            isReversed = true
            player.rate = -1.0
            player.play()

        case .restart:
            didReachEnd = false
            player.seek(to: .zero)
            player.rate = 1.0
            player.play()

        case .gotoPosition:
            if let percent = gotoPercent {
                let duration = item.duration
                if duration.isNumeric {
                    let targetTime = CMTime(
                        seconds: duration.seconds * Double(percent / 100.0),
                        preferredTimescale: duration.timescale
                    )
                    player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    player.pause()
                }
            }
        }
    }

    func getCurrentFrame() -> CVPixelBuffer? {
        // Return the display buffer (thread-safe read)
        bufferLock.lock()
        let frame = displayBuffer
        bufferLock.unlock()
        return frame
    }

    /// Background decode loop - continuously decodes frames ahead of display
    private func startDecodeLoop() {
        guard !isDecoding else { return }
        isDecoding = true

        decodeQueue.async { [weak self] in
            while let self = self, self.shouldDecode {
                guard let videoOutput = self.videoOutput,
                      let player = self.player else {
                    Thread.sleep(forTimeInterval: 0.001)
                    continue
                }

                let currentTime = player.currentTime()
                if videoOutput.hasNewPixelBuffer(forItemTime: currentTime) {
                    if let newBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) {
                        // Swap buffers atomically
                        self.bufferLock.lock()
                        self.pendingBuffer = self.displayBuffer
                        self.displayBuffer = newBuffer
                        self.bufferLock.unlock()
                    }
                }

                // Small sleep to prevent busy-waiting (~120Hz check rate)
                Thread.sleep(forTimeInterval: 0.008)
            }
            self?.isDecoding = false
        }
    }

    func stop() {
        shouldDecode = false  // Stop decode loop
        player?.pause()
        player = nil
        if let item = playerItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: item)
        }
        playerItem = nil
        bufferLock.lock()
        displayBuffer = nil
        pendingBuffer = nil
        bufferLock.unlock()
        videoOutput = nil
        currentURL = nil
        didReachEnd = false
    }

    deinit {
        stop()
    }
}

// MARK: - Video Slot Manager

@MainActor
final class VideoSlotManager {
    static let shared = VideoSlotManager()

    private var videoPlayers: [String: VideoPlayer] = [:]  // Keyed by file path
    private var textureCache: CVMetalTextureCache?
    private var device: MTLDevice?
    private var lastTextures: [String: MTLTexture] = [:]  // Cache last valid texture per path
    private var imageTextures: [String: MTLTexture] = [:]  // Cache static image textures

    // Frame-level caching: texture created once per frame per slot, shared across all fixtures
    private var currentFrameId: UInt64 = 0
    private var frameTextureCache: [Int: (frameId: UInt64, texture: MTLTexture)] = [:]  // Keyed by slot
    private var framePlaybackUpdated: Set<Int> = []  // Track which slots had playback updated this frame

    // Track last applied state per slot to avoid re-applying same state every frame
    private var lastAppliedState: [Int: (state: VideoPlaybackState, gotoPercent: Float?, volume: Float)] = [:]

    private init() {
        print("VideoSlotManager: Initialized")
    }

    func setup(device: MTLDevice) {
        self.device = device
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache

        // Initialize NDI source manager with Metal device
        NDISourceManager.shared.setDevice(device)
    }

    /// Call at the start of each render frame to reset per-frame caches
    func beginFrame() {
        currentFrameId &+= 1
        framePlaybackUpdated.removeAll()
        pendingSlotStates.removeAll()

        // Periodically clean up unused video players (every ~60 frames)
        if currentFrameId % 60 == 0 {
            cleanupUnusedPlayers()
        }
    }

    /// Stop and remove video players that are no longer assigned to any slot
    private func cleanupUnusedPlayers() {
        // Get all video paths currently in use
        var usedPaths = Set<String>()
        for slot in 201...255 {
            let source = MediaSlotConfig.shared.getSource(forSlot: slot)
            if case .video(let path) = source {
                usedPaths.insert(path)
            }
        }

        // Find and remove unused players
        let allPaths = Array(videoPlayers.keys)
        for path in allPaths {
            if !usedPaths.contains(path) {
                if let player = videoPlayers.removeValue(forKey: path) {
                    player.stop()
                    print("VideoSlotManager: Stopped unused player for \(URL(fileURLWithPath: path).lastPathComponent)")
                }
                lastTextures.removeValue(forKey: path)
            }
        }
    }

    // Collect video states from all objects, then apply the "most active" per slot
    private var pendingSlotStates: [Int: (state: VideoPlaybackState, gotoPercent: Float?, volume: Float)] = [:]

    /// Collect playback state from a fixture - called for each video fixture before rendering
    func collectPlaybackState(forSlot slotIndex: Int, state: VideoPlaybackState, gotoPercent: Float?, volume: Float) {
        guard slotIndex >= 201 && slotIndex <= 255 else { return }

        // Priority: play states > pause > stop
        // Higher state values generally mean more "active" playback
        if let existing = pendingSlotStates[slotIndex] {
            // Keep the more "active" state (play > pause > stop)
            let existingPriority = playbackPriority(existing.state)
            let newPriority = playbackPriority(state)
            if newPriority > existingPriority {
                pendingSlotStates[slotIndex] = (state, gotoPercent, max(existing.volume, volume))
            } else if newPriority == existingPriority {
                // Same priority - average volume
                pendingSlotStates[slotIndex] = (existing.state, existing.gotoPercent, max(existing.volume, volume))
            }
        } else {
            pendingSlotStates[slotIndex] = (state, gotoPercent, volume)
        }
    }

    /// Apply all collected states - called once after collecting all fixture states
    func applyCollectedStates() {
        for (slotIndex, pending) in pendingSlotStates {
            applyPlaybackState(forSlot: slotIndex, state: pending.state, gotoPercent: pending.gotoPercent, volume: pending.volume)
        }
    }

    private func playbackPriority(_ state: VideoPlaybackState) -> Int {
        switch state {
        case .stop: return 0
        case .pause: return 1
        case .play, .playHold, .playLoop, .playBounce, .reverse, .restart: return 2
        case .gotoPosition: return 1  // Scrub is like pause
        }
    }

    private func applyPlaybackState(forSlot slotIndex: Int, state: VideoPlaybackState, gotoPercent: Float?, volume: Float) {
        // Only apply once per frame
        if framePlaybackUpdated.contains(slotIndex) {
            return
        }
        framePlaybackUpdated.insert(slotIndex)

        let source = MediaSlotConfig.shared.getSource(forSlot: slotIndex)

        switch source {
        case .video(let path):
            let last = lastAppliedState[slotIndex]
            let stateChanged = last == nil ||
                               last!.state != state ||
                               last!.gotoPercent != gotoPercent
            let volumeChanged = last == nil || abs(last!.volume - volume) > 0.01

            let player = getVideoPlayer(forPath: path)

            if volumeChanged {
                player.setVolume(volume)
            }

            if stateChanged {
                player.applyState(state, gotoPercent: gotoPercent)
                lastAppliedState[slotIndex] = (state, gotoPercent, volume)
            } else if volumeChanged {
                lastAppliedState[slotIndex] = (state, gotoPercent, volume)
            }

        case .ndi, .image, .none:
            // NDI and images don't need playback control
            // But if there was a previous video on this slot, stop it
            if let lastState = lastAppliedState[slotIndex] {
                // Slot changed from video to something else - clear state
                lastAppliedState.removeValue(forKey: slotIndex)
            }
            break
        }
    }

    /// Stop a specific video player by path and mute it immediately
    func stopVideoPlayer(forPath path: String) {
        if let player = videoPlayers[path] {
            player.setVolume(0)  // Mute immediately
            player.stop()
        }
        videoPlayers.removeValue(forKey: path)
        lastTextures.removeValue(forKey: path)
    }

    /// Get or create video player for a file path
    func getVideoPlayer(forPath path: String) -> VideoPlayer {
        if let existing = videoPlayers[path] {
            return existing
        }

        let player = VideoPlayer()
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            player.load(url: url)
        }
        videoPlayers[path] = player
        return player
    }

    /// Get texture for a media slot (201-255) based on its configured source
    func getTexture(forSlot slotIndex: Int) -> MTLTexture? {
        guard let device = device, let cache = textureCache else { return nil }
        guard slotIndex >= 201 && slotIndex <= 255 else { return nil }

        // Check frame cache first
        if let cached = frameTextureCache[slotIndex], cached.frameId == currentFrameId {
            return cached.texture
        }

        // Look up what source is assigned to this slot
        let source = MediaSlotConfig.shared.getSource(forSlot: slotIndex)

        switch source {
        case .video(let path):
            // Get video player for this file
            let player = getVideoPlayer(forPath: path)
            if let pixelBuffer = player.getCurrentFrame() {
                if let texture = createTexture(from: pixelBuffer, cache: cache, device: device) {
                    lastTextures[path] = texture
                    frameTextureCache[slotIndex] = (currentFrameId, texture)
                    return texture
                }
            }
            // Return cached texture if no new frame available
            if let lastTexture = lastTextures[path] {
                frameTextureCache[slotIndex] = (currentFrameId, lastTexture)
                return lastTexture
            }
            return nil

        case .ndi(let sourceName):
            // Get NDI texture by source name
            if let texture = NDISourceManager.shared.getTexture(forSourceName: sourceName) {
                frameTextureCache[slotIndex] = (currentFrameId, texture)
                return texture
            }
            return nil

        case .image(let path):
            // Get static image texture (cached)
            if let texture = getImageTexture(forPath: path) {
                frameTextureCache[slotIndex] = (currentFrameId, texture)
                return texture
            }
            return nil

        case .none:
            // Slot not configured
            return nil
        }
    }

    /// Load and cache a static image as a Metal texture
    private func getImageTexture(forPath path: String) -> MTLTexture? {
        // Return cached texture if exists
        if let cached = imageTextures[path] {
            return cached
        }

        guard let device = device else { return nil }

        // Load image from disk
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            print("VideoSlotManager: Failed to load image: \(path)")
            return nil
        }

        // Create Metal texture from CGImage
        let width = cgImage.width
        let height = cgImage.height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            print("VideoSlotManager: Failed to create texture for image: \(path)")
            return nil
        }

        // Convert CGImage to BGRA pixel data
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            print("VideoSlotManager: Failed to create CGContext for image: \(path)")
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Upload to Metal texture
        texture.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0,
            withBytes: pixelData,
            bytesPerRow: bytesPerRow
        )

        // Cache the texture
        imageTextures[path] = texture
        print("VideoSlotManager: Loaded image texture \(width)x\(height) from \(URL(fileURLWithPath: path).lastPathComponent)")

        return texture
    }

    func updatePlaybackState(forSlot slotIndex: Int, state: VideoPlaybackState, gotoPercent: Float?, volume: Float = 1.0) {
        guard slotIndex >= 201 && slotIndex <= 255 else { return }

        // Only update playback state once per frame per slot
        if framePlaybackUpdated.contains(slotIndex) {
            return
        }
        framePlaybackUpdated.insert(slotIndex)

        // Look up what source is assigned to this slot
        let source = MediaSlotConfig.shared.getSource(forSlot: slotIndex)

        switch source {
        case .video(let path):
            // Check if state actually changed
            let last = lastAppliedState[slotIndex]
            let stateChanged = last == nil ||
                               last!.state != state ||
                               last!.gotoPercent != gotoPercent
            let volumeChanged = last == nil || abs(last!.volume - volume) > 0.01

            let player = getVideoPlayer(forPath: path)

            // Always update volume if changed
            if volumeChanged {
                player.setVolume(volume)
            }

            // Only apply playback state if changed
            if stateChanged {
                player.applyState(state, gotoPercent: gotoPercent)
                lastAppliedState[slotIndex] = (state, gotoPercent, volume)
            } else if volumeChanged {
                lastAppliedState[slotIndex] = (state, gotoPercent, volume)
            }

        case .ndi, .image, .none:
            // NDI sources and static images don't have playback state
            break
        }
    }

    private func createTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache, device: MTLDevice) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard result == kCVReturnSuccess, let cvTex = cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }
}

@MainActor
final class GoboLibrary {
    static let shared = GoboLibrary()

    private var goboImages: [Int: CGImage] = [:]
    private let definitions: [Int: GoboDefinition]

    private init() {
        var defs: [Int: GoboDefinition] = [:]

        // Custom User Slots (21-50)
        for i in 21...50 {
            let name = "Custom \(i)"
            let filename = "gobo_\(String(format: "%03d", i)).png"
            defs[i] = GoboDefinition(id: i, name: name, category: .special, filename: filename)
        }

        // Breakups (51-70)
        let breakups: [(Int, String)] = [
            (51, "Leaves Sparse"), (52, "Leaves Dense"), (53, "Branches"), (54, "Branches Dense"),
            (55, "Cloud Soft"), (56, "Cloud Heavy"), (57, "Water Ripple"), (58, "Water Caustics"),
            (59, "Dappled Light"), (60, "Forest Floor"), (61, "Bamboo"), (62, "Fern"),
            (63, "Oak Leaves"), (64, "Maple Leaves"), (65, "Pine Needles"), (66, "Ivy"),
            (67, "Grass"), (68, "Raindrops"), (69, "Snowflakes"), (70, "Ice Crystals")
        ]
        for (id, name) in breakups {
            let filename = "gobo_\(String(format: "%03d", id))_\(name.lowercased().replacingOccurrences(of: " ", with: "_")).png"
            defs[id] = GoboDefinition(id: id, name: name, category: .breakups, filename: filename)
        }

        // Geometric (71-90)
        let geometric: [(Int, String)] = [
            (71, "Triangle Grid"), (72, "Triangle Scatter"), (73, "Circle Grid"), (74, "Circle Scatter"),
            (75, "Square Grid"), (76, "Square Scatter"), (77, "Hexagon Grid"), (78, "Hexagon Scatter"),
            (79, "Diamond Grid"), (80, "Diamond Scatter"), (81, "Confetti"), (82, "Mod Confetti"),
            (83, "Polka Dots"), (84, "Stripes Vertical"), (85, "Stripes Horizontal"), (86, "Stripes Diagonal"),
            (87, "Checkerboard"), (88, "Chevron"), (89, "Zigzag"), (90, "Crosshatch")
        ]
        for (id, name) in geometric {
            let filename = "gobo_\(String(format: "%03d", id))_\(name.lowercased().replacingOccurrences(of: " ", with: "_")).png"
            defs[id] = GoboDefinition(id: id, name: name, category: .geometric, filename: filename)
        }

        // Nature (91-110)
        let nature: [(Int, String)] = [
            (91, "Palm Leaves"), (92, "Palm Fronds"), (93, "Tropical Leaves"), (94, "Monstera"),
            (95, "Sand Texture"), (96, "Sand Dunes"), (97, "Lava Flow"), (98, "Lava Cracks"),
            (99, "Rock Texture"), (100, "Stone Wall"), (101, "Wood Grain"), (102, "Bark"),
            (103, "Coral"), (104, "Seaweed"), (105, "Flames"), (106, "Fire Flicker"),
            (107, "Smoke"), (108, "Fog"), (109, "Lightning"), (110, "Aurora")
        ]
        for (id, name) in nature {
            let filename = "gobo_\(String(format: "%03d", id))_\(name.lowercased().replacingOccurrences(of: " ", with: "_")).png"
            defs[id] = GoboDefinition(id: id, name: name, category: .nature, filename: filename)
        }

        // Cosmic (111-130)
        let cosmic: [(Int, String)] = [
            (111, "Galaxy Spiral"), (112, "Galaxy Cluster"), (113, "Nebula 1"), (114, "Nebula 2"),
            (115, "Nebula 3"), (116, "Star Field Sparse"), (117, "Star Field Dense"), (118, "Star Cluster"),
            (119, "Comet"), (120, "Meteor Shower"), (121, "Planet Ring"), (122, "Jupiter"),
            (123, "Moon Surface"), (124, "Sun Flare"), (125, "Solar Eclipse"), (126, "Black Hole"),
            (127, "Wormhole"), (128, "Space Dust"), (129, "Asteroid Field"), (130, "Supernova")
        ]
        for (id, name) in cosmic {
            let filename = "gobo_\(String(format: "%03d", id))_\(name.lowercased().replacingOccurrences(of: " ", with: "_")).png"
            defs[id] = GoboDefinition(id: id, name: name, category: .cosmic, filename: filename)
        }

        // Textures (131-150)
        let textures: [(Int, String)] = [
            (131, "Shredded Water"), (132, "Shredded Earth"), (133, "Shredded Fire"), (134, "Paint Mix"),
            (135, "Paint Splatter"), (136, "Ink Blot"), (137, "Swirls"), (138, "Curls"),
            (139, "Noise Fine"), (140, "Noise Coarse"), (141, "Perlin Noise"), (142, "Fractal 1"),
            (143, "Fractal 2"), (144, "Marble"), (145, "Granite"), (146, "Rust"),
            (147, "Patina"), (148, "Grunge"), (149, "Distressed"), (150, "Cracked")
        ]
        for (id, name) in textures {
            let filename = "gobo_\(String(format: "%03d", id))_\(name.lowercased().replacingOccurrences(of: " ", with: "_")).png"
            defs[id] = GoboDefinition(id: id, name: name, category: .textures, filename: filename)
        }

        // Architectural (151-170)
        let architectural: [(Int, String)] = [
            (151, "Window Single"), (152, "Window Grid"), (153, "Window Gothic"), (154, "Window Church"),
            (155, "Blinds Horizontal"), (156, "Blinds Vertical"), (157, "Blinds Angled"), (158, "Bars Vertical"),
            (159, "Bars Horizontal"), (160, "Prison Bars"), (161, "Gate Ornate"), (162, "Gate Iron"),
            (163, "Fence Chain Link"), (164, "Fence Picket"), (165, "Brick Wall"), (166, "Tile Floor"),
            (167, "Staircase"), (168, "Columns"), (169, "Arches"), (170, "Skylight")
        ]
        for (id, name) in architectural {
            let filename = "gobo_\(String(format: "%03d", id))_\(name.lowercased().replacingOccurrences(of: " ", with: "_")).png"
            defs[id] = GoboDefinition(id: id, name: name, category: .architectural, filename: filename)
        }

        // Abstract (171-190)
        let abstract: [(Int, String)] = [
            (171, "Organic Blob 1"), (172, "Organic Blob 2"), (173, "Organic Blob 3"), (174, "Splatter 1"),
            (175, "Splatter 2"), (176, "Splatter 3"), (177, "Gradient Radial"), (178, "Gradient Linear"),
            (179, "Gradient Angular"), (180, "Vignette Soft"), (181, "Vignette Hard"), (182, "Spotlight"),
            (183, "Beam Single"), (184, "Beam Array"), (185, "Rays Radial"), (186, "Rays Burst"),
            (187, "Waves"), (188, "Ripples"), (189, "Interference"), (190, "Moire")
        ]
        for (id, name) in abstract {
            let filename = "gobo_\(String(format: "%03d", id))_\(name.lowercased().replacingOccurrences(of: " ", with: "_")).png"
            defs[id] = GoboDefinition(id: id, name: name, category: .abstract, filename: filename)
        }

        // Special/Custom (191-200)
        for i in 191...200 {
            let name = "Custom \(i - 190)"
            let filename = "gobo_\(String(format: "%03d", i))_custom_\(i - 190).png"
            defs[i] = GoboDefinition(id: i, name: name, category: .special, filename: filename)
        }

        self.definitions = defs
    }

    func definition(for id: Int) -> GoboDefinition? {
        return definitions[id]
    }

    /// Gobo search folders (portable paths)
    private let goboFolders: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GeoDraw/gobos"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GoboCreator/Library")
    ]

    func image(for id: Int) -> CGImage? {
        if let cached = goboImages[id] {
            return cached
        }

        guard let def = definitions[id] else { return nil }

        // Try to load from Resources folder
        let bundle = Bundle.main
        if let url = bundle.url(forResource: def.filename.replacingOccurrences(of: ".png", with: ""), withExtension: "png", subdirectory: "gobos"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            goboImages[id] = image
            return image
        }

        // Try loading from watched gobo folders (project gobos + GoboCreator Library)
        for folder in goboFolders {
            let fileURL = folder.appendingPathComponent(def.filename)
            if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                goboImages[id] = image
                return image
            }
        }

        // Fallback: try loading by slot number only (for gobos without names)
        let slotFilename = "gobo_\(String(format: "%03d", id)).png"
        for folder in goboFolders {
            let slotURL = folder.appendingPathComponent(slotFilename)
            if let source = CGImageSourceCreateWithURL(slotURL as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                goboImages[id] = image
                return image
            }
        }

        return nil
    }

    /// Clear cached gobo images and scan all gobo folders for files
    func refreshGobos() {
        goboImages.removeAll()
        var foundCount = 0

        NSLog("GoboLibrary: Refreshing gobos from %d folders...", goboFolders.count)

        for folder in goboFolders {
            guard FileManager.default.fileExists(atPath: folder.path) else {
                NSLog("GoboLibrary: Folder not found: %@", folder.path)
                continue
            }
            NSLog("GoboLibrary: Scanning folder: %@", folder.path)

            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                continue
            }

            for file in files where file.pathExtension == "png" {
                let filename = file.lastPathComponent

                // Try pattern 1: gobo_XXX_name.png (3-digit slot number)
                let slotPattern = #"gobo_(\d{3})"#
                if let regex = try? NSRegularExpression(pattern: slotPattern),
                   let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
                   let range = Range(match.range(at: 1), in: filename),
                   let goboId = Int(filename[range]) {

                    if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                       let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                        goboImages[goboId] = image
                        foundCount += 1
                    }
                    continue
                }

                // Try pattern 2: gobo_XXXXXXXX.png (GoboCreator hex ID)
                // Assign to next available slot starting from 100
                let hexPattern = #"gobo_([0-9A-Fa-f]{8})\.png"#
                if let regex = try? NSRegularExpression(pattern: hexPattern),
                   regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) != nil {

                    // Find next available slot (100-200)
                    var assignedSlot: Int? = nil
                    for slot in 100...200 {
                        if goboImages[slot] == nil {
                            assignedSlot = slot
                            break
                        }
                    }

                    if let slot = assignedSlot,
                       let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                       let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                        goboImages[slot] = image
                        foundCount += 1
                        NSLog("GoboLibrary: Assigned GoboCreator file %@ to slot %d", filename, slot)
                    }
                }
            }
        }

        NSLog("GoboLibrary: Loaded %d gobos into cache", foundCount)

        // Notify that gobos were refreshed so textures can be reloaded
        NotificationCenter.default.post(name: .goboFileChanged, object: nil, userInfo: ["refresh": true])
    }

    func generatePlaceholder(for id: Int, size: CGFloat = 256) -> CGImage? {
        guard let def = definitions[id] else { return nil }

        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        guard let ctx = CGContext(
            data: nil,
            width: Int(size),
            height: Int(size),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Generate procedural pattern based on category
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(rect)

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

        switch def.category {
        case .breakups:
            // Random organic shapes
            for _ in 0..<20 {
                let x = CGFloat.random(in: 0...size)
                let y = CGFloat.random(in: 0...size)
                let r = CGFloat.random(in: 10...40)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        case .geometric:
            // Grid pattern
            let spacing = size / 8
            for row in 0..<8 {
                for col in 0..<8 {
                    if (row + col) % 2 == 0 {
                        ctx.fill(CGRect(x: CGFloat(col) * spacing, y: CGFloat(row) * spacing, width: spacing, height: spacing))
                    }
                }
            }
        case .nature:
            // Wavy lines
            for i in 0..<10 {
                let y = size * CGFloat(i) / 10
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: y))
                for x in stride(from: 0, to: size, by: 10) {
                    let waveY = y + sin(x / 20) * 10
                    path.addLine(to: CGPoint(x: x, y: waveY))
                }
                ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.setLineWidth(2)
                ctx.addPath(path)
                ctx.strokePath()
            }
        case .cosmic:
            // Stars / dots
            for _ in 0..<50 {
                let x = CGFloat.random(in: 0...size)
                let y = CGFloat.random(in: 0...size)
                let r = CGFloat.random(in: 1...5)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        case .textures:
            // Noise-like pattern
            for _ in 0..<100 {
                let x = CGFloat.random(in: 0...size)
                let y = CGFloat.random(in: 0...size)
                let w = CGFloat.random(in: 5...20)
                let h = CGFloat.random(in: 5...20)
                ctx.fill(CGRect(x: x, y: y, width: w, height: h))
            }
        case .architectural:
            // Window/grid pattern
            let spacing = size / 4
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(4)
            for i in 0...4 {
                ctx.move(to: CGPoint(x: CGFloat(i) * spacing, y: 0))
                ctx.addLine(to: CGPoint(x: CGFloat(i) * spacing, y: size))
                ctx.move(to: CGPoint(x: 0, y: CGFloat(i) * spacing))
                ctx.addLine(to: CGPoint(x: size, y: CGFloat(i) * spacing))
            }
            ctx.strokePath()
        case .abstract:
            // Radial gradient simulation
            let center = CGPoint(x: size / 2, y: size / 2)
            for r in stride(from: size / 2, to: 0, by: -10) {
                let alpha = 1.0 - (r / (size / 2))
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
                ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
        case .special:
            // Simple "C" for custom
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size * 0.6, nil)
            let text = "C\(id - 190)" as CFString
            let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)] as CFDictionary
            let attrString = CFAttributedStringCreate(nil, text, attributes)!
            let line = CTLineCreateWithAttributedString(attrString)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2)
            CTLineDraw(line, ctx)
        }

        return ctx.makeImage()
    }

    func getOrGenerateImage(for id: Int) -> CGImage? {
        if let img = image(for: id) {
            return img
        }
        // Generate and cache placeholder
        if let placeholder = generatePlaceholder(for: id) {
            goboImages[id] = placeholder
            return placeholder
        }
        return nil
    }

    /// Invalidate cached gobo image (called when file changes)
    func invalidateGobo(id: Int) {
        goboImages.removeValue(forKey: id)
        print("GoboLibrary: Invalidated cache for gobo \(id)")
    }

    /// Force reload a gobo from disk
    func reloadGobo(id: Int) -> CGImage? {
        invalidateGobo(id: id)
        return image(for: id)
    }

    var allDefinitions: [GoboDefinition] {
        return definitions.values.sorted { $0.id < $1.id }
    }
}

struct VisualObject {
    var mode: DMXMode = .full  // Per-fixture mode (33ch/23ch/10ch)
    var universe: Int = 1      // Fixed universe for this fixture
    var address: Int = 1       // Fixed start address for this fixture
    var shapeIndex: Int = 1  // Raw DMX value (0-255)
    var shape: ShapeType = .circle
    var goboId: Int? = nil   // If 51-200, this is a gobo
    var videoSlot: Int? = nil  // If 201-255, this is a media slot index
    var videoPlaybackState: VideoPlaybackState = .stop
    var videoGotoPercent: Float? = nil
    var videoMaskBlend: Float = 0.0  // CH22: 0.0 = full color, 1.0 = full grayscale mask (crossfadable)
    var videoVolume: Float = 1.0     // CH23: 0.0 - 1.0
    var position: CGPoint = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    var zIndex: Int = 0
    var scale: CGSize = CGSize(width: 1, height: 1)
    var softness: CGFloat = 0
    var opacity: CGFloat = 1
    var intensity: CGFloat = 1
    var color: NSColor = NSColor.white
    var baseRotation: CGFloat = 0
    var spinSpeed: CGFloat = 0
    var spinAccum: CGFloat = 0

    // Iris and Framing Shutter masks (CH24-33)
    var iris: Float = 1.0                    // CH24: 1.0 = fully open, 0.0 = closed
    var shutterTopInsertion: Float = 0.0     // CH25: 0-1 (percentage into beam)
    var shutterTopAngle: Float = 0.0         // CH26: -π/4 to +π/4 (±45°)
    var shutterBottomInsertion: Float = 0.0  // CH27
    var shutterBottomAngle: Float = 0.0      // CH28
    var shutterLeftInsertion: Float = 0.0    // CH29
    var shutterLeftAngle: Float = 0.0        // CH30
    var shutterRightInsertion: Float = 0.0   // CH31
    var shutterRightAngle: Float = 0.0       // CH32
    var shutterRotation: Float = 0.0         // CH33: Assembly rotation -π/4 to +π/4

    // Prism Beam Multiplication (CH34)
    var prismType: PrismType = .off          // CH34: Type of prism (off, circular, linear)
    var prismFacets: Int = 0                 // Number of beam copies (3, 5, 6, 8, 16, 18, 24)
    var prismSpread: Float = 0.0             // Spread factor 0.0-1.0 (higher DMX = wider spread)

    // Animation Wheel (CH35) - separate from prism so both can work together
    var animationType: Int = 0               // CH35: 0=off, 1-10=animation types
    var animPrismaticFill: Bool = false      // Animation dark areas filled with prismatic colors

    // Prismatics Dichroic Colors (CH35)
    var prismaticPattern: Int = 0            // CH35: 0=off, 1-7=dichroic color pattern types
    var prismaticPaletteIndex: Int = 0       // Which color palette to use (0-255 maps to palette index)
    var prismaticPhase: Float = 0.0          // Accumulated animation phase for prismatics

    // Prism Rotation (CH36)
    var prismRotationMode: PrismRotationMode = .index  // Index vs CCW vs CW
    var prismIndexAngle: Float = 0.0         // For index mode: static angle (0-360°)
    var prismRotationSpeed: Float = 0.0      // For rotation mode: speed (-1 to 1, negative=CCW)
    var prismRotationAccum: Float = 0.0      // Accumulated rotation angle

    mutating func advance(deltaTime: CGFloat) {
        // Spin animation (object rotation)
        // When spin stops (spinSpeed = 0), reset accumulated rotation so gobo returns to baseRotation
        if spinSpeed == 0 {
            spinAccum = 0
        } else {
            spinAccum += spinSpeed * deltaTime
        }

        // Prism rotation animation - DON'T wrap, let it accumulate continuously
        // Wrapping causes a visible jump when crossing 360->0
        if prismRotationMode != .index {
            prismRotationAccum += prismRotationSpeed * Float(deltaTime) * 360.0  // degrees per second
            // No wrapping - cos/sin in shader handle any value naturally
        }

        // Prismatic phase tied to prism rotation (CH37)
        prismaticPhase = prismAngle / 360.0 * Float.pi * 2.0  // Convert degrees to radians
    }

    /// Get the current prism rotation angle (for beam offset calculation)
    var prismAngle: Float {
        switch prismRotationMode {
        case .index: return prismIndexAngle
        case .ccw, .cw: return prismRotationAccum
        }
    }

    var totalRotation: CGFloat {
        baseRotation + spinAccum
    }

    var isGobo: Bool {
        return (shapeIndex >= 21 && shapeIndex <= 50) || (shapeIndex >= 51 && shapeIndex <= 200)
    }

    var isVideo: Bool {
        return shapeIndex >= 201 && shapeIndex <= 255
    }
}

final class SceneController {
    private let state: DMXState
    private(set) var startUniverse: Int
    private(set) var universeCount: Int
    private(set) var startAddress: Int
    private(set) var startFixtureId: Int
    var defaultMode: DMXMode  // Default mode for new fixtures
    private(set) var objects: [VisualObject]

    // Master DMX Control - Universe 0
    // ═══════════════════════════════════════════════════════════════
    // CONTROL UNIVERSE CHANNEL MAP:
    // Ch 1:  Master Intensity (0-255 = 0-100%)
    // Ch 2:  Test Pattern (0-127=off, 128-255=on)
    // Ch 3:  Show Borders (0-127=off, 128-255=on)
    // Ch 4-9: Reserved
    //
    // Per-Output Control (8 outputs max, 14 channels each):
    // Each output block:
    //   +0: Enable (128+=on)
    //   +1: Edge Blend Left (0-255 = 0-500px)
    //   +2: Edge Blend Right
    //   +3: Edge Blend Top
    //   +4: Edge Blend Bottom
    //   +5: Warp Top-Left X (0=-200px, 128=0, 255=+200px)
    //   +6: Warp Top-Left Y
    //   +7: Warp Top-Right X
    //   +8: Warp Top-Right Y
    //   +9: Warp Bottom-Left X
    //  +10: Warp Bottom-Left Y
    //  +11: Warp Bottom-Right X
    //  +12: Warp Bottom-Right Y
    //  +13: Curvature (0=-1.0, 128=0, 255=+1.0)
    //
    // Output 1: Ch 10-23
    // Output 2: Ch 24-37
    // Output 3: Ch 38-51
    // Output 4: Ch 52-65
    // Output 5: Ch 66-79
    // Output 6: Ch 80-93
    // Output 7: Ch 94-107
    // Output 8: Ch 108-121
    // ═══════════════════════════════════════════════════════════════
    // Master Control universe/address are now configurable via UserDefaults
    static var controlUniverse: Int {
        return UserDefaults.standard.integer(forKey: "masterControlUniverse")
    }
    static var controlAddress: Int {
        let addr = UserDefaults.standard.integer(forKey: "masterControlAddress")
        return addr > 0 ? addr - 1 : 0  // Convert 1-based to 0-based index
    }
    static var masterControlEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "masterControlEnabled")
    }
    static let maxEdgeBlendPixels: Float = 500.0  // Max edge blend in pixels
    static let maxWarpPixels: Float = 500.0       // Max warp offset in pixels (16-bit precision)

    // Master Control fixture (3ch) - channel offsets
    static let chMasterIntensity = 0   // Ch 1: Master intensity
    static let chTestPattern = 1       // Ch 2: Test pattern
    static let chShowBorders = 2       // Ch 3: Show borders
    static let masterChannelCount = 3  // Total master channels

    // Per-output fixture (28ch) - channel offsets matching geodraw@output_28ch.xml
    static let chOutIntensity = 0      // Ch 1: Output intensity
    static let chOutAutoBlend = 1      // Ch 2: Auto blend enable (0-127=off, 128-255=on)
    static let chOutPosXCoarse = 2     // Ch 3: Position X coarse (16-bit, center=32768)
    static let chOutPosXFine = 3       // Ch 4: Position X fine
    static let chOutPosYCoarse = 4     // Ch 5: Position Y coarse (16-bit, center=32768)
    static let chOutPosYFine = 5       // Ch 6: Position Y fine
    static let chOutZOrder = 6         // Ch 7: Z-Order (0-127=default, 128-255=manual)
    static let chOutEdgeL = 7          // Ch 8: Edge blend left (0-500px)
    static let chOutEdgeR = 8          // Ch 9: Edge blend right
    static let chOutEdgeT = 9          // Ch 10: Edge blend top
    static let chOutEdgeB = 10         // Ch 11: Edge blend bottom
    static let chOutWarpTLXCoarse = 11 // Ch 12: Warp TL X coarse (16-bit)
    static let chOutWarpTLXFine = 12   // Ch 13: Warp TL X fine
    static let chOutWarpTLYCoarse = 13 // Ch 14: Warp TL Y coarse
    static let chOutWarpTLYFine = 14   // Ch 15: Warp TL Y fine
    static let chOutWarpTRXCoarse = 15 // Ch 16: Warp TR X coarse
    static let chOutWarpTRXFine = 16   // Ch 17: Warp TR X fine
    static let chOutWarpTRYCoarse = 17 // Ch 18: Warp TR Y coarse
    static let chOutWarpTRYFine = 18   // Ch 19: Warp TR Y fine
    static let chOutWarpBLXCoarse = 19 // Ch 20: Warp BL X coarse
    static let chOutWarpBLXFine = 20   // Ch 21: Warp BL X fine
    static let chOutWarpBLYCoarse = 21 // Ch 22: Warp BL Y coarse
    static let chOutWarpBLYFine = 22   // Ch 23: Warp BL Y fine
    static let chOutWarpBRXCoarse = 23 // Ch 24: Warp BR X coarse
    static let chOutWarpBRXFine = 24   // Ch 25: Warp BR X fine
    static let chOutWarpBRYCoarse = 25 // Ch 26: Warp BR Y coarse
    static let chOutWarpBRYFine = 26   // Ch 27: Warp BR Y fine
    static let chOutCurvature = 27     // Ch 28: Curvature (0=-1.0, 128=0, 255=+1.0)
    static let outputChannelCount = 28 // Total per-output channels

    static let maxPositionOffset: Float = 10000.0  // Max per-output position offset (+/- 10000px)

    private(set) var masterIntensity: CGFloat = 1.0
    private(set) var controlUniverseActive = false

    // For backwards compatibility
    var mode: DMXMode { defaultMode }

    init(fixtureCount: Int, state: DMXState, startUniverse: Int, startAddress: Int = 1, startFixtureId: Int = 1, mode: DMXMode = .full) {
        self.state = state
        self.startUniverse = startUniverse
        self.defaultMode = mode
        self.startAddress = startAddress
        self.startFixtureId = startFixtureId
        self.universeCount = 1  // Placeholder, will be recalculated
        // Create fixtures with the default mode
        self.objects = (0..<fixtureCount).map { _ in
            var obj = VisualObject()
            obj.mode = mode
            return obj
        }
        // Assign sequential addresses to all fixtures
        updateAddressing(startUniverse: startUniverse, startAddress: startAddress, startFixtureId: startFixtureId)
    }

    /// Calculate total universes needed based on per-fixture universes
    private func calculateUniverseCount() -> Int {
        guard !objects.isEmpty else { return 1 }
        // Find the highest universe used by any fixture
        let maxUniverse = objects.map { $0.universe }.max() ?? startUniverse
        let minUniverse = objects.map { $0.universe }.min() ?? startUniverse
        return maxUniverse - minUniverse + 1
    }

    /// Get the universe and address for a specific fixture (0-indexed)
    /// Now just returns the fixture's stored values
    func getFixtureAddress(index: Int) -> (universe: Int, address: Int) {
        guard index >= 0 && index < objects.count else {
            return (startUniverse, startAddress)
        }
        return (objects[index].universe, objects[index].address)
    }

    /// Set the mode for a specific fixture
    func setFixtureMode(index: Int, mode: DMXMode) {
        guard index >= 0 && index < objects.count else { return }
        objects[index].mode = mode
        universeCount = calculateUniverseCount()
    }

    /// Remove fixtures at specific indices
    func removeFixtures(at indices: IndexSet) {
        // Remove in reverse order to preserve indices
        for index in indices.reversed() {
            guard index >= 0 && index < objects.count else { continue }
            objects.remove(at: index)
        }
        universeCount = calculateUniverseCount()
    }

    /// Add a new fixture at the next available address
    /// Uses universe auto-spanning: if fixture doesn't fit in remaining space, moves to next universe
    func addFixture(mode: DMXMode? = nil, universe: Int? = nil, address: Int? = nil) {
        var obj = VisualObject()
        let fixtureMode = mode ?? defaultMode
        obj.mode = fixtureMode

        // Calculate next available address if not specified
        if let u = universe, let a = address {
            obj.universe = u
            obj.address = a
        } else {
            // Find the next address after the last fixture, with auto-spanning
            let (nextUniv, nextAddr) = getNextAvailableAddress(forMode: fixtureMode)
            obj.universe = nextUniv
            obj.address = nextAddr
        }

        objects.append(obj)
        universeCount = calculateUniverseCount()
    }

    /// Get the next available address after all existing fixtures
    /// If forMode is provided, checks if that fixture would fit in the remaining space
    /// Uses universe auto-spanning: if fixture doesn't fit, moves to next universe
    func getNextAvailableAddress(forMode: DMXMode? = nil) -> (universe: Int, address: Int) {
        var nextUniv: Int
        var nextAddr: Int

        if let lastObj = objects.last {
            // Calculate address after last fixture
            nextAddr = lastObj.address + lastObj.mode.channelsPerFixture
            nextUniv = lastObj.universe

            // Check if start address is past end of universe
            if nextAddr > 512 {
                nextUniv += 1
                nextAddr = 1
            }
        } else {
            // First fixture - use configured start address
            nextUniv = startUniverse
            nextAddr = startAddress
        }

        // Universe auto-spanning: check if the new fixture would fit completely
        // If the fixture's last channel would exceed 512, move to next universe
        if let mode = forMode {
            let endChannel = nextAddr + mode.channelsPerFixture - 1
            if endChannel > 512 {
                nextUniv += 1
                nextAddr = 1
            }
        }

        return (nextUniv, nextAddr)
    }

    /// Repatch all fixtures sequentially starting from the given universe/address
    func updateAddressing(startUniverse: Int, startAddress: Int, startFixtureId: Int) {
        self.startUniverse = startUniverse
        self.startAddress = startAddress
        self.startFixtureId = startFixtureId

        // Repatch all fixtures sequentially
        var currentUniverse = startUniverse
        var currentAddress = startAddress

        for i in 0..<objects.count {
            let channelsNeeded = objects[i].mode.channelsPerFixture

            // Check if fixture fits in current universe
            if currentAddress + channelsNeeded - 1 > 512 {
                // Move to next universe
                currentUniverse += 1
                currentAddress = 1
            }

            objects[i].universe = currentUniverse
            objects[i].address = currentAddress

            // Move to next address
            currentAddress += channelsNeeded
        }

        self.universeCount = calculateUniverseCount()
    }

    /// Set universe and address for a specific fixture
    func setFixtureAddress(index: Int, universe: Int, address: Int) {
        guard index >= 0 && index < objects.count else { return }
        objects[index].universe = universe
        objects[index].address = address
        universeCount = calculateUniverseCount()
    }

    /// Set position for a specific fixture (for layout editor)
    func setFixturePosition(index: Int, position: CGPoint) {
        guard index >= 0 && index < objects.count else { return }
        objects[index].position = position
    }

    /// Set scale for a specific fixture (for layout editor)
    func setFixtureScale(index: Int, scale: CGSize) {
        guard index >= 0 && index < objects.count else { return }
        objects[index].scale = scale
    }

    /// Apply positions to all fixtures (for layout editor)
    func applyLayoutPositions(_ positions: [(x: Float, y: Float)]) {
        for (i, pos) in positions.enumerated() {
            if i < objects.count {
                objects[i].position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
            }
        }
    }

    func updateConfig(fixtureCount: Int, startUniverse: Int, startAddress: Int, startFixtureId: Int = 1, mode: DMXMode? = nil) {
        if let newMode = mode {
            self.defaultMode = newMode
            // Update all existing fixtures to the new mode
            for i in 0..<objects.count {
                objects[i].mode = newMode
            }
        }

        if fixtureCount != objects.count {
            if fixtureCount > objects.count {
                // Add new fixtures
                while objects.count < fixtureCount {
                    var obj = VisualObject()
                    obj.mode = defaultMode
                    objects.append(obj)
                }
            } else {
                // Remove fixtures from end
                objects = Array(objects.prefix(fixtureCount))
            }
        }

        // Repatch all fixtures sequentially
        updateAddressing(startUniverse: startUniverse, startAddress: startAddress, startFixtureId: startFixtureId)
    }

    func tick(deltaTime: CGFloat, canvasSize: CGSize) {
        // Process Master Control fixture (3ch) if enabled
        let masterEnabled = SceneController.masterControlEnabled
        controlUniverseActive = masterEnabled && state.hasReceivedData(for: SceneController.controlUniverse)

        if controlUniverseActive {
            let ctrl = state.values(for: SceneController.controlUniverse)
            let addr = SceneController.controlAddress  // Base address offset (0-based)

            // Ch 1: Master Intensity
            masterIntensity = CGFloat(ctrl[addr + SceneController.chMasterIntensity]) / 255.0

            // Ch 2: Test Pattern (128+ = on)
            OutputSettingsWindowController.testPatternActive = ctrl[addr + SceneController.chTestPattern] >= 128

            // Ch 3: Show Borders (128+ = on)
            OutputSettingsWindowController.showBordersActive = ctrl[addr + SceneController.chShowBorders] >= 128
        } else {
            masterIntensity = 1.0  // Full brightness when no master control data
        }

        // Process each output's individual DMX patch (27ch per output)
        let allOutputs = OutputManager.shared.getAllOutputs()
        for output in allOutputs {
            // Skip outputs without DMX patch (universe 0 = disabled)
            guard output.config.dmxUniverse > 0 else {
                continue
            }

            let universe = output.config.dmxUniverse
            guard state.hasReceivedData(for: universe) else { continue }

            let dmx = state.values(for: universe)
            let base = output.config.dmxAddress - 1  // Convert 1-based to 0-based

            // Ensure we have enough channels
            guard base >= 0, base + SceneController.outputChannelCount <= dmx.count else { continue }

            // Ch 1: Output Intensity (default 255 = full)
            let outputIntensity = Float(dmx[base + SceneController.chOutIntensity]) / 255.0
            OutputManager.shared.updateOutputIntensity(id: output.id, intensity: outputIntensity)

            // Ch 2: Auto Blend Enable (128+ = on) - auto-calculate edge blend from position overlaps
            let autoBlendValue = dmx[base + SceneController.chOutAutoBlend]
            let autoBlendEnabled = autoBlendValue >= 128

            // Ch 3-6: Edge Blend (0-255 = 0-500px)
            let edgeLeft = Float(dmx[base + SceneController.chOutEdgeL]) / 255.0 * SceneController.maxEdgeBlendPixels
            let edgeRight = Float(dmx[base + SceneController.chOutEdgeR]) / 255.0 * SceneController.maxEdgeBlendPixels
            let edgeTop = Float(dmx[base + SceneController.chOutEdgeT]) / 255.0 * SceneController.maxEdgeBlendPixels
            let edgeBottom = Float(dmx[base + SceneController.chOutEdgeB]) / 255.0 * SceneController.maxEdgeBlendPixels

            // Ch 7-22: 4-Corner Warp (16-bit each, signed: 32768 = center)
            func signedWarp16(_ coarse: UInt8, _ fine: UInt8) -> Float {
                let raw = (Int(coarse) << 8) | Int(fine)
                return (Float(raw) - 32768.0) / 32767.0 * SceneController.maxWarpPixels
            }
            let warpTLX = signedWarp16(dmx[base + SceneController.chOutWarpTLXCoarse], dmx[base + SceneController.chOutWarpTLXFine])
            let warpTLY = signedWarp16(dmx[base + SceneController.chOutWarpTLYCoarse], dmx[base + SceneController.chOutWarpTLYFine])
            let warpTRX = signedWarp16(dmx[base + SceneController.chOutWarpTRXCoarse], dmx[base + SceneController.chOutWarpTRXFine])
            let warpTRY = signedWarp16(dmx[base + SceneController.chOutWarpTRYCoarse], dmx[base + SceneController.chOutWarpTRYFine])
            let warpBLX = signedWarp16(dmx[base + SceneController.chOutWarpBLXCoarse], dmx[base + SceneController.chOutWarpBLXFine])
            let warpBLY = signedWarp16(dmx[base + SceneController.chOutWarpBLYCoarse], dmx[base + SceneController.chOutWarpBLYFine])
            let warpBRX = signedWarp16(dmx[base + SceneController.chOutWarpBRXCoarse], dmx[base + SceneController.chOutWarpBRXFine])
            let warpBRY = signedWarp16(dmx[base + SceneController.chOutWarpBRYCoarse], dmx[base + SceneController.chOutWarpBRYFine])

            // Ch 23: Curvature (0=-1.0, 128=0, 255=+1.0)
            let curvature = (Float(dmx[base + SceneController.chOutCurvature]) - 128.0) / 127.0

            // Ch 24-27: Position X/Y (16-bit, signed: 32768 = center)
            let posXRaw = (Int(dmx[base + SceneController.chOutPosXCoarse]) << 8) | Int(dmx[base + SceneController.chOutPosXFine])
            let posYRaw = (Int(dmx[base + SceneController.chOutPosYCoarse]) << 8) | Int(dmx[base + SceneController.chOutPosYFine])
            let posX = Int((Float(posXRaw) - 32768.0) / 32767.0 * SceneController.maxPositionOffset)
            let posY = Int((Float(posYRaw) - 32768.0) / 32767.0 * SceneController.maxPositionOffset)

            // Check if values changed (avoid unnecessary updates)
            let currentConfig = output.config
            let edgeChanged = abs(edgeLeft - currentConfig.edgeBlendLeft) > 1 ||
                              abs(edgeRight - currentConfig.edgeBlendRight) > 1 ||
                              abs(edgeTop - currentConfig.edgeBlendTop) > 1 ||
                              abs(edgeBottom - currentConfig.edgeBlendBottom) > 1

            let warpChanged = abs(warpTLX - currentConfig.warpTopLeftX) > 0.5 ||
                              abs(warpTLY - currentConfig.warpTopLeftY) > 0.5 ||
                              abs(warpTRX - currentConfig.warpTopRightX) > 0.5 ||
                              abs(warpTRY - currentConfig.warpTopRightY) > 0.5 ||
                              abs(warpBLX - currentConfig.warpBottomLeftX) > 0.5 ||
                              abs(warpBLY - currentConfig.warpBottomLeftY) > 0.5 ||
                              abs(warpBRX - currentConfig.warpBottomRightX) > 0.5 ||
                              abs(warpBRY - currentConfig.warpBottomRightY) > 0.5 ||
                              abs(curvature - currentConfig.warpCurvature) > 0.01

            let currentPosX = currentConfig.positionX ?? 0
            let currentPosY = currentConfig.positionY ?? 0
            let posChanged = abs(posX - currentPosX) > 1 || abs(posY - currentPosY) > 1

            // Update position if changed
            if posChanged {
                NSLog("OUTPUT DMX: %@ pos changed from (%d,%d) to (%d,%d) [raw X=%d Y=%d]",
                      output.name, currentPosX, currentPosY, posX, posY, posXRaw, posYRaw)
                OutputManager.shared.updatePosition(
                    id: output.id,
                    x: posX,
                    y: posY,
                    w: currentConfig.positionW ?? 1920,
                    h: currentConfig.positionH ?? 1080
                )
            }

            // Auto-calculate edge blend when enabled (uses current positions)
            if autoBlendEnabled {
                // Use current position (from DMX or config)
                let currentX = posChanged ? posX : (currentConfig.positionX ?? 0)
                let currentY = posChanged ? posY : (currentConfig.positionY ?? 0)
                let currentW = currentConfig.positionW ?? 1920
                let currentH = currentConfig.positionH ?? 1080

                // Find this output's index in allOutputs
                let outputIdx = allOutputs.firstIndex(where: { $0.id == output.id }) ?? 0
                let (autoL, autoR, autoT, autoB) = calculateOverlapsForOutput(
                    outputIndex: outputIdx,
                    outputs: allOutputs,
                    posX: currentX,
                    posY: currentY,
                    posW: currentW,
                    posH: currentH
                )
                OutputManager.shared.updateEdgeBlend(
                    id: output.id,
                    left: autoL, right: autoR,
                    top: autoT, bottom: autoB,
                    gamma: currentConfig.edgeBlendGamma,
                    power: currentConfig.edgeBlendPower,
                    blackLevel: currentConfig.edgeBlendBlackLevel
                )
            }

            // Update edge blend and warp if changed (manual DMX control, only when auto blend is off)
            if !autoBlendEnabled && (edgeChanged || warpChanged) {
                output.config.warpTopLeftX = warpTLX
                output.config.warpTopLeftY = warpTLY
                output.config.warpTopRightX = warpTRX
                output.config.warpTopRightY = warpTRY
                output.config.warpBottomLeftX = warpBLX
                output.config.warpBottomLeftY = warpBLY
                output.config.warpBottomRightX = warpBRX
                output.config.warpBottomRightY = warpBRY
                output.config.warpCurvature = curvature

                OutputManager.shared.updateEdgeBlend(
                    id: output.id,
                    left: edgeLeft, right: edgeRight,
                    top: edgeTop, bottom: edgeBottom,
                    gamma: currentConfig.edgeBlendGamma,
                    power: currentConfig.edgeBlendPower,
                    blackLevel: currentConfig.edgeBlendBlackLevel
                )
            }
        }

        // Cache universe data
        var universeCache: [Int: [UInt8]] = [:]

        // Process each fixture with its individual mode and address
        for i in 0..<objects.count {
            var obj = objects[i]
            let (universe, address) = getFixtureAddress(index: i)
            let base = address - 1  // Convert 1-based to 0-based

            // Get or cache universe data
            if universeCache[universe] == nil {
                universeCache[universe] = state.values(for: universe)
            }
            guard let dmx = universeCache[universe] else { continue }

            let chCount = obj.mode.channelsPerFixture
            guard base >= 0, base + chCount <= dmx.count else { continue }

            // Parse based on fixture's own mode
            switch obj.mode {
            case .compact:
                parseCompactMode(dmx: dmx, base: base, obj: &obj, canvasSize: canvasSize)
            case .standard:
                parseStandardMode(dmx: dmx, base: base, obj: &obj, canvasSize: canvasSize)
            case .full:
                parseFullMode(dmx: dmx, base: base, obj: &obj, canvasSize: canvasSize)
            }

            // Apply master intensity to fixture color
            if masterIntensity < 1.0 {
                let r = obj.color.redComponent * masterIntensity
                let g = obj.color.greenComponent * masterIntensity
                let b = obj.color.blueComponent * masterIntensity
                obj.color = NSColor(calibratedRed: r, green: g, blue: b, alpha: obj.color.alphaComponent)
            }

            obj.advance(deltaTime: deltaTime)
            objects[i] = obj
        }

        objects.sort { lhs, rhs in
            if lhs.zIndex == rhs.zIndex {
                return lhs.position.y < rhs.position.y
            }
            return lhs.zIndex < rhs.zIndex
        }
    }

    // MARK: - Auto Edge Blend Calculation

    /// Calculate edge blend overlaps for an output based on position relative to other outputs
    /// Uses SEAM DETECTION: vertical seam (side-by-side) -> L/R feather, horizontal seam (stacked) -> T/B feather
    private func calculateOverlapsForOutput(
        outputIndex: Int,
        outputs: [ManagedOutput],
        posX: Int,
        posY: Int,
        posW: Int,
        posH: Int
    ) -> (left: Float, right: Float, top: Float, bottom: Float) {
        var featherL: Float = 0
        var featherR: Float = 0
        var featherT: Float = 0
        var featherB: Float = 0

        let aX = posX
        let aY = posY
        let aW = posW
        let aH = posH

        for (i, other) in outputs.enumerated() {
            if i == outputIndex { continue }

            let bX = other.config.positionX ?? 0
            let bY = other.config.positionY ?? 0
            let bW = other.config.positionW ?? Int(other.width)
            let bH = other.config.positionH ?? Int(other.height)

            // Calculate the overlap bounding box
            let overlapLeft = max(aX, bX)
            let overlapRight = min(aX + aW, bX + bW)
            let overlapTop = max(aY, bY)
            let overlapBottom = min(aY + aH, bY + bH)

            let overlapWidth = max(0, overlapRight - overlapLeft)
            let overlapHeight = max(0, overlapBottom - overlapTop)

            // Skip if no actual overlap
            if overlapWidth <= 0 || overlapHeight <= 0 { continue }

            // SEAM DETECTION: Determine if this is a vertical seam (side-by-side) or horizontal seam (stacked)
            // Vertical seam = overlap taller than wide → apply LEFT/RIGHT feathering
            // Horizontal seam = overlap wider than tall → apply TOP/BOTTOM feathering
            let isVerticalSeam = overlapHeight > overlapWidth

            if isVerticalSeam {
                // Side-by-side outputs → apply LEFT or RIGHT feathering
                // Left: B is to the left of A and extends into A
                if bX < aX && bX + bW > aX {
                    let overlap = Float((bX + bW) - aX)
                    featherL = max(featherL, overlap)
                }
                // Right: B is to the right of A and A extends into B
                if bX > aX && aX + aW > bX {
                    let overlap = Float((aX + aW) - bX)
                    featherR = max(featherR, overlap)
                }
            } else {
                // Stacked outputs → apply TOP or BOTTOM feathering
                // Top: B is above A and extends into A
                if bY < aY && bY + bH > aY {
                    let overlap = Float((bY + bH) - aY)
                    featherT = max(featherT, overlap)
                }
                // Bottom: B is below A and A extends into B
                if bY > aY && aY + aH > bY {
                    let overlap = Float((aY + aH) - bY)
                    featherB = max(featherB, overlap)
                }
            }
        }

        return (featherL, featherR, featherT, featherB)
    }

    // MARK: - Mode-Specific Parsing

    /// Compact Mode (10ch): Content, X, Y, Scale, Opacity, R, G, B, Softness, Spin
    private func parseCompactMode(dmx: [UInt8], base: Int, obj: inout VisualObject, canvasSize: CGSize) {
        let shapeIndex = Int(dmx[base])     // CH1: Content
        let xValue = Int(dmx[base + 1])     // CH2: X (8-bit)
        let yValue = Int(dmx[base + 2])     // CH3: Y (8-bit)
        let scaleValue = Int(dmx[base + 3]) // CH4: Scale
        let opacityValue = Int(dmx[base + 4]) // CH5: Opacity
        let r = CGFloat(dmx[base + 5]) / 255.0  // CH6: Red
        let g = CGFloat(dmx[base + 6]) / 255.0  // CH7: Green
        let b = CGFloat(dmx[base + 7]) / 255.0  // CH8: Blue
        let softnessValue = Int(dmx[base + 8])  // CH9: Softness
        let spinValue = Int(dmx[base + 9])      // CH10: Spin

        // Parse shape/gobo/video
        let (shape, goboId, videoSlot) = parseContentChannel(shapeIndex)

        obj.shapeIndex = shapeIndex
        obj.shape = shape
        obj.goboId = goboId
        obj.videoSlot = videoSlot
        obj.videoPlaybackState = videoSlot != nil ? .playLoop : .stop
        obj.videoGotoPercent = nil
        obj.videoMaskBlend = 0.0
        obj.videoVolume = 1.0

        // 8-bit position mapping
        obj.position = CGPoint(
            x: mapPosition8(value: xValue, max: canvasSize.width),
            y: mapPosition8(value: yValue, max: canvasSize.height)
        )
        obj.zIndex = 0

        // Single 8-bit scale
        let uniformScale = map8(value: scaleValue, max: 6.0)
        obj.scale = CGSize(width: uniformScale, height: uniformScale)

        obj.softness = map8(value: softnessValue, max: 40.0)
        obj.opacity = map8(value: opacityValue, max: 1.0)
        obj.intensity = 1.0
        obj.color = NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
        obj.baseRotation = 0
        obj.spinSpeed = spinDegreesPerSecond(from: spinValue) * (.pi / 180.0)

        // No iris/shutters in compact mode
        obj.iris = 1.0
        obj.shutterTopInsertion = 0
        obj.shutterBottomInsertion = 0
        obj.shutterLeftInsertion = 0
        obj.shutterRightInsertion = 0
    }

    /// Standard Mode (23ch): Full control except iris/shutters
    private func parseStandardMode(dmx: [UInt8], base: Int, obj: inout VisualObject, canvasSize: CGSize) {
        let shapeIndex = Int(dmx[base])

        // Parse shape/gobo/video
        let (shape, goboId, videoSlot) = parseContentChannel(shapeIndex)

        // Video playback state
        var videoPlaybackState: VideoPlaybackState = .stop
        var videoGotoPercent: Float? = nil
        if videoSlot != nil {
            let playbackValue = dmx[base + 20]
            let parsed = VideoPlaybackState.from(dmxValue: playbackValue)
            videoPlaybackState = parsed.state
            videoGotoPercent = parsed.gotoPercent
        }

        let xValue = Int(dmx[base + 1]) << 8 | Int(dmx[base + 2])
        let yValue = Int(dmx[base + 3]) << 8 | Int(dmx[base + 4])
        let z = Int(dmx[base + 5])
        let scaleValue = Int(dmx[base + 6]) << 8 | Int(dmx[base + 7])
        let hScaleValue = Int(dmx[base + 8]) << 8 | Int(dmx[base + 9])
        let vScaleValue = Int(dmx[base + 10]) << 8 | Int(dmx[base + 11])
        let softnessValue = Int(dmx[base + 12])
        let opacityValue = Int(dmx[base + 13])
        let intensityValue = Int(dmx[base + 14])
        let r = CGFloat(dmx[base + 15]) / 255.0
        let g = CGFloat(dmx[base + 16]) / 255.0
        let b = CGFloat(dmx[base + 17]) / 255.0
        let rotationValue = Int(dmx[base + 18])
        let spinValue = Int(dmx[base + 19])
        let videoModeValue = Int(dmx[base + 21])
        let volumeValue = Int(dmx[base + 22])

        obj.shapeIndex = shapeIndex
        obj.shape = shape
        obj.goboId = goboId
        obj.videoSlot = videoSlot
        obj.videoPlaybackState = videoPlaybackState
        obj.videoGotoPercent = videoGotoPercent
        obj.videoMaskBlend = Float(videoModeValue) / 255.0
        obj.videoVolume = Float(volumeValue) / 255.0
        obj.position = CGPoint(x: mapPosition16(value: xValue, max: canvasSize.width), y: mapPosition16(value: yValue, max: canvasSize.height))
        obj.zIndex = z

        let uniformScale = map16(value: scaleValue, max: 6.0)
        let hScale = max(0.1, map16(value: hScaleValue, max: 2.0))
        let vScale = max(0.1, map16(value: vScaleValue, max: 2.0))
        obj.scale = CGSize(width: uniformScale * hScale, height: uniformScale * vScale)

        obj.softness = map8(value: softnessValue, max: 40.0)
        obj.opacity = map8(value: opacityValue, max: 1.0)
        obj.intensity = map8(value: intensityValue, max: 1.0)
        let intensity = obj.intensity
        obj.color = NSColor(calibratedRed: r * intensity, green: g * intensity, blue: b * intensity, alpha: 1.0)
        obj.baseRotation = (CGFloat(rotationValue) / 255.0) * 2.0 * .pi
        obj.spinSpeed = spinDegreesPerSecond(from: spinValue) * (.pi / 180.0)

        // No iris/shutters in standard mode
        obj.iris = 1.0
        obj.shutterTopInsertion = 0
        obj.shutterBottomInsertion = 0
        obj.shutterLeftInsertion = 0
        obj.shutterRightInsertion = 0
    }

    /// Full Mode (33ch): All features including iris and shutters
    private func parseFullMode(dmx: [UInt8], base: Int, obj: inout VisualObject, canvasSize: CGSize) {
        let shapeIndex = Int(dmx[base])

        // Parse shape/gobo/video
        let (shape, goboId, videoSlot) = parseContentChannel(shapeIndex)

        // Video playback state
        var videoPlaybackState: VideoPlaybackState = .stop
        var videoGotoPercent: Float? = nil
        if videoSlot != nil {
            let playbackValue = dmx[base + 20]
            let parsed = VideoPlaybackState.from(dmxValue: playbackValue)
            videoPlaybackState = parsed.state
            videoGotoPercent = parsed.gotoPercent
        }

        let xValue = Int(dmx[base + 1]) << 8 | Int(dmx[base + 2])
        let yValue = Int(dmx[base + 3]) << 8 | Int(dmx[base + 4])
        let z = Int(dmx[base + 5])
        let scaleValue = Int(dmx[base + 6]) << 8 | Int(dmx[base + 7])
        let hScaleValue = Int(dmx[base + 8]) << 8 | Int(dmx[base + 9])
        let vScaleValue = Int(dmx[base + 10]) << 8 | Int(dmx[base + 11])
        let softnessValue = Int(dmx[base + 12])
        let opacityValue = Int(dmx[base + 13])
        let intensityValue = Int(dmx[base + 14])
        let r = CGFloat(dmx[base + 15]) / 255.0
        let g = CGFloat(dmx[base + 16]) / 255.0
        let b = CGFloat(dmx[base + 17]) / 255.0
        let rotationValue = Int(dmx[base + 18])
        let spinValue = Int(dmx[base + 19])
        let videoModeValue = Int(dmx[base + 21])
        let volumeValue = Int(dmx[base + 22])

        // Iris and Framing Shutter channels (CH24-33)
        let irisValue = Int(dmx[base + 23])
        let blade1InsValue = Int(dmx[base + 24])
        let blade1AngValue = Int(dmx[base + 25])
        let blade2InsValue = Int(dmx[base + 26])
        let blade2AngValue = Int(dmx[base + 27])
        let blade3InsValue = Int(dmx[base + 28])
        let blade3AngValue = Int(dmx[base + 29])
        let blade4InsValue = Int(dmx[base + 30])
        let blade4AngValue = Int(dmx[base + 31])
        let assemblyRotValue = Int(dmx[base + 32])

        obj.shapeIndex = shapeIndex
        obj.shape = shape
        obj.goboId = goboId
        obj.videoSlot = videoSlot
        obj.videoPlaybackState = videoPlaybackState
        obj.videoGotoPercent = videoGotoPercent
        obj.videoMaskBlend = Float(videoModeValue) / 255.0
        obj.videoVolume = Float(volumeValue) / 255.0
        obj.position = CGPoint(x: mapPosition16(value: xValue, max: canvasSize.width), y: mapPosition16(value: yValue, max: canvasSize.height))
        obj.zIndex = z


        let uniformScale = map16(value: scaleValue, max: 6.0)
        let hScale = max(0.1, map16(value: hScaleValue, max: 2.0))
        let vScale = max(0.1, map16(value: vScaleValue, max: 2.0))
        obj.scale = CGSize(width: uniformScale * hScale, height: uniformScale * vScale)

        obj.softness = map8(value: softnessValue, max: 40.0)
        obj.opacity = map8(value: opacityValue, max: 1.0)
        obj.intensity = map8(value: intensityValue, max: 1.0)
        let intensity = obj.intensity
        obj.color = NSColor(calibratedRed: r * intensity, green: g * intensity, blue: b * intensity, alpha: 1.0)

        obj.baseRotation = (CGFloat(rotationValue) / 255.0) * 2.0 * .pi
        obj.spinSpeed = spinDegreesPerSecond(from: spinValue) * (.pi / 180.0)

        // Iris and Framing Shutters
        obj.iris = Float(irisValue) / 255.0
        obj.shutterTopInsertion = Float(blade1InsValue) / 255.0
        obj.shutterTopAngle = ((Float(blade1AngValue) - 128.0) / 127.0) * (Float.pi / 4.0)
        obj.shutterBottomInsertion = Float(blade2InsValue) / 255.0
        obj.shutterBottomAngle = ((Float(blade2AngValue) - 128.0) / 127.0) * (Float.pi / 4.0)
        obj.shutterLeftInsertion = Float(blade3InsValue) / 255.0
        obj.shutterLeftAngle = ((Float(blade3AngValue) - 128.0) / 127.0) * (Float.pi / 4.0)
        obj.shutterRightInsertion = Float(blade4InsValue) / 255.0
        obj.shutterRightAngle = ((Float(blade4AngValue) - 128.0) / 127.0) * (Float.pi / 4.0)
        obj.shutterRotation = ((Float(assemblyRotValue) - 128.0) / 127.0) * (Float.pi / 4.0)

        // CH34: Prism Pattern (facet beam multiplication only)
        let prismPatternValue = Int(dmx[base + 33])
        parsePrismPattern(prismPatternValue, obj: &obj)

        // CH35: Animation Wheel
        let animationValue = Int(dmx[base + 34])
        parseAnimationWheel(animationValue, obj: &obj)


        // CH36: Prismatics (dichroic color sets) - also controls fill mode for animations
        let prismaticsValue = Int(dmx[base + 35])
        parsePrismatics(prismaticsValue, obj: &obj)

        // CH37: Prism/Animation Rotation (0-127=index, 128-191=CCW, 192=stop, 193-255=CW)
        let prismRotValue = Int(dmx[base + 36])
        parsePrismRotation(prismRotValue, obj: &obj)
    }

    /// Parse content channel (CH1) to determine shape, gobo, or video
    private func parseContentChannel(_ shapeIndex: Int) -> (ShapeType, Int?, Int?) {
        if shapeIndex >= 201 && shapeIndex <= 255 {
            // Media slot
            return (.circle, nil, shapeIndex)
        } else if shapeIndex >= 21 && shapeIndex <= 200 {
            // Gobo
            return (.circle, shapeIndex, nil)
        } else if shapeIndex < ShapeType.allCases.count {
            // Basic shape
            return (ShapeType.allCases[shapeIndex], nil, nil)
        } else {
            // Unknown - default to circle
            return (.circle, nil, nil)
        }
    }

    private func map16(value: Int, max: CGFloat) -> CGFloat {
        let t = CGFloat(value) / 65535.0
        return t * max
    }

    private func map8(value: Int, max: CGFloat) -> CGFloat {
        let t = CGFloat(value) / 255.0
        return t * max
    }

    // Position mapping with 20% overflow on all edges
    private func mapPosition16(value: Int, max: CGFloat) -> CGFloat {
        let t = CGFloat(value) / 65535.0
        return max * (t * 1.4 - 0.2)
    }

    private func mapPosition8(value: Int, max: CGFloat) -> CGFloat {
        let t = CGFloat(value) / 255.0
        return max * (t * 1.4 - 0.2)
    }

    private func spinDegreesPerSecond(from value: Int) -> CGFloat {
        if value <= 127 {
            return -CGFloat(value) / 127.0 * 180.0 // CCW
        } else {
            return CGFloat(value - 128) / 127.0 * 180.0 // CW
        }
    }

    /// Parse CH34: Prism Pattern (beam multiplication)
    /// Ordered by facet count: higher DMX = wider spread
    /// Within each prism range, spread goes from tight (0.2) to wide (2.5)
    /// 0=Off, 1-25=3C, 26-50=3L, 51-75=4L, 76-100=5C, 101-125=6C, 126-150=6L,
    /// 151-175=8C, 176-200=16C, 201-225=18C, 226-255=24L
    private func parsePrismPattern(_ value: Int, obj: inout VisualObject) {
        // Helper to calculate spread within a range (0.1 to 1.2)
        // Reduced max to keep copies on screen
        func spreadInRange(_ val: Int, rangeStart: Int, rangeEnd: Int) -> Float {
            let position = Float(val - rangeStart) / Float(rangeEnd - rangeStart)
            return 0.1 + position * 1.1  // 0.1 at start, 1.2 at end of range
        }

        switch value {
        case 0:
            obj.prismType = .off
            obj.prismFacets = 0
            obj.prismSpread = 0.0
        case 1...25:
            obj.prismType = .circular3
            obj.prismFacets = 3
            obj.prismSpread = spreadInRange(value, rangeStart: 1, rangeEnd: 25)
        case 26...50:
            obj.prismType = .linear3
            obj.prismFacets = 3
            obj.prismSpread = spreadInRange(value, rangeStart: 26, rangeEnd: 50)
        case 51...75:
            obj.prismType = .linear4
            obj.prismFacets = 4
            obj.prismSpread = spreadInRange(value, rangeStart: 51, rangeEnd: 75)
        case 76...100:
            obj.prismType = .circular5
            obj.prismFacets = 5
            obj.prismSpread = spreadInRange(value, rangeStart: 76, rangeEnd: 100)
        case 101...125:
            obj.prismType = .circular6
            obj.prismFacets = 6
            obj.prismSpread = spreadInRange(value, rangeStart: 101, rangeEnd: 125)
        case 126...150:
            obj.prismType = .linear6
            obj.prismFacets = 6
            obj.prismSpread = spreadInRange(value, rangeStart: 126, rangeEnd: 150)
        case 151...175:
            obj.prismType = .circular8
            obj.prismFacets = 8
            obj.prismSpread = spreadInRange(value, rangeStart: 151, rangeEnd: 175)
        case 176...200:
            obj.prismType = .circular16
            obj.prismFacets = 16
            obj.prismSpread = spreadInRange(value, rangeStart: 176, rangeEnd: 200)
        case 201...225:
            obj.prismType = .circular18
            obj.prismFacets = 18
            obj.prismSpread = spreadInRange(value, rangeStart: 201, rangeEnd: 225)
        case 226...255:
            obj.prismType = .linear24
            obj.prismFacets = 24
            obj.prismSpread = spreadInRange(value, rangeStart: 226, rangeEnd: 255)
        default:
            obj.prismType = .off
            obj.prismFacets = 0
            obj.prismSpread = 0.0
        }
    }

    /// Parse CH35: Animation Wheel
    /// DMX 0=Off, 1-25=Fire, 26-50=Water, 51-75=Clouds, 76-100=RadialBreakup,
    /// 101-125=EllipticalBreakup, 126-150=Bubbles, 151-175=Snow, 176-200=Lightning,
    /// 201-225=Plasma, 226-255=Spiral
    /// NOTE: Sets animationType separately from prismType so both can work together
    private func parseAnimationWheel(_ value: Int, obj: inout VisualObject) {
        switch value {
        case 0:
            obj.animationType = 0  // No animation
        case 1...25:
            obj.animationType = 1  // Fire
        case 26...50:
            obj.animationType = 2  // Water
        case 51...75:
            obj.animationType = 3  // Clouds
        case 76...100:
            obj.animationType = 4  // Radial Breakup
        case 101...125:
            obj.animationType = 5  // Elliptical Breakup
        case 126...150:
            obj.animationType = 6  // Bubbles
        case 151...175:
            obj.animationType = 7  // Snow
        case 176...200:
            obj.animationType = 8  // Lightning
        case 201...225:
            obj.animationType = 9  // Plasma
        case 226...255:
            obj.animationType = 10 // Spiral
        default:
            obj.animationType = 0  // Unknown value, off
        }
    }

    /// Parse CH36: Prismatics (dichroic color sets)
    /// DMX 0=Off (dark fill for animations), 1+=Prismatic palette (prismatic fill for animations)
    /// 0=Off, 1-42=Kaleidoscope, 43-84=BlueWater, 85-126=Crystaline,
    /// 127-168=Fire, 169-210=Aurora, 211-255=Sunset
    private func parsePrismatics(_ value: Int, obj: inout VisualObject) {
        // CH36 > 0 enables prismatic fill for animations
        obj.animPrismaticFill = value > 0

        switch value {
        case 0:
            obj.prismaticPattern = 0  // Off
            obj.prismaticPaletteIndex = 0
        case 1...42:
            obj.prismaticPattern = 7  // Kaleidoscope pattern
            obj.prismaticPaletteIndex = 0  // Rainbow palette
        case 43...84:
            obj.prismaticPattern = 5  // Voronoi (dichroic chip look)
            obj.prismaticPaletteIndex = 1  // Blue Water palette
        case 85...126:
            obj.prismaticPattern = 5  // Voronoi
            obj.prismaticPaletteIndex = 2  // Crystaline palette
        case 127...168:
            obj.prismaticPattern = 5  // Voronoi
            obj.prismaticPaletteIndex = 3  // Fire palette
        case 169...210:
            obj.prismaticPattern = 5  // Voronoi
            obj.prismaticPaletteIndex = 4  // Aurora palette
        case 211...255:
            obj.prismaticPattern = 5  // Voronoi
            obj.prismaticPaletteIndex = 5  // Sunset palette
        default:
            obj.prismaticPattern = 0
            obj.prismaticPaletteIndex = 0
        }
    }

    /// Parse CH37: Prism/Animation Rotation
    /// DMX 0-127=Index (0-360°), 128-159=CCW fast, 160-191=CCW slow, 192=Stop,
    /// 193-224=CW slow, 225-255=CW fast
    private func parsePrismRotation(_ value: Int, obj: inout VisualObject) {
        switch value {
        case 0...127:
            // Index mode: static position
            obj.prismRotationMode = .index
            obj.prismIndexAngle = Float(value) / 127.0 * 360.0
            obj.prismRotationSpeed = 0
        case 128...159:
            // CCW fast to medium
            obj.prismRotationMode = .ccw
            let speed = 1.0 - Float(value - 128) / 31.0  // 1.0 (fast) to 0.0 (slow)
            obj.prismRotationSpeed = -speed * 2.0  // negative = CCW
        case 160...191:
            // CCW medium to slow
            obj.prismRotationMode = .ccw
            let speed = 1.0 - Float(value - 160) / 31.0  // Continuing slowdown
            obj.prismRotationSpeed = -speed * 0.5  // Slower range
        case 192:
            // Stop
            obj.prismRotationMode = .index
            obj.prismRotationSpeed = 0
        case 193...224:
            // CW slow to medium
            obj.prismRotationMode = .cw
            let speed = Float(value - 193) / 31.0  // 0.0 (slow) to 1.0 (fast)
            obj.prismRotationSpeed = speed * 0.5  // positive = CW
        case 225...255:
            // CW medium to fast
            obj.prismRotationMode = .cw
            let speed = Float(value - 225) / 30.0  // 0.0 to 1.0
            obj.prismRotationSpeed = 0.5 + speed * 1.5  // Faster range
        default:
            obj.prismRotationMode = .index
            obj.prismRotationSpeed = 0
        }
    }

}

// MARK: - Rendering view

@MainActor
final class RenderView: NSView {
    private let controller: SceneController
    private var lastTimestamp: CFTimeInterval = CACurrentMediaTime()
    private let baseRadius: CGFloat = 120
    private var displayLink: CVDisplayLink?
    private var fallbackTimer: Timer?

    // NDI Output
    private var ndiSender: NDISender?
    private var ndiEnabled: Bool = true
    private var offscreenBitmap: NSBitmapImageRep?

    init(frame: CGRect, controller: SceneController) {
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = true

        ndiLog("RenderView init: frame=\(frame.size), checking NDI...")

        // Initialize NDI sender
        ndiLog("RenderView: NDILibrary.shared.isLoaded = \(NDILibrary.shared.isLoaded)")
        if NDILibrary.shared.isLoaded {
            ndiSender = NDISender(name: "GeoDrawNDI", width: Int(frame.width), height: Int(frame.height))

            // Create offscreen bitmap for NDI capture
            offscreenBitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(frame.width),
                pixelsHigh: Int(frame.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: Int(frame.width) * 4,
                bitsPerPixel: 32
            )
        }
    }

    var isNDIActive: Bool {
        return ndiSender?.isActive ?? false
    }

    var ndiConnectionCount: Int32 {
        return ndiSender?.connectionCount ?? 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startDisplayLink() {
        var link: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if result == kCVReturnSuccess, let link = link {
            CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userData) -> CVReturn in
                let view = unsafeBitCast(userData, to: RenderView.self)
                DispatchQueue.main.async {
                    view.tick()
                }
                return kCVReturnSuccess
            }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
            CVDisplayLinkStart(link)
            displayLink = link
        } else {
            // Fallback: timer at ~60fps
            fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    self.tick()
                }
            }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let delta = CGFloat(now - lastTimestamp)
        lastTimestamp = now
        controller.tick(deltaTime: delta, canvasSize: canvasSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()

        for obj in controller.objects {
            draw(object: obj, in: ctx)
        }

        // Send frame to NDI if enabled
        if ndiEnabled, let sender = ndiSender, let bitmap = offscreenBitmap {
            // Render to offscreen bitmap
            if let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) {
                let oldContext = NSGraphicsContext.current
                NSGraphicsContext.current = bitmapContext

                let cgCtx = bitmapContext.cgContext
                cgCtx.saveGState()
                cgCtx.setFillColor(NSColor.black.cgColor)
                cgCtx.fill(CGRect(origin: .zero, size: bounds.size))
                cgCtx.restoreGState()

                for obj in controller.objects {
                    draw(object: obj, in: cgCtx)
                }

                NSGraphicsContext.current = oldContext
            }

            // Send to NDI
            sender.sendFrame(bitmap: bitmap)
        }
    }

    private func draw(object: VisualObject, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: object.position.x, y: object.position.y)
        ctx.rotate(by: object.totalRotation)
        ctx.scaleBy(x: object.scale.width, y: object.scale.height)
        ctx.setAlpha(object.opacity)

        if object.softness > 0.01 {
            ctx.setShadow(offset: .zero, blur: object.softness, color: object.color.withAlphaComponent(object.opacity).cgColor)
        } else {
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }

        // Check if this is a gobo
        if object.isGobo, let goboId = object.goboId {
            drawGobo(goboId: goboId, object: object, in: ctx)
            ctx.restoreGState()
            return
        }

        ctx.setFillColor(object.color.cgColor)
        ctx.setStrokeColor(object.color.cgColor)
        ctx.setLineWidth(8)
        ctx.setLineJoin(.round)

        let path: CGPath
        switch object.shape {
        case .line:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -baseRadius, y: 0))
            p.addLine(to: CGPoint(x: baseRadius, y: 0))
            path = p
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
            return
        case .circle:
            path = CGPath(ellipseIn: CGRect(x: -baseRadius, y: -baseRadius, width: baseRadius * 2, height: baseRadius * 2), transform: nil)
        case .triangle:
            path = polygonPath(sides: 3, radius: baseRadius, star: false)
        case .triangleStar:
            path = starPath(points: 3, radius: baseRadius)
        case .square:
            path = polygonPath(sides: 4, radius: baseRadius, star: false)
        case .squareStar:
            path = starPath(points: 4, radius: baseRadius)
        case .pentagon:
            path = polygonPath(sides: 5, radius: baseRadius, star: false)
        case .pentagonStar:
            path = starPath(points: 5, radius: baseRadius)
        case .hexagon:
            path = polygonPath(sides: 6, radius: baseRadius, star: false)
        case .hexagonStar:
            path = starPath(points: 6, radius: baseRadius)
        case .septagon:
            path = polygonPath(sides: 7, radius: baseRadius, star: false)
        case .septagonStar:
            path = starPath(points: 7, radius: baseRadius)
        }

        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    private func drawGobo(goboId: Int, object: VisualObject, in ctx: CGContext) {
        let goboSize = baseRadius * 2

        // Get the gobo image (will generate placeholder if not available)
        guard let goboImage = GoboLibrary.shared.getOrGenerateImage(for: goboId) else {
            // Fallback: draw a circle with "G" label
            ctx.setFillColor(object.color.cgColor)
            ctx.fillEllipse(in: CGRect(x: -baseRadius, y: -baseRadius, width: goboSize, height: goboSize))
            return
        }

        // Create a rect centered at origin
        let rect = CGRect(x: -baseRadius, y: -baseRadius, width: goboSize, height: goboSize)

        // Draw the gobo image with color tinting
        // First, draw the gobo as a mask
        ctx.saveGState()

        // Clip to the gobo shape
        ctx.clip(to: rect, mask: goboImage)

        // Fill with the object's color
        ctx.setFillColor(object.color.cgColor)
        ctx.fill(rect)

        ctx.restoreGState()
    }

    private func polygonPath(sides: Int, radius: CGFloat, star: Bool) -> CGPath {
        let path = CGMutablePath()
        guard sides >= 3 else { return path }
        let step = 2 * CGFloat.pi / CGFloat(sides)
        // Offset for flat-edge orientation (squares, hexagons)
        let offset: CGFloat = (sides == 4 || sides == 6) ? (step / 2) : 0
        for i in 0..<sides {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * step + offset
            let pt = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if i == 0 {
                path.move(to: pt)
            } else {
                path.addLine(to: pt)
            }
        }
        path.closeSubpath()
        if star {
            let starPath = CGMutablePath()
            let points = (0..<sides).map { i -> CGPoint in
                let angle = -CGFloat.pi / 2 + CGFloat(i) * step
                return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }
            starPath.move(to: points[0])
            for i in 1...sides {
                let idx = (i * 2) % sides
                starPath.addLine(to: points[idx])
            }
            starPath.closeSubpath()
            return starPath
        }
        return path
    }

    private func starPath(points: Int, radius: CGFloat) -> CGPath {
        let outer = radius
        let inner = radius * 0.5
        let total = points * 2
        let step = CGFloat.pi * 2 / CGFloat(total)
        let path = CGMutablePath()
        for i in 0..<total {
            let r = (i % 2 == 0) ? outer : inner
            let angle = -CGFloat.pi / 2 + CGFloat(i) * step
            let pt = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Settings Window Controller

struct SettingsConfig {
    var fixtureCount: Int
    var startUniverse: Int
    var startAddress: Int
    var startFixtureId: Int
    var protocolType: DMXProtocol
    var networkInterface: NetworkInterface
    var resolutionWidth: Int
    var resolutionHeight: Int
    var mode: DMXMode

    var universeCount: Int {
        return max(1, (fixtureCount + mode.fixturesPerUniverse - 1) / mode.fixturesPerUniverse)
    }

    var resolution: CGSize {
        return CGSize(width: resolutionWidth, height: resolutionHeight)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let controller: SceneController
    private let receiver: DMXReceiver
    private let state: DMXState
    private let maxObjects: Int
    private var onApply: ((SettingsConfig) -> Void)?
    private var statusTimer: Timer?

    private var fixtureCountField: NSTextField!
    private var startFixtureIdField: NSTextField!
    private var modePopup: NSPopUpButton!
    private var universeField: NSTextField!
    private var startAddressField: NSTextField!
    private var protocolPopup: NSPopUpButton!
    private var interfacePopup: NSPopUpButton!
    private var patchInfoLabel: NSTextField!
    private var connectionStatusLabel: NSTextField!
    private var packetStatusLabel: NSTextField!
    private var patchTableView: NSTableView!
    private var patchScrollView: NSScrollView!
    private var patchButton: NSButton!
    private var setModePopup: NSPopUpButton!

    // Resolution fields
    private var resolutionPopup: NSPopUpButton!
    private var widthField: NSTextField!
    private var heightField: NSTextField!

    private var availableInterfaces: [NetworkInterface] = []

    // Media tab
    private var tabView: NSTabView!
    private var videoTableView: NSTableView!
    private var videoLayers: [(layer: Int, filename: String?)] = []
    private var ndiInterfacePopup: NSPopUpButton!
    private var ndiSameAsDMXCheck: NSButton!
    private var ndiLegacyModeCheck: NSButton!

    // Custom tab buttons
    private var tabButtonStack: NSStackView!
    private var tabColors: [NSColor] = []

    init(controller: SceneController, receiver: DMXReceiver, state: DMXState, maxObjects: Int, onApply: @escaping (SettingsConfig) -> Void) {
        self.controller = controller
        self.receiver = receiver
        self.state = state
        self.maxObjects = maxObjects
        self.onApply = onApply
        self.availableInterfaces = NetworkInterface.all()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "◈ SETTINGS ◈"
        window.isReleasedWhenClosed = false
        RetroTheme.styleWindow(window)

        super.init(window: window)
        loadVideoLayers()
        setupUI()
        updateFields()
        startStatusTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func cleanup() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func loadVideoLayers() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let mediaBasePath = documentsPath.appendingPathComponent("DMXMedia")
        let videoExtensions = ["mp4", "mov", "m4v", "avi"]

        videoLayers = []
        for layer in 1...25 {
            let layerPath = mediaBasePath.appendingPathComponent("layer_\(String(format: "%02d", layer))")
            var filename: String? = nil

            if let contents = try? FileManager.default.contentsOfDirectory(at: layerPath, includingPropertiesForKeys: nil) {
                let videos = contents.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                filename = videos.first?.lastPathComponent
            }

            videoLayers.append((layer: layer, filename: filename))
        }
    }

    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePacketStatus()
            }
        }
    }

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        RetroTheme.styleContentView(contentView, withGrid: true)

        // Create custom tab buttons for better visibility
        let tabButtonStack = NSStackView()
        tabButtonStack.translatesAutoresizingMaskIntoConstraints = false
        tabButtonStack.orientation = .horizontal
        tabButtonStack.spacing = 8
        tabButtonStack.distribution = .fillEqually
        contentView.addSubview(tabButtonStack)

        let tabColors: [NSColor] = [RetroTheme.neonOrange, RetroTheme.neonCyan, RetroTheme.neonMagenta, RetroTheme.neonPurple]
        let tabTitles = ["◆ DMX", "◆ DISPLAY", "◆ MEDIA", "◆ PRISMATICS"]

        for (index, title) in tabTitles.enumerated() {
            let btn = NSButton(title: title, target: self, action: #selector(tabButtonClicked(_:)))
            btn.tag = index
            btn.bezelStyle = .rounded
            btn.font = RetroTheme.headerFont(size: 11)
            btn.wantsLayer = true
            btn.contentTintColor = tabColors[index]
            btn.layer?.cornerRadius = 4
            if index == 0 {
                btn.layer?.backgroundColor = tabColors[index].withAlphaComponent(0.2).cgColor
            }
            tabButtonStack.addArrangedSubview(btn)
        }
        self.tabButtonStack = tabButtonStack
        self.tabColors = tabColors

        // Create tab view (hidden tabs - we use custom buttons)
        tabView = NSTabView(frame: .zero)
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .noTabsNoBorder
        contentView.addSubview(tabView)

        // DMX Settings Tab
        let dmxTab = NSTabViewItem(identifier: "dmx")
        dmxTab.view = createDMXSettingsView()
        tabView.addTabViewItem(dmxTab)

        // Display Tab
        let displayTab = NSTabViewItem(identifier: "display")
        displayTab.view = createDisplaySettingsView()
        tabView.addTabViewItem(displayTab)

        // Media Tab
        let mediaTab = NSTabViewItem(identifier: "media")
        mediaTab.view = createMediaView()
        tabView.addTabViewItem(mediaTab)

        // Prismatics Tab
        let prismaticsTab = NSTabViewItem(identifier: "prismatics")
        prismaticsTab.view = createPrismaticsView()
        tabView.addTabViewItem(prismaticsTab)

        // Apply/Cancel buttons with retro styling
        let applyButton = NSButton(title: "▷ APPLY", target: self, action: #selector(applySettings))
        applyButton.keyEquivalent = "\r"
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        applyButton.font = RetroTheme.headerFont(size: 11)
        RetroTheme.styleButton(applyButton, color: RetroTheme.neonGreen)
        contentView.addSubview(applyButton)

        let cancelButton = NSButton(title: "◁ CANCEL", target: self, action: #selector(cancelSettings))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.font = RetroTheme.headerFont(size: 11)
        RetroTheme.styleButton(cancelButton, color: RetroTheme.textSecondary)
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            // Tab buttons at top
            tabButtonStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 15),
            tabButtonStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 15),
            tabButtonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -15),
            tabButtonStack.heightAnchor.constraint(equalToConstant: 30),

            // Tab content below buttons
            tabView.topAnchor.constraint(equalTo: tabButtonStack.bottomAnchor, constant: 10),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            tabView.bottomAnchor.constraint(equalTo: applyButton.topAnchor, constant: -15),

            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -15),
            cancelButton.trailingAnchor.constraint(equalTo: applyButton.leadingAnchor, constant: -12),

            applyButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -15),
            applyButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
        ])

        window.contentView = contentView
    }

    @objc private func tabButtonClicked(_ sender: NSButton) {
        let index = sender.tag
        tabView.selectTabViewItem(at: index)

        // Update button appearances
        for (i, view) in tabButtonStack.arrangedSubviews.enumerated() {
            guard let btn = view as? NSButton else { continue }
            if i == index {
                btn.layer?.backgroundColor = tabColors[i].withAlphaComponent(0.2).cgColor
            } else {
                btn.layer?.backgroundColor = nil
            }
        }
    }

    private func createDMXSettingsView() -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true

        // === Connection Section ===
        let connectionHeader = RetroTheme.makeLabel("◈ CONNECTION", style: .header, size: 11, color: RetroTheme.neonOrange)
        connectionHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(connectionHeader)

        let interfaceLabel = RetroTheme.makeLabel("Network Interface:", style: .body, size: 11)
        interfaceLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(interfaceLabel)

        interfacePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        interfacePopup.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.stylePopup(interfacePopup)
        for iface in availableInterfaces {
            interfacePopup.addItem(withTitle: iface.displayName)
        }
        interfacePopup.target = self
        interfacePopup.action = #selector(interfaceChanged)
        view.addSubview(interfacePopup)

        let protocolLabel = RetroTheme.makeLabel("Protocol:", style: .body, size: 11)
        protocolLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(protocolLabel)

        protocolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        protocolPopup.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.stylePopup(protocolPopup)
        for proto in DMXProtocol.allCases {
            protocolPopup.addItem(withTitle: proto.displayName)
        }
        protocolPopup.target = self
        protocolPopup.action = #selector(protocolChanged)
        view.addSubview(protocolPopup)

        connectionStatusLabel = NSTextField(labelWithString: "")
        connectionStatusLabel.isEditable = false
        connectionStatusLabel.isBordered = false
        connectionStatusLabel.backgroundColor = .clear
        connectionStatusLabel.font = RetroTheme.bodyFont(size: 11)
        connectionStatusLabel.textColor = RetroTheme.neonGreen
        connectionStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(connectionStatusLabel)

        packetStatusLabel = NSTextField(labelWithString: "No packets received")
        packetStatusLabel.isEditable = false
        packetStatusLabel.isBordered = false
        packetStatusLabel.backgroundColor = .clear
        packetStatusLabel.font = RetroTheme.numberFont(size: 11)
        packetStatusLabel.textColor = RetroTheme.neonOrange
        packetStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(packetStatusLabel)

        // === Patch Section ===
        let patchHeader = RetroTheme.makeLabel("◈ DMX PATCH", style: .header, size: 11, color: RetroTheme.neonCyan)
        patchHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(patchHeader)

        let universeLabel = RetroTheme.makeLabel("Universe (1-63999):", style: .body, size: 11)
        universeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(universeLabel)

        universeField = NSTextField(string: "")
        universeField.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleTextField(universeField, isNumeric: true, color: RetroTheme.neonCyan)
        let universeFormatter = NumberFormatter()
        universeFormatter.minimum = 1
        universeFormatter.maximum = 63999
        universeFormatter.allowsFloats = false
        universeField.formatter = universeFormatter
        universeField.target = self
        universeField.action = #selector(fieldsChanged)
        view.addSubview(universeField)

        let startAddrLabel = RetroTheme.makeLabel("Start Address (1-512):", style: .body, size: 11)
        startAddrLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(startAddrLabel)

        startAddressField = NSTextField(string: "")
        startAddressField.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleTextField(startAddressField, isNumeric: true, color: RetroTheme.neonCyan)
        let startAddrFormatter = NumberFormatter()
        startAddrFormatter.minimum = 1
        startAddrFormatter.maximum = 512
        startAddrFormatter.allowsFloats = false
        startAddressField.formatter = startAddrFormatter
        startAddressField.target = self
        startAddressField.action = #selector(fieldsChanged)
        view.addSubview(startAddressField)

        let fixtureLabel = RetroTheme.makeLabel("Fixture Count (1-\(maxObjects)):", style: .body, size: 11)
        fixtureLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fixtureLabel)

        fixtureCountField = NSTextField(string: "")
        fixtureCountField.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleTextField(fixtureCountField, isNumeric: true, color: RetroTheme.neonCyan)
        let fixtureFormatter = NumberFormatter()
        fixtureFormatter.minimum = 1
        fixtureFormatter.maximum = NSNumber(value: maxObjects)
        fixtureFormatter.allowsFloats = false
        fixtureCountField.formatter = fixtureFormatter
        fixtureCountField.target = self
        fixtureCountField.action = #selector(fieldsChanged)
        view.addSubview(fixtureCountField)

        let startIdLabel = RetroTheme.makeLabel("Starting Fixture ID:", style: .body, size: 11)
        startIdLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(startIdLabel)

        startFixtureIdField = NSTextField(string: "1")
        startFixtureIdField.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleTextField(startFixtureIdField, isNumeric: true, color: RetroTheme.neonCyan)
        let idFormatter = NumberFormatter()
        idFormatter.minimum = 1
        idFormatter.maximum = 9999
        idFormatter.allowsFloats = false
        startFixtureIdField.formatter = idFormatter
        startFixtureIdField.target = self
        startFixtureIdField.action = #selector(fieldsChanged)
        view.addSubview(startFixtureIdField)

        let modeLabel = RetroTheme.makeLabel("DMX Mode:", style: .body, size: 11)
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeLabel)

        modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.stylePopup(modePopup)
        for mode in DMXMode.allCases {
            modePopup.addItem(withTitle: mode.displayName)
        }
        modePopup.target = self
        modePopup.action = #selector(fieldsChanged)
        view.addSubview(modePopup)

        patchInfoLabel = NSTextField(labelWithString: "")
        patchInfoLabel.isEditable = false
        patchInfoLabel.isBordered = false
        patchInfoLabel.backgroundColor = .clear
        patchInfoLabel.textColor = RetroTheme.textSecondary
        patchInfoLabel.font = RetroTheme.bodyFont(size: 11)
        patchInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(patchInfoLabel)

        // === Fixture List Table ===
        let fixtureListHeader = RetroTheme.makeLabel("◈ FIXTURE LIST", style: .header, size: 11, color: RetroTheme.neonMagenta)
        fixtureListHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fixtureListHeader)

        patchTableView = NSTableView()
        patchTableView.style = .plain
        patchTableView.usesAlternatingRowBackgroundColors = true
        patchTableView.rowHeight = 18
        patchTableView.headerView?.frame.size.height = 22
        patchTableView.dataSource = self
        patchTableView.delegate = self
        patchTableView.allowsMultipleSelection = true  // Enable shift/cmd-click selection

        let idColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("id"))
        idColumn.title = "ID"
        idColumn.width = 40
        idColumn.minWidth = 30
        patchTableView.addTableColumn(idColumn)

        let univColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("universe"))
        univColumn.title = "Univ"
        univColumn.width = 50
        univColumn.minWidth = 40
        patchTableView.addTableColumn(univColumn)

        let addrColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("address"))
        addrColumn.title = "Addr"
        addrColumn.width = 50
        addrColumn.minWidth = 40
        patchTableView.addTableColumn(addrColumn)

        let channelsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channels"))
        channelsColumn.title = "Channels"
        channelsColumn.width = 80
        channelsColumn.minWidth = 60
        patchTableView.addTableColumn(channelsColumn)

        let modeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mode"))
        modeColumn.title = "Mode"
        modeColumn.width = 70
        modeColumn.minWidth = 50
        patchTableView.addTableColumn(modeColumn)

        patchScrollView = NSScrollView()
        patchScrollView.documentView = patchTableView
        patchScrollView.hasVerticalScroller = true
        patchScrollView.hasHorizontalScroller = false
        patchScrollView.autohidesScrollers = true
        patchScrollView.borderType = .bezelBorder
        patchScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(patchScrollView)

        let addFixtureButton = NSButton(title: "+", target: self, action: #selector(addFixture))
        addFixtureButton.bezelStyle = .smallSquare
        addFixtureButton.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleButton(addFixtureButton, color: RetroTheme.neonGreen)
        view.addSubview(addFixtureButton)

        let removeFixtureButton = NSButton(title: "-", target: self, action: #selector(removeFixture))
        removeFixtureButton.bezelStyle = .smallSquare
        removeFixtureButton.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleButton(removeFixtureButton, color: RetroTheme.neonRed)
        view.addSubview(removeFixtureButton)

        // Set Mode popup for selected fixtures
        let setModeLabel = NSTextField(labelWithString: "Set Selected:")
        setModeLabel.font = NSFont.systemFont(ofSize: 11)
        setModeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(setModeLabel)

        setModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        setModePopup.addItems(withTitles: DMXMode.allCases.map { $0.shortName })
        setModePopup.target = self
        setModePopup.action = #selector(setModeForSelected)
        setModePopup.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(setModePopup)

        patchButton = NSButton(title: "▷ PATCH", target: self, action: #selector(patchFixtures))
        patchButton.bezelStyle = .rounded
        patchButton.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleButton(patchButton, color: RetroTheme.neonCyan)
        view.addSubview(patchButton)

        let refreshButton = NSButton(title: "⟳ REFRESH", target: self, action: #selector(refreshInterfaces))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleButton(refreshButton, color: RetroTheme.neonOrange)
        view.addSubview(refreshButton)

        let labelWidth: CGFloat = 160

        NSLayoutConstraint.activate([
            connectionHeader.topAnchor.constraint(equalTo: view.topAnchor, constant: 15),
            connectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            interfaceLabel.topAnchor.constraint(equalTo: connectionHeader.bottomAnchor, constant: 12),
            interfaceLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            interfaceLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            interfacePopup.centerYAnchor.constraint(equalTo: interfaceLabel.centerYAnchor),
            interfacePopup.leadingAnchor.constraint(equalTo: interfaceLabel.trailingAnchor, constant: 8),
            interfacePopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            protocolLabel.topAnchor.constraint(equalTo: interfaceLabel.bottomAnchor, constant: 12),
            protocolLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            protocolLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            protocolPopup.centerYAnchor.constraint(equalTo: protocolLabel.centerYAnchor),
            protocolPopup.leadingAnchor.constraint(equalTo: protocolLabel.trailingAnchor, constant: 8),
            protocolPopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            connectionStatusLabel.topAnchor.constraint(equalTo: protocolLabel.bottomAnchor, constant: 8),
            connectionStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            connectionStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            packetStatusLabel.topAnchor.constraint(equalTo: connectionStatusLabel.bottomAnchor, constant: 4),
            packetStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            packetStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            patchHeader.topAnchor.constraint(equalTo: packetStatusLabel.bottomAnchor, constant: 20),
            patchHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            universeLabel.topAnchor.constraint(equalTo: patchHeader.bottomAnchor, constant: 12),
            universeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            universeLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            universeField.centerYAnchor.constraint(equalTo: universeLabel.centerYAnchor),
            universeField.leadingAnchor.constraint(equalTo: universeLabel.trailingAnchor, constant: 8),
            universeField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            startAddrLabel.topAnchor.constraint(equalTo: universeLabel.bottomAnchor, constant: 12),
            startAddrLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            startAddrLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            startAddressField.centerYAnchor.constraint(equalTo: startAddrLabel.centerYAnchor),
            startAddressField.leadingAnchor.constraint(equalTo: startAddrLabel.trailingAnchor, constant: 8),
            startAddressField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            fixtureLabel.topAnchor.constraint(equalTo: startAddrLabel.bottomAnchor, constant: 12),
            fixtureLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            fixtureLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            fixtureCountField.centerYAnchor.constraint(equalTo: fixtureLabel.centerYAnchor),
            fixtureCountField.leadingAnchor.constraint(equalTo: fixtureLabel.trailingAnchor, constant: 8),
            fixtureCountField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            startIdLabel.topAnchor.constraint(equalTo: fixtureLabel.bottomAnchor, constant: 12),
            startIdLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            startIdLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            startFixtureIdField.centerYAnchor.constraint(equalTo: startIdLabel.centerYAnchor),
            startFixtureIdField.leadingAnchor.constraint(equalTo: startIdLabel.trailingAnchor, constant: 8),
            startFixtureIdField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            modeLabel.topAnchor.constraint(equalTo: startIdLabel.bottomAnchor, constant: 12),
            modeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            modeLabel.widthAnchor.constraint(equalToConstant: labelWidth),

            modePopup.centerYAnchor.constraint(equalTo: modeLabel.centerYAnchor),
            modePopup.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 8),
            modePopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            patchInfoLabel.topAnchor.constraint(equalTo: modeLabel.bottomAnchor, constant: 12),
            patchInfoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            patchInfoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            fixtureListHeader.topAnchor.constraint(equalTo: patchInfoLabel.bottomAnchor, constant: 20),
            fixtureListHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            patchScrollView.topAnchor.constraint(equalTo: fixtureListHeader.bottomAnchor, constant: 8),
            patchScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            patchScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),
            patchScrollView.heightAnchor.constraint(equalToConstant: 150),

            addFixtureButton.topAnchor.constraint(equalTo: patchScrollView.bottomAnchor, constant: 8),
            addFixtureButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            addFixtureButton.widthAnchor.constraint(equalToConstant: 30),

            removeFixtureButton.topAnchor.constraint(equalTo: patchScrollView.bottomAnchor, constant: 8),
            removeFixtureButton.leadingAnchor.constraint(equalTo: addFixtureButton.trailingAnchor, constant: 4),
            removeFixtureButton.widthAnchor.constraint(equalToConstant: 30),

            setModeLabel.centerYAnchor.constraint(equalTo: addFixtureButton.centerYAnchor),
            setModeLabel.leadingAnchor.constraint(equalTo: removeFixtureButton.trailingAnchor, constant: 15),

            setModePopup.centerYAnchor.constraint(equalTo: addFixtureButton.centerYAnchor),
            setModePopup.leadingAnchor.constraint(equalTo: setModeLabel.trailingAnchor, constant: 4),
            setModePopup.widthAnchor.constraint(equalToConstant: 70),

            patchButton.centerYAnchor.constraint(equalTo: addFixtureButton.centerYAnchor),
            patchButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            refreshButton.topAnchor.constraint(equalTo: addFixtureButton.bottomAnchor, constant: 15),
            refreshButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
        ])

        return view
    }

    private func createDisplaySettingsView() -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true

        // === Resolution Section ===
        let resolutionHeader = RetroTheme.makeLabel("◈ CANVAS RESOLUTION", style: .header, size: 11, color: RetroTheme.neonCyan)
        resolutionHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resolutionHeader)

        // Preset dropdown
        let presetLabel = RetroTheme.makeLabel("Preset:", style: .body, size: 11)
        presetLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(presetLabel)

        resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        resolutionPopup.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.stylePopup(resolutionPopup)
        for preset in ResolutionPreset.allCases {
            resolutionPopup.addItem(withTitle: preset.rawValue)
        }
        resolutionPopup.target = self
        resolutionPopup.action = #selector(resolutionPresetChanged)
        view.addSubview(resolutionPopup)

        // Width field
        let widthLabel = RetroTheme.makeLabel("Width:", style: .body, size: 11)
        widthLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(widthLabel)

        widthField = NSTextField(string: "")
        widthField.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleTextField(widthField, isNumeric: true, color: RetroTheme.neonCyan)
        let widthFormatter = NumberFormatter()
        widthFormatter.minimum = 320
        widthFormatter.maximum = 7680
        widthFormatter.allowsFloats = false
        widthField.formatter = widthFormatter
        widthField.target = self
        widthField.action = #selector(resolutionFieldsChanged)
        view.addSubview(widthField)

        // Height field
        let heightLabel = RetroTheme.makeLabel("Height:", style: .body, size: 11)
        heightLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heightLabel)

        heightField = NSTextField(string: "")
        heightField.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleTextField(heightField, isNumeric: true, color: RetroTheme.neonCyan)
        let heightFormatter = NumberFormatter()
        heightFormatter.minimum = 240
        heightFormatter.maximum = 4320
        heightFormatter.allowsFloats = false
        heightField.formatter = heightFormatter
        heightField.target = self
        heightField.action = #selector(resolutionFieldsChanged)
        view.addSubview(heightField)

        // Info label
        let infoLabel = RetroTheme.makeLabel("Note: Changing resolution requires restart to take effect.", style: .body, size: 10)
        infoLabel.textColor = RetroTheme.neonOrange
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        // Current resolution display
        let currentLabel = RetroTheme.makeLabel("Current: \(Int(canvasSize.width))x\(Int(canvasSize.height))", style: .number, size: 11, color: RetroTheme.neonGreen)
        currentLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(currentLabel)

        // Set current values
        widthField.integerValue = Int(canvasSize.width)
        heightField.integerValue = Int(canvasSize.height)
        let currentPreset = ResolutionPreset.from(size: canvasSize)
        if let index = ResolutionPreset.allCases.firstIndex(of: currentPreset) {
            resolutionPopup.selectItem(at: index)
        }

        NSLayoutConstraint.activate([
            resolutionHeader.topAnchor.constraint(equalTo: view.topAnchor, constant: 15),
            resolutionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            presetLabel.topAnchor.constraint(equalTo: resolutionHeader.bottomAnchor, constant: 15),
            presetLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            presetLabel.widthAnchor.constraint(equalToConstant: 60),

            resolutionPopup.centerYAnchor.constraint(equalTo: presetLabel.centerYAnchor),
            resolutionPopup.leadingAnchor.constraint(equalTo: presetLabel.trailingAnchor, constant: 8),
            resolutionPopup.widthAnchor.constraint(equalToConstant: 180),

            widthLabel.topAnchor.constraint(equalTo: presetLabel.bottomAnchor, constant: 15),
            widthLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            widthLabel.widthAnchor.constraint(equalToConstant: 60),

            widthField.centerYAnchor.constraint(equalTo: widthLabel.centerYAnchor),
            widthField.leadingAnchor.constraint(equalTo: widthLabel.trailingAnchor, constant: 8),
            widthField.widthAnchor.constraint(equalToConstant: 80),

            heightLabel.centerYAnchor.constraint(equalTo: widthLabel.centerYAnchor),
            heightLabel.leadingAnchor.constraint(equalTo: widthField.trailingAnchor, constant: 20),

            heightField.centerYAnchor.constraint(equalTo: heightLabel.centerYAnchor),
            heightField.leadingAnchor.constraint(equalTo: heightLabel.trailingAnchor, constant: 8),
            heightField.widthAnchor.constraint(equalToConstant: 80),

            infoLabel.topAnchor.constraint(equalTo: widthLabel.bottomAnchor, constant: 20),
            infoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            currentLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 8),
            currentLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
        ])

        return view
    }

    @objc private func resolutionPresetChanged() {
        let index = resolutionPopup.indexOfSelectedItem
        guard index >= 0 && index < ResolutionPreset.allCases.count else { return }
        let preset = ResolutionPreset.allCases[index]
        if let size = preset.size {
            widthField.integerValue = Int(size.width)
            heightField.integerValue = Int(size.height)
        }
        // Enable/disable custom fields based on preset
        let isCustom = preset == .custom
        widthField.isEnabled = true
        heightField.isEnabled = true
    }

    @objc private func resolutionFieldsChanged() {
        // Update preset popup if dimensions match a preset
        let size = CGSize(width: CGFloat(widthField.integerValue), height: CGFloat(heightField.integerValue))
        let preset = ResolutionPreset.from(size: size)
        if let index = ResolutionPreset.allCases.firstIndex(of: preset) {
            resolutionPopup.selectItem(at: index)
        }
    }

    private func createMediaView() -> NSView {
        let view = NSView(frame: .zero)

        // Header
        let header = RetroTheme.makeLabel("◈ VIDEO LAYERS", style: .header, size: 11, color: RetroTheme.neonMagenta)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let infoLabel = RetroTheme.makeLabel("DMX values 201-225 select Video layers 1-25", style: .body, size: 10, color: RetroTheme.neonMagenta.withAlphaComponent(0.6))
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        // Scroll view with table
        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        view.addSubview(scrollView)

        videoTableView = NSTableView(frame: .zero)
        videoTableView.dataSource = self
        videoTableView.delegate = self
        videoTableView.rowHeight = 24
        videoTableView.usesAlternatingRowBackgroundColors = true

        let layerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        layerColumn.title = "Layer"
        layerColumn.width = 50
        videoTableView.addTableColumn(layerColumn)

        let dmxColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dmx"))
        dmxColumn.title = "DMX"
        dmxColumn.width = 45
        videoTableView.addTableColumn(dmxColumn)

        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fileColumn.title = "Video File"
        fileColumn.width = 280
        videoTableView.addTableColumn(fileColumn)

        scrollView.documentView = videoTableView

        // Buttons
        let openFolderButton = NSButton(title: "📁 OPEN FOLDER", target: self, action: #selector(openMediaFolder))
        openFolderButton.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleButton(openFolderButton, color: RetroTheme.neonMagenta)
        view.addSubview(openFolderButton)

        let refreshButton = NSButton(title: "⟳ REFRESH", target: self, action: #selector(refreshVideoList))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleButton(refreshButton, color: RetroTheme.neonOrange)
        view.addSubview(refreshButton)

        let helpLabel = RetroTheme.makeLabel("Drop video files (MP4, MOV) into layer folders", style: .body, size: 10, color: RetroTheme.neonOrange.withAlphaComponent(0.7))
        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(helpLabel)

        // === NDI Network Interface Section ===
        let ndiHeader = RetroTheme.makeLabel("◈ NDI OUTPUT NETWORK", style: .header, size: 11, color: RetroTheme.neonCyan)
        ndiHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ndiHeader)

        ndiSameAsDMXCheck = NSButton(checkboxWithTitle: "Same as DMX", target: self, action: #selector(ndiSameAsDMXChanged))
        ndiSameAsDMXCheck.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ndiSameAsDMXCheck)

        let ndiInterfaceLabel = RetroTheme.makeLabel("NDI Interface:", style: .body, size: 11, color: RetroTheme.neonCyan)
        ndiInterfaceLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ndiInterfaceLabel)

        ndiInterfacePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        ndiInterfacePopup.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.stylePopup(ndiInterfacePopup)
        ndiInterfacePopup.addItem(withTitle: "All Interfaces (0.0.0.0)")
        ndiInterfacePopup.addItem(withTitle: "Loopback (127.0.0.1)")
        for iface in availableInterfaces where !iface.isLoopback {
            ndiInterfacePopup.addItem(withTitle: iface.displayName)
        }
        ndiInterfacePopup.target = self
        ndiInterfacePopup.action = #selector(ndiInterfaceChanged)
        view.addSubview(ndiInterfacePopup)

        // Load current NDI interface setting
        let currentNDIInterface = OutputManager.shared.ndiNetworkInterface
        if currentNDIInterface.isEmpty {
            ndiSameAsDMXCheck.state = .on
            ndiInterfacePopup.isEnabled = false
        } else {
            ndiSameAsDMXCheck.state = .off
            ndiInterfacePopup.isEnabled = true
            // Find and select the matching interface
            if currentNDIInterface == "127.0.0.1" {
                ndiInterfacePopup.selectItem(at: 1)  // Loopback item
            } else {
                for (idx, iface) in availableInterfaces.enumerated() where !iface.isLoopback {
                    if iface.ip == currentNDIInterface {
                        ndiInterfacePopup.selectItem(at: idx + 2)  // +2 for "All Interfaces" and "Loopback" items
                        break
                    }
                }
            }
        }

        // Legacy NDI mode checkbox
        ndiLegacyModeCheck = NSButton(checkboxWithTitle: "Use Legacy NDI (more compatible)", target: self, action: #selector(ndiLegacyModeChanged))
        ndiLegacyModeCheck.translatesAutoresizingMaskIntoConstraints = false
        ndiLegacyModeCheck.toolTip = "Enable for better compatibility with some NDI receivers. Uses synchronous sending which may reduce performance but improves stability."
        view.addSubview(ndiLegacyModeCheck)

        // Load legacy mode preference
        let legacyEnabled = UserDefaults.standard.bool(forKey: "NDILegacyMode")
        ndiLegacyModeCheck.state = legacyEnabled ? .on : .off
        // Apply legacy mode to all existing NDI outputs
        for output in OutputManager.shared.getAllOutputs() where output.type == .NDI {
            output.ndiOutput?.setLegacyMode(legacyEnabled)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 15),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            infoLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),
            scrollView.bottomAnchor.constraint(equalTo: openFolderButton.topAnchor, constant: -10),

            openFolderButton.bottomAnchor.constraint(equalTo: helpLabel.topAnchor, constant: -8),
            openFolderButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            refreshButton.centerYAnchor.constraint(equalTo: openFolderButton.centerYAnchor),
            refreshButton.leadingAnchor.constraint(equalTo: openFolderButton.trailingAnchor, constant: 10),

            helpLabel.bottomAnchor.constraint(equalTo: ndiHeader.topAnchor, constant: -15),
            helpLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            // NDI section
            ndiHeader.bottomAnchor.constraint(equalTo: ndiSameAsDMXCheck.topAnchor, constant: -8),
            ndiHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            ndiSameAsDMXCheck.bottomAnchor.constraint(equalTo: ndiInterfaceLabel.topAnchor, constant: -6),
            ndiSameAsDMXCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            ndiInterfaceLabel.bottomAnchor.constraint(equalTo: ndiLegacyModeCheck.topAnchor, constant: -8),
            ndiInterfaceLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            ndiInterfacePopup.centerYAnchor.constraint(equalTo: ndiInterfaceLabel.centerYAnchor),
            ndiInterfacePopup.leadingAnchor.constraint(equalTo: ndiInterfaceLabel.trailingAnchor, constant: 8),
            ndiInterfacePopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            ndiLegacyModeCheck.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            ndiLegacyModeCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
        ])

        return view
    }

    // MARK: - Prismatics Tab

    private var paletteTableView: NSTableView!
    private var colorSwatchesView: NSStackView!
    private var selectedPaletteIndex: Int = -1
    private var paletteNameField: NSTextField!
    private var editingColorIndex: Int = -1  // Track which color swatch is being edited

    private func createPrismaticsView() -> NSView {
        let view = NSView(frame: .zero)

        // Header
        let header = RetroTheme.makeLabel("◈ COLOR PALETTES", style: .header, size: 11, color: RetroTheme.neonPurple)
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let infoLabel = RetroTheme.makeLabel("Define multi-color palettes for prismatic effects", style: .body, size: 10, color: RetroTheme.neonPurple.withAlphaComponent(0.6))
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoLabel)

        // Palette list (left side)
        let paletteScrollView = NSScrollView(frame: .zero)
        paletteScrollView.translatesAutoresizingMaskIntoConstraints = false
        paletteScrollView.hasVerticalScroller = true
        paletteScrollView.borderType = .bezelBorder
        view.addSubview(paletteScrollView)

        paletteTableView = NSTableView(frame: .zero)
        paletteTableView.dataSource = self
        paletteTableView.delegate = self
        paletteTableView.rowHeight = 36
        paletteTableView.usesAlternatingRowBackgroundColors = true
        paletteTableView.target = self
        paletteTableView.action = #selector(paletteTableClicked)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("paletteName"))
        nameColumn.title = "Palette"
        nameColumn.width = 120
        paletteTableView.addTableColumn(nameColumn)

        let previewColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("palettePreview"))
        previewColumn.title = "Colors"
        previewColumn.width = 180
        paletteTableView.addTableColumn(previewColumn)

        paletteScrollView.documentView = paletteTableView

        // Add/Remove palette buttons
        let addPaletteButton = NSButton(title: "+", target: self, action: #selector(addNewPalette))
        addPaletteButton.translatesAutoresizingMaskIntoConstraints = false
        addPaletteButton.bezelStyle = .smallSquare
        RetroTheme.styleButton(addPaletteButton, color: RetroTheme.neonGreen)
        view.addSubview(addPaletteButton)

        let removePaletteButton = NSButton(title: "-", target: self, action: #selector(removeSelectedPalette))
        removePaletteButton.translatesAutoresizingMaskIntoConstraints = false
        removePaletteButton.bezelStyle = .smallSquare
        RetroTheme.styleButton(removePaletteButton, color: RetroTheme.neonRed)
        view.addSubview(removePaletteButton)

        // Editor section (right side) - Edit selected palette
        let editorBox = NSBox(frame: .zero)
        editorBox.translatesAutoresizingMaskIntoConstraints = false
        editorBox.title = "◈ EDIT PALETTE"
        editorBox.titlePosition = .atTop
        editorBox.titleFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        editorBox.borderColor = RetroTheme.neonPurple.withAlphaComponent(0.3)
        view.addSubview(editorBox)

        let editorContent = NSView(frame: .zero)
        editorContent.translatesAutoresizingMaskIntoConstraints = false
        editorBox.contentView = editorContent

        // Palette name field
        let nameLabel = RetroTheme.makeLabel("Name:", style: .body, size: 11, color: RetroTheme.neonPurple)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        editorContent.addSubview(nameLabel)

        paletteNameField = NSTextField(string: "")
        paletteNameField.translatesAutoresizingMaskIntoConstraints = false
        paletteNameField.placeholderString = "Palette name"
        RetroTheme.styleTextField(paletteNameField, isNumeric: false, color: RetroTheme.neonPurple)
        paletteNameField.target = self
        paletteNameField.action = #selector(paletteNameChanged)
        editorContent.addSubview(paletteNameField)

        // Color swatches display
        let colorsLabel = RetroTheme.makeLabel("Colors:", style: .body, size: 11, color: RetroTheme.neonPurple)
        colorsLabel.translatesAutoresizingMaskIntoConstraints = false
        editorContent.addSubview(colorsLabel)

        colorSwatchesView = NSStackView(frame: .zero)
        colorSwatchesView.translatesAutoresizingMaskIntoConstraints = false
        colorSwatchesView.orientation = .horizontal
        colorSwatchesView.spacing = 4
        colorSwatchesView.distribution = .fillEqually
        editorContent.addSubview(colorSwatchesView)

        // Add color button
        let addColorButton = NSButton(title: "+ ADD", target: self, action: #selector(addColorToPalette))
        addColorButton.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleButton(addColorButton, color: RetroTheme.neonGreen)
        editorContent.addSubview(addColorButton)

        // Remove color button
        let removeColorButton = NSButton(title: "- REMOVE", target: self, action: #selector(removeLastColor))
        removeColorButton.translatesAutoresizingMaskIntoConstraints = false
        RetroTheme.styleButton(removeColorButton, color: RetroTheme.neonRed)
        editorContent.addSubview(removeColorButton)

        // Constraints
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 15),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),

            infoLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),

            paletteScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            paletteScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            paletteScrollView.widthAnchor.constraint(equalToConstant: 320),
            paletteScrollView.bottomAnchor.constraint(equalTo: addPaletteButton.topAnchor, constant: -8),

            addPaletteButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
            addPaletteButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            addPaletteButton.widthAnchor.constraint(equalToConstant: 30),

            removePaletteButton.leadingAnchor.constraint(equalTo: addPaletteButton.trailingAnchor, constant: 4),
            removePaletteButton.centerYAnchor.constraint(equalTo: addPaletteButton.centerYAnchor),
            removePaletteButton.widthAnchor.constraint(equalToConstant: 30),

            editorBox.topAnchor.constraint(equalTo: paletteScrollView.topAnchor),
            editorBox.leadingAnchor.constraint(equalTo: paletteScrollView.trailingAnchor, constant: 15),
            editorBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -15),
            editorBox.heightAnchor.constraint(equalToConstant: 180),

            // Editor content constraints
            nameLabel.topAnchor.constraint(equalTo: editorContent.topAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: editorContent.leadingAnchor, constant: 10),
            nameLabel.widthAnchor.constraint(equalToConstant: 50),

            paletteNameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            paletteNameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            paletteNameField.trailingAnchor.constraint(equalTo: editorContent.trailingAnchor, constant: -10),

            colorsLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 15),
            colorsLabel.leadingAnchor.constraint(equalTo: editorContent.leadingAnchor, constant: 10),

            colorSwatchesView.topAnchor.constraint(equalTo: colorsLabel.bottomAnchor, constant: 8),
            colorSwatchesView.leadingAnchor.constraint(equalTo: editorContent.leadingAnchor, constant: 10),
            colorSwatchesView.trailingAnchor.constraint(equalTo: editorContent.trailingAnchor, constant: -10),
            colorSwatchesView.heightAnchor.constraint(equalToConstant: 30),

            addColorButton.topAnchor.constraint(equalTo: colorSwatchesView.bottomAnchor, constant: 15),
            addColorButton.leadingAnchor.constraint(equalTo: editorContent.leadingAnchor, constant: 10),

            removeColorButton.centerYAnchor.constraint(equalTo: addColorButton.centerYAnchor),
            removeColorButton.leadingAnchor.constraint(equalTo: addColorButton.trailingAnchor, constant: 10),
        ])

        return view
    }

    @objc private func paletteTableClicked() {
        let row = paletteTableView.selectedRow
        if row >= 0 && row < PaletteManager.shared.palettes.count {
            selectedPaletteIndex = row
            updatePaletteEditor()
        }
    }

    @objc private func addNewPalette() {
        let newPalette = ColorPalette(name: "New Palette", colors: [
            ColorPalette.PaletteColor(red: 1.0, green: 0.0, blue: 0.0),
            ColorPalette.PaletteColor(red: 0.0, green: 0.0, blue: 1.0),
        ])
        PaletteManager.shared.addPalette(newPalette)
        paletteTableView.reloadData()
        selectedPaletteIndex = PaletteManager.shared.palettes.count - 1
        paletteTableView.selectRowIndexes(IndexSet(integer: selectedPaletteIndex), byExtendingSelection: false)
        updatePaletteEditor()
    }

    @objc private func removeSelectedPalette() {
        guard selectedPaletteIndex >= 0 && selectedPaletteIndex < PaletteManager.shared.palettes.count else { return }
        PaletteManager.shared.deletePalette(at: selectedPaletteIndex)
        paletteTableView.reloadData()
        selectedPaletteIndex = min(selectedPaletteIndex, PaletteManager.shared.palettes.count - 1)
        if selectedPaletteIndex >= 0 {
            paletteTableView.selectRowIndexes(IndexSet(integer: selectedPaletteIndex), byExtendingSelection: false)
        }
        updatePaletteEditor()
    }

    @objc private func paletteNameChanged() {
        guard selectedPaletteIndex >= 0 && selectedPaletteIndex < PaletteManager.shared.palettes.count else { return }
        var palette = PaletteManager.shared.palettes[selectedPaletteIndex]
        palette.name = paletteNameField.stringValue
        PaletteManager.shared.updatePalette(palette)
        paletteTableView.reloadData()
    }

    @objc private func addColorToPalette() {
        guard selectedPaletteIndex >= 0 && selectedPaletteIndex < PaletteManager.shared.palettes.count else { return }
        var palette = PaletteManager.shared.palettes[selectedPaletteIndex]
        guard palette.colors.count < 8 else { return }  // Max 8 colors

        // Show color picker
        let colorPanel = NSColorPanel.shared
        colorPanel.setTarget(self)
        colorPanel.setAction(#selector(colorPickerChanged))
        colorPanel.color = NSColor.white
        colorPanel.orderFront(nil)
    }

    @objc private func colorPickerChanged(_ sender: NSColorPanel) {
        guard selectedPaletteIndex >= 0 && selectedPaletteIndex < PaletteManager.shared.palettes.count else { return }
        var palette = PaletteManager.shared.palettes[selectedPaletteIndex]
        guard palette.colors.count < 8 else { return }

        // Convert color to calibrated RGB
        guard let rgbColor = sender.color.usingColorSpace(.genericRGB) else { return }
        let newColor = ColorPalette.PaletteColor(color: rgbColor)
        palette.colors.append(newColor)
        PaletteManager.shared.updatePalette(palette)
        updatePaletteEditor()
        paletteTableView.reloadData()

        // Close color panel after adding
        sender.orderOut(nil)
    }

    @objc private func removeLastColor() {
        guard selectedPaletteIndex >= 0 && selectedPaletteIndex < PaletteManager.shared.palettes.count else { return }
        var palette = PaletteManager.shared.palettes[selectedPaletteIndex]
        guard palette.colors.count > 1 else { return }  // Keep at least 1 color
        palette.colors.removeLast()
        PaletteManager.shared.updatePalette(palette)
        updatePaletteEditor()
        paletteTableView.reloadData()
    }

    private func updatePaletteEditor() {
        // Clear existing swatches
        colorSwatchesView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard selectedPaletteIndex >= 0 && selectedPaletteIndex < PaletteManager.shared.palettes.count else {
            paletteNameField.stringValue = ""
            return
        }

        let palette = PaletteManager.shared.palettes[selectedPaletteIndex]
        paletteNameField.stringValue = palette.name

        // Add color swatches
        for (index, color) in palette.colors.enumerated() {
            let swatch = NSButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.nsColor.cgColor
            swatch.layer?.cornerRadius = 4
            swatch.layer?.borderWidth = 1
            swatch.layer?.borderColor = NSColor.separatorColor.cgColor
            swatch.isBordered = false
            swatch.title = ""
            swatch.tag = index
            swatch.target = self
            swatch.action = #selector(swatchClicked(_:))
            colorSwatchesView.addArrangedSubview(swatch)
        }
    }

    @objc private func swatchClicked(_ sender: NSButton) {
        guard selectedPaletteIndex >= 0 && selectedPaletteIndex < PaletteManager.shared.palettes.count else { return }
        let colorIndex = sender.tag
        let palette = PaletteManager.shared.palettes[selectedPaletteIndex]
        guard colorIndex < palette.colors.count else { return }

        // Open color picker to edit this specific color
        editingColorIndex = colorIndex
        let colorPanel = NSColorPanel.shared
        colorPanel.color = palette.colors[colorIndex].nsColor
        colorPanel.setTarget(self)
        colorPanel.setAction(#selector(editColorChanged(_:)))
        colorPanel.orderFront(nil)
    }

    @objc private func editColorChanged(_ sender: NSColorPanel) {
        guard selectedPaletteIndex >= 0 && selectedPaletteIndex < PaletteManager.shared.palettes.count,
              editingColorIndex >= 0 else { return }
        var palette = PaletteManager.shared.palettes[selectedPaletteIndex]
        guard editingColorIndex < palette.colors.count else { return }

        guard let rgbColor = sender.color.usingColorSpace(.genericRGB) else { return }
        palette.colors[editingColorIndex] = ColorPalette.PaletteColor(color: rgbColor)
        PaletteManager.shared.updatePalette(palette)
        updatePaletteEditor()
        paletteTableView.reloadData()
    }

    private func paletteCellView(for tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < PaletteManager.shared.palettes.count else { return nil }
        let palette = PaletteManager.shared.palettes[row]

        switch tableColumn?.identifier.rawValue {
        case "paletteName":
            let cell = NSTextField(labelWithString: palette.name)
            cell.font = NSFont.systemFont(ofSize: 12)
            cell.isBordered = false
            cell.drawsBackground = false
            return cell

        case "palettePreview":
            // Create a horizontal stack of color swatches
            let stack = NSStackView(frame: .zero)
            stack.orientation = .horizontal
            stack.spacing = 2
            stack.distribution = .fillEqually

            for color in palette.colors.prefix(8) {
                let swatch = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
                swatch.wantsLayer = true
                swatch.layer?.backgroundColor = color.nsColor.cgColor
                swatch.layer?.cornerRadius = 3
                stack.addArrangedSubview(swatch)
            }

            return stack

        default:
            return nil
        }
    }

    // MARK: - NSTableViewDataSource

    @objc func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == patchTableView {
            // Show ACTUAL patched fixtures from controller, not pending field values
            return controller.objects.count
        }
        if tableView == paletteTableView {
            return PaletteManager.shared.palettes.count
        }
        return videoLayers.count
    }

    // MARK: - NSTableViewDelegate

    @objc func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == patchTableView {
            return patchTableCellView(for: tableColumn, row: row)
        }
        if tableView == paletteTableView {
            return paletteCellView(for: tableColumn, row: row)
        }
        return videoTableCellView(for: tableColumn, row: row)
    }

    private func videoTableCellView(for tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < videoLayers.count else { return nil }
        let layer = videoLayers[row]

        let cell = NSTextField(labelWithString: "")
        cell.font = NSFont.systemFont(ofSize: 11)
        cell.isBordered = false
        cell.drawsBackground = false

        switch tableColumn?.identifier.rawValue {
        case "layer":
            cell.stringValue = String(format: "%02d", layer.layer)
            cell.alignment = .center
        case "dmx":
            cell.stringValue = "\(200 + layer.layer)"
            cell.alignment = .center
            cell.textColor = .secondaryLabelColor
        case "file":
            if let filename = layer.filename {
                cell.stringValue = filename
                cell.textColor = .labelColor
            } else {
                cell.stringValue = "(empty)"
                cell.textColor = .tertiaryLabelColor
            }
        default:
            break
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = videoTableView.selectedRow
        if row >= 0 && row < videoLayers.count {
            openLayerFolder(videoLayers[row].layer)
        }
    }

    @objc private func openMediaFolder() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let mediaPath = documentsPath.appendingPathComponent("DMXMedia")
        NSWorkspace.shared.open(mediaPath)
    }

    @objc private func refreshVideoList() {
        loadVideoLayers()
        videoTableView.reloadData()
    }

    @objc private func ndiSameAsDMXChanged() {
        let useSameAsDMX = ndiSameAsDMXCheck.state == .on
        ndiInterfacePopup.isEnabled = !useSameAsDMX

        if useSameAsDMX {
            // Use same interface as DMX (empty string means use DMX interface)
            OutputManager.shared.setNDINetworkInterface("")
        } else {
            // Use selected interface
            ndiInterfaceChanged()
        }
    }

    @objc private func ndiInterfaceChanged() {
        let selectedIndex = ndiInterfacePopup.indexOfSelectedItem
        if selectedIndex == 0 {
            // "All Interfaces"
            OutputManager.shared.setNDINetworkInterface("0.0.0.0")
        } else if selectedIndex == 1 {
            // "Loopback"
            OutputManager.shared.setNDINetworkInterface("127.0.0.1")
        } else {
            // Get the actual interface IP (offset by 2 for "All" and "Loopback")
            var ifaceIndex = 1  // Start at 1 to account for offset
            for iface in availableInterfaces where !iface.isLoopback {
                ifaceIndex += 1
                if ifaceIndex == selectedIndex {
                    OutputManager.shared.setNDINetworkInterface(iface.ip)
                    break
                }
            }
        }
    }

    @objc private func ndiLegacyModeChanged() {
        let enabled = ndiLegacyModeCheck.state == .on
        UserDefaults.standard.set(enabled, forKey: "NDILegacyMode")

        // Apply to all NDI outputs
        for output in OutputManager.shared.getAllOutputs() where output.type == .NDI {
            output.ndiOutput?.setLegacyMode(enabled)
        }

        print("NDI Legacy Mode: \(enabled ? "ENABLED" : "DISABLED")")
    }

    private func openLayerFolder(_ layer: Int) {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let layerPath = documentsPath.appendingPathComponent("DMXMedia/layer_\(String(format: "%02d", layer))")
        NSWorkspace.shared.open(layerPath)
    }

    private func updateFields() {
        fixtureCountField.integerValue = controller.objects.count
        startFixtureIdField.integerValue = controller.startFixtureId
        universeField.integerValue = controller.startUniverse
        startAddressField.integerValue = controller.startAddress
        modePopup.selectItem(at: controller.mode.rawValue)
        protocolPopup.selectItem(at: receiver.protocolType.rawValue)

        // Select current interface
        if let idx = availableInterfaces.firstIndex(where: { $0.ip == receiver.networkInterface.ip }) {
            interfacePopup.selectItem(at: idx)
        }

        updatePatchInfo()
        updateConnectionStatus()
        updatePacketStatus()
    }

    @objc private func fieldsChanged() {
        updatePatchInfo()
    }

    @objc private func protocolChanged() {
        updateConnectionStatus()
    }

    @objc private func interfaceChanged() {
        updateConnectionStatus()
    }

    @objc private func refreshInterfaces() {
        availableInterfaces = NetworkInterface.all()
        let currentSelection = interfacePopup.indexOfSelectedItem
        interfacePopup.removeAllItems()
        for iface in availableInterfaces {
            interfacePopup.addItem(withTitle: iface.displayName)
        }
        if currentSelection < availableInterfaces.count {
            interfacePopup.selectItem(at: currentSelection)
        }
    }

    private func updatePatchInfo() {
        // Show info based on ACTUAL patched fixtures (not pending field values)
        let count = controller.objects.count
        guard count > 0 else {
            patchInfoLabel.stringValue = "No fixtures patched"
            return
        }

        // Calculate total channels and check for mixed modes
        var totalChannels = 0
        var modeSet = Set<DMXMode>()
        for obj in controller.objects {
            totalChannels += obj.mode.channelsPerFixture
            modeSet.insert(obj.mode)
        }

        let universesNeeded = controller.universeCount
        let startUniv = controller.startUniverse

        // Build mode summary
        let modeInfo: String
        if modeSet.count == 1, let singleMode = modeSet.first {
            modeInfo = "\(singleMode.channelsPerFixture)ch"
        } else {
            // Mixed modes - show count of each
            var modeCounts: [DMXMode: Int] = [:]
            for obj in controller.objects {
                modeCounts[obj.mode, default: 0] += 1
            }
            let parts = modeCounts.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.value)×\($0.key.shortName)" }
            modeInfo = parts.joined(separator: ", ")
        }

        if universesNeeded > 1 {
            let endUniv = startUniv + universesNeeded - 1
            patchInfoLabel.textColor = .secondaryLabelColor
            patchInfoLabel.stringValue = "\(count) fixtures, \(totalChannels) ch total (\(modeInfo)), U\(startUniv)-U\(endUniv)"
        } else {
            let (_, lastAddr) = controller.getFixtureAddress(index: count - 1)
            let lastMode = controller.objects[count - 1].mode
            let endChannel = lastAddr + lastMode.channelsPerFixture - 1

            if endChannel > 512 {
                patchInfoLabel.textColor = .systemRed
                patchInfoLabel.stringValue = "Warning: Patch exceeds 512 (ends at \(endChannel))"
            } else {
                patchInfoLabel.textColor = .secondaryLabelColor
                patchInfoLabel.stringValue = "\(count) fixtures, \(totalChannels) ch total (\(modeInfo))"
            }
        }
    }

    // MARK: - Fixture Table Helper

    private func patchTableCellView(for tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnId = tableColumn?.identifier.rawValue else { return nil }
        guard row < controller.objects.count else { return nil }

        // Get per-fixture data
        let startId = controller.startFixtureId
        let fixtureId = startId + row
        let fixtureMode = controller.objects[row].mode
        let (universe, address) = controller.getFixtureAddress(index: row)
        let endAddress = address + fixtureMode.channelsPerFixture - 1

        // Color coding for fixture modes
        let modeColor: NSColor = {
            switch fixtureMode {
            case .full: return RetroTheme.neonCyan      // 37ch - Full features
            case .standard: return RetroTheme.neonGreen // 23ch - Standard
            case .compact: return RetroTheme.neonOrange // 10ch - Compact
            }
        }()

        switch columnId {
        case "mode":
            // Return a popup button for mode selection with color indicator
            let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 75, height: 18))

            // Color indicator dot
            let colorDot = NSView(frame: NSRect(x: 0, y: 5, width: 8, height: 8))
            colorDot.wantsLayer = true
            colorDot.layer?.backgroundColor = modeColor.cgColor
            colorDot.layer?.cornerRadius = 4
            containerView.addSubview(colorDot)

            let popup = NSPopUpButton(frame: NSRect(x: 10, y: 0, width: 65, height: 18), pullsDown: false)
            popup.font = NSFont.systemFont(ofSize: 10)
            popup.isBordered = false
            popup.addItems(withTitles: DMXMode.allCases.map { $0.shortName })
            popup.selectItem(at: fixtureMode.rawValue)
            popup.tag = row  // Store row index in tag
            popup.target = self
            popup.action = #selector(fixtureModeCellChanged(_:))
            containerView.addSubview(popup)

            return containerView
        default:
            let cellView = NSTextField(labelWithString: "")
            cellView.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

            switch columnId {
            case "id":
                cellView.stringValue = "\(fixtureId)"
                // Color the ID based on mode for quick visual reference
                cellView.textColor = modeColor
            case "universe":
                cellView.stringValue = "\(universe)"
            case "address":
                cellView.stringValue = "\(address)"
            case "channels":
                cellView.stringValue = "\(address)-\(endAddress)"
                // Show channel range in mode color
                cellView.textColor = modeColor.withAlphaComponent(0.8)
            default:
                break
            }
            return cellView
        }
    }

    @objc private func fixtureModeCellChanged(_ sender: NSPopUpButton) {
        let row = sender.tag
        guard let newMode = DMXMode(rawValue: sender.indexOfSelectedItem) else { return }
        controller.setFixtureMode(index: row, mode: newMode)
        // Reload table to update addresses for all fixtures after this one
        patchTableView.reloadData()
        updatePatchInfo()
    }

    @objc private func setModeForSelected() {
        let selectedRows = patchTableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        guard let newMode = DMXMode(rawValue: setModePopup.indexOfSelectedItem) else { return }

        // Apply mode to all selected fixtures
        for row in selectedRows {
            controller.setFixtureMode(index: row, mode: newMode)
        }
        patchTableView.reloadData()
        updatePatchInfo()
    }

    @objc private func addFixture() {
        // Show dialog to add multiple fixtures with mode selection
        let alert = NSAlert()
        alert.messageText = "Add Fixtures"
        alert.informativeText = "Add fixtures with specific mode:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        // Create accessory view with count and mode selection
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 70))

        // Count label and field
        let countLabel = NSTextField(labelWithString: "Count:")
        countLabel.frame = NSRect(x: 0, y: 45, width: 60, height: 20)
        accessoryView.addSubview(countLabel)

        let countField = NSTextField(frame: NSRect(x: 65, y: 43, width: 60, height: 24))
        countField.integerValue = 1
        countField.alignment = .center
        accessoryView.addSubview(countField)

        let countStepper = NSStepper(frame: NSRect(x: 130, y: 43, width: 20, height: 24))
        countStepper.minValue = 1
        countStepper.maxValue = Double(maxObjects - controller.objects.count)
        countStepper.integerValue = 1
        countStepper.target = countField
        countStepper.action = #selector(NSTextField.takeIntValueFrom(_:))
        accessoryView.addSubview(countStepper)

        // Mode label and popup
        let modeLabel = NSTextField(labelWithString: "Mode:")
        modeLabel.frame = NSRect(x: 0, y: 10, width: 60, height: 20)
        accessoryView.addSubview(modeLabel)

        let modePopupLocal = NSPopUpButton(frame: NSRect(x: 65, y: 8, width: 200, height: 24), pullsDown: false)
        modePopupLocal.addItems(withTitles: [
            "Full (37ch) - All features",
            "Standard (23ch) - No iris/shutters",
            "Compact (10ch) - Basic control"
        ])
        accessoryView.addSubview(modePopupLocal)

        alert.accessoryView = accessoryView

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let count = max(1, min(countField.integerValue, maxObjects - controller.objects.count))
            guard let mode = DMXMode(rawValue: modePopupLocal.indexOfSelectedItem) else { return }

            // Add the specified number of fixtures with the selected mode
            for _ in 0..<count {
                if controller.objects.count < maxObjects {
                    controller.addFixture(mode: mode)
                }
            }

            fixtureCountField.integerValue = controller.objects.count
            patchTableView.reloadData()
            updatePatchInfo()
            updateNextAvailableFields()
        }
    }

    /// Quick add single fixture using current default mode
    @objc private func addSingleFixture() {
        if controller.objects.count < maxObjects {
            let mode = DMXMode(rawValue: modePopup.indexOfSelectedItem) ?? .full
            controller.addFixture(mode: mode)
            fixtureCountField.integerValue = controller.objects.count
            patchTableView.reloadData()
            updatePatchInfo()
            updateNextAvailableFields()
        }
    }

    @objc private func removeFixture() {
        let selectedRows = patchTableView.selectedRowIndexes
        if !selectedRows.isEmpty {
            // Remove selected fixtures
            controller.removeFixtures(at: selectedRows)
            fixtureCountField.integerValue = controller.objects.count
            patchTableView.reloadData()
            updatePatchInfo()
            updateNextAvailableFields()
        } else {
            // No selection - just decrement count in field
            let current = fixtureCountField.integerValue
            if current > 1 {
                fixtureCountField.integerValue = current - 1
                updatePatchInfo()
            }
        }
    }

    /// Update fields to reflect current patch configuration
    private func updateNextAvailableFields() {
        // Keep showing the original start values - don't auto-change them
        // This ensures the user always sees where their patch begins
        universeField.integerValue = controller.startUniverse
        startAddressField.integerValue = controller.startAddress
        startFixtureIdField.integerValue = controller.startFixtureId
    }

    @objc private func patchFixtures() {
        let fixtureCount = clamp(fixtureCountField.integerValue, min: 1, max: maxObjects)
        let startUniverse = clamp(universeField.integerValue, min: 1, max: 63999)
        let startAddress = clamp(startAddressField.integerValue, min: 1, max: 512)
        let startFixtureId = clamp(startFixtureIdField.integerValue, min: 1, max: 9999)
        let mode = DMXMode(rawValue: modePopup.indexOfSelectedItem) ?? .full

        // Save settings to UserDefaults
        UserDefaults.standard.set(mode.rawValue, forKey: "dmxMode")
        UserDefaults.standard.set(startFixtureId, forKey: "startFixtureId")

        // Update default mode for new fixtures
        controller.defaultMode = mode

        // Add fixtures if count is higher than current (preserving existing fixtures and their modes)
        while controller.objects.count < fixtureCount {
            controller.addFixture(mode: mode)
        }

        // Update addressing
        controller.updateAddressing(startUniverse: startUniverse, startAddress: startAddress, startFixtureId: startFixtureId)

        // Update receiver - include output universes in subscription
        let protocolType = DMXProtocol(rawValue: protocolPopup.indexOfSelectedItem) ?? .both
        let networkInterface = availableInterfaces[interfacePopup.indexOfSelectedItem]
        let maxOutputUniverse = OutputManager.shared.getMaxOutputUniverse()
        let totalUniverseCount = max(controller.universeCount, maxOutputUniverse - startUniverse + 1)
        receiver.restart(startUniverse: startUniverse, universeCount: totalUniverseCount, protocolType: protocolType, networkInterface: networkInterface)

        // Reload table to show updated addresses
        patchTableView.reloadData()
        updatePatchInfo()

        // Visual feedback
        patchButton.title = "Patched!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.patchButton.title = "Patch"
        }
    }

    private func updateConnectionStatus() {
        guard let selectedProto = DMXProtocol(rawValue: protocolPopup.indexOfSelectedItem) else { return }
        let selectedInterface = availableInterfaces[interfacePopup.indexOfSelectedItem]

        var statusParts: [String] = []

        switch selectedProto {
        case .artNet:
            statusParts.append("Art-Net: UDP port 6454 on \(selectedInterface.ip)")
        case .sACN:
            let universe = max(1, universeField.integerValue)
            let hi = (universe >> 8) & 0xFF
            let lo = universe & 0xFF
            statusParts.append("sACN: UDP port 5568, Multicast 239.255.\(hi).\(lo)")
        case .both:
            statusParts.append("Art-Net: UDP 6454 | sACN: UDP 5568")
        }

        connectionStatusLabel.textColor = .systemGreen
        connectionStatusLabel.stringValue = statusParts.joined(separator: "\n")
    }

    private func updatePacketStatus() {
        let stats = state.getStats()
        if stats.count > 0 {
            let elapsed = Date().timeIntervalSince(stats.lastPacket)
            if elapsed < 2.0 {
                packetStatusLabel.textColor = .systemGreen
                packetStatusLabel.stringValue = "Receiving DMX - \(stats.count) packets (\(String(format: "%.1f", elapsed))s ago)"
            } else {
                packetStatusLabel.textColor = .systemOrange
                packetStatusLabel.stringValue = "DMX signal lost - last packet \(String(format: "%.1f", elapsed))s ago"
            }
        } else {
            packetStatusLabel.textColor = .systemRed
            packetStatusLabel.stringValue = "No DMX packets received"
        }
    }

    @objc private func applySettings() {
        // Apply only non-patch settings (protocol, interface, resolution)
        // Patch settings are preserved from the controller - use Patch button to change them
        let protocolType = DMXProtocol(rawValue: protocolPopup.indexOfSelectedItem) ?? .both
        let networkInterface = availableInterfaces[interfacePopup.indexOfSelectedItem]
        let resWidth = clamp(widthField.integerValue, min: 320, max: 7680)
        let resHeight = clamp(heightField.integerValue, min: 240, max: 4320)

        // Save resolution to UserDefaults for next launch
        UserDefaults.standard.set(resWidth, forKey: "canvasWidth")
        UserDefaults.standard.set(resHeight, forKey: "canvasHeight")

        // Use CURRENT controller patch values (don't overwrite patch)
        let config = SettingsConfig(
            fixtureCount: controller.objects.count,
            startUniverse: controller.startUniverse,
            startAddress: controller.startAddress,
            startFixtureId: controller.startFixtureId,
            protocolType: protocolType,
            networkInterface: networkInterface,
            resolutionWidth: resWidth,
            resolutionHeight: resHeight,
            mode: controller.mode
        )

        onApply?(config)
        window?.close()

        // Show restart alert if resolution changed
        let newSize = CGSize(width: resWidth, height: resHeight)
        if newSize != canvasSize {
            let alert = NSAlert()
            alert.messageText = "Resolution Changed"
            alert.informativeText = "The new resolution (\(resWidth)x\(resHeight)) will take effect after restarting the application."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func cancelSettings() {
        window?.close()
    }
}

// MARK: - Layout Editor

enum LayoutType: Int {
    case grid = 0
    case perimeter = 1
    case line = 2
    case rows = 3
}

enum LayoutDirection: Int {
    case across = 0  // Left to right, then down
    case down = 1    // Top to bottom, then right
}

@MainActor
final class LayoutWindowController: NSWindowController {
    private let controller: SceneController
    private var layoutTypePopup: NSPopUpButton!
    private var directionPopup: NSPopUpButton!
    private var rowsField: NSTextField!
    private var columnsField: NSTextField!
    private var rowsLabel: NSTextField!
    private var columnsLabel: NSTextField!
    private var spacingXField: NSTextField!
    private var spacingYField: NSTextField!
    private var marginXField: NSTextField!
    private var marginYField: NSTextField!
    private var previewView: LayoutPreviewView!
    private var infoLabel: NSTextField!
    private var startFixtureField: NSTextField!
    private var endFixtureField: NSTextField!

    init(controller: SceneController) {
        self.controller = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "◈ LAYOUT EDITOR ◈"
        window.isReleasedWhenClosed = false
        RetroTheme.styleWindow(window)

        super.init(window: window)
        setupUI()
        updatePreview()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        RetroTheme.styleContentView(contentView, withGrid: true)

        var y: CGFloat = 440

        // Layout Type
        let typeLabel = createLabel("Layout Type:", x: 20, y: y)
        contentView.addSubview(typeLabel)

        layoutTypePopup = NSPopUpButton(frame: NSRect(x: 130, y: y - 4, width: 150, height: 26))
        layoutTypePopup.addItems(withTitles: ["Grid", "Perimeter", "Line", "Rows"])
        layoutTypePopup.target = self
        layoutTypePopup.action = #selector(layoutTypeChanged)
        contentView.addSubview(layoutTypePopup)

        // Direction
        let dirLabel = createLabel("Direction:", x: 300, y: y)
        contentView.addSubview(dirLabel)

        directionPopup = NSPopUpButton(frame: NSRect(x: 380, y: y - 4, width: 100, height: 26))
        directionPopup.addItems(withTitles: ["Across", "Down"])
        directionPopup.target = self
        directionPopup.action = #selector(updatePreview)
        contentView.addSubview(directionPopup)

        y -= 40

        // Rows/Columns
        rowsLabel = createLabel("Rows:", x: 20, y: y)
        contentView.addSubview(rowsLabel)

        rowsField = NSTextField(frame: NSRect(x: 130, y: y - 2, width: 60, height: 22))
        rowsField.integerValue = 2
        rowsField.target = self
        rowsField.action = #selector(updatePreview)
        contentView.addSubview(rowsField)

        columnsLabel = createLabel("Columns:", x: 210, y: y)
        contentView.addSubview(columnsLabel)

        columnsField = NSTextField(frame: NSRect(x: 280, y: y - 2, width: 60, height: 22))
        columnsField.integerValue = 2
        columnsField.target = self
        columnsField.action = #selector(updatePreview)
        contentView.addSubview(columnsField)

        // Auto Calculate button
        let autoButton = NSButton(title: "AUTO", target: self, action: #selector(autoCalculateGrid))
        autoButton.frame = NSRect(x: 360, y: y - 3, width: 60, height: 24)
        autoButton.bezelStyle = .rounded
        RetroTheme.styleButton(autoButton, color: RetroTheme.neonCyan)
        contentView.addSubview(autoButton)

        // Hidden spacing/margin fields (set to 0 for edge-to-edge)
        spacingXField = NSTextField(frame: .zero)
        spacingXField.integerValue = 0
        spacingYField = NSTextField(frame: .zero)
        spacingYField.integerValue = 0
        marginXField = NSTextField(frame: .zero)
        marginXField.integerValue = 0
        marginYField = NSTextField(frame: .zero)
        marginYField.integerValue = 0

        y -= 40

        // Fixture Range
        let startLabel = createLabel("Start Fixture:", x: 20, y: y)
        contentView.addSubview(startLabel)

        startFixtureField = NSTextField(frame: NSRect(x: 130, y: y - 2, width: 60, height: 22))
        startFixtureField.integerValue = 1
        startFixtureField.target = self
        startFixtureField.action = #selector(updatePreview)
        contentView.addSubview(startFixtureField)

        let endLabel = createLabel("End Fixture:", x: 210, y: y)
        contentView.addSubview(endLabel)

        endFixtureField = NSTextField(frame: NSRect(x: 290, y: y - 2, width: 60, height: 22))
        endFixtureField.integerValue = controller.objects.count
        endFixtureField.target = self
        endFixtureField.action = #selector(updatePreview)
        contentView.addSubview(endFixtureField)

        // "All" button to reset range
        let allButton = NSButton(title: "ALL", target: self, action: #selector(selectAllFixtures))
        allButton.frame = NSRect(x: 360, y: y - 3, width: 50, height: 24)
        allButton.bezelStyle = .rounded
        RetroTheme.styleButton(allButton, color: RetroTheme.neonOrange)
        contentView.addSubview(allButton)

        y -= 30

        // Info label
        infoLabel = NSTextField(labelWithString: "")
        infoLabel.frame = NSRect(x: 20, y: y, width: 460, height: 18)
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        contentView.addSubview(infoLabel)

        y -= 20

        // Preview area
        let previewFrame = NSRect(x: 20, y: 60, width: 460, height: y - 70)
        previewView = LayoutPreviewView(frame: previewFrame)
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.cgColor
        previewView.layer?.cornerRadius = 4
        contentView.addSubview(previewView)

        // Buttons
        let cancelButton = NSButton(title: "◁ CANCEL", target: self, action: #selector(cancelAction))
        cancelButton.frame = NSRect(x: 200, y: 20, width: 80, height: 28)
        cancelButton.keyEquivalent = "\u{1b}"
        RetroTheme.styleButton(cancelButton, color: RetroTheme.textSecondary)
        contentView.addSubview(cancelButton)

        let applyButton = NSButton(title: "▷ APPLY", target: self, action: #selector(applyLayout))
        applyButton.frame = NSRect(x: 290, y: 20, width: 90, height: 28)
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        RetroTheme.styleButton(applyButton, color: RetroTheme.neonGreen)
        contentView.addSubview(applyButton)
    }

    private func createLabel(_ text: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: x, y: y, width: 100, height: 18)
        label.font = NSFont.systemFont(ofSize: 12)
        return label
    }

    @objc private func layoutTypeChanged() {
        let layoutType = LayoutType(rawValue: layoutTypePopup.indexOfSelectedItem) ?? .grid

        // Show/hide fields based on layout type
        switch layoutType {
        case .grid:
            rowsLabel.stringValue = "Rows:"
            columnsLabel.stringValue = "Columns:"
            rowsField.isHidden = false
            columnsField.isHidden = false
            rowsLabel.isHidden = false
            columnsLabel.isHidden = false
        case .perimeter:
            rowsLabel.stringValue = "Rows:"
            columnsLabel.stringValue = "Columns:"
            rowsField.isHidden = false
            columnsField.isHidden = false
            rowsLabel.isHidden = false
            columnsLabel.isHidden = false
        case .line:
            rowsLabel.isHidden = true
            columnsLabel.isHidden = true
            rowsField.isHidden = true
            columnsField.isHidden = true
        case .rows:
            rowsLabel.stringValue = "Rows:"
            columnsLabel.isHidden = true
            columnsField.isHidden = true
            rowsField.isHidden = false
            rowsLabel.isHidden = false
        }

        updatePreview()
    }

    @objc private func selectAllFixtures() {
        startFixtureField.integerValue = 1
        endFixtureField.integerValue = controller.objects.count
        updatePreview()
    }

    /// Auto-calculate optimal rows and columns for edge-to-edge tiling
    /// Height is PERFECT (1080 / rows), width may exceed slightly
    @objc private func autoCalculateGrid() {
        let range = getFixtureRange()
        let fixtureCount = range.count
        guard fixtureCount > 0 else { return }

        let canvasWidth: Float = 1920.0
        let canvasHeight: Float = 1080.0

        // Find optimal rows/columns for edge-to-edge with minimal width overflow
        // Target: square-ish cells that fill the height perfectly
        var bestRows = 1
        var bestCols = fixtureCount
        var bestWidthError: Float = .infinity

        for rows in 1...fixtureCount {
            let cols = (fixtureCount + rows - 1) / rows  // ceiling division
            if rows * cols < fixtureCount { continue }  // not enough cells

            // Cell dimensions for edge-to-edge
            let cellHeight = canvasHeight / Float(rows)

            // Calculate how much width exceeds if we use square cells based on height
            // Square cell width = cellHeight, total width = cellHeight * cols
            let squareWidth = cellHeight * Float(cols)
            let widthError = abs(squareWidth - canvasWidth)

            // Prefer layouts where total width is close to canvas width
            // Also prefer layouts with fewer empty cells
            let emptyCells = rows * cols - fixtureCount
            let score = widthError + Float(emptyCells) * 10.0

            if score < bestWidthError {
                bestWidthError = score
                bestRows = rows
                bestCols = cols
            }
        }

        rowsField.integerValue = bestRows
        columnsField.integerValue = bestCols
        updatePreview()
    }

    /// Get the fixture range (0-indexed)
    private func getFixtureRange() -> (start: Int, end: Int, count: Int) {
        let startFix = max(1, startFixtureField.integerValue)
        let endFix = min(controller.objects.count, max(startFix, endFixtureField.integerValue))
        let count = endFix - startFix + 1
        return (startFix - 1, endFix - 1, count)  // Convert to 0-indexed
    }

    @objc private func updatePreview() {
        let positions = calculatePositions()
        previewView.positions = positions
        previewView.needsDisplay = true

        // Update info label with range and scale info
        let range = getFixtureRange()
        let layout = calculateLayout()
        let scaleInfo = layout.isEmpty ? "" : String(format: " | Scale: %.2fx%.2f", layout[0].scaleX, layout[0].scaleY)
        infoLabel.stringValue = "Fixtures \(range.start + 1)-\(range.end + 1) (\(range.count) total)\(scaleInfo)"
    }

    /// Layout result containing position and scale for each fixture
    struct LayoutResult {
        var x: Float
        var y: Float
        var scaleX: Float
        var scaleY: Float
    }

    private func calculateLayout() -> [LayoutResult] {
        let range = getFixtureRange()
        let fixtureCount = range.count
        guard fixtureCount > 0 else { return [] }

        let layoutType = LayoutType(rawValue: layoutTypePopup.indexOfSelectedItem) ?? .grid
        let direction = LayoutDirection(rawValue: directionPopup.indexOfSelectedItem) ?? .across
        let rows = max(1, rowsField.integerValue)
        let columns = max(1, columnsField.integerValue)

        // Canvas size
        let canvasWidth: Float = 1920.0
        let canvasHeight: Float = 1080.0

        // Base radius used in shader (fixture diameter = scale * baseRadius * 2)
        let baseRadius: Float = 120.0

        var results: [LayoutResult] = []

        switch layoutType {
        case .grid:
            // Edge-to-edge tiling: fixtures fill the entire canvas
            // Height is PERFECT: cell height = canvas height / rows
            // Width may exceed slightly to maintain even spacing

            let cellHeight = canvasHeight / Float(rows)
            let cellWidth = canvasWidth / Float(columns)

            // Calculate scale to fill each cell
            // Fixture diameter should equal cell size
            // diameter = scale * baseRadius * 2
            // scale = diameter / (baseRadius * 2) = cellSize / (baseRadius * 2)
            let scaleY = cellHeight / (baseRadius * 2.0)  // Height is perfect
            let scaleX = cellWidth / (baseRadius * 2.0)   // Width fills evenly

            for i in 0..<fixtureCount {
                let col: Int
                let row: Int
                if direction == .across {
                    col = i % columns
                    row = i / columns
                } else {
                    row = i % rows
                    col = i / rows
                }

                // Position at CENTER of each cell
                let x = cellWidth / 2.0 + Float(col) * cellWidth
                let y = cellHeight / 2.0 + Float(row) * cellHeight

                results.append(LayoutResult(x: x, y: y, scaleX: scaleX, scaleY: scaleY))
            }

        case .perimeter:
            // Perimeter layout - fixtures around the edges
            let cellHeight = canvasHeight / Float(rows)
            let cellWidth = canvasWidth / Float(columns)
            let scaleY = cellHeight / (baseRadius * 2.0)
            let scaleX = cellWidth / (baseRadius * 2.0)

            var perimeterResults: [LayoutResult] = []

            // Top edge (left to right)
            for col in 0..<columns {
                let x = cellWidth / 2.0 + Float(col) * cellWidth
                let y = cellHeight / 2.0
                perimeterResults.append(LayoutResult(x: x, y: y, scaleX: scaleX, scaleY: scaleY))
            }
            // Right edge (skip first corner)
            for row in 1..<rows {
                let x = canvasWidth - cellWidth / 2.0
                let y = cellHeight / 2.0 + Float(row) * cellHeight
                perimeterResults.append(LayoutResult(x: x, y: y, scaleX: scaleX, scaleY: scaleY))
            }
            // Bottom edge (right to left, skip first corner)
            for col in stride(from: columns - 2, through: 0, by: -1) {
                let x = cellWidth / 2.0 + Float(col) * cellWidth
                let y = canvasHeight - cellHeight / 2.0
                perimeterResults.append(LayoutResult(x: x, y: y, scaleX: scaleX, scaleY: scaleY))
            }
            // Left edge (skip both corners)
            for row in stride(from: rows - 2, through: 1, by: -1) {
                let x = cellWidth / 2.0
                let y = cellHeight / 2.0 + Float(row) * cellHeight
                perimeterResults.append(LayoutResult(x: x, y: y, scaleX: scaleX, scaleY: scaleY))
            }

            for i in 0..<fixtureCount {
                let idx = i % perimeterResults.count
                results.append(perimeterResults[idx])
            }

        case .line:
            // Single line - fill the entire dimension
            if direction == .across {
                // Horizontal line - fixtures fill width, height is single row
                let cellWidth = canvasWidth / Float(fixtureCount)
                let cellHeight = canvasHeight  // Full height for single row
                let scaleX = cellWidth / (baseRadius * 2.0)
                let scaleY = cellHeight / (baseRadius * 2.0)

                for i in 0..<fixtureCount {
                    let x = cellWidth / 2.0 + Float(i) * cellWidth
                    let y = canvasHeight / 2.0
                    results.append(LayoutResult(x: x, y: y, scaleX: scaleX, scaleY: scaleY))
                }
            } else {
                // Vertical line - fixtures fill height, width is single column
                let cellWidth = canvasWidth  // Full width for single column
                let cellHeight = canvasHeight / Float(fixtureCount)
                let scaleX = cellWidth / (baseRadius * 2.0)
                let scaleY = cellHeight / (baseRadius * 2.0)

                for i in 0..<fixtureCount {
                    let x = canvasWidth / 2.0
                    let y = cellHeight / 2.0 + Float(i) * cellHeight
                    results.append(LayoutResult(x: x, y: y, scaleX: scaleX, scaleY: scaleY))
                }
            }

        case .rows:
            // Multiple rows - distribute evenly
            let actualRows = max(1, rows)
            let fixturesPerRow = (fixtureCount + actualRows - 1) / actualRows

            let cellHeight = canvasHeight / Float(actualRows)
            let cellWidth = canvasWidth / Float(fixturesPerRow)
            let scaleY = cellHeight / (baseRadius * 2.0)
            let scaleX = cellWidth / (baseRadius * 2.0)

            for i in 0..<fixtureCount {
                let row = i / fixturesPerRow
                let col = i % fixturesPerRow

                let x = cellWidth / 2.0 + Float(col) * cellWidth
                let y = cellHeight / 2.0 + Float(row) * cellHeight
                results.append(LayoutResult(x: x, y: y, scaleX: scaleX, scaleY: scaleY))
            }
        }

        return results
    }

    /// Legacy method for preview compatibility - returns just positions
    private func calculatePositions() -> [(x: Float, y: Float)] {
        return calculateLayout().map { ($0.x, $0.y) }
    }

    @objc private func applyLayout() {
        let layout = calculateLayout()
        let range = getFixtureRange()

        // Apply positions AND scales to the specified fixture range
        for (i, result) in layout.enumerated() {
            let fixtureIndex = range.start + i
            if fixtureIndex <= range.end && fixtureIndex < controller.objects.count {
                controller.setFixturePosition(index: fixtureIndex, position: CGPoint(x: CGFloat(result.x), y: CGFloat(result.y)))
                controller.setFixtureScale(index: fixtureIndex, scale: CGSize(width: CGFloat(result.scaleX), height: CGFloat(result.scaleY)))
            }
        }

        // Show confirmation with position and scale summary
        let scaleInfo = layout.isEmpty ? "" : String(format: "\nScale: %.2f x %.2f", layout[0].scaleX, layout[0].scaleY)
        let alert = NSAlert()
        alert.messageText = "Layout Applied"
        alert.informativeText = "Applied layout to fixtures \(range.start + 1)-\(range.end + 1) (\(layout.count) fixtures).\(scaleInfo)\n\nPositions and scales are now live. To make permanent, record a cue on your console."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()

        window?.close()
    }

    @objc private func cancelAction() {
        window?.close()
    }
}

// MARK: - Layout Preview View

@MainActor
final class LayoutPreviewView: NSView {
    var positions: [(x: Float, y: Float)] = []

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Draw background
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        // Draw canvas outline (scaled to fit preview)
        let canvasWidth: CGFloat = 1920
        let canvasHeight: CGFloat = 1080
        let scale = min(bounds.width / canvasWidth, bounds.height / canvasHeight) * 0.95
        let offsetX = (bounds.width - canvasWidth * scale) / 2
        let offsetY = (bounds.height - canvasHeight * scale) / 2

        // Canvas border
        context.setStrokeColor(NSColor.darkGray.cgColor)
        context.setLineWidth(1)
        let canvasRect = CGRect(
            x: offsetX,
            y: offsetY,
            width: canvasWidth * scale,
            height: canvasHeight * scale
        )
        context.stroke(canvasRect)

        // Draw fixtures as dots
        let dotSize: CGFloat = 8
        for (i, pos) in positions.enumerated() {
            let x = offsetX + CGFloat(pos.x) * scale
            let y = offsetY + (canvasHeight - CGFloat(pos.y)) * scale  // Flip Y for screen coords

            // Fixture dot
            let hue = CGFloat(i) / max(1, CGFloat(positions.count)) * 0.7  // Rainbow from red to blue
            let color = NSColor(hue: hue, saturation: 0.8, brightness: 1.0, alpha: 1.0)
            context.setFillColor(color.cgColor)

            let dotRect = CGRect(x: x - dotSize/2, y: y - dotSize/2, width: dotSize, height: dotSize)
            context.fillEllipse(in: dotRect)

            // Fixture number
            let numStr = "\(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 8)
            ]
            numStr.draw(at: CGPoint(x: x + 5, y: y - 4), withAttributes: attrs)
        }
    }
}

// MARK: - App lifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let state: DMXState
    private let controller: SceneController
    private let receiver: DMXReceiver
    private let window: NSWindow
    private var renderView: RenderView?       // Fallback CoreGraphics renderer
    private var metalRenderView: MetalRenderView?  // Metal GPU renderer
    private let maxObjects: Int
    private var currentProtocol: DMXProtocol
    private var currentInterface: NetworkInterface
    private var settingsWindowController: SettingsWindowController?
    private var layoutWindowController: LayoutWindowController?
    private var helpWindows: [NSWindow] = []  // Retain help windows to prevent crash on exit
    private var useMetal: Bool = false
    private var currentShowPath: URL? = nil

    init(fixtureCount: Int, startUniverse: Int, startAddress: Int = 1, protocolType: DMXProtocol = .both, networkInterface: NetworkInterface? = nil) {
        self.maxObjects = 200  // Max fixtures supported
        self.state = DMXState()
        self.controller = SceneController(fixtureCount: fixtureCount, state: state, startUniverse: startUniverse, startAddress: startAddress)
        let iface = networkInterface ?? NetworkInterface.all().first!
        let universeCount = controller.universeCount
        self.receiver = DMXReceiver(state: state, startUniverse: startUniverse, universeCount: universeCount, protocolType: protocolType, networkInterface: iface)
        self.currentProtocol = protocolType
        self.currentInterface = iface

        // Scale window to fit on screen while maintaining canvas aspect ratio
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let maxWidth = screenFrame.width * 0.9
        let maxHeight = screenFrame.height * 0.8
        let aspectRatio = canvasSize.width / canvasSize.height

        var windowWidth = min(canvasSize.width, maxWidth)
        var windowHeight = windowWidth / aspectRatio

        if windowHeight > maxHeight {
            windowHeight = maxHeight
            windowWidth = windowHeight * aspectRatio
        }

        let rect = CGRect(origin: .zero, size: CGSize(width: windowWidth, height: windowHeight))

        // Try Metal first, fall back to CoreGraphics
        if let metalView = MetalRenderView(frame: rect, controller: controller) {
            self.metalRenderView = metalView
            self.useMetal = true
            sharedMetalRenderView = metalView  // Set global reference for live preview
            print("Renderer: Using Metal GPU acceleration")
        } else {
            self.renderView = RenderView(frame: rect, controller: controller)
            self.useMetal = false
            print("Renderer: Using CoreGraphics + NDI")
        }

        self.window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = buildWindowTitle(startUniverse: startUniverse, universeCount: universeCount, protocolType: protocolType, iface: iface)
        window.contentAspectRatio = canvasSize  // Lock aspect ratio when resizing
        window.center()
        window.contentView = useMetal ? metalRenderView : renderView
        // Apply retro theme to main window
        RetroTheme.styleWindow(window)
    }

    private func buildWindowTitle(startUniverse: Int, universeCount: Int, protocolType: DMXProtocol, iface: NetworkInterface) -> String {
        let universeText = universeCount > 1 ? "U\(startUniverse)-\(startUniverse + universeCount - 1)" : "U\(startUniverse)"
        let fixtureCount = controller.objects.count
        return "GeoDraw \(AppVersion.string) - \(fixtureCount) fixtures - \(universeText) [\(protocolType.displayName)] \(iface.ip)"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()

        // Force restart to ensure all settings are properly applied - include output universes
        let maxOutputUniverse = OutputManager.shared.getMaxOutputUniverse()
        let totalUniverseCount = max(controller.universeCount, maxOutputUniverse - controller.startUniverse + 1)
        receiver.restart(
            startUniverse: controller.startUniverse,
            universeCount: totalUniverseCount,
            protocolType: currentProtocol,
            networkInterface: currentInterface
        )

        // MTKView handles its own frame timing; CoreGraphics needs display link
        if !useMetal {
            renderView?.startDisplayLink()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Start web server for remote media management
        WebServer.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        receiver.stop()
        WebServer.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About DMX Visualizer", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit DMX Visualizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Show", action: #selector(newShow), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open Show...", action: #selector(openShow), keyEquivalent: "o")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Save Show", action: #selector(saveShowAction), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Save Show As...", action: #selector(saveShowAs), keyEquivalent: "S")

        // Media menu
        let mediaMenuItem = NSMenuItem()
        mainMenu.addItem(mediaMenuItem)
        let mediaMenu = NSMenu(title: "Media")
        mediaMenuItem.submenu = mediaMenu
        mediaMenu.addItem(withTitle: "Media Slots...", action: #selector(showMediaSlots), keyEquivalent: "m")
        mediaMenu.addItem(NSMenuItem.separator())
        mediaMenu.addItem(withTitle: "Refresh Gobos", action: #selector(refreshGobos), keyEquivalent: "g")
        mediaMenu.addItem(withTitle: "Refresh NDI Sources", action: #selector(refreshNDI), keyEquivalent: "r")

        // Output menu
        let outputMenuItem = NSMenuItem()
        mainMenu.addItem(outputMenuItem)
        let outputMenu = NSMenu(title: "Output")
        outputMenuItem.submenu = outputMenu

        // Canvas size display at top of menu
        let canvasW = UserDefaults.standard.integer(forKey: "canvasWidth")
        let canvasH = UserDefaults.standard.integer(forKey: "canvasHeight")
        let canvasSizeItem = NSMenuItem(title: "Canvas: \(canvasW > 0 ? canvasW : 7680) × \(canvasH > 0 ? canvasH : 1080)", action: nil, keyEquivalent: "")
        canvasSizeItem.isEnabled = false
        outputMenu.addItem(canvasSizeItem)

        outputMenu.addItem(NSMenuItem.separator())

        let ndiItem = NSMenuItem(title: "NDI Output", action: #selector(toggleNDI), keyEquivalent: "n")
        ndiItem.keyEquivalentModifierMask = [.command, .shift]
        ndiItem.target = self
        outputMenu.addItem(ndiItem)

        outputMenu.addItem(NSMenuItem.separator())

        // Display Outputs submenu
        let displayOutputsItem = NSMenuItem(title: "Display Outputs", action: nil, keyEquivalent: "")
        let displayOutputsMenu = NSMenu(title: "Display Outputs")
        displayOutputsItem.submenu = displayOutputsMenu

        // Add available displays dynamically
        let displays = OutputManager.shared.getAvailableDisplays()
        for display in displays {
            let item = NSMenuItem(title: "\(display.name) (\(display.width)x\(display.height))",
                                  action: #selector(toggleDisplayOutput(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = Int(display.displayId)
            item.representedObject = display
            displayOutputsMenu.addItem(item)
        }
        if displays.isEmpty {
            let noDisplaysItem = NSMenuItem(title: "No External Displays", action: nil, keyEquivalent: "")
            noDisplaysItem.isEnabled = false
            displayOutputsMenu.addItem(noDisplaysItem)
        }
        outputMenu.addItem(displayOutputsItem)

        // Canvas NDI Output (using new output engine)
        let asyncNdiItem = NSMenuItem(title: "Add Canvas NDI Output...", action: #selector(addAsyncNDIOutput), keyEquivalent: "")
        asyncNdiItem.target = self
        outputMenu.addItem(asyncNdiItem)

        outputMenu.addItem(NSMenuItem.separator())

        // Output Settings
        let outputSettingsItem = NSMenuItem(title: "Output Settings...", action: #selector(showOutputSettings), keyEquivalent: "o")
        outputSettingsItem.keyEquivalentModifierMask = [.command, .shift]
        outputSettingsItem.target = self
        outputMenu.addItem(outputSettingsItem)

        outputMenu.addItem(NSMenuItem.separator())

        // Venue Configuration submenu
        let venueItem = NSMenuItem(title: "Venue Configuration", action: nil, keyEquivalent: "")
        let venueMenu = NSMenu(title: "Venue Configuration")
        venueItem.submenu = venueMenu

        let saveVenueItem = NSMenuItem(title: "Save Venue Config...", action: #selector(saveVenueConfig), keyEquivalent: "")
        saveVenueItem.target = self
        venueMenu.addItem(saveVenueItem)

        let loadVenueItem = NSMenuItem(title: "Load Venue Config...", action: #selector(loadVenueConfig), keyEquivalent: "")
        loadVenueItem.target = self
        venueMenu.addItem(loadVenueItem)

        venueMenu.addItem(NSMenuItem.separator())

        let venueHelpItem = NSMenuItem(title: "Venue configs store canvas & output settings", action: nil, keyEquivalent: "")
        venueHelpItem.isEnabled = false
        venueMenu.addItem(venueHelpItem)

        outputMenu.addItem(venueItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Layout Editor...", action: #selector(showLayoutEditor), keyEquivalent: "l")
        viewMenu.addItem(NSMenuItem.separator())
        let canvasNDIItem = NSMenuItem(title: "Canvas NDI Preview", action: #selector(toggleCanvasNDIMenu(_:)), keyEquivalent: "n")
        canvasNDIItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(canvasNDIItem)
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")

        // Help menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "DMX Channel Reference", action: #selector(showChannelReference), keyEquivalent: "")
        helpMenu.addItem(withTitle: "Quick Start Guide", action: #selector(showQuickStart), keyEquivalent: "")
        helpMenu.addItem(NSMenuItem.separator())
        helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "GeoDraw DMX Visualizer"
        alert.informativeText = """
            Professional DMX-controlled media server & visualizer.

            Features:
            • 37-channel fixture control (Full/Standard/Compact modes)
            • 150+ gobo patterns with live sync
            • Video playback & NDI I/O
            • Multi-output with edge blending & warping
            • Art-Net & sACN (E1.31) input

            \(AppVersion.full)
            © 2026 RocKontrol
            """
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func showMediaSlots() {
        showMediaSlotConfig()
    }

    @objc private func refreshNDI() {
        MediaSlotConfig.shared.refreshNDISources()
        let count = MediaSlotConfig.shared.availableNDISources.count
        let alert = NSAlert()
        alert.messageText = "NDI Sources"
        alert.informativeText = count > 0
            ? "Found \(count) NDI source(s):\n\(MediaSlotConfig.shared.availableNDISources.joined(separator: "\n"))"
            : "No NDI sources found on the network."
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func refreshGobos() {
        GoboLibrary.shared.refreshGobos()

        // Also trigger texture reload in the renderer
        metalRenderView?.reloadAllGobos()

        let alert = NSAlert()
        alert.messageText = "Gobos Refreshed"
        alert.informativeText = "Gobos have been reloaded from:\n• DMX Visualizer/gobos\n• GoboCreator/Library"
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func toggleNDI(_ sender: NSMenuItem) {
        guard let renderView = metalRenderView else { return }
        renderView.ndiEnabled.toggle()
        sender.state = renderView.ndiEnabled ? .on : .off
    }

    @objc private func toggleDisplayOutput(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? GDDisplayInfo else { return }

        // Check if we already have an output for this display
        let existingOutputs = OutputManager.shared.getAllOutputs()
        if let existing = existingOutputs.first(where: { $0.config.displayId == display.displayId }) {
            // Toggle existing output
            let newState = !existing.config.enabled
            OutputManager.shared.enableOutput(id: existing.id, enabled: newState)
            sender.state = newState ? .on : .off
        } else {
            // Create new display output
            if let id = OutputManager.shared.addDisplayOutput(displayId: display.displayId, name: display.name) {
                OutputManager.shared.enableOutput(id: id, enabled: true)
                sender.state = .on
                print("Output: Added display output '\(display.name)'")
            }
        }
    }

    private func updateOverlapsMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let outputs = OutputManager.shared.getAllOutputs()
        if outputs.count < 2 {
            let noOverlapsItem = NSMenuItem(title: "Add 2+ outputs to detect overlaps", action: nil, keyEquivalent: "")
            noOverlapsItem.isEnabled = false
            menu.addItem(noOverlapsItem)
            return
        }

        // Get canvas size
        let canvasH = UserDefaults.standard.integer(forKey: "canvasHeight")
        let cH = canvasH > 0 ? canvasH : 1080

        // Calculate default positions (side by side)
        var positions: [(name: String, x: Int, y: Int, w: Int, h: Int)] = []
        var xOffset = 0
        for output in outputs {
            let w = Int(output.width)
            let h = cH
            positions.append((output.name, xOffset, 0, w, h))
            xOffset += w
        }

        var hasOverlaps = false

        // Calculate overlaps for each output
        for (i, posA) in positions.enumerated() {
            var featherL = 0, featherR = 0, featherT = 0, featherB = 0

            for (j, posB) in positions.enumerated() {
                if i == j { continue }

                // Left overlap
                if posB.x < posA.x && posB.x + posB.w > posA.x {
                    featherL = max(featherL, (posB.x + posB.w) - posA.x)
                }
                // Right overlap
                if posB.x > posA.x && posB.x < posA.x + posA.w {
                    featherR = max(featherR, (posA.x + posA.w) - posB.x)
                }
                // Top overlap
                if posB.y < posA.y && posB.y + posB.h > posA.y {
                    featherT = max(featherT, (posB.y + posB.h) - posA.y)
                }
                // Bottom overlap
                if posB.y > posA.y && posB.y < posA.y + posA.h {
                    featherB = max(featherB, (posA.y + posA.h) - posB.y)
                }
            }

            if featherL > 0 || featherR > 0 || featherT > 0 || featherB > 0 {
                hasOverlaps = true
                var edges: [String] = []
                if featherL > 0 { edges.append("L:\(featherL)px") }
                if featherR > 0 { edges.append("R:\(featherR)px") }
                if featherT > 0 { edges.append("T:\(featherT)px") }
                if featherB > 0 { edges.append("B:\(featherB)px") }

                let item = NSMenuItem(title: "\(posA.name): \(edges.joined(separator: ", "))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if !hasOverlaps {
            let noOverlapsItem = NSMenuItem(title: "No overlaps detected", action: nil, keyEquivalent: "")
            noOverlapsItem.isEnabled = false
            menu.addItem(noOverlapsItem)

            menu.addItem(NSMenuItem.separator())

            let helpItem = NSMenuItem(title: "Position outputs with overlap in Output Settings", action: nil, keyEquivalent: "")
            helpItem.isEnabled = false
            menu.addItem(helpItem)
        }
    }

    @objc private func addAsyncNDIOutput() {
        let alert = NSAlert()
        alert.messageText = "Add NDI Output"
        alert.informativeText = "Enter a name for the NDI source:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = "GeoDraw NDI"
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = input.stringValue.isEmpty ? "GeoDraw NDI" : input.stringValue
            if let id = OutputManager.shared.addNDIOutput(sourceName: name) {
                OutputManager.shared.enableOutput(id: id, enabled: true)
                print("Output: Added async NDI output '\(name)'")
            }
        }
    }

    @objc private func showOutputSettings() {
        showOutputSettingsWindow()
    }

    @objc private func saveVenueConfig() {
        let panel = NSSavePanel()
        panel.title = "Save Venue Configuration"
        panel.nameFieldLabel = "Venue Name:"
        panel.nameFieldStringValue = "MyVenue"
        panel.allowedContentTypes = [.init(filenameExtension: VenueConfig.fileExtension) ?? .json]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            let venueName = url.deletingPathExtension().lastPathComponent
            let config = OutputManager.shared.createVenueConfig(name: venueName)

            do {
                try OutputManager.shared.saveVenueConfig(config, to: url)

                let alert = NSAlert()
                alert.messageText = "Venue Saved"
                alert.informativeText = "Saved venue configuration '\(venueName)' with \(config.outputs.count) outputs.\n\nCanvas: \(config.canvasWidth) × \(config.canvasHeight)"
                alert.alertStyle = .informational
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Save Failed"
                alert.informativeText = "Could not save venue configuration: \(error.localizedDescription)"
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    @objc private func loadVenueConfig() {
        let panel = NSOpenPanel()
        panel.title = "Load Venue Configuration"
        panel.allowedContentTypes = [.init(filenameExtension: VenueConfig.fileExtension) ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let config = try OutputManager.shared.loadVenueConfig(from: url)

                // Confirm before applying
                let alert = NSAlert()
                alert.messageText = "Load Venue '\(config.name)'?"
                alert.informativeText = "This will replace your current canvas and output configuration.\n\nCanvas: \(config.canvasWidth) × \(config.canvasHeight)\nOutputs: \(config.outputs.count)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Load")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() == .alertFirstButtonReturn {
                    OutputManager.shared.applyVenueConfig(config)

                    // Refresh output settings window if open
                    refreshOutputSettingsWindowIfVisible()

                    let successAlert = NSAlert()
                    successAlert.messageText = "Venue Loaded"
                    successAlert.informativeText = "Applied venue configuration '\(config.name)'."
                    successAlert.alertStyle = .informational
                    successAlert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Load Failed"
                alert.informativeText = "Could not load venue configuration: \(error.localizedDescription)"
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleNDI(_:)) {
            menuItem.state = (metalRenderView?.ndiEnabled ?? false) ? .on : .off
        } else if menuItem.action == #selector(toggleCanvasNDIMenu(_:)) {
            menuItem.state = CanvasNDIManager.shared.isEnabled ? .on : .off
        } else if menuItem.action == #selector(toggleDisplayOutput(_:)) {
            // Check if display output is enabled
            if let display = menuItem.representedObject as? GDDisplayInfo {
                let outputs = OutputManager.shared.getAllOutputs()
                if let output = outputs.first(where: { $0.config.displayId == display.displayId }) {
                    menuItem.state = output.config.enabled ? .on : .off
                } else {
                    menuItem.state = .off
                }
            }
        }
        return true
    }

    // MARK: - Help System

    @objc private func showChannelReference() {
        let content = """
        DMX CHANNEL REFERENCE - GeoDraw \(AppVersion.string)
        ═══════════════════════════════════════════════════

        ───────────────────────────────────────────────────
        MASTER CONTROL (3 CHANNELS) - Universe 0
        ───────────────────────────────────────────────────
        CH1   Master Intensity   0-255 = 0-100% global dimmer
        CH2   Test Pattern       0-127=Off, 128-255=On
        CH3   Show Borders       0-127=Off, 128-255=On

        ───────────────────────────────────────────────────
        OUTPUT CONTROL (28 CHANNELS PER OUTPUT)
        ───────────────────────────────────────────────────
        Patch geodraw@output_28ch_v2 in MA3

        CH1     Intensity        0-255 = Output dimmer
        CH2     Auto Blend       0-127=Off, 128-255=On
        CH3-4   Position X       16-bit (32768=center, ±10000px)
        CH5-6   Position Y       16-bit (32768=center, ±10000px)
        CH7     Z-Order          0-127=Default, 128-255=Manual
        CH8     Edge Left        0-255 = 0-500px blend width
        CH9     Edge Right       0-255 = 0-500px
        CH10    Edge Top         0-255 = 0-500px
        CH11    Edge Bottom      0-255 = 0-500px
        CH12-13 Warp TL X        16-bit (32768=center, ±500px)
        CH14-15 Warp TL Y        16-bit
        CH16-17 Warp TR X        16-bit
        CH18-19 Warp TR Y        16-bit
        CH20-21 Warp BL X        16-bit
        CH22-23 Warp BL Y        16-bit
        CH24-25 Warp BR X        16-bit
        CH26-27 Warp BR Y        16-bit
        CH28    Curvature        0=-1.0, 128=0, 255=+1.0

        ───────────────────────────────────────────────────
        FIXTURE MODES
        ───────────────────────────────────────────────────
        • Full Mode:     37 channels (all features)
        • Standard Mode: 23 channels (no iris/shutters)
        • Compact Mode:  10 channels (basic control)

        ───────────────────────────────────────────────────
        FULL MODE (37 CHANNELS)
        ───────────────────────────────────────────────────

        CONTENT SELECTION
        CH1   Content           0=Off, 1-20=Shapes, 21-200=Gobos, 201-255=Media

        POSITION (16-bit)
        CH2   X Position MSB    ┐ 16-bit horizontal position
        CH3   X Position LSB    ┘ 0=left edge, 65535=right edge
        CH4   Y Position MSB    ┐ 16-bit vertical position
        CH5   Y Position LSB    ┘ 0=top edge, 65535=bottom edge
        CH6   Z-Index           Layer order (higher=front)

        SCALE (16-bit)
        CH7   Scale MSB         ┐ Overall size multiplier
        CH8   Scale LSB         ┘ 0-6x range
        CH9   H-Scale MSB       ┐ Horizontal stretch
        CH10  H-Scale LSB       ┘ 0-2x range
        CH11  V-Scale MSB       ┐ Vertical stretch
        CH12  V-Scale LSB       ┘ 0-2x range

        APPEARANCE
        CH13  Softness          Edge blur (0=sharp, 255=max blur)
        CH14  Opacity           Transparency (0=invisible, 255=solid)
        CH15  Intensity         Brightness multiplier
        CH16  Red               Color component
        CH17  Green             Color component
        CH18  Blue              Color component
        CH19  Rotation          Static angle (0=0°, 255=360°)
        CH20  Spin Speed        Continuous rotation speed

        VIDEO CONTROL
        CH21  Playback          0=Stop, 1-127=Various modes, 128-255=Scrub
        CH22  Video Mode        0-127=Color, 128-255=Mask blend
        CH23  Volume            Audio level

        FRAMING SHUTTERS
        CH24  Iris              0=Open, 255=Closed
        CH25  Top Blade Ins     Insertion amount (0-255)
        CH26  Top Blade Angle   -45° to +45° (128=center)
        CH27  Bottom Blade Ins  Insertion amount
        CH28  Bottom Blade Ang  Angle
        CH29  Left Blade Ins    Insertion amount
        CH30  Left Blade Angle  Angle
        CH31  Right Blade Ins   Insertion amount
        CH32  Right Blade Ang   Angle
        CH33  Shutter Rotate    Assembly rotation (±45°)

        EFFECTS
        CH34  Prism Pattern     0=Off, 1-50=Patterns, 51-100=Facets
        CH35  Animation Wheel   0=Off, 1-255=Animation patterns
        CH36  Prismatics        0=Off, 1-255=Color palette effects
        CH37  Prism Rotation    0-127=Index, 128-191=CCW, 192=Stop, 193-255=CW

        ───────────────────────────────────────────────────
        STANDARD MODE (23 CHANNELS)
        ───────────────────────────────────────────────────
        CH1-20  Same as Full (Content → Spin)
        CH21    Video Playback
        CH22    Video Mode
        CH23    Volume
        (No iris/shutters or effects)

        ───────────────────────────────────────────────────
        COMPACT MODE (10 CHANNELS)
        ───────────────────────────────────────────────────
        CH1   Content       0=Off, 1-20=Shapes, 21-200=Gobos, 201-255=Media
        CH2   X Position    8-bit (0=left, 255=right)
        CH3   Y Position    8-bit (0=top, 255=bottom)
        CH4   Scale         Overall size
        CH5   Opacity       Transparency
        CH6   Red           Color
        CH7   Green         Color
        CH8   Blue          Color
        CH9   Softness      Edge blur
        CH10  Spin          Rotation speed

        ───────────────────────────────────────────────────
        CONTENT VALUES (CH1)
        ───────────────────────────────────────────────────
        0       Off/Invisible
        1-10    Shapes: Line, Circle, Triangle, TriStar, Square,
                SqStar, Pentagon, PentStar, Hexagon, HexStar
        11-20   Bezel versions of shapes 1-10
        21-200  Gobo slots (gobo_021.png through gobo_200.png)
        201-255 Media slots (video/NDI sources)
        """
        showHelpWindow(title: "DMX Channel Reference", content: content)
    }

    @objc private func showQuickStart() {
        let content = """
        QUICK START GUIDE - GeoDraw \(AppVersion.string)
        ═════════════════════════════════════════════════

        1. CONFIGURE NETWORK (⌘,)
           • Choose protocol: Art-Net, sACN, or Both
           • Select network interface
           • Set start universe (default: 2)

        2. ADD FIXTURES
           • Settings → DMX tab → Add Fixtures
           • Choose mode:
             - Full (37ch): All features + shutters + effects
             - Standard (23ch): No iris/shutters/effects
             - Compact (10ch): Basic control only
           • Color coding: Cyan=Full, Green=Std, Orange=Compact

        3. PATCH YOUR CONSOLE
           • Full mode: 13 fixtures per universe
           • Standard: 22 fixtures per universe
           • Compact: 51 fixtures per universe

        4. BASIC CONTROL
           • CH1: Content (1-20=shapes, 21-200=gobos, 201-255=media)
           • CH2-5: X/Y Position (16-bit)
           • CH7-8: Scale (16-bit)
           • CH14: Opacity (fade in/out)
           • CH16-18: RGB color

        5. ADD GOBOS
           • Place PNG files in ~/Documents/GeoDraw/gobos/
           • Name format: gobo_XXX_name.png (XXX = slot 021-200)
           • Or use GoboCreator app (~/Documents/GoboCreator/Library/)
           • Set CH1 to gobo slot number (21-200)
           • ⌘G to refresh gobo library

        6. VIDEO CONTENT
           • Media → Media Slots (⌘M)
           • Assign videos to slots 201-255
           • Set CH1 to media slot number
           • CH21: Playback control
           • CH22: Color/Mask blend mode

        7. OUTPUTS
           • Output → Configure Outputs
           • Multiple independent NDI outputs
           • Edge blending & warping per output

        8. SAVE YOUR WORK
           • File → Save Show (⌘S) - fixtures & patch
           • File → Save Venue (⌘⇧V) - outputs & canvas

        TIPS
        • CH24 (Iris): 0=Open, 255=Closed (Full mode only)
        • CH25-33: Framing shutters (Full mode only)
        • CH34-37: Prism/Animation effects (Full mode only)
        • Use Layout Editor for fixture positioning
        """
        showHelpWindow(title: "Quick Start Guide", content: content)
    }

    @objc private func showShortcuts() {
        let content = """
        KEYBOARD SHORTCUTS - GeoDraw \(AppVersion.string)
        ═════════════════════════════════════════════════

        APPLICATION
        ⌘,        Settings / Preferences
        ⌘H        Hide GeoDraw
        ⌘Q        Quit

        FILE
        ⌘N        New Show
        ⌘O        Open Show
        ⌘S        Save Show
        ⇧⌘S       Save Show As
        ⌘V        Load Venue
        ⇧⌘V       Save Venue

        MEDIA
        ⌘M        Media Slot Configuration
        ⌘G        Refresh Gobo Library
        ⌘R        Refresh NDI Sources

        OUTPUT
        ⇧⌘N       Toggle NDI Output
        ⇧⌘O       Configure Outputs

        VIEW
        ⌘F        Toggle Full Screen
        ⌘L        Layout Editor
        ⌘1-4      Select Output 1-4

        WINDOW
        ⌘M        Minimize Window
        ⌘W        Close Window

        HELP
        ⌘?        DMX Channel Reference
        ⇧⌘?       Quick Start Guide
        """
        showHelpWindow(title: "Keyboard Shortcuts", content: content)
    }

    private func showHelpWindow(title: String, content: String) {
        // Clean up closed windows from the array
        helpWindows.removeAll { !$0.isVisible }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "◈ \(title.uppercased()) ◈"
        window.isReleasedWhenClosed = false  // Prevent premature deallocation
        RetroTheme.styleWindow(window)
        window.center()

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = RetroTheme.backgroundDeep.cgColor

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = RetroTheme.bodyFont(size: 12)
        textView.textContainerInset = NSSize(width: 15, height: 15)
        textView.backgroundColor = RetroTheme.backgroundDeep
        textView.textColor = RetroTheme.textPrimary
        textView.string = content

        scrollView.documentView = textView
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)

        // Retain window to prevent crash on app exit
        helpWindows.append(window)
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                controller: controller,
                receiver: receiver,
                state: state,
                maxObjects: maxObjects
            ) { [weak self] config in
                self?.applySettings(config: config)
            }
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
    }

    @objc private func showLayoutEditor() {
        if layoutWindowController == nil {
            layoutWindowController = LayoutWindowController(controller: controller)
        }
        layoutWindowController?.showWindow(nil)
        layoutWindowController?.window?.center()
    }

    @objc private func toggleCanvasNDIMenu(_ sender: NSMenuItem) {
        CanvasNDIManager.shared.toggle()
    }

    private func applySettings(config: SettingsConfig) {
        let universeChanged = config.startUniverse != controller.startUniverse || config.universeCount != controller.universeCount
        let protocolChanged = config.protocolType != currentProtocol
        let interfaceChanged = config.networkInterface.ip != currentInterface.ip

        controller.updateConfig(fixtureCount: config.fixtureCount, startUniverse: config.startUniverse, startAddress: config.startAddress, startFixtureId: config.startFixtureId, mode: config.mode)

        if universeChanged || protocolChanged || interfaceChanged {
            let maxOutputUniverse = OutputManager.shared.getMaxOutputUniverse()
            let totalUniverseCount = max(controller.universeCount, maxOutputUniverse - config.startUniverse + 1)
            receiver.restart(startUniverse: config.startUniverse, universeCount: totalUniverseCount, protocolType: config.protocolType, networkInterface: config.networkInterface)
            currentProtocol = config.protocolType
            currentInterface = config.networkInterface
        }

        let maxOutUni = OutputManager.shared.getMaxOutputUniverse()
        let displayUniverseCount = max(controller.universeCount, maxOutUni - config.startUniverse + 1)
        window.title = buildWindowTitle(startUniverse: config.startUniverse, universeCount: displayUniverseCount, protocolType: config.protocolType, iface: config.networkInterface)

        // Save settings for next launch
        SavedSettings.save(
            fixtureCount: config.fixtureCount,
            startUniverse: config.startUniverse,
            startAddress: config.startAddress,
            protocolType: config.protocolType,
            interfaceIP: config.networkInterface.ip
        )
    }

    // MARK: - Show File Management

    @objc private func newShow() {
        // Reset to defaults
        let config = SettingsConfig(
            fixtureCount: 4,
            startUniverse: 1,
            startAddress: 1,
            startFixtureId: 1,
            protocolType: .both,
            networkInterface: NetworkInterface.all().first { !$0.isLoopback } ?? NetworkInterface.all().first!,
            resolutionWidth: Int(canvasSize.width),
            resolutionHeight: Int(canvasSize.height),
            mode: .full
        )
        applySettings(config: config)
        currentShowPath = nil
        updateWindowTitleWithShow()
    }

    @objc private func openShow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Show File"

        if panel.runModal() == .OK, let url = panel.url {
            loadShow(from: url)
        }
    }

    @objc private func saveShowAction() {
        if let path = currentShowPath {
            writeShow(to: path)
        } else {
            saveShowAs()
        }
    }

    @objc private func saveShowAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = currentShowPath?.lastPathComponent ?? "Untitled.geodraw"
        panel.title = "Save Show File"

        if panel.runModal() == .OK, let url = panel.url {
            writeShow(to: url)
            currentShowPath = url
            updateWindowTitleWithShow()
        }
    }

    private func writeShow(to url: URL) {
        // Save per-fixture data
        let fixtureModes = controller.objects.map { $0.mode.rawValue }
        let fixtureUniverses = controller.objects.map { $0.universe }
        let fixtureAddresses = controller.objects.map { $0.address }
        let show = ShowFile(
            fixtureCount: controller.objects.count,
            startUniverse: controller.startUniverse,
            startAddress: controller.startAddress,
            startFixtureId: controller.startFixtureId,
            protocolType: currentProtocol.rawValue,
            interfaceIP: currentInterface.ip,
            resolutionWidth: Int(canvasSize.width),
            resolutionHeight: Int(canvasSize.height),
            dmxMode: controller.defaultMode.rawValue,
            fixtureModes: fixtureModes,
            fixtureUniverses: fixtureUniverses,
            fixtureAddresses: fixtureAddresses
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(show)
            try data.write(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to Save Show"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func loadShow(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let show = try decoder.decode(ShowFile.self, from: data)

            let interfaces = NetworkInterface.all()
            let networkInterface = interfaces.first { $0.ip == show.interfaceIP }
                ?? interfaces.first { !$0.isLoopback }
                ?? interfaces.first!

            let config = SettingsConfig(
                fixtureCount: show.fixtureCount,
                startUniverse: show.startUniverse,
                startAddress: show.startAddress,
                startFixtureId: show.startFixtureId ?? 1,
                protocolType: DMXProtocol(rawValue: show.protocolType) ?? .both,
                networkInterface: networkInterface,
                resolutionWidth: show.resolutionWidth ?? Int(canvasSize.width),
                resolutionHeight: show.resolutionHeight ?? Int(canvasSize.height),
                mode: DMXMode(rawValue: show.dmxMode ?? 0) ?? .full
            )
            applySettings(config: config)

            // Apply per-fixture modes if saved
            if let fixtureModes = show.fixtureModes {
                for (index, modeRaw) in fixtureModes.enumerated() {
                    if let mode = DMXMode(rawValue: modeRaw) {
                        controller.setFixtureMode(index: index, mode: mode)
                    }
                }
            }

            // Apply per-fixture universes and addresses if saved
            if let fixtureUniverses = show.fixtureUniverses,
               let fixtureAddresses = show.fixtureAddresses {
                for index in 0..<min(fixtureUniverses.count, fixtureAddresses.count) {
                    controller.setFixtureAddress(index: index,
                                                 universe: fixtureUniverses[index],
                                                 address: fixtureAddresses[index])
                }
            }

            currentShowPath = url
            updateWindowTitleWithShow()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to Open Show"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func updateWindowTitleWithShow() {
        var title = buildWindowTitle(
            startUniverse: controller.startUniverse,
            universeCount: controller.universeCount,
            protocolType: currentProtocol,
            iface: currentInterface
        )
        if let path = currentShowPath {
            title = "\(path.deletingPathExtension().lastPathComponent) - " + title
        }
        window.title = title
    }
}

// MARK: - Show File Format

struct ShowFile: Codable {
    let fixtureCount: Int
    let startUniverse: Int
    let startAddress: Int
    var startFixtureId: Int?  // Starting fixture ID number
    let protocolType: Int
    let interfaceIP: String
    var resolutionWidth: Int?
    var resolutionHeight: Int?
    var dmxMode: Int?  // Default mode: 0=full, 1=standard, 2=compact (legacy)
    var fixtureModes: [Int]?  // Per-fixture modes array
    var fixtureUniverses: [Int]?  // Per-fixture universe array
    var fixtureAddresses: [Int]?  // Per-fixture address array
}

// MARK: - Helpers

private func clamp(_ value: Int, min: Int, max: Int) -> Int {
    if value < min { return min }
    if value > max { return max }
    return value
}
// MARK: - Settings Persistence

@MainActor
struct SavedSettings {
    static let defaults = UserDefaults.standard

    static func save(fixtureCount: Int, startUniverse: Int, startAddress: Int, protocolType: DMXProtocol, interfaceIP: String) {
        defaults.set(fixtureCount, forKey: "fixtureCount")
        defaults.set(startUniverse, forKey: "startUniverse")
        defaults.set(startAddress, forKey: "startAddress")
        defaults.set(protocolType.rawValue, forKey: "protocolType")
        defaults.set(interfaceIP, forKey: "interfaceIP")
    }

    static func load() -> (fixtureCount: Int, startUniverse: Int, startAddress: Int, protocolType: DMXProtocol, networkInterface: NetworkInterface) {
        let fixtureCount = defaults.integer(forKey: "fixtureCount")
        let startUniverse = defaults.integer(forKey: "startUniverse")
        let startAddress = defaults.integer(forKey: "startAddress")
        let protocolRaw = defaults.integer(forKey: "protocolType")
        let interfaceIP = defaults.string(forKey: "interfaceIP") ?? ""

        let interfaces = NetworkInterface.all()
        let networkInterface = interfaces.first { $0.ip == interfaceIP }
            ?? interfaces.first { !$0.isLoopback }
            ?? interfaces.first!

        return (
            fixtureCount: fixtureCount > 0 ? fixtureCount : 4,
            startUniverse: startUniverse > 0 ? startUniverse : 1,
            startAddress: startAddress > 0 ? startAddress : 1,
            protocolType: DMXProtocol(rawValue: protocolRaw) ?? .both,
            networkInterface: networkInterface
        )
    }
}

// MARK: - Entry

@main
struct DMXVisualizerMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // Load saved settings or use defaults
        let saved = SavedSettings.load()
        let delegate = AppDelegate(
            fixtureCount: saved.fixtureCount,
            startUniverse: saved.startUniverse,
            startAddress: saved.startAddress,
            protocolType: saved.protocolType,
            networkInterface: saved.networkInterface
        )
        app.delegate = delegate
        app.run()
    }
}
