import Foundation
import Network
import AppKit

// MARK: - Web Server

/// Built-in HTTP server for remote media management
/// Accessible at http://<host>:8080
final class WebServer: @unchecked Sendable {
    @MainActor static let shared = WebServer()

    private var listener: NWListener?
    private let port: UInt16 = 8082
    private let queue = DispatchQueue(label: "com.geodraw.webserver", qos: .userInitiated)
    private var isRunning = false

    private init() {}

    @MainActor
    func start() {
        guard !isRunning else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("WebServer: Listening on port \(self?.port ?? 0)")
                    print("WebServer: Access at http://localhost:\(self?.port ?? 0)")
                case .failed(let error):
                    print("WebServer: Failed - \(error)")
                case .cancelled:
                    print("WebServer: Stopped")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: queue)
            isRunning = true
        } catch {
            print("WebServer: Failed to start - \(error)")
        }
    }

    @MainActor
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handleConnection(_ connection: NWConnection) {
        NSLog("WebServer: New connection")
        connection.start(queue: queue)
        receiveData(connection: connection, accumulated: Data())
    }

    private func receiveData(connection: NWConnection, accumulated: Data) {
        // Read in chunks, max 100MB total
        let maxSize = 100 * 1024 * 1024

        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            if let error = error {
                NSLog("WebServer: Receive error - %@", error.localizedDescription)
            }
            var newData = accumulated
            if let data = data {
                newData.append(data)
                NSLog("WebServer: Received chunk %d bytes (total: %d)", data.count, newData.count)
            }

            // Check if we have complete headers and can determine content length
            if let headerEnd = newData.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = newData.subdata(in: newData.startIndex..<headerEnd.lowerBound)
                if let headerStr = String(data: headerData, encoding: .utf8) {
                    // Parse content-length
                    var contentLength = 0
                    for line in headerStr.components(separatedBy: "\r\n") {
                        if line.lowercased().hasPrefix("content-length:") {
                            let value = line.components(separatedBy: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)
                            contentLength = Int(value) ?? 0
                            break
                        }
                    }

                    let bodyStart = headerEnd.upperBound
                    let bodyLength = newData.count - newData.distance(from: newData.startIndex, to: bodyStart)
                    let expectedTotal = newData.distance(from: newData.startIndex, to: bodyStart) + contentLength

                    // If we have all the data or hit max size, process it
                    if bodyLength >= contentLength || newData.count >= maxSize || isComplete {
                        self?.processRequest(data: newData, connection: connection)
                        return
                    }
                }
            }

            // Keep reading if not complete and under max size
            if !isComplete && error == nil && newData.count < maxSize {
                self?.receiveData(connection: connection, accumulated: newData)
            } else {
                // Process whatever we have
                self?.processRequest(data: newData, connection: connection)
            }
        }
    }

    private func processRequest(data: Data, connection: NWConnection) {
        NSLog("WebServer: processRequest with %d bytes", data.count)
        guard let request = HTTPRequest.parse(data: data) else {
            NSLog("WebServer: Failed to parse HTTP request")
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "binary data"
            NSLog("WebServer: Request preview: %@", preview)
            sendResponse(HTTPResponse.badRequest(), connection: connection)
            return
        }

        // Route the request on MainActor
        Task { @MainActor in
            let response = await self.route(request: request)
            self.sendResponse(response, connection: connection)
        }
    }

    private func sendResponse(_ response: HTTPResponse, connection: NWConnection) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("WebServer: Send error - \(error)")
            }
            connection.cancel()
        })
    }

    // MARK: - Router

    @MainActor
    private func route(request: HTTPRequest) async -> HTTPResponse {
        let path = request.path
        let method = request.method

        NSLog("WebServer: %@ %@ (body: %d bytes)", method, path, request.body.count)

        // CORS preflight
        if method == "OPTIONS" {
            return HTTPResponse.cors()
        }

        // Static files (root serves index.html)
        if path == "/" || path == "/index.html" {
            return serveIndexHTML()
        }

        // API routes
        if path.hasPrefix("/api/v1/") {
            return await handleAPI(request: request)
        }

        // Favicon
        if path == "/favicon.ico" {
            return HTTPResponse.notFound()
        }

        return HTTPResponse.notFound()
    }

    // MARK: - API Handler

    @MainActor
    private func handleAPI(request: HTTPRequest) async -> HTTPResponse {
        let path = request.path.replacingOccurrences(of: "/api/v1", with: "")
        let method = request.method

        // Status endpoints
        if path == "/status" && method == "GET" {
            return handleGetStatus()
        }
        if path == "/status/preview" && method == "GET" {
            return handleGetPreview()
        }

        // Gobo endpoints
        if path == "/gobos" && method == "GET" {
            return handleGetGobos()
        }
        if path.hasPrefix("/gobos/") && path.hasSuffix("/image") && method == "GET" {
            let idStr = path.replacingOccurrences(of: "/gobos/", with: "").replacingOccurrences(of: "/image", with: "")
            if let id = Int(idStr) {
                return handleGetGoboImage(id: id)
            }
        }
        if path == "/gobos/upload" && method == "POST" {
            return handleGoboUpload(request: request)
        }
        if path.hasPrefix("/gobos/") && method == "DELETE" {
            let idStr = path.replacingOccurrences(of: "/gobos/", with: "")
            if let id = Int(idStr) {
                return handleDeleteGobo(id: id)
            }
        }
        // Move/reorder gobo: PUT /gobos/{fromId}/move/{toId}
        if path.hasPrefix("/gobos/") && path.contains("/move/") && method == "PUT" {
            let regex = try? NSRegularExpression(pattern: #"/gobos/(\d+)/move/(\d+)"#)
            if let match = regex?.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
               let fromRange = Range(match.range(at: 1), in: path),
               let toRange = Range(match.range(at: 2), in: path),
               let fromId = Int(path[fromRange]),
               let toId = Int(path[toRange]) {
                return handleMoveGobo(fromId: fromId, toId: toId)
            }
        }

        // Media slot endpoints
        if path == "/media/slots" && method == "GET" {
            return handleGetMediaSlots()
        }
        if path.hasPrefix("/media/slots/") && method == "PUT" {
            let slotStr = path.replacingOccurrences(of: "/media/slots/", with: "")
            if let slot = Int(slotStr) {
                return handleSetMediaSlot(slot: slot, request: request)
            }
        }
        if path.hasPrefix("/media/slots/") && method == "DELETE" {
            let slotStr = path.replacingOccurrences(of: "/media/slots/", with: "")
            if let slot = Int(slotStr) {
                return handleClearMediaSlot(slot: slot)
            }
        }
        if path == "/media/videos" && method == "GET" {
            return handleGetVideos()
        }
        if path == "/media/videos/upload" && method == "POST" {
            return handleVideoUpload(request: request)
        }
        if path == "/media/images" && method == "GET" {
            return handleGetImages()
        }
        if path == "/media/images/upload" && method == "POST" {
            return handleImageUpload(request: request)
        }

        // NDI endpoints
        if path == "/ndi/sources" && method == "GET" {
            return handleGetNDISources()
        }
        if path == "/ndi/refresh" && method == "POST" {
            return handleRefreshNDI()
        }

        // Output endpoints
        if path == "/outputs" && method == "GET" {
            return handleGetOutputs()
        }
        if path == "/displays" && method == "GET" {
            return handleGetDisplays()
        }
        if path == "/outputs/display" && method == "POST" {
            return handleAddDisplayOutput(request: request)
        }
        if path == "/outputs/ndi" && method == "POST" {
            return handleAddNDIOutput(request: request)
        }
        if path.hasPrefix("/outputs/") && path.hasSuffix("/enable") && method == "PUT" {
            let idStr = path.replacingOccurrences(of: "/outputs/", with: "").replacingOccurrences(of: "/enable", with: "")
            if let uuid = UUID(uuidString: idStr) {
                return handleEnableOutput(id: uuid, enabled: true)
            }
        }
        if path.hasPrefix("/outputs/") && path.hasSuffix("/disable") && method == "PUT" {
            let idStr = path.replacingOccurrences(of: "/outputs/", with: "").replacingOccurrences(of: "/disable", with: "")
            if let uuid = UUID(uuidString: idStr) {
                return handleEnableOutput(id: uuid, enabled: false)
            }
        }
        if path.hasPrefix("/outputs/") && method == "DELETE" {
            let idStr = path.replacingOccurrences(of: "/outputs/", with: "")
            if let uuid = UUID(uuidString: idStr) {
                return handleRemoveOutput(id: uuid)
            }
        }
        if path.hasPrefix("/outputs/") && path.hasSuffix("/settings") && method == "PUT" {
            let idStr = path.replacingOccurrences(of: "/outputs/", with: "").replacingOccurrences(of: "/settings", with: "")
            if let uuid = UUID(uuidString: idStr) {
                return handleUpdateOutputSettings(id: uuid, request: request)
            }
        }
        return HTTPResponse.notFound()
    }

    // MARK: - Status Handlers

    @MainActor
    private func handleGetStatus() -> HTTPResponse {
        let fixtureCount = sharedMetalRenderView?.fixtureCount ?? 0
        let activeFixtures = sharedMetalRenderView?.activeFixtureCount ?? 0

        let canvasWidth = UserDefaults.standard.integer(forKey: "canvasWidth")
        let canvasHeight = UserDefaults.standard.integer(forKey: "canvasHeight")

        let status: [String: Any] = [
            "version": AppVersion.string,
            "fixtureCount": fixtureCount,
            "activeFixtures": activeFixtures,
            "resolution": [
                "width": canvasWidth > 0 ? canvasWidth : 1920,
                "height": canvasHeight > 0 ? canvasHeight : 1080
            ],
            "outputCount": OutputManager.shared.getAllOutputs().count
        ]

        return HTTPResponse.json(status)
    }

    @MainActor
    private func handleGetPreview() -> HTTPResponse {
        guard let renderView = sharedMetalRenderView,
              let image = renderView.captureCurrentFrame() else {
            return HTTPResponse.notFound()
        }

        // Resize to preview (larger for full-width display)
        let maxWidth: CGFloat = 960
        let scale = min(1.0, maxWidth / image.size.width)  // Don't upscale
        let newSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        let preview = NSImage(size: newSize)
        preview.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        preview.unlockFocus()

        // Convert to JPEG (higher quality for larger preview)
        guard let tiff = preview.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return HTTPResponse.error(500, "Failed to encode image")
        }

        return HTTPResponse(status: 200, statusText: "OK", contentType: "image/jpeg", body: jpeg)
    }

    // MARK: - Gobo Handlers

    @MainActor
    private func handleGetGobos() -> HTTPResponse {
        // Refresh gobo library to pick up any new files
        GoboLibrary.shared.refreshGobos()

        var gobos: [[String: Any]] = []

        for id in 21...200 {
            let hasImage = GoboLibrary.shared.image(for: id) != nil
            let name = GoboLibrary.shared.definition(for: id)?.name ?? "Slot \(id)"
            let category = GoboLibrary.shared.definition(for: id)?.category.rawValue ?? "custom"

            gobos.append([
                "id": id,
                "name": name,
                "category": category,
                "hasImage": hasImage,
                "imageUrl": "/api/v1/gobos/\(id)/image"
            ])
        }

        let response: [String: Any] = [
            "gobos": gobos,
            "range": ["start": 21, "end": 200],
            "uploadFolder": getGoboUploadFolder().path
        ]

        return HTTPResponse.json(response)
    }

    @MainActor
    private func handleGetGoboImage(id: Int) -> HTTPResponse {
        guard let cgImage = GoboLibrary.shared.image(for: id) else {
            return HTTPResponse.notFound()
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return HTTPResponse.error(500, "Failed to encode image")
        }

        return HTTPResponse(status: 200, statusText: "OK", contentType: "image/png", body: png)
    }

    @MainActor
    private func handleGoboUpload(request: HTTPRequest) -> HTTPResponse {
        guard let contentType = request.headers["content-type"],
              contentType.contains("multipart/form-data"),
              let boundary = extractBoundary(from: contentType) else {
            return HTTPResponse.badRequest("Expected multipart/form-data")
        }

        guard let parts = parseMultipart(data: request.body, boundary: boundary),
              let filePart = parts.first(where: { $0.filename != nil }) else {
            return HTTPResponse.badRequest("No file uploaded")
        }

        // Check for slot parameter in form data
        var slotId = 21
        if let slotPart = parts.first(where: { $0.name == "slot" }),
           let slotStr = String(data: slotPart.data, encoding: .utf8),
           let requestedSlot = Int(slotStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           requestedSlot >= 21 && requestedSlot <= 200 {
            slotId = requestedSlot
        } else {
            // Find next available slot if not specified
            for id in 21...200 {
                if GoboLibrary.shared.image(for: id) == nil {
                    slotId = id
                    break
                }
            }
        }

        // Generate filename with slot number
        let safeName = filePart.filename?
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".png", with: "") ?? "custom"
        let filename = "gobo_\(String(format: "%03d", slotId))_\(safeName).png"

        // Save to upload folder
        let uploadFolder = getGoboUploadFolder()
        try? FileManager.default.createDirectory(at: uploadFolder, withIntermediateDirectories: true)
        let fileURL = uploadFolder.appendingPathComponent(filename)

        do {
            NSLog("WebServer: Saving gobo to %@", fileURL.path)
            try filePart.data.write(to: fileURL)
            NSLog("WebServer: Gobo saved successfully, refreshing library")

            // Refresh gobo library to pick up new file (already on MainActor)
            GoboLibrary.shared.refreshGobos()

            return HTTPResponse.json([
                "success": true,
                "slot": slotId,
                "filename": filename,
                "path": fileURL.path
            ])
        } catch {
            NSLog("WebServer: Failed to save gobo: %@", error.localizedDescription)
            return HTTPResponse.error(500, "Failed to save file: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleDeleteGobo(id: Int) -> HTTPResponse {
        // Search all gobo folders for files matching this ID
        let prefix = "gobo_\(String(format: "%03d", id))_"
        var deletedCount = 0

        for folder in [getGoboUploadFolder(), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GoboCreator/Library")] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }

            for file in files {
                if file.lastPathComponent.hasPrefix(prefix) && file.pathExtension.lowercased() == "png" {
                    do {
                        try FileManager.default.removeItem(at: file)
                        deletedCount += 1
                        NSLog("WebServer: Deleted gobo file: %@", file.lastPathComponent)
                    } catch {
                        NSLog("WebServer: Failed to delete %@: %@", file.path, error.localizedDescription)
                    }
                }
            }
        }

        if deletedCount > 0 {
            GoboLibrary.shared.refreshGobos()
            return HTTPResponse.json(["success": true, "id": id, "deletedFiles": deletedCount])
        }

        return HTTPResponse.error(404, "No gobo files found for slot \(id)")
    }

    @MainActor
    private func handleMoveGobo(fromId: Int, toId: Int) -> HTTPResponse {
        guard fromId >= 21 && fromId <= 200 && toId >= 21 && toId <= 200 else {
            return HTTPResponse.badRequest("Invalid slot IDs (must be 21-200)")
        }

        NSLog("WebServer: Moving gobo from slot %d to slot %d", fromId, toId)

        // Find the source gobo file
        let fromPrefix = "gobo_\(String(format: "%03d", fromId))_"
        let toPrefix = "gobo_\(String(format: "%03d", toId))_"

        var fromFile: URL? = nil
        var toFile: URL? = nil
        let folders = [getGoboUploadFolder(), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GoboCreator/Library")]

        // Find source and target files
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension.lowercased() == "png" {
                if file.lastPathComponent.hasPrefix(fromPrefix) { fromFile = file }
                if file.lastPathComponent.hasPrefix(toPrefix) { toFile = file }
            }
        }

        guard let sourceFile = fromFile else {
            return HTTPResponse.error(404, "Source gobo not found for slot \(fromId)")
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory

        do {
            // Get the descriptive part of filenames (after gobo_XXX_)
            let sourceName = sourceFile.lastPathComponent
                .replacingOccurrences(of: fromPrefix, with: "")

            // If target slot has a file, we need to swap
            if let targetFile = toFile {
                let targetName = targetFile.lastPathComponent
                    .replacingOccurrences(of: toPrefix, with: "")

                // Move target to temp
                let tempFile = tempDir.appendingPathComponent("gobo_temp_\(UUID().uuidString).png")
                try fm.moveItem(at: targetFile, to: tempFile)

                // Move source to target slot (same folder as source was in)
                let newSourcePath = sourceFile.deletingLastPathComponent()
                    .appendingPathComponent("gobo_\(String(format: "%03d", toId))_\(sourceName)")
                try fm.moveItem(at: sourceFile, to: newSourcePath)

                // Move temp (old target) to source slot
                let newTargetPath = sourceFile.deletingLastPathComponent()
                    .appendingPathComponent("gobo_\(String(format: "%03d", fromId))_\(targetName)")
                try fm.moveItem(at: tempFile, to: newTargetPath)

                NSLog("WebServer: Swapped gobo %d <-> %d", fromId, toId)
            } else {
                // Just move source to empty target slot
                let newPath = sourceFile.deletingLastPathComponent()
                    .appendingPathComponent("gobo_\(String(format: "%03d", toId))_\(sourceName)")
                try fm.moveItem(at: sourceFile, to: newPath)

                NSLog("WebServer: Moved gobo %d -> %d", fromId, toId)
            }

            // Refresh gobo library
            GoboLibrary.shared.refreshGobos()

            return HTTPResponse.json([
                "success": true,
                "from": fromId,
                "to": toId,
                "swapped": toFile != nil
            ])
        } catch {
            NSLog("WebServer: Failed to move gobo: %@", error.localizedDescription)
            return HTTPResponse.error(500, "Failed to move gobo: \(error.localizedDescription)")
        }
    }

    // MARK: - Media Slot Handlers

    @MainActor
    private func handleGetMediaSlots() -> HTTPResponse {
        var slots: [[String: Any]] = []

        for slot in 201...255 {
            var slotInfo: [String: Any] = ["slot": slot]

            let sourceType = MediaSlotConfig.shared.getSource(forSlot: slot)
            switch sourceType {
            case .video(let path):
                slotInfo["type"] = "video"
                slotInfo["source"] = path
                slotInfo["displayName"] = URL(fileURLWithPath: path).lastPathComponent
            case .image(let path):
                slotInfo["type"] = "image"
                slotInfo["source"] = path
                slotInfo["displayName"] = URL(fileURLWithPath: path).lastPathComponent
            case .ndi(let sourceName):
                slotInfo["type"] = "ndi"
                slotInfo["source"] = sourceName
                slotInfo["displayName"] = "NDI: \(sourceName)"
            case .none:
                slotInfo["type"] = "none"
                slotInfo["source"] = NSNull()
                slotInfo["displayName"] = "Empty"
            }

            slots.append(slotInfo)
        }

        return HTTPResponse.json(["slots": slots])
    }

    @MainActor
    private func handleSetMediaSlot(slot: Int, request: HTTPRequest) -> HTTPResponse {
        guard slot >= 201 && slot <= 255 else {
            return HTTPResponse.badRequest("Invalid slot (must be 201-255)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let type = json["type"] as? String,
              let source = json["source"] as? String else {
            return HTTPResponse.badRequest("Expected JSON with type and source")
        }

        if type == "ndi" {
            MediaSlotConfig.shared.assignNDI(sourceName: source, toSlot: slot)
        } else if type == "image" {
            MediaSlotConfig.shared.assignImage(path: source, toSlot: slot)
        } else {
            MediaSlotConfig.shared.assignVideo(path: source, toSlot: slot)
        }

        return HTTPResponse.json(["success": true, "slot": slot])
    }

    @MainActor
    private func handleClearMediaSlot(slot: Int) -> HTTPResponse {
        guard slot >= 201 && slot <= 255 else {
            return HTTPResponse.badRequest("Invalid slot (must be 201-255)")
        }

        MediaSlotConfig.shared.clearSlot(slot)

        return HTTPResponse.json(["success": true, "slot": slot])
    }

    private func handleGetVideos() -> HTTPResponse {
        let videosFolder = getVideosFolder()
        var videos: [[String: Any]] = []

        if let files = try? FileManager.default.contentsOfDirectory(at: videosFolder, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                let ext = file.pathExtension.lowercased()
                if ["mp4", "mov", "avi", "mkv", "m4v"].contains(ext) {
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    videos.append([
                        "filename": file.lastPathComponent,
                        "path": file.path,
                        "size": size
                    ])
                }
            }
        }

        return HTTPResponse.json(["videos": videos, "folder": videosFolder.path])
    }

    private func handleVideoUpload(request: HTTPRequest) -> HTTPResponse {
        NSLog("WebServer: handleVideoUpload called")
        guard let contentType = request.headers["content-type"],
              contentType.contains("multipart/form-data"),
              let boundary = extractBoundary(from: contentType) else {
            NSLog("WebServer: Video upload - missing content-type or boundary")
            NSLog("WebServer: Headers: %@", request.headers.description)
            return HTTPResponse.badRequest("Expected multipart/form-data")
        }

        NSLog("WebServer: Video upload - body size: %d bytes, boundary: %@", request.body.count, boundary)

        guard let parts = parseMultipart(data: request.body, boundary: boundary),
              let filePart = parts.first(where: { $0.filename != nil }),
              let filename = filePart.filename else {
            NSLog("WebServer: Video upload - failed to parse multipart or no file found")
            let preview = String(data: request.body.prefix(500), encoding: .utf8) ?? "binary"
            NSLog("WebServer: Body preview: %@", preview)
            return HTTPResponse.badRequest("No file uploaded - body size: \(request.body.count)")
        }

        let videosFolder = getVideosFolder()
        try? FileManager.default.createDirectory(at: videosFolder, withIntermediateDirectories: true)
        let fileURL = videosFolder.appendingPathComponent(filename)

        do {
            try filePart.data.write(to: fileURL)
            return HTTPResponse.json([
                "success": true,
                "filename": filename,
                "path": fileURL.path
            ])
        } catch {
            return HTTPResponse.error(500, "Failed to save video: \(error.localizedDescription)")
        }
    }

    // MARK: - Image Handlers

    private func handleGetImages() -> HTTPResponse {
        let imagesFolder = getImagesFolder()

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: imagesFolder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return HTTPResponse.json(["images": [], "folder": imagesFolder.path])
        }

        let imageExtensions = ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "webp"]
        let images = contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .map { ["filename": $0.lastPathComponent, "path": $0.path] }

        return HTTPResponse.json(["images": images, "folder": imagesFolder.path])
    }

    private func handleImageUpload(request: HTTPRequest) -> HTTPResponse {
        NSLog("WebServer: handleImageUpload called")
        guard let contentType = request.headers["content-type"],
              contentType.contains("multipart/form-data"),
              let boundary = extractBoundary(from: contentType) else {
            NSLog("WebServer: Image upload - missing content-type or boundary")
            return HTTPResponse.badRequest("Expected multipart/form-data")
        }

        NSLog("WebServer: Image upload - body size: %d bytes", request.body.count)

        guard let parts = parseMultipart(data: request.body, boundary: boundary),
              let filePart = parts.first(where: { $0.filename != nil }),
              let filename = filePart.filename else {
            NSLog("WebServer: Image upload - failed to parse multipart or no file found")
            return HTTPResponse.badRequest("No file uploaded")
        }

        let imagesFolder = getImagesFolder()
        try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        let fileURL = imagesFolder.appendingPathComponent(filename)

        do {
            try filePart.data.write(to: fileURL)
            NSLog("WebServer: Image saved to %@", fileURL.path)
            return HTTPResponse.json([
                "success": true,
                "filename": filename,
                "path": fileURL.path
            ])
        } catch {
            return HTTPResponse.error(500, "Failed to save image: \(error.localizedDescription)")
        }
    }

    // MARK: - NDI Handlers

    @MainActor
    private func handleGetNDISources() -> HTTPResponse {
        let sources = NDISourceManager.shared.getAvailableSourceNames()
        let sourceList = sources.map { ["name": $0] }

        return HTTPResponse.json(["sources": sourceList])
    }

    @MainActor
    private func handleRefreshNDI() -> HTTPResponse {
        NDISourceManager.shared.refreshSources()
        return HTTPResponse.json(["success": true])
    }

    // MARK: - Output Handlers

    @MainActor
    private func handleGetOutputs() -> HTTPResponse {
        let outputs = OutputManager.shared.getAllOutputs()

        var outputList: [[String: Any]] = []
        for output in outputs {
            let c = output.config
            var info: [String: Any] = [
                "id": output.id.uuidString,
                "name": output.name,
                "type": output.type == .display ? "display" : "ndi",
                "enabled": c.enabled,
                "resolution": "\(output.width)x\(output.height)",
                // Position & Size
                "position": [
                    "x": c.positionX ?? 0,
                    "y": c.positionY ?? 0,
                    "w": c.positionW ?? Int(output.width),
                    "h": c.positionH ?? Int(output.height)
                ],
                // Crop
                "crop": [
                    "x": c.cropX,
                    "y": c.cropY,
                    "width": c.cropWidth,
                    "height": c.cropHeight
                ],
                // Edge Blend
                "edgeBlend": [
                    "left": c.edgeBlendLeft,
                    "right": c.edgeBlendRight,
                    "top": c.edgeBlendTop,
                    "bottom": c.edgeBlendBottom,
                    "gamma": c.edgeBlendGamma,
                    "power": c.edgeBlendPower,
                    "blackLevel": c.edgeBlendBlackLevel
                ],
                // Warp (8-point)
                "warp": [
                    "topLeft": ["x": c.warpTopLeftX, "y": c.warpTopLeftY],
                    "topMiddle": ["x": c.warpTopMiddleX, "y": c.warpTopMiddleY],
                    "topRight": ["x": c.warpTopRightX, "y": c.warpTopRightY],
                    "middleLeft": ["x": c.warpMiddleLeftX, "y": c.warpMiddleLeftY],
                    "middleRight": ["x": c.warpMiddleRightX, "y": c.warpMiddleRightY],
                    "bottomLeft": ["x": c.warpBottomLeftX, "y": c.warpBottomLeftY],
                    "bottomMiddle": ["x": c.warpBottomMiddleX, "y": c.warpBottomMiddleY],
                    "bottomRight": ["x": c.warpBottomRightX, "y": c.warpBottomRightY],
                    "curvature": c.warpCurvature
                ],
                // Lens Correction
                "lens": [
                    "k1": c.lensK1,
                    "k2": c.lensK2,
                    "centerX": c.lensCenterX,
                    "centerY": c.lensCenterY
                ],
                // DMX Patch
                "dmx": [
                    "universe": c.dmxUniverse,
                    "address": c.dmxAddress
                ],
                // Intensity
                "intensity": c.outputIntensity
            ]
            if output.type == .display {
                info["displayId"] = c.displayId as Any
            }
            outputList.append(info)
        }

        return HTTPResponse.json(["outputs": outputList])
    }

    @MainActor
    private func handleGetDisplays() -> HTTPResponse {
        let displays = OutputManager.shared.getAvailableDisplays()
        let existingOutputs = OutputManager.shared.getAllOutputs()

        var displayList: [[String: Any]] = []
        for display in displays {
            let hasOutput = existingOutputs.contains { $0.config.displayId == display.displayId }
            displayList.append([
                "displayId": display.displayId,
                "name": display.name,
                "width": display.width,
                "height": display.height,
                "refreshRate": display.refreshRate,
                "isMain": display.isMain,
                "hasOutput": hasOutput
            ])
        }

        return HTTPResponse.json(["displays": displayList])
    }

    @MainActor
    private func handleAddDisplayOutput(request: HTTPRequest) -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let displayId = json["displayId"] as? UInt32 else {
            return HTTPResponse.badRequest("Expected JSON with displayId")
        }

        let displays = OutputManager.shared.getAvailableDisplays()
        guard let display = displays.first(where: { $0.displayId == displayId }) else {
            return HTTPResponse.error(404, "Display not found")
        }

        // Check if already exists
        let existing = OutputManager.shared.getAllOutputs().first { $0.config.displayId == displayId }
        if existing != nil {
            return HTTPResponse.error(409, "Display output already exists")
        }

        if let id = OutputManager.shared.addDisplayOutput(displayId: displayId, name: display.name) {
            OutputManager.shared.enableOutput(id: id, enabled: true)
            return HTTPResponse.json(["success": true, "id": id.uuidString, "name": display.name])
        }

        return HTTPResponse.error(500, "Failed to add display output")
    }

    @MainActor
    private func handleAddNDIOutput(request: HTTPRequest) -> HTTPResponse {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let name = json["name"] as? String else {
            return HTTPResponse.badRequest("Expected JSON with name")
        }

        let sourceName = name.isEmpty ? "GeoDraw NDI" : name

        if let id = OutputManager.shared.addNDIOutput(sourceName: sourceName) {
            OutputManager.shared.enableOutput(id: id, enabled: true)
            return HTTPResponse.json(["success": true, "id": id.uuidString, "name": sourceName])
        }

        return HTTPResponse.error(500, "Failed to add NDI output")
    }

    @MainActor
    private func handleEnableOutput(id: UUID, enabled: Bool) -> HTTPResponse {
        let outputs = OutputManager.shared.getAllOutputs()
        guard outputs.contains(where: { $0.id == id }) else {
            return HTTPResponse.error(404, "Output not found")
        }

        OutputManager.shared.enableOutput(id: id, enabled: enabled)
        return HTTPResponse.json(["success": true, "id": id.uuidString, "enabled": enabled])
    }

    @MainActor
    private func handleRemoveOutput(id: UUID) -> HTTPResponse {
        let outputs = OutputManager.shared.getAllOutputs()
        guard outputs.contains(where: { $0.id == id }) else {
            return HTTPResponse.error(404, "Output not found")
        }

        OutputManager.shared.removeOutput(id: id)
        return HTTPResponse.json(["success": true, "id": id.uuidString])
    }

    @MainActor
    private func handleUpdateOutputSettings(id: UUID, request: HTTPRequest) -> HTTPResponse {
        let outputs = OutputManager.shared.getAllOutputs()
        guard outputs.contains(where: { $0.id == id }) else {
            return HTTPResponse.error(404, "Output not found")
        }

        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return HTTPResponse.badRequest("Invalid JSON")
        }

        // Position & Size
        if let position = json["position"] as? [String: Any] {
            let x = position["x"] as? Int ?? 0
            let y = position["y"] as? Int ?? 0
            let w = position["w"] as? Int ?? 1920
            let h = position["h"] as? Int ?? 1080
            OutputManager.shared.updatePosition(id: id, x: x, y: y, w: w, h: h)
        }

        // Crop
        if let crop = json["crop"] as? [String: Any] {
            let x = (crop["x"] as? NSNumber)?.floatValue ?? 0
            let y = (crop["y"] as? NSNumber)?.floatValue ?? 0
            let width = (crop["width"] as? NSNumber)?.floatValue ?? 1
            let height = (crop["height"] as? NSNumber)?.floatValue ?? 1
            OutputManager.shared.updateCrop(id: id, x: x, y: y, width: width, height: height)
        }

        // Edge Blend
        if let edge = json["edgeBlend"] as? [String: Any] {
            let left = (edge["left"] as? NSNumber)?.floatValue ?? 0
            let right = (edge["right"] as? NSNumber)?.floatValue ?? 0
            let top = (edge["top"] as? NSNumber)?.floatValue ?? 0
            let bottom = (edge["bottom"] as? NSNumber)?.floatValue ?? 0
            let gamma = (edge["gamma"] as? NSNumber)?.floatValue ?? 2.2
            let power = (edge["power"] as? NSNumber)?.floatValue ?? 1.0
            let blackLevel = (edge["blackLevel"] as? NSNumber)?.floatValue ?? 0
            OutputManager.shared.updateEdgeBlend(id: id, left: left, right: right, top: top, bottom: bottom,
                                                  gamma: gamma, power: power, blackLevel: blackLevel)
        }

        // Warp (8-point)
        if let warp = json["warp"] as? [String: Any] {
            // Parse warp points
            func getPoint(_ key: String) -> (Float, Float) {
                if let pt = warp[key] as? [String: Any] {
                    let x = (pt["x"] as? NSNumber)?.floatValue ?? 0
                    let y = (pt["y"] as? NSNumber)?.floatValue ?? 0
                    return (x, y)
                }
                return (0, 0)
            }
            let topLeft = getPoint("topLeft")
            let topMiddle = getPoint("topMiddle")
            let topRight = getPoint("topRight")
            let middleLeft = getPoint("middleLeft")
            let middleRight = getPoint("middleRight")
            let bottomLeft = getPoint("bottomLeft")
            let bottomMiddle = getPoint("bottomMiddle")
            let bottomRight = getPoint("bottomRight")

            OutputManager.shared.updateQuadWarp(id: id,
                topLeftX: topLeft.0, topLeftY: topLeft.1,
                topMiddleX: topMiddle.0, topMiddleY: topMiddle.1,
                topRightX: topRight.0, topRightY: topRight.1,
                middleLeftX: middleLeft.0, middleLeftY: middleLeft.1,
                middleRightX: middleRight.0, middleRightY: middleRight.1,
                bottomLeftX: bottomLeft.0, bottomLeftY: bottomLeft.1,
                bottomMiddleX: bottomMiddle.0, bottomMiddleY: bottomMiddle.1,
                bottomRightX: bottomRight.0, bottomRightY: bottomRight.1)
        }

        // Lens Correction
        if let lens = json["lens"] as? [String: Any] {
            let k1 = (lens["k1"] as? NSNumber)?.floatValue ?? 0
            let k2 = (lens["k2"] as? NSNumber)?.floatValue ?? 0
            let centerX = (lens["centerX"] as? NSNumber)?.floatValue ?? 0.5
            let centerY = (lens["centerY"] as? NSNumber)?.floatValue ?? 0.5
            OutputManager.shared.updateLensCorrection(id: id, k1: k1, k2: k2, centerX: centerX, centerY: centerY)
        }

        // DMX Patch
        if let dmx = json["dmx"] as? [String: Any] {
            let universe = dmx["universe"] as? Int ?? 0
            let address = dmx["address"] as? Int ?? 1
            OutputManager.shared.updateDMXPatch(id: id, universe: universe, address: address)
        }

        // Intensity
        if let intensity = (json["intensity"] as? NSNumber)?.floatValue {
            OutputManager.shared.updateOutputIntensity(id: id, intensity: intensity)
        }

        return HTTPResponse.json(["success": true, "id": id.uuidString])
    }

    // MARK: - Helpers

    private func getGoboUploadFolder() -> URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GeoDraw/gobos")
    }

    private func getVideosFolder() -> URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/DMXMedia/videos")
    }

    private func getImagesFolder() -> URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/DMXMedia/images")
    }

    private func extractBoundary(from contentType: String) -> String? {
        let parts = contentType.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("boundary=") {
                return trimmed.replacingOccurrences(of: "boundary=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    // MARK: - Static HTML

    private func serveIndexHTML() -> HTTPResponse {
        return HTTPResponse(status: 200, statusText: "OK", contentType: "text/html", body: Data(indexHTML.utf8))
    }
}

// MARK: - HTTP Request/Response

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(data: Data) -> HTTPRequest? {
        // Find header/body separator - binary body may not be valid UTF-8
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Parse request line
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let path = requestLine[1].components(separatedBy: "?")[0] // Strip query string

        // Parse headers
        var headers: [String: String] = [:]
        for (i, line) in lines.enumerated() {
            if i == 0 { continue }
            if line.isEmpty { break }
            let parts = line.components(separatedBy: ": ")
            if parts.count >= 2 {
                headers[parts[0].lowercased()] = parts.dropFirst().joined(separator: ": ")
            }
        }

        // Body is everything after \r\n\r\n (kept as raw Data for binary support)
        let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}

struct HTTPResponse {
    let status: Int
    let statusText: String
    let contentType: String
    let body: Data
    var additionalHeaders: [String: String] = [:]

    func serialize() -> Data {
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n"
        response += "Access-Control-Allow-Headers: Content-Type\r\n"
        response += "Connection: close\r\n"
        for (key, value) in additionalHeaders {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    static func json(_ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        return HTTPResponse(status: 200, statusText: "OK", contentType: "application/json", body: data)
    }

    static func notFound() -> HTTPResponse {
        let body = Data("{\"error\": \"Not found\"}".utf8)
        return HTTPResponse(status: 404, statusText: "Not Found", contentType: "application/json", body: body)
    }

    static func badRequest(_ message: String = "Bad request") -> HTTPResponse {
        let body = Data("{\"error\": \"\(message)\"}".utf8)
        return HTTPResponse(status: 400, statusText: "Bad Request", contentType: "application/json", body: body)
    }

    static func error(_ code: Int, _ message: String) -> HTTPResponse {
        let body = Data("{\"error\": \"\(message)\"}".utf8)
        return HTTPResponse(status: code, statusText: "Error", contentType: "application/json", body: body)
    }

    static func cors() -> HTTPResponse {
        return HTTPResponse(status: 204, statusText: "No Content", contentType: "text/plain", body: Data())
    }
}

// MARK: - Multipart Parser

struct MultipartPart {
    let name: String
    let filename: String?
    let contentType: String?
    let data: Data
}

func parseMultipart(data: Data, boundary: String) -> [MultipartPart]? {
    let boundaryData = Data("--\(boundary)".utf8)
    let endBoundary = Data("--\(boundary)--".utf8)

    var parts: [MultipartPart] = []
    var currentIndex = data.startIndex

    while currentIndex < data.endIndex {
        // Find boundary
        guard let boundaryRange = data.range(of: boundaryData, in: currentIndex..<data.endIndex) else {
            break
        }

        // Skip to after boundary + CRLF
        var partStart = boundaryRange.upperBound
        if partStart < data.endIndex - 1 && data[partStart] == 0x0D && data[partStart + 1] == 0x0A {
            partStart = data.index(partStart, offsetBy: 2)
        }

        // Find next boundary
        let searchEnd = data.endIndex
        guard let nextBoundary = data.range(of: boundaryData, in: partStart..<searchEnd) else {
            break
        }

        let partData = data.subdata(in: partStart..<nextBoundary.lowerBound)

        // Parse headers and body
        if let headerEnd = partData.range(of: Data("\r\n\r\n".utf8)) {
            let headerData = partData.subdata(in: partData.startIndex..<headerEnd.lowerBound)
            var bodyData = partData.subdata(in: headerEnd.upperBound..<partData.endIndex)

            // Remove trailing CRLF
            if bodyData.count >= 2 && bodyData[bodyData.endIndex - 2] == 0x0D && bodyData[bodyData.endIndex - 1] == 0x0A {
                bodyData = bodyData.subdata(in: bodyData.startIndex..<bodyData.index(bodyData.endIndex, offsetBy: -2))
            }

            if let headerStr = String(data: headerData, encoding: .utf8) {
                var name = ""
                var filename: String? = nil
                var contentType: String? = nil

                for line in headerStr.components(separatedBy: "\r\n") {
                    if line.lowercased().hasPrefix("content-disposition:") {
                        if let nameMatch = line.range(of: "name=\"") {
                            let start = nameMatch.upperBound
                            if let end = line.range(of: "\"", range: start..<line.endIndex) {
                                name = String(line[start..<end.lowerBound])
                            }
                        }
                        if let filenameMatch = line.range(of: "filename=\"") {
                            let start = filenameMatch.upperBound
                            if let end = line.range(of: "\"", range: start..<line.endIndex) {
                                filename = String(line[start..<end.lowerBound])
                            }
                        }
                    } else if line.lowercased().hasPrefix("content-type:") {
                        contentType = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    }
                }

                parts.append(MultipartPart(name: name, filename: filename, contentType: contentType, data: bodyData))
            }
        }

        currentIndex = nextBoundary.lowerBound

        // Check for end boundary
        if data.range(of: endBoundary, in: currentIndex..<min(currentIndex + endBoundary.count + 10, data.endIndex)) != nil {
            break
        }
    }

    return parts.isEmpty ? nil : parts
}

// MARK: - Embedded HTML

private let indexHTML = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>GeoDraw - Web Control</title>
    <style>
        /* 80s Retro Sci-Fi Theme - Matching GeoDraw Desktop */
        @import url('https://fonts.googleapis.com/css2?family=Orbitron:wght@400;700&family=Share+Tech+Mono&display=swap');

        :root {
            --bg-deep: rgb(5, 5, 15);
            --bg-panel: rgb(10, 10, 26);
            --bg-card: rgb(15, 15, 36);
            --bg-input: rgb(20, 20, 41);
            --neon-cyan: #00ffff;
            --neon-magenta: #ff00cc;
            --neon-purple: #9900ff;
            --neon-orange: #ff6600;
            --neon-green: #33ff66;
            --neon-red: #ff1a4d;
            --neon-blue: #0099ff;
            --neon-yellow: #ffff00;
            --text-primary: rgb(230, 255, 255);
            --text-secondary: rgb(128, 153, 179);
            --border-default: rgb(38, 51, 77);
            --grid-line: rgba(0, 77, 102, 0.3);
        }

        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Share Tech Mono', monospace;
            background: var(--bg-deep);
            background-image:
                linear-gradient(var(--grid-line) 1px, transparent 1px),
                linear-gradient(90deg, var(--grid-line) 1px, transparent 1px);
            background-size: 40px 40px;
            color: var(--text-primary);
            min-height: 100vh;
        }
        header {
            background: linear-gradient(180deg, var(--bg-panel) 0%, var(--bg-deep) 100%);
            padding: 1rem;
            border-bottom: 2px solid var(--neon-cyan);
            box-shadow: 0 0 20px rgba(0, 255, 255, 0.3);
        }
        header h1 {
            font-family: 'Orbitron', sans-serif;
            font-size: 1.8rem;
            font-weight: 700;
            color: var(--neon-cyan);
            text-shadow: 0 0 10px var(--neon-cyan), 0 0 20px var(--neon-cyan);
            letter-spacing: 3px;
        }
        nav {
            display: flex;
            gap: 0.5rem;
            margin-top: 0.75rem;
        }
        nav button {
            padding: 0.5rem 1rem;
            border: 1px solid var(--border-default);
            background: var(--bg-card);
            color: var(--text-secondary);
            border-radius: 4px;
            cursor: pointer;
            font-family: 'Share Tech Mono', monospace;
            font-size: 0.9rem;
            text-transform: uppercase;
            letter-spacing: 1px;
            transition: all 0.3s;
        }
        nav button:hover {
            border-color: var(--neon-cyan);
            color: var(--neon-cyan);
            box-shadow: 0 0 10px rgba(0, 255, 255, 0.3);
        }
        nav button.active {
            background: rgba(0, 255, 255, 0.15);
            border-color: var(--neon-cyan);
            color: var(--neon-cyan);
            box-shadow: 0 0 15px rgba(0, 255, 255, 0.4);
        }
        main { padding: 1rem; max-width: 1200px; margin: 0 auto; }
        .section { display: none; }
        .section.active { display: block; }
        h2 {
            font-family: 'Orbitron', sans-serif;
            color: var(--neon-magenta);
            text-shadow: 0 0 8px var(--neon-magenta);
            margin-bottom: 1rem;
            letter-spacing: 2px;
            border-bottom: 1px solid var(--neon-magenta);
            padding-bottom: 0.5rem;
        }

        /* Status Panel */
        .status-grid {
            display: flex;
            flex-direction: column;
            gap: 1rem;
            margin-bottom: 1rem;
        }
        .status-info {
            background: var(--bg-panel);
            padding: 0.75rem 1rem;
            border-radius: 8px;
            border: 1px solid var(--border-default);
            display: flex;
            flex-wrap: wrap;
            gap: 1.5rem;
        }
        .status-item {
            display: flex;
            gap: 0.5rem;
            align-items: center;
        }
        .status-value {
            color: var(--neon-green);
            font-weight: bold;
            text-shadow: 0 0 5px var(--neon-green);
        }
        .preview-container {
            background: #000;
            border-radius: 8px;
            overflow: hidden;
            border: 2px solid var(--neon-cyan);
            box-shadow: 0 0 20px rgba(0, 255, 255, 0.3);
            width: 100%;
        }
        .preview-container img {
            width: 100%;
            height: auto;
            display: block;
            transition: opacity 0.1s ease;
        }

        /* Gobo Grid */
        .gobo-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(100px, 1fr));
            gap: 0.75rem;
            margin-top: 1rem;
        }
        .gobo-item {
            background: var(--bg-card);
            border-radius: 8px;
            padding: 0.5rem;
            text-align: center;
            border: 1px solid var(--border-default);
            transition: all 0.3s;
        }
        .gobo-item:hover {
            border-color: var(--neon-purple);
            box-shadow: 0 0 15px rgba(153, 0, 255, 0.4);
        }
        .gobo-item img {
            width: 80px;
            height: 80px;
            object-fit: contain;
            background: #000;
            border-radius: 4px;
        }
        .gobo-item .gobo-id {
            font-size: 0.75rem;
            color: var(--neon-purple);
            margin-top: 0.25rem;
        }
        .gobo-item.empty {
            opacity: 0.3;
        }
        .gobo-item[draggable="true"] {
            cursor: grab;
        }
        .gobo-item[draggable="true"]:active {
            cursor: grabbing;
        }
        .gobo-item.dragging {
            opacity: 0.5;
            border-color: var(--neon-cyan);
            box-shadow: 0 0 20px rgba(0, 255, 255, 0.5);
        }
        .gobo-item.drag-over {
            border-color: var(--neon-green);
            box-shadow: 0 0 20px rgba(0, 255, 0, 0.6);
            transform: scale(1.05);
        }
        .gobo-grid.dragging-active .gobo-item:not(.dragging):hover {
            border-color: var(--neon-orange);
        }

        /* Upload Zone */
        .upload-zone {
            border: 2px dashed var(--neon-magenta);
            border-radius: 8px;
            padding: 1.5rem;
            text-align: center;
            margin-bottom: 1rem;
            background: rgba(255, 0, 204, 0.05);
            transition: all 0.3s;
        }
        .upload-zone:hover {
            border-color: var(--neon-cyan);
            background: rgba(0, 255, 255, 0.05);
            box-shadow: 0 0 20px rgba(0, 255, 255, 0.2);
        }
        .upload-zone.dragover {
            border-color: var(--neon-green);
            background: rgba(51, 255, 102, 0.1);
            box-shadow: 0 0 30px rgba(51, 255, 102, 0.3);
        }
        .upload-zone input { display: none; }
        .upload-zone p { margin-bottom: 0.75rem; color: var(--text-secondary); }
        .upload-zone .btn-browse {
            padding: 0.5rem 1.5rem;
            background: linear-gradient(135deg, var(--neon-magenta), var(--neon-purple));
            color: white;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-family: 'Share Tech Mono', monospace;
            font-size: 0.9rem;
            text-transform: uppercase;
            letter-spacing: 1px;
            box-shadow: 0 0 15px rgba(255, 0, 204, 0.5);
            transition: all 0.3s;
        }
        .upload-zone .btn-browse:hover {
            box-shadow: 0 0 25px rgba(255, 0, 204, 0.7);
            transform: scale(1.02);
        }
        .upload-status {
            margin-top: 0.5rem;
            font-size: 0.85rem;
            color: var(--neon-green);
            text-shadow: 0 0 5px var(--neon-green);
        }
        .upload-status.error {
            color: var(--neon-red);
            text-shadow: 0 0 5px var(--neon-red);
        }

        /* Media Slots Table */
        .slots-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 1rem;
        }
        .slots-table th, .slots-table td {
            padding: 0.75rem;
            text-align: left;
            border-bottom: 1px solid var(--border-default);
        }
        .slots-table th {
            background: var(--bg-panel);
            color: var(--neon-orange);
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        .slots-table tr:hover { background: rgba(0, 255, 255, 0.05); }
        .slot-empty { color: var(--text-secondary); }
        .btn {
            padding: 0.25rem 0.5rem;
            border: 1px solid transparent;
            border-radius: 4px;
            cursor: pointer;
            font-family: 'Share Tech Mono', monospace;
            font-size: 0.8rem;
            text-transform: uppercase;
            transition: all 0.3s;
        }
        .btn-danger {
            background: var(--neon-red);
            color: white;
            box-shadow: 0 0 10px rgba(255, 26, 77, 0.5);
        }
        .btn-danger:hover {
            box-shadow: 0 0 20px rgba(255, 26, 77, 0.8);
        }
        .btn-primary {
            background: var(--bg-card);
            color: var(--neon-cyan);
            border-color: var(--neon-cyan);
        }
        .btn-primary:hover {
            box-shadow: 0 0 15px rgba(0, 255, 255, 0.5);
        }

        /* NDI Sources */
        .source-list {
            display: flex;
            flex-direction: column;
            gap: 0.5rem;
            margin-top: 1rem;
        }
        .source-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            background: var(--bg-card);
            padding: 0.75rem 1rem;
            border: 1px solid var(--neon-blue);
            box-shadow: 0 0 10px rgba(0, 153, 255, 0.2);
            border-radius: 4px;
        }

        /* Toggle Switch */
        .toggle-switch {
            position: relative;
            display: inline-block;
            width: 50px;
            height: 26px;
        }
        .toggle-switch input {
            opacity: 0;
            width: 0;
            height: 0;
        }
        .toggle-slider {
            position: absolute;
            cursor: pointer;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background-color: var(--bg-input);
            border: 1px solid var(--border-default);
            transition: 0.3s;
            border-radius: 26px;
        }
        .toggle-slider:before {
            position: absolute;
            content: "";
            height: 18px;
            width: 18px;
            left: 4px;
            bottom: 3px;
            background-color: var(--text-secondary);
            transition: 0.3s;
            border-radius: 50%;
        }
        .toggle-switch input:checked + .toggle-slider {
            background-color: rgba(0, 255, 255, 0.2);
            border-color: var(--neon-cyan);
        }
        .toggle-switch input:checked + .toggle-slider:before {
            transform: translateX(22px);
            background-color: var(--neon-cyan);
            box-shadow: 0 0 10px var(--neon-cyan);
        }

        /* Outputs List */
        .outputs-list, .displays-list {
            display: flex;
            flex-direction: column;
            gap: 0.5rem;
        }
        .output-item, .display-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            background: var(--bg-card);
            padding: 0.75rem 1rem;
            border: 1px solid var(--border-default);
            border-radius: 4px;
            transition: all 0.3s;
        }
        .output-item:hover, .display-item:hover {
            border-color: var(--neon-cyan);
            box-shadow: 0 0 10px rgba(0, 255, 255, 0.2);
        }
        .output-item.enabled {
            border-color: var(--neon-green);
            box-shadow: 0 0 10px rgba(51, 255, 102, 0.3);
        }
        .output-item.disabled {
            opacity: 0.6;
        }
        .output-info {
            display: flex;
            flex-direction: column;
            gap: 0.25rem;
        }
        .output-name {
            font-weight: bold;
            color: var(--text-primary);
        }
        .output-type {
            font-size: 0.8rem;
            color: var(--text-secondary);
        }
        .output-actions {
            display: flex;
            gap: 0.5rem;
            align-items: center;
        }
        .btn-success {
            background: var(--neon-green);
            color: black;
            box-shadow: 0 0 10px rgba(51, 255, 102, 0.5);
        }
        .btn-warning {
            background: var(--neon-orange);
            color: white;
            box-shadow: 0 0 10px rgba(255, 102, 0, 0.5);
        }

        /* Modal */
        .modal-overlay {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background: rgba(0, 0, 0, 0.8);
            z-index: 1000;
            align-items: center;
            justify-content: center;
        }
        .modal-overlay.active {
            display: flex;
        }
        .modal-content {
            background: var(--bg-panel);
            border: 2px solid var(--neon-cyan);
            border-radius: 8px;
            padding: 1.5rem;
            max-width: 400px;
            width: 90%;
            box-shadow: 0 0 30px rgba(0, 255, 255, 0.3);
        }
        .modal-content h3 {
            color: var(--neon-cyan);
            margin-bottom: 1rem;
        }
        .modal-content input {
            width: 100%;
            padding: 0.75rem;
            background: var(--bg-input);
            border: 1px solid var(--border-default);
            border-radius: 4px;
            color: var(--text-primary);
            font-family: inherit;
            margin-bottom: 1rem;
        }
        .modal-content input:focus {
            outline: none;
            border-color: var(--neon-cyan);
        }
        .modal-buttons {
            display: flex;
            gap: 0.5rem;
            justify-content: flex-end;
        }

        /* Settings Tabs */
        .settings-tab {
            padding: 0.4rem 0.8rem;
            background: var(--bg-card);
            border: 1px solid var(--border-default);
            border-radius: 4px;
            color: var(--text-secondary);
            cursor: pointer;
            font-size: 0.85rem;
        }
        .settings-tab:hover {
            border-color: var(--neon-cyan);
        }
        .settings-tab.active {
            background: var(--neon-cyan);
            color: black;
            border-color: var(--neon-cyan);
        }
        .settings-panel {
            display: none;
        }
        .settings-panel.active {
            display: block;
        }
        .settings-row {
            display: flex;
            align-items: center;
            gap: 1rem;
            margin-bottom: 0.75rem;
        }
        .settings-row label {
            min-width: 100px;
            color: var(--text-secondary);
            font-size: 0.9rem;
        }
        .settings-row input[type="number"] {
            width: 80px;
            padding: 0.4rem;
            background: var(--bg-input);
            border: 1px solid var(--border-default);
            border-radius: 4px;
            color: var(--text-primary);
        }
        .settings-row input[type="range"] {
            flex: 1;
            max-width: 200px;
        }
        .settings-row span {
            min-width: 50px;
            color: var(--neon-cyan);
            font-size: 0.85rem;
        }
        .warp-point {
            display: flex;
            flex-direction: column;
            gap: 0.25rem;
            padding: 0.5rem;
            background: var(--bg-card);
            border-radius: 4px;
        }
        .warp-point label {
            font-size: 0.75rem;
            color: var(--text-secondary);
        }
        .warp-point input {
            padding: 0.3rem;
            background: var(--bg-input);
            border: 1px solid var(--border-default);
            border-radius: 3px;
            color: var(--text-primary);
            font-size: 0.85rem;
        }

        @media (max-width: 768px) {
            .status-grid { grid-template-columns: 1fr; }
            .gobo-grid { grid-template-columns: repeat(auto-fill, minmax(80px, 1fr)); }
        }
    </style>
