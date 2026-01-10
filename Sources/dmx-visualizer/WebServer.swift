import Foundation
import Network
import AppKit

// MARK: - Web Server

/// Built-in HTTP server for remote media management
/// Accessible at http://<host>:8080
final class WebServer: @unchecked Sendable {
    @MainActor static let shared = WebServer()

    private var listener: NWListener?
    private let port: UInt16 = 8080
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
        connection.start(queue: queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.processRequest(data: data, connection: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func processRequest(data: Data, connection: NWConnection) {
        guard let request = HTTPRequest.parse(data: data) else {
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

        // NDI endpoints
        if path == "/ndi/sources" && method == "GET" {
            return handleGetNDISources()
        }
        if path == "/ndi/refresh" && method == "POST" {
            return handleRefreshNDI()
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
            "outputs": [
                "syphon": sharedMetalRenderView?.syphonEnabled ?? false
            ]
        ]

        return HTTPResponse.json(status)
    }

    @MainActor
    private func handleGetPreview() -> HTTPResponse {
        guard let renderView = sharedMetalRenderView,
              let image = renderView.captureCurrentFrame() else {
            return HTTPResponse.notFound()
        }

        // Resize to thumbnail
        let maxWidth: CGFloat = 320
        let scale = maxWidth / image.size.width
        let newSize = NSSize(width: maxWidth, height: image.size.height * scale)

        let thumbnail = NSImage(size: newSize)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        thumbnail.unlockFocus()

        // Convert to JPEG
        guard let tiff = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            return HTTPResponse.error(500, "Failed to encode image")
        }

        return HTTPResponse(status: 200, statusText: "OK", contentType: "image/jpeg", body: jpeg)
    }

    // MARK: - Gobo Handlers

    @MainActor
    private func handleGetGobos() -> HTTPResponse {
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

        // Find next available slot ID
        var slotId = 21
        for id in 21...50 {
            if GoboLibrary.shared.image(for: id) == nil {
                slotId = id
                break
            }
        }

        // Generate filename
        let safeName = filePart.filename?
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".png", with: "") ?? "custom"
        let filename = "gobo_\(String(format: "%03d", slotId))_\(safeName).png"

        // Save to upload folder
        let uploadFolder = getGoboUploadFolder()
        try? FileManager.default.createDirectory(at: uploadFolder, withIntermediateDirectories: true)
        let fileURL = uploadFolder.appendingPathComponent(filename)

        do {
            try filePart.data.write(to: fileURL)

            // GoboFileWatcher will detect and reload
            return HTTPResponse.json([
                "success": true,
                "id": slotId,
                "filename": filename,
                "path": fileURL.path
            ])
        } catch {
            return HTTPResponse.error(500, "Failed to save file: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleDeleteGobo(id: Int) -> HTTPResponse {
        // Find the gobo file
        guard let def = GoboLibrary.shared.definition(for: id) else {
            return HTTPResponse.notFound()
        }

        // Try to find and delete the file
        let uploadFolder = getGoboUploadFolder()
        let filename = "gobo_\(String(format: "%03d", id))_\(def.name.lowercased().replacingOccurrences(of: " ", with: "_")).png"
        let fileURL = uploadFolder.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
                return HTTPResponse.json(["success": true, "id": id])
            } catch {
                return HTTPResponse.error(500, "Failed to delete: \(error.localizedDescription)")
            }
        }

        return HTTPResponse.notFound()
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
        guard let contentType = request.headers["content-type"],
              contentType.contains("multipart/form-data"),
              let boundary = extractBoundary(from: contentType) else {
            return HTTPResponse.badRequest("Expected multipart/form-data")
        }

        guard let parts = parseMultipart(data: request.body, boundary: boundary),
              let filePart = parts.first(where: { $0.filename != nil }),
              let filename = filePart.filename else {
            return HTTPResponse.badRequest("No file uploaded")
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

    // MARK: - Helpers

    private func getGoboUploadFolder() -> URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/GeoDraw/gobos")
    }

    private func getVideosFolder() -> URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/DMXMedia/videos")
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
        guard let str = String(data: data, encoding: .utf8) else { return nil }

        let lines = str.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Parse request line
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let path = requestLine[1].components(separatedBy: "?")[0] // Strip query string

        // Parse headers
        var headers: [String: String] = [:]
        var bodyStart = 0
        for (i, line) in lines.enumerated() {
            if i == 0 { continue }
            if line.isEmpty {
                bodyStart = i + 1
                break
            }
            let parts = line.components(separatedBy: ": ")
            if parts.count >= 2 {
                headers[parts[0].lowercased()] = parts.dropFirst().joined(separator: ": ")
            }
        }

        // Parse body
        var body = Data()
        if bodyStart > 0 && bodyStart < lines.count {
            // Find body in raw data (after \r\n\r\n)
            if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                body = data.subdata(in: range.upperBound..<data.endIndex)
            }
        }

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
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #1a1a2e;
            color: #eee;
            min-height: 100vh;
        }
        header {
            background: #16213e;
            padding: 1rem;
            border-bottom: 1px solid #0f3460;
        }
        header h1 { font-size: 1.5rem; font-weight: 500; }
        nav {
            display: flex;
            gap: 0.5rem;
            margin-top: 0.75rem;
        }
        nav button {
            padding: 0.5rem 1rem;
            border: none;
            background: #0f3460;
            color: #eee;
            border-radius: 4px;
            cursor: pointer;
            font-size: 0.9rem;
        }
        nav button:hover { background: #1a4980; }
        nav button.active { background: #e94560; }
        main { padding: 1rem; max-width: 1200px; margin: 0 auto; }
        .section { display: none; }
        .section.active { display: block; }

        /* Status Panel */
        .status-grid {
            display: grid;
            grid-template-columns: 320px 1fr;
            gap: 1rem;
            margin-bottom: 1rem;
        }
        .preview-container {
            background: #000;
            border-radius: 8px;
            overflow: hidden;
        }
        .preview-container img {
            width: 100%;
            height: auto;
            display: block;
        }
        .status-info {
            background: #16213e;
            padding: 1rem;
            border-radius: 8px;
        }
        .status-item {
            display: flex;
            justify-content: space-between;
            padding: 0.5rem 0;
            border-bottom: 1px solid #0f3460;
        }
        .status-item:last-child { border-bottom: none; }
        .status-value { color: #e94560; font-weight: 500; }

        /* Gobo Grid */
        .gobo-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(100px, 1fr));
            gap: 0.75rem;
            margin-top: 1rem;
        }
        .gobo-item {
            background: #16213e;
            border-radius: 8px;
            padding: 0.5rem;
            text-align: center;
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
            color: #888;
            margin-top: 0.25rem;
        }
        .gobo-item.empty {
            opacity: 0.3;
        }

        /* Upload Zone */
        .upload-zone {
            border: 2px dashed #0f3460;
            border-radius: 8px;
            padding: 2rem;
            text-align: center;
            margin-bottom: 1rem;
            cursor: pointer;
            transition: border-color 0.2s;
        }
        .upload-zone:hover { border-color: #e94560; }
        .upload-zone.dragover { border-color: #e94560; background: rgba(233, 69, 96, 0.1); }
        .upload-zone input { display: none; }

        /* Media Slots Table */
        .slots-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 1rem;
        }
        .slots-table th, .slots-table td {
            padding: 0.75rem;
            text-align: left;
            border-bottom: 1px solid #0f3460;
        }
        .slots-table th { background: #16213e; }
        .slots-table tr:hover { background: rgba(255,255,255,0.05); }
        .slot-empty { color: #666; }
        .btn {
            padding: 0.25rem 0.5rem;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 0.8rem;
        }
        .btn-danger { background: #e94560; color: white; }
        .btn-primary { background: #0f3460; color: white; }

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
            background: #16213e;
            padding: 0.75rem 1rem;
            border-radius: 4px;
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
            <button data-section="gobos">Gobos</button>
            <button data-section="media">Media Slots</button>
            <button data-section="ndi">NDI Sources</button>
        </nav>
    </header>
    <main>
        <!-- Status Section -->
        <div id="status" class="section active">
            <div class="status-grid">
                <div class="preview-container">
                    <img id="preview" src="/api/v1/status/preview" alt="Preview">
                </div>
                <div class="status-info">
                    <div class="status-item">
                        <span>Version</span>
                        <span class="status-value" id="version">-</span>
                    </div>
                    <div class="status-item">
                        <span>Fixtures</span>
                        <span class="status-value" id="fixtures">-</span>
                    </div>
                    <div class="status-item">
                        <span>Resolution</span>
                        <span class="status-value" id="resolution">-</span>
                    </div>
                    <div class="status-item">
                        <span>Syphon Output</span>
                        <span class="status-value" id="syphon">-</span>
                    </div>
                </div>
            </div>
        </div>

        <!-- Gobos Section -->
        <div id="gobos" class="section">
            <h2>Gobos (Slots 21-200)</h2>
            <div class="upload-zone" id="goboUpload">
                <p>Drag & drop PNG files here or click to browse</p>
                <input type="file" accept=".png" multiple>
            </div>
            <div class="gobo-grid" id="goboGrid"></div>
        </div>

        <!-- Media Slots Section -->
        <div id="media" class="section">
            <h2>Media Slots (201-255)</h2>
            <div class="upload-zone" id="videoUpload">
                <p>Drag & drop video files here or click to browse</p>
                <input type="file" accept=".mp4,.mov,.avi,.mkv,.m4v" multiple>
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
                document.getElementById('syphon').textContent = data.outputs.syphon ? 'Enabled' : 'Disabled';
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
                grid.innerHTML = data.gobos.map(g => `
                    <div class="gobo-item ${g.hasImage ? '' : 'empty'}">
                        ${g.hasImage ? `<img src="${g.imageUrl}" alt="Gobo ${g.id}">` : '<div style="width:80px;height:80px;background:#000;border-radius:4px"></div>'}
                        <div class="gobo-id">${g.id}: ${g.name}</div>
                    </div>
                `).join('');
            } catch (e) { console.error('Gobos error:', e); }
        }

        // Upload handling
        function setupUpload(zoneId, endpoint, onSuccess) {
            const zone = document.getElementById(zoneId);
            const input = zone.querySelector('input');

            zone.addEventListener('click', () => input.click());
            zone.addEventListener('dragover', e => { e.preventDefault(); zone.classList.add('dragover'); });
            zone.addEventListener('dragleave', () => zone.classList.remove('dragover'));
            zone.addEventListener('drop', e => {
                e.preventDefault();
                zone.classList.remove('dragover');
                uploadFiles(e.dataTransfer.files, endpoint, onSuccess);
            });
            input.addEventListener('change', () => uploadFiles(input.files, endpoint, onSuccess));
        }

        async function uploadFiles(files, endpoint, onSuccess) {
            for (const file of files) {
                const formData = new FormData();
                formData.append('file', file);
                try {
                    await fetch(endpoint, { method: 'POST', body: formData });
                    onSuccess();
                } catch (e) { console.error('Upload error:', e); }
            }
        }

        // Media Slots
        async function loadSlots() {
            try {
                const res = await fetch('/api/v1/media/slots');
                const data = await res.json();
                const table = document.getElementById('slotsTable');
                table.innerHTML = data.slots.map(s => `
                    <tr>
                        <td>${s.slot}</td>
                        <td>${s.type}</td>
                        <td class="${s.type === 'none' ? 'slot-empty' : ''}">${s.displayName}</td>
                        <td>${s.type !== 'none' ? `<button class="btn btn-danger" onclick="clearSlot(${s.slot})">Clear</button>` : ''}</td>
                    </tr>
                `).join('');
            } catch (e) { console.error('Slots error:', e); }
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

        // Init
        updateStatus();
        loadGobos();
        loadSlots();
        loadNDI();
        setupUpload('goboUpload', '/api/v1/gobos/upload', loadGobos);
        setupUpload('videoUpload', '/api/v1/media/videos/upload', loadSlots);

        // Auto-refresh
        setInterval(updateStatus, 5000);
        setInterval(updatePreview, 500);
    </script>
</body>
</html>
"""