</head>
<body>
    <header>
        <h1>GeoDraw - Web Control</h1>
        <nav>
            <button class="active" data-section="status">Status</button>
            <button data-section="outputs">Outputs</button>
            <button data-section="gobos">Gobos</button>
            <button data-section="media">Media Slots</button>
            <button data-section="ndi">NDI Sources</button>
        </nav>
    </header>
    <main>
        <!-- Status Section -->
        <div id="status" class="section active">
            <div class="status-grid">
                <div class="status-info">
                    <div class="status-item">
                        <span>Version:</span>
                        <span class="status-value" id="version">-</span>
                    </div>
                    <div class="status-item">
                        <span>Fixtures:</span>
                        <span class="status-value" id="fixtures">-</span>
                    </div>
                    <div class="status-item">
                        <span>Resolution:</span>
                        <span class="status-value" id="resolution">-</span>
                    </div>
                    <div class="status-item">
                        <span>Outputs:</span>
                        <span class="status-value" id="outputCount">-</span>
                    </div>
                </div>
                <div class="preview-container">
                    <img id="preview" src="/api/v1/status/preview" alt="Preview">
                </div>
            </div>
        </div>

        <!-- Outputs Section -->
        <div id="outputs" class="section">
            <h2>Output Settings</h2>

            <!-- Add Output Buttons -->
            <div style="display:flex;gap:1rem;margin-bottom:1rem;flex-wrap:wrap;">
                <button class="btn btn-primary" onclick="showAddDisplayModal()">+ Add Display Output</button>
                <button class="btn btn-primary" onclick="showAddNDIModal()">+ Add NDI Output</button>
            </div>

            <!-- Configured Outputs List -->
            <h3 style="color:var(--neon-cyan);margin-bottom:0.5rem;">Configured Outputs</h3>
            <div id="outputsList" class="outputs-list"></div>

            <!-- Available Displays -->
            <h3 style="color:var(--neon-orange);margin:1.5rem 0 0.5rem;">Available Displays</h3>
            <div id="displaysList" class="displays-list"></div>
        </div>

        <!-- Gobos Section -->
        <div id="gobos" class="section">
            <h2>Gobos (Slots 21-200)</h2>
            <div class="upload-zone" id="goboUpload">
                <p>Upload gobo to specific DMX slot</p>
                <div style="display:flex;gap:1rem;justify-content:center;align-items:center;margin-bottom:0.75rem;flex-wrap:wrap;">
                    <label style="color:var(--neon-cyan);">Slot:</label>
                    <input type="number" id="goboSlotInput" min="21" max="200" value="21"
                           style="width:80px;padding:0.5rem;background:var(--bg-input);border:1px solid var(--neon-cyan);border-radius:4px;color:var(--text-primary);font-family:inherit;text-align:center;">
                    <span id="slotStatus" style="font-size:0.85rem;color:var(--neon-green);"></span>
                    <button class="btn-browse" onclick="document.getElementById('goboFileInput').click()">Browse PNG</button>
                </div>
                <input type="file" id="goboFileInput" accept=".png,image/png">
                <div class="upload-status" id="goboUploadStatus"></div>
            </div>
            <div class="gobo-grid" id="goboGrid"></div>
        </div>

        <!-- Media Slots Section -->
        <div id="media" class="section">
            <h2>Media Slots (201-255)</h2>
            <div style="display: flex; gap: 20px; flex-wrap: wrap;">
                <div class="upload-zone" id="videoUpload" style="flex: 1; min-width: 200px;">
                    <p>Drag & drop <b>video</b> files here</p>
                    <button class="btn-browse" onclick="document.getElementById('videoFileInput').click()">Browse Videos</button>
                    <input type="file" id="videoFileInput" accept=".mp4,.mov,.avi,.mkv,.m4v,video/*" multiple>
                    <div class="upload-status" id="videoUploadStatus"></div>
                </div>
                <div class="upload-zone" id="imageUpload" style="flex: 1; min-width: 200px;">
                    <p>Drag & drop <b>image</b> files here</p>
                    <button class="btn-browse" onclick="document.getElementById('imageFileInput').click()">Browse Images</button>
                    <input type="file" id="imageFileInput" accept=".png,.jpg,.jpeg,.gif,.tiff,.bmp,.webp,image/*" multiple>
                    <div class="upload-status" id="imageUploadStatus"></div>
                </div>
            </div>
            <table class="slots-table">
                <thead>
                    <tr><th>Slot</th><th>Type</th><th>Source</th><th>Actions</th></tr>
                </thead>
                <tbody id="slotsTable"></tbody>
            </table>
        </div>

        <!-- NDI Section -->
        <div id="ndi" class="section">
            <h2>NDI Sources</h2>
            <button class="btn btn-primary" onclick="refreshNDI()">Refresh Sources</button>
            <div class="source-list" id="ndiSources"></div>
        </div>
    </main>

    <!-- Add Display Modal -->
    <div id="displayModal" class="modal-overlay" onclick="if(event.target===this)closeModals()">
        <div class="modal-content">
            <h3>Add Display Output</h3>
            <p style="color:var(--text-secondary);margin-bottom:1rem;">Select a display from the Available Displays list below.</p>
            <div class="modal-buttons">
                <button class="btn btn-primary" onclick="closeModals()">Close</button>
            </div>
        </div>
    </div>

    <!-- Add NDI Output Modal -->
    <div id="ndiModal" class="modal-overlay" onclick="if(event.target===this)closeModals()">
        <div class="modal-content">
            <h3>Add NDI Output</h3>
            <label style="color:var(--text-secondary);font-size:0.9rem;">NDI Source Name:</label>
            <input type="text" id="ndiOutputName" placeholder="GeoDraw NDI" value="GeoDraw NDI">
            <div class="modal-buttons">
                <button class="btn" style="background:var(--bg-card);color:var(--text-secondary);" onclick="closeModals()">Cancel</button>
                <button class="btn btn-success" onclick="addNDIOutput()">Add Output</button>
            </div>
        </div>
    </div>

    <!-- Output Settings Modal -->
    <div id="settingsModal" class="modal-overlay" onclick="if(event.target===this)closeModals()">
        <div class="modal-content" style="max-width:600px;max-height:80vh;overflow-y:auto;">
            <h3 id="settingsTitle">Output Settings</h3>
            <input type="hidden" id="settingsOutputId">

            <!-- Settings Tabs -->
            <div style="display:flex;gap:0.5rem;margin-bottom:1rem;flex-wrap:wrap;">
                <button class="settings-tab active" onclick="showSettingsTab('position')">Position</button>
                <button class="settings-tab" onclick="showSettingsTab('edgeblend')">Edge Blend</button>
                <button class="settings-tab" onclick="showSettingsTab('warp')">Warp</button>
                <button class="settings-tab" onclick="showSettingsTab('lens')">Lens</button>
                <button class="settings-tab" onclick="showSettingsTab('dmx')">DMX</button>
            </div>

            <!-- Position Tab -->
            <div id="tab-position" class="settings-panel active">
                <div class="settings-row">
                    <label>X Position</label>
                    <input type="number" id="set-pos-x" value="0">
                </div>
                <div class="settings-row">
                    <label>Y Position</label>
                    <input type="number" id="set-pos-y" value="0">
                </div>
                <div class="settings-row">
                    <label>Width</label>
                    <input type="number" id="set-pos-w" value="1920">
                </div>
                <div class="settings-row">
                    <label>Height</label>
                    <input type="number" id="set-pos-h" value="1080">
                </div>
                <div class="settings-row">
                    <label>Intensity</label>
                    <input type="range" id="set-intensity" min="0" max="1" step="0.01" value="1">
                    <span id="set-intensity-val">100%</span>
                </div>
            </div>

            <!-- Edge Blend Tab -->
            <div id="tab-edgeblend" class="settings-panel">
                <div class="settings-row">
                    <label>Left Blend</label>
                    <input type="range" id="set-edge-left" min="0" max="500" value="0">
                    <span id="set-edge-left-val">0px</span>
                </div>
                <div class="settings-row">
                    <label>Right Blend</label>
                    <input type="range" id="set-edge-right" min="0" max="500" value="0">
                    <span id="set-edge-right-val">0px</span>
                </div>
                <div class="settings-row">
                    <label>Top Blend</label>
                    <input type="range" id="set-edge-top" min="0" max="500" value="0">
                    <span id="set-edge-top-val">0px</span>
                </div>
                <div class="settings-row">
                    <label>Bottom Blend</label>
                    <input type="range" id="set-edge-bottom" min="0" max="500" value="0">
                    <span id="set-edge-bottom-val">0px</span>
                </div>
                <div class="settings-row">
                    <label>Gamma</label>
                    <input type="range" id="set-edge-gamma" min="1" max="4" step="0.1" value="2.2">
                    <span id="set-edge-gamma-val">2.2</span>
                </div>
            </div>

            <!-- Warp Tab -->
            <div id="tab-warp" class="settings-panel">
                <p style="color:var(--text-secondary);font-size:0.85rem;margin-bottom:1rem;">Adjust corner and edge points (pixels offset)</p>
                <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:0.5rem;">
                    <div class="warp-point">
                        <label>Top Left</label>
                        <input type="number" id="set-warp-tl-x" placeholder="X" style="width:60px;">
                        <input type="number" id="set-warp-tl-y" placeholder="Y" style="width:60px;">
                    </div>
                    <div class="warp-point">
                        <label>Top Mid</label>
                        <input type="number" id="set-warp-tm-x" placeholder="X" style="width:60px;">
                        <input type="number" id="set-warp-tm-y" placeholder="Y" style="width:60px;">
                    </div>
                    <div class="warp-point">
                        <label>Top Right</label>
                        <input type="number" id="set-warp-tr-x" placeholder="X" style="width:60px;">
                        <input type="number" id="set-warp-tr-y" placeholder="Y" style="width:60px;">
                    </div>
                    <div class="warp-point">
                        <label>Mid Left</label>
                        <input type="number" id="set-warp-ml-x" placeholder="X" style="width:60px;">
                        <input type="number" id="set-warp-ml-y" placeholder="Y" style="width:60px;">
                    </div>
                    <div class="warp-point" style="visibility:hidden;"></div>
                    <div class="warp-point">
                        <label>Mid Right</label>
                        <input type="number" id="set-warp-mr-x" placeholder="X" style="width:60px;">
                        <input type="number" id="set-warp-mr-y" placeholder="Y" style="width:60px;">
                    </div>
                    <div class="warp-point">
                        <label>Bot Left</label>
                        <input type="number" id="set-warp-bl-x" placeholder="X" style="width:60px;">
                        <input type="number" id="set-warp-bl-y" placeholder="Y" style="width:60px;">
                    </div>
                    <div class="warp-point">
                        <label>Bot Mid</label>
                        <input type="number" id="set-warp-bm-x" placeholder="X" style="width:60px;">
                        <input type="number" id="set-warp-bm-y" placeholder="Y" style="width:60px;">
                    </div>
                    <div class="warp-point">
                        <label>Bot Right</label>
                        <input type="number" id="set-warp-br-x" placeholder="X" style="width:60px;">
                        <input type="number" id="set-warp-br-y" placeholder="Y" style="width:60px;">
                    </div>
                </div>
                <div class="settings-row" style="margin-top:1rem;">
                    <label>Curvature</label>
                    <input type="range" id="set-warp-curve" min="-1" max="1" step="0.01" value="0">
                    <span id="set-warp-curve-val">0</span>
                </div>
            </div>

            <!-- Lens Tab -->
            <div id="tab-lens" class="settings-panel">
                <div class="settings-row">
                    <label>K1 (Primary)</label>
                    <input type="range" id="set-lens-k1" min="-0.5" max="0.5" step="0.01" value="0">
                    <span id="set-lens-k1-val">0</span>
                </div>
                <div class="settings-row">
                    <label>K2 (Secondary)</label>
                    <input type="range" id="set-lens-k2" min="-0.5" max="0.5" step="0.01" value="0">
                    <span id="set-lens-k2-val">0</span>
                </div>
                <div class="settings-row">
                    <label>Center X</label>
                    <input type="range" id="set-lens-cx" min="0" max="1" step="0.01" value="0.5">
                    <span id="set-lens-cx-val">0.5</span>
                </div>
                <div class="settings-row">
                    <label>Center Y</label>
                    <input type="range" id="set-lens-cy" min="0" max="1" step="0.01" value="0.5">
                    <span id="set-lens-cy-val">0.5</span>
                </div>
            </div>

            <!-- DMX Tab -->
            <div id="tab-dmx" class="settings-panel">
                <p style="color:var(--text-secondary);font-size:0.85rem;margin-bottom:1rem;">Control output via DMX (27 channels)</p>
                <div class="settings-row">
                    <label>Universe</label>
                    <input type="number" id="set-dmx-universe" min="0" max="64" value="0">
                    <span style="color:var(--text-secondary);font-size:0.8rem;">0 = disabled</span>
                </div>
                <div class="settings-row">
                    <label>Address</label>
                    <input type="number" id="set-dmx-address" min="1" max="512" value="1">
                </div>
            </div>

            <div class="modal-buttons" style="margin-top:1.5rem;">
                <button class="btn" style="background:var(--bg-card);color:var(--text-secondary);" onclick="closeModals()">Cancel</button>
                <button class="btn" style="background:var(--neon-orange);" onclick="resetOutputSettings()">Reset</button>
                <button class="btn btn-success" onclick="saveOutputSettings()">Save</button>
            </div>
        </div>
    </div>

    <script>
        // Navigation
        document.querySelectorAll('nav button').forEach(btn => {
            btn.addEventListener('click', () => {
                document.querySelectorAll('nav button').forEach(b => b.classList.remove('active'));
                document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
                btn.classList.add('active');
                document.getElementById(btn.dataset.section).classList.add('active');
            });
        });

        // Status
        async function updateStatus() {
            try {
                const res = await fetch('/api/v1/status');
                const data = await res.json();
                document.getElementById('version').textContent = data.version;
                document.getElementById('fixtures').textContent = `${data.activeFixtures}/${data.fixtureCount} active`;
                document.getElementById('resolution').textContent = `${data.resolution.width}x${data.resolution.height}`;
                document.getElementById('outputCount').textContent = data.outputCount || 0;
            } catch (e) { console.error('Status error:', e); }
        }

        function updatePreview() {
            document.getElementById('preview').src = '/api/v1/status/preview?' + Date.now();
        }

        // Gobos
        async function loadGobos() {
            try {
                const res = await fetch('/api/v1/gobos');
                const data = await res.json();
                const grid = document.getElementById('goboGrid');

                // Track occupied slots
                occupiedGoboSlots = {};
                data.gobos.forEach(g => {
                    if (g.hasImage) occupiedGoboSlots[g.id] = g.name;
                });

                // Set input to first empty slot
                const emptySlot = findEmptySlot();
                document.getElementById('goboSlotInput').value = emptySlot;
                updateSlotStatus();

                // Only show gobos that have images (occupied slots)
                const occupiedGobos = data.gobos.filter(g => g.hasImage);
                grid.innerHTML = occupiedGobos.map(g => `
                    <div class="gobo-item" data-gobo-id="${g.id}" draggable="true" style="position:relative;">
                        <img src="${g.imageUrl}" alt="Gobo ${g.id}" onclick="selectGoboSlot(${g.id})" style="cursor:pointer;" draggable="false">
                        <div class="gobo-id">${g.id}: ${g.name}</div>
                        <button onclick="event.stopPropagation();deleteGobo(${g.id})" style="position:absolute;top:4px;right:4px;background:var(--neon-red);border:none;color:white;width:20px;height:20px;border-radius:50%;cursor:pointer;font-size:12px;line-height:1;" title="Delete">×</button>
                    </div>
                `).join('') || '<p style="color:var(--text-secondary);padding:1rem;">No gobos loaded</p>';

                // Setup drag-and-drop for gobo reordering
                setupGoboDragAndDrop();
            } catch (e) { console.error('Gobos error:', e); }
        }

        // Gobo drag-and-drop reordering
        let draggedGoboId = null;

        function setupGoboDragAndDrop() {
            const grid = document.getElementById('goboGrid');
            const items = grid.querySelectorAll('.gobo-item[draggable="true"]');

            items.forEach(item => {
                item.addEventListener('dragstart', handleGoboDragStart);
                item.addEventListener('dragend', handleGoboDragEnd);
                item.addEventListener('dragover', handleGoboDragOver);
                item.addEventListener('dragleave', handleGoboDragLeave);
                item.addEventListener('drop', handleGoboDrop);
            });
        }

        function handleGoboDragStart(e) {
            draggedGoboId = parseInt(this.dataset.goboId);
            this.classList.add('dragging');
            document.getElementById('goboGrid').classList.add('dragging-active');
            e.dataTransfer.effectAllowed = 'move';
            e.dataTransfer.setData('text/plain', draggedGoboId);
        }

        function handleGoboDragEnd(e) {
            this.classList.remove('dragging');
            document.getElementById('goboGrid').classList.remove('dragging-active');
            document.querySelectorAll('.gobo-item.drag-over').forEach(el => el.classList.remove('drag-over'));
            draggedGoboId = null;
        }

        function handleGoboDragOver(e) {
            e.preventDefault();
            e.dataTransfer.dropEffect = 'move';
            const targetId = parseInt(this.dataset.goboId);
            if (targetId !== draggedGoboId) {
                this.classList.add('drag-over');
            }
        }

        function handleGoboDragLeave(e) {
            this.classList.remove('drag-over');
        }

        async function handleGoboDrop(e) {
            e.preventDefault();
            this.classList.remove('drag-over');
            const targetId = parseInt(this.dataset.goboId);

            if (draggedGoboId && targetId !== draggedGoboId) {
                try {
                    const response = await fetch(`/api/v1/gobos/${draggedGoboId}/move/${targetId}`, {
                        method: 'PUT'
                    });
                    if (response.ok) {
                        loadGobos(); // Refresh grid
                    } else {
                        const err = await response.text();
                        console.error('Move failed:', err);
                        alert('Failed to move gobo: ' + err);
                    }
                } catch (e) {
                    console.error('Move error:', e);
                }
            }
        }

        // Upload handling
        function setupUpload(zoneId, inputId, statusId, endpoint, onSuccess) {
            const zone = document.getElementById(zoneId);
            const input = document.getElementById(inputId);
            const status = document.getElementById(statusId);

            // Drag and drop
            zone.addEventListener('dragover', e => {
                e.preventDefault();
                e.stopPropagation();
                zone.classList.add('dragover');
            });
            zone.addEventListener('dragleave', e => {
                e.preventDefault();
                zone.classList.remove('dragover');
            });
            zone.addEventListener('drop', e => {
                e.preventDefault();
                e.stopPropagation();
                zone.classList.remove('dragover');
                if (e.dataTransfer.files.length > 0) {
                    uploadFiles(e.dataTransfer.files, endpoint, status, onSuccess);
                }
            });

            // File input change
            input.addEventListener('change', () => {
                if (input.files.length > 0) {
                    uploadFiles(input.files, endpoint, status, onSuccess);
                    input.value = ''; // Reset for next upload
                }
            });
        }

        async function uploadFiles(files, endpoint, statusEl, onSuccess) {
            statusEl.textContent = `Uploading ${files.length} file(s)...`;
            statusEl.className = 'upload-status';

            let successCount = 0;
            let errorCount = 0;
            let lastError = '';

            for (const file of files) {
                statusEl.textContent = `Uploading ${file.name} (${(file.size/1024/1024).toFixed(1)}MB)...`;
                const formData = new FormData();
                formData.append('file', file);
                try {
                    const response = await fetch(endpoint, { method: 'POST', body: formData });
                    const text = await response.text();
                    console.log('Upload response:', response.status, text);
                    if (response.ok) {
                        successCount++;
                    } else {
                        errorCount++;
                        lastError = text;
                        console.error('Upload failed:', response.status, text);
                    }
                } catch (e) {
                    errorCount++;
                    lastError = e.message;
                    console.error('Upload error:', e);
                }
            }

            if (errorCount > 0) {
                statusEl.textContent = `Failed: ${lastError || 'Unknown error'}`;
                statusEl.className = 'upload-status error';
            } else {
                statusEl.textContent = `Uploaded ${successCount} file(s) successfully`;
                statusEl.className = 'upload-status';
            }

            onSuccess();

            // Clear status after 3 seconds
            setTimeout(() => { statusEl.textContent = ''; }, 3000);
        }

        // Media Slots
        let availableVideos = [];
        let availableNDI = [];
        let availableImages = [];

        async function loadVideos() {
            try {
                const res = await fetch('/api/v1/media/videos');
                const data = await res.json();
                availableVideos = data.videos || [];
            } catch (e) { console.error('Videos error:', e); }
        }

        async function loadNDISources() {
            try {
                const res = await fetch('/api/v1/ndi/sources');
                const data = await res.json();
                availableNDI = data.sources || [];
            } catch (e) { console.error('NDI error:', e); }
        }

        async function loadImages() {
            try {
                const res = await fetch('/api/v1/media/images');
                const data = await res.json();
                availableImages = data.images || [];
            } catch (e) { console.error('Images error:', e); }
        }

        async function loadSlots() {
            await Promise.all([loadVideos(), loadNDISources(), loadImages()]);
            try {
                const res = await fetch('/api/v1/media/slots');
                const data = await res.json();
                const table = document.getElementById('slotsTable');
                table.innerHTML = data.slots.map(s => `
                    <tr>
                        <td>${s.slot}</td>
                        <td>${s.type}</td>
                        <td class="${s.type === 'none' ? 'slot-empty' : ''}">${s.displayName}</td>
                        <td>
                            ${s.type !== 'none'
                                ? `<button class="btn btn-danger" onclick="clearSlot(${s.slot})">Clear</button>`
                                : `<select onchange="assignSource(${s.slot}, this.value)" style="padding:4px;border-radius:4px;background:#0f3460;color:#eee;border:none;max-width:200px;">
                                    <option value="">Assign Source...</option>
                                    <optgroup label="Videos">
                                        ${availableVideos.map(v => `<option value="video:${v.path}">${v.filename}</option>`).join('')}
                                    </optgroup>
                                    <optgroup label="Images">
                                        ${availableImages.map(i => `<option value="image:${i.path}">${i.filename}</option>`).join('')}
                                    </optgroup>
                                    <optgroup label="NDI Sources">
                                        ${availableNDI.map(n => `<option value="ndi:${n.name}">${n.name}</option>`).join('')}
                                    </optgroup>
                                   </select>`
                            }
                        </td>
                    </tr>
                `).join('');
            } catch (e) { console.error('Slots error:', e); }
        }

        async function assignSource(slot, value) {
            if (!value) return;
            const [type, source] = value.split(':');
            const fullSource = value.substring(value.indexOf(':') + 1);
            try {
                await fetch(`/api/v1/media/slots/${slot}`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ type: type, source: fullSource })
                });
                loadSlots();
            } catch (e) { console.error('Assign error:', e); }
        }

        async function clearSlot(slot) {
            await fetch(`/api/v1/media/slots/${slot}`, { method: 'DELETE' });
            loadSlots();
        }

        // NDI
        async function loadNDI() {
            try {
                const res = await fetch('/api/v1/ndi/sources');
                const data = await res.json();
                const list = document.getElementById('ndiSources');
                if (data.sources.length === 0) {
                    list.innerHTML = '<p style="color:#666;padding:1rem">No NDI sources found</p>';
                } else {
                    list.innerHTML = data.sources.map(s => `
                        <div class="source-item">
                            <span>${s.name}</span>
                        </div>
                    `).join('');
                }
            } catch (e) { console.error('NDI error:', e); }
        }

        async function refreshNDI() {
            await fetch('/api/v1/ndi/refresh', { method: 'POST' });
            setTimeout(loadNDI, 1000);
        }

        // Outputs
        let outputsData = [];

        async function loadOutputs() {
            try {
                const res = await fetch('/api/v1/outputs');
                const data = await res.json();
                outputsData = data.outputs;

                // Render configured outputs
                const list = document.getElementById('outputsList');
                if (data.outputs.length === 0) {
                    list.innerHTML = '<p style="color:var(--text-secondary);padding:0.5rem;">No outputs configured</p>';
                } else {
                    list.innerHTML = data.outputs.map(o => `
                        <div class="output-item ${o.enabled ? 'enabled' : 'disabled'}">
                            <div class="output-info">
                                <span class="output-name">${o.name}</span>
                                <span class="output-type">${o.type.toUpperCase()} - ${o.resolution}</span>
                            </div>
                            <div class="output-actions">
                                <button class="btn" style="background:var(--neon-purple);padding:0.3rem 0.6rem;font-size:0.8rem;" onclick="openOutputSettings('${o.id}')" title="Settings">Settings</button>
                                <label class="toggle-switch">
                                    <input type="checkbox" ${o.enabled ? 'checked' : ''} onchange="toggleOutput('${o.id}', this.checked)">
                                    <span class="toggle-slider"></span>
                                </label>
                                <button class="btn btn-danger" onclick="removeOutput('${o.id}')" title="Remove">×</button>
                            </div>
                        </div>
                    `).join('');
                }
            } catch (e) { console.error('Outputs error:', e); }
        }

        async function loadDisplays() {
            try {
                const res = await fetch('/api/v1/displays');
                const data = await res.json();

                const list = document.getElementById('displaysList');
                if (data.displays.length === 0) {
                    list.innerHTML = '<p style="color:var(--text-secondary);padding:0.5rem;">No displays detected</p>';
                } else {
                    list.innerHTML = data.displays.map(d => `
                        <div class="display-item">
                            <div class="output-info">
                                <span class="output-name">${d.name}${d.isMain ? ' (Main)' : ''}</span>
                                <span class="output-type">${d.width}x${d.height} @ ${d.refreshRate}Hz</span>
                            </div>
                            <div class="output-actions">
                                ${d.hasOutput
                                    ? '<span style="color:var(--neon-green);">Output Added</span>'
                                    : `<button class="btn btn-primary" onclick="addDisplayOutput(${d.displayId}, '${d.name}')">Add Output</button>`
                                }
                            </div>
                        </div>
                    `).join('');
                }
            } catch (e) { console.error('Displays error:', e); }
        }

        async function toggleOutput(id, enabled) {
            try {
                await fetch(`/api/v1/outputs/${id}/${enabled ? 'enable' : 'disable'}`, { method: 'PUT' });
                loadOutputs();
            } catch (e) { console.error('Output toggle error:', e); }
        }

        async function addDisplayOutput(displayId, name) {
            try {
                const res = await fetch('/api/v1/outputs/display', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ displayId: displayId })
                });
                if (res.ok) {
                    loadOutputs();
                    loadDisplays();
                } else {
                    const data = await res.json();
                    alert(data.error || 'Failed to add display output');
                }
            } catch (e) { console.error('Add display error:', e); }
        }

        async function addNDIOutput() {
            const name = document.getElementById('ndiOutputName').value || 'GeoDraw NDI';
            try {
                const res = await fetch('/api/v1/outputs/ndi', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ name: name })
                });
                if (res.ok) {
                    closeModals();
                    loadOutputs();
                } else {
                    const data = await res.json();
                    alert(data.error || 'Failed to add NDI output');
                }
            } catch (e) { console.error('Add NDI error:', e); }
        }

        async function removeOutput(id) {
            if (!confirm('Remove this output?')) return;
            try {
                await fetch(`/api/v1/outputs/${id}`, { method: 'DELETE' });
                loadOutputs();
                loadDisplays();
            } catch (e) { console.error('Remove output error:', e); }
        }

        function showAddDisplayModal() {
            document.getElementById('displayModal').classList.add('active');
        }

        function showAddNDIModal() {
            document.getElementById('ndiModal').classList.add('active');
            document.getElementById('ndiOutputName').value = 'GeoDraw NDI';
        }

        function closeModals() {
            document.querySelectorAll('.modal-overlay').forEach(m => m.classList.remove('active'));
        }

        // Output Settings
        function showSettingsTab(tab) {
            document.querySelectorAll('.settings-tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.settings-panel').forEach(p => p.classList.remove('active'));
            event.target.classList.add('active');
            document.getElementById('tab-' + tab).classList.add('active');
        }

        function openOutputSettings(id) {
            const output = outputsData.find(o => o.id === id);
            if (!output) return;

            document.getElementById('settingsOutputId').value = id;
            document.getElementById('settingsTitle').textContent = output.name + ' Settings';

            // Position
            document.getElementById('set-pos-x').value = output.position?.x || 0;
            document.getElementById('set-pos-y').value = output.position?.y || 0;
            document.getElementById('set-pos-w').value = output.position?.w || 1920;
            document.getElementById('set-pos-h').value = output.position?.h || 1080;
            const intensity = output.intensity || 1;
            document.getElementById('set-intensity').value = intensity;
            document.getElementById('set-intensity-val').textContent = Math.round(intensity * 100) + '%';

            // Edge Blend
            const edge = output.edgeBlend || {};
            document.getElementById('set-edge-left').value = edge.left || 0;
            document.getElementById('set-edge-left-val').textContent = Math.round(edge.left || 0) + 'px';
            document.getElementById('set-edge-right').value = edge.right || 0;
            document.getElementById('set-edge-right-val').textContent = Math.round(edge.right || 0) + 'px';
            document.getElementById('set-edge-top').value = edge.top || 0;
            document.getElementById('set-edge-top-val').textContent = Math.round(edge.top || 0) + 'px';
            document.getElementById('set-edge-bottom').value = edge.bottom || 0;
            document.getElementById('set-edge-bottom-val').textContent = Math.round(edge.bottom || 0) + 'px';
            document.getElementById('set-edge-gamma').value = edge.gamma || 2.2;
            document.getElementById('set-edge-gamma-val').textContent = (edge.gamma || 2.2).toFixed(1);

            // Warp
            const warp = output.warp || {};
            document.getElementById('set-warp-tl-x').value = warp.topLeft?.x || 0;
            document.getElementById('set-warp-tl-y').value = warp.topLeft?.y || 0;
            document.getElementById('set-warp-tm-x').value = warp.topMiddle?.x || 0;
            document.getElementById('set-warp-tm-y').value = warp.topMiddle?.y || 0;
            document.getElementById('set-warp-tr-x').value = warp.topRight?.x || 0;
            document.getElementById('set-warp-tr-y').value = warp.topRight?.y || 0;
            document.getElementById('set-warp-ml-x').value = warp.middleLeft?.x || 0;
            document.getElementById('set-warp-ml-y').value = warp.middleLeft?.y || 0;
            document.getElementById('set-warp-mr-x').value = warp.middleRight?.x || 0;
            document.getElementById('set-warp-mr-y').value = warp.middleRight?.y || 0;
            document.getElementById('set-warp-bl-x').value = warp.bottomLeft?.x || 0;
            document.getElementById('set-warp-bl-y').value = warp.bottomLeft?.y || 0;
            document.getElementById('set-warp-bm-x').value = warp.bottomMiddle?.x || 0;
            document.getElementById('set-warp-bm-y').value = warp.bottomMiddle?.y || 0;
            document.getElementById('set-warp-br-x').value = warp.bottomRight?.x || 0;
            document.getElementById('set-warp-br-y').value = warp.bottomRight?.y || 0;
            document.getElementById('set-warp-curve').value = warp.curvature || 0;
            document.getElementById('set-warp-curve-val').textContent = (warp.curvature || 0).toFixed(2);

            // Lens
            const lens = output.lens || {};
            document.getElementById('set-lens-k1').value = lens.k1 || 0;
            document.getElementById('set-lens-k1-val').textContent = (lens.k1 || 0).toFixed(2);
            document.getElementById('set-lens-k2').value = lens.k2 || 0;
            document.getElementById('set-lens-k2-val').textContent = (lens.k2 || 0).toFixed(2);
            document.getElementById('set-lens-cx').value = lens.centerX || 0.5;
            document.getElementById('set-lens-cx-val').textContent = (lens.centerX || 0.5).toFixed(2);
            document.getElementById('set-lens-cy').value = lens.centerY || 0.5;
            document.getElementById('set-lens-cy-val').textContent = (lens.centerY || 0.5).toFixed(2);

            // DMX
            const dmx = output.dmx || {};
            document.getElementById('set-dmx-universe').value = dmx.universe || 0;
            document.getElementById('set-dmx-address').value = dmx.address || 1;

            // Reset to first tab
            document.querySelectorAll('.settings-tab').forEach((t, i) => t.classList.toggle('active', i === 0));
            document.querySelectorAll('.settings-panel').forEach((p, i) => p.classList.toggle('active', i === 0));

            document.getElementById('settingsModal').classList.add('active');
        }

        async function saveOutputSettings() {
            const id = document.getElementById('settingsOutputId').value;
            const settings = {
                position: {
                    x: parseInt(document.getElementById('set-pos-x').value) || 0,
                    y: parseInt(document.getElementById('set-pos-y').value) || 0,
                    w: parseInt(document.getElementById('set-pos-w').value) || 1920,
                    h: parseInt(document.getElementById('set-pos-h').value) || 1080
                },
                intensity: parseFloat(document.getElementById('set-intensity').value) || 1,
                edgeBlend: {
                    left: parseFloat(document.getElementById('set-edge-left').value) || 0,
                    right: parseFloat(document.getElementById('set-edge-right').value) || 0,
                    top: parseFloat(document.getElementById('set-edge-top').value) || 0,
                    bottom: parseFloat(document.getElementById('set-edge-bottom').value) || 0,
                    gamma: parseFloat(document.getElementById('set-edge-gamma').value) || 2.2
                },
                warp: {
                    topLeft: { x: parseFloat(document.getElementById('set-warp-tl-x').value) || 0, y: parseFloat(document.getElementById('set-warp-tl-y').value) || 0 },
                    topMiddle: { x: parseFloat(document.getElementById('set-warp-tm-x').value) || 0, y: parseFloat(document.getElementById('set-warp-tm-y').value) || 0 },
                    topRight: { x: parseFloat(document.getElementById('set-warp-tr-x').value) || 0, y: parseFloat(document.getElementById('set-warp-tr-y').value) || 0 },
                    middleLeft: { x: parseFloat(document.getElementById('set-warp-ml-x').value) || 0, y: parseFloat(document.getElementById('set-warp-ml-y').value) || 0 },
                    middleRight: { x: parseFloat(document.getElementById('set-warp-mr-x').value) || 0, y: parseFloat(document.getElementById('set-warp-mr-y').value) || 0 },
                    bottomLeft: { x: parseFloat(document.getElementById('set-warp-bl-x').value) || 0, y: parseFloat(document.getElementById('set-warp-bl-y').value) || 0 },
                    bottomMiddle: { x: parseFloat(document.getElementById('set-warp-bm-x').value) || 0, y: parseFloat(document.getElementById('set-warp-bm-y').value) || 0 },
                    bottomRight: { x: parseFloat(document.getElementById('set-warp-br-x').value) || 0, y: parseFloat(document.getElementById('set-warp-br-y').value) || 0 },
                    curvature: parseFloat(document.getElementById('set-warp-curve').value) || 0
                },
                lens: {
                    k1: parseFloat(document.getElementById('set-lens-k1').value) || 0,
                    k2: parseFloat(document.getElementById('set-lens-k2').value) || 0,
                    centerX: parseFloat(document.getElementById('set-lens-cx').value) || 0.5,
                    centerY: parseFloat(document.getElementById('set-lens-cy').value) || 0.5
                },
                dmx: {
                    universe: parseInt(document.getElementById('set-dmx-universe').value) || 0,
                    address: parseInt(document.getElementById('set-dmx-address').value) || 1
                }
            };

            try {
                const res = await fetch(`/api/v1/outputs/${id}/settings`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(settings)
                });
                if (res.ok) {
                    closeModals();
                    loadOutputs();
                } else {
                    const err = await res.json();
                    alert(err.error || 'Failed to save settings');
                }
            } catch (e) {
                console.error('Save settings error:', e);
                alert('Failed to save settings');
            }
        }

        function resetOutputSettings() {
            if (!confirm('Reset all settings for this output to defaults?')) return;
            // Reset position
            document.getElementById('set-pos-x').value = 0;
            document.getElementById('set-pos-y').value = 0;
            document.getElementById('set-pos-w').value = 1920;
            document.getElementById('set-pos-h').value = 1080;
            document.getElementById('set-intensity').value = 1;
            document.getElementById('set-intensity-val').textContent = '100%';
            // Reset edge blend
            ['left', 'right', 'top', 'bottom'].forEach(s => {
                document.getElementById('set-edge-' + s).value = 0;
                document.getElementById('set-edge-' + s + '-val').textContent = '0px';
            });
            document.getElementById('set-edge-gamma').value = 2.2;
            document.getElementById('set-edge-gamma-val').textContent = '2.2';
            // Reset warp
            ['tl', 'tm', 'tr', 'ml', 'mr', 'bl', 'bm', 'br'].forEach(p => {
                document.getElementById('set-warp-' + p + '-x').value = 0;
                document.getElementById('set-warp-' + p + '-y').value = 0;
            });
            document.getElementById('set-warp-curve').value = 0;
            document.getElementById('set-warp-curve-val').textContent = '0';
            // Reset lens
            document.getElementById('set-lens-k1').value = 0;
            document.getElementById('set-lens-k1-val').textContent = '0';
            document.getElementById('set-lens-k2').value = 0;
            document.getElementById('set-lens-k2-val').textContent = '0';
            document.getElementById('set-lens-cx').value = 0.5;
            document.getElementById('set-lens-cx-val').textContent = '0.5';
            document.getElementById('set-lens-cy').value = 0.5;
            document.getElementById('set-lens-cy-val').textContent = '0.5';
            // Reset DMX
            document.getElementById('set-dmx-universe').value = 0;
            document.getElementById('set-dmx-address').value = 1;
        }

        // Range input live updates
        document.getElementById('set-intensity').addEventListener('input', e => {
            document.getElementById('set-intensity-val').textContent = Math.round(e.target.value * 100) + '%';
        });
        ['left', 'right', 'top', 'bottom'].forEach(s => {
            document.getElementById('set-edge-' + s).addEventListener('input', e => {
                document.getElementById('set-edge-' + s + '-val').textContent = Math.round(e.target.value) + 'px';
            });
        });
        document.getElementById('set-edge-gamma').addEventListener('input', e => {
            document.getElementById('set-edge-gamma-val').textContent = parseFloat(e.target.value).toFixed(1);
        });
        document.getElementById('set-warp-curve').addEventListener('input', e => {
            document.getElementById('set-warp-curve-val').textContent = parseFloat(e.target.value).toFixed(2);
        });
        ['k1', 'k2', 'cx', 'cy'].forEach(s => {
            document.getElementById('set-lens-' + s).addEventListener('input', e => {
                document.getElementById('set-lens-' + s + '-val').textContent = parseFloat(e.target.value).toFixed(2);
            });
        });

        // Init
        updateStatus();
        loadOutputs();
        loadDisplays();
        loadGobos();
        loadSlots();
        loadNDI();

        // Track occupied gobo slots
        let occupiedGoboSlots = {};

        function updateSlotStatus() {
            const slot = parseInt(document.getElementById('goboSlotInput').value);
            const statusEl = document.getElementById('slotStatus');
            if (occupiedGoboSlots[slot]) {
                statusEl.textContent = '⚠ OCCUPIED';
                statusEl.style.color = 'var(--neon-orange)';
            } else {
                statusEl.textContent = '✓ Empty';
                statusEl.style.color = 'var(--neon-green)';
            }
        }

        // Update slot status when input changes
        document.getElementById('goboSlotInput').addEventListener('input', updateSlotStatus);

        // Find first empty slot
        function findEmptySlot() {
            for (let i = 21; i <= 200; i++) {
                if (!occupiedGoboSlots[i]) return i;
            }
            return 21;
        }

        // Select a gobo slot (click on gobo image to set input to that slot)
        function selectGoboSlot(id) {
            document.getElementById('goboSlotInput').value = id;
            updateSlotStatus();
        }

        // Delete a gobo
        async function deleteGobo(id) {
            const name = occupiedGoboSlots[id] || `Gobo ${id}`;
            if (!confirm(`Delete gobo ${id} (${name})?`)) return;
            try {
                const res = await fetch(`/api/v1/gobos/${id}`, { method: 'DELETE' });
                if (res.ok) {
                    loadGobos();
                } else {
                    const data = await res.json();
                    alert(data.error || 'Delete failed');
                }
            } catch (e) {
                alert('Delete error: ' + e.message);
            }
        }

        // Gobo upload with slot selection and overwrite protection
        document.getElementById('goboFileInput').addEventListener('change', async (e) => {
            const file = e.target.files[0];
            if (!file) return;
            const slot = parseInt(document.getElementById('goboSlotInput').value);
            if (slot < 21 || slot > 200) {
                document.getElementById('goboUploadStatus').textContent = 'Slot must be 21-200';
                document.getElementById('goboUploadStatus').className = 'upload-status error';
                return;
            }
            // Warn if slot is occupied
            if (occupiedGoboSlots[slot]) {
                if (!confirm(`Slot ${slot} already has a gobo (${occupiedGoboSlots[slot]}). Replace it?`)) {
                    e.target.value = '';
                    return;
                }
            }
            const status = document.getElementById('goboUploadStatus');
            status.textContent = `Uploading to slot ${slot}...`;
            status.className = 'upload-status';
            const formData = new FormData();
            formData.append('file', file);
            formData.append('slot', slot);
            try {
                const res = await fetch('/api/v1/gobos/upload', { method: 'POST', body: formData });
                const data = await res.json();
                if (res.ok) {
                    status.textContent = `Uploaded to slot ${data.slot}`;
                    loadGobos();
                } else {
                    status.textContent = data.error || 'Upload failed';
                    status.className = 'upload-status error';
                }
            } catch (err) {
                status.textContent = err.message;
                status.className = 'upload-status error';
            }
            e.target.value = '';
            setTimeout(() => { status.textContent = ''; }, 3000);
        });
        setupUpload('videoUpload', 'videoFileInput', 'videoUploadStatus', '/api/v1/media/videos/upload', loadSlots);
        setupUpload('imageUpload', 'imageFileInput', 'imageUploadStatus', '/api/v1/media/images/upload', loadSlots);

        // Auto-refresh
        setInterval(updateStatus, 5000);
        setInterval(updatePreview, 100);  // Smoother 10fps preview
    </script>
</body>
</html>
"""
