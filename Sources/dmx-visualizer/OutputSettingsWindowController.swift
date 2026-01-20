// OutputSettingsWindowController.swift - Destination configuration window
// Based on Switcher's destination editor modal

import AppKit
import OutputEngine

// RetroTheme is now in RetroTheme.swift

// MARK: - Canvas NDI Manager (Singleton)
// Manages persistent Canvas NDI preview that runs independently of Output Settings window

@MainActor
class CanvasNDIManager {
    static let shared = CanvasNDIManager()

    private var ndiOutput: GDNDIOutput?
    private var captureTimer: Timer?
    private(set) var isEnabled: Bool = false
    private var outputWidth: Int = 960
    private var outputHeight: Int = 540

    // Reusable bitmap buffer (avoid allocation every frame)
    private var reusableBitmapRep: NSBitmapImageRep?
    private var isCapturing: Bool = false  // Skip if busy

    // Callback for UI updates
    var onStateChanged: ((Bool) -> Void)?

    private init() {
        // Restore saved state
        isEnabled = UserDefaults.standard.bool(forKey: "canvasNDIEnabled")
        if isEnabled {
            start()
        }
    }

    func toggle() {
        if isEnabled {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard ndiOutput == nil else { return }

        // Get Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("CanvasNDIManager: Failed to get Metal device")
            return
        }

        // Calculate output dimensions from canvas size
        let canvasW = CGFloat(UserDefaults.standard.integer(forKey: "canvasWidth").nonZero ?? 7680)
        let canvasH = CGFloat(UserDefaults.standard.integer(forKey: "canvasHeight").nonZero ?? 2000)
        let canvasAspect = canvasW / canvasH

        let maxWidth: CGFloat = 960
        let maxHeight: CGFloat = 540
        let maxAspect = maxWidth / maxHeight

        if canvasAspect > maxAspect {
            outputWidth = Int(maxWidth)
            outputHeight = Int(maxWidth / canvasAspect)
        } else {
            outputHeight = Int(maxHeight)
            outputWidth = Int(maxHeight * canvasAspect)
        }

        // Ensure even dimensions
        outputWidth = (outputWidth / 2) * 2
        outputHeight = (outputHeight / 2) * 2

        // Create NDI output
        let ndi = GDNDIOutput(device: device)
        ndi.configure(withSourceName: "GeoDraw Canvas Preview", groups: nil, networkInterface: nil, clockVideo: false, asyncQueueSize: 3)
        _ = ndi.setResolutionWidth(UInt32(outputWidth), height: UInt32(outputHeight))
        _ = ndi.start()
        ndiOutput = ndi

        isEnabled = true
        UserDefaults.standard.set(true, forKey: "canvasNDIEnabled")
        NSLog("CanvasNDIManager: Started 'GeoDraw Canvas Preview' at \(outputWidth)x\(outputHeight)")

        // Start capture timer at 10fps - captures from main render view (reduced for CPU)
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.0/10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureAndSend()
            }
        }

        onStateChanged?(true)
    }

    func stop() {
        captureTimer?.invalidate()
        captureTimer = nil

        ndiOutput?.stop()
        ndiOutput = nil
        reusableBitmapRep = nil  // Free memory

        isEnabled = false
        UserDefaults.standard.set(false, forKey: "canvasNDIEnabled")
        NSLog("CanvasNDIManager: Stopped")

        onStateChanged?(false)
    }

    private func captureAndSend() {
        guard let ndi = ndiOutput, ndi.isRunning() else { return }

        // Skip if previous capture still processing
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        // Capture from the main render view (works even when Output Settings is closed)
        guard let image = sharedMetalRenderView?.captureCurrentFrame() else { return }

        // Convert NSImage to bitmap data (reuses buffer)
        guard let bitmapRep = convertToBitmap(image: image, width: outputWidth, height: outputHeight) else { return }
        guard let data = bitmapRep.bitmapData else { return }

        // Send to NDI at 10fps
        let timestamp = UInt64(CACurrentMediaTime() * 1_000_000_000)
        _ = ndi.pushPixelData(data, width: UInt32(outputWidth), height: UInt32(outputHeight), timestamp: timestamp, frameRate: 10)
    }

    private func convertToBitmap(image: NSImage, width: Int, height: Int) -> NSBitmapImageRep? {
        // Reuse existing bitmap if dimensions match, otherwise create new one
        let bitmapRep: NSBitmapImageRep
        if let existing = reusableBitmapRep, existing.pixelsWide == width, existing.pixelsHigh == height {
            bitmapRep = existing
        } else {
            guard let newRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [.thirtyTwoBitLittleEndian],
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            ) else { return nil }
            reusableBitmapRep = newRep
            bitmapRep = newRep
        }

        guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // Draw scaled and flipped for correct NDI orientation
        let targetRect = NSRect(x: 0, y: 0, width: width, height: height)
        image.draw(in: targetRect, from: .zero, operation: .copy, fraction: 1.0)

        // Draw output rectangles overlay
        drawOutputOverlays(width: width, height: height)

        NSGraphicsContext.restoreGraphicsState()
        return bitmapRep
    }

    private func drawOutputOverlays(width: Int, height: Int) {
        // Get canvas dimensions
        let canvasW = CGFloat(UserDefaults.standard.integer(forKey: "canvasWidth").nonZero ?? 7680)
        let canvasH = CGFloat(UserDefaults.standard.integer(forKey: "canvasHeight").nonZero ?? 2000)

        // Calculate scale from canvas to output preview
        let scaleX = CGFloat(width) / canvasW
        let scaleY = CGFloat(height) / canvasH

        // Get all outputs
        let outputs = OutputManager.shared.getAllOutputs()

        // Colors for different outputs (cycle through)
        let colors: [NSColor] = [
            NSColor(red: 0, green: 1, blue: 1, alpha: 0.8),     // Cyan
            NSColor(red: 1, green: 0, blue: 1, alpha: 0.8),     // Magenta
            NSColor(red: 1, green: 1, blue: 0, alpha: 0.8),     // Yellow
            NSColor(red: 0, green: 1, blue: 0, alpha: 0.8),     // Green
            NSColor(red: 1, green: 0.5, blue: 0, alpha: 0.8),   // Orange
            NSColor(red: 0.5, green: 0.5, blue: 1, alpha: 0.8), // Light blue
        ]

        for (index, output) in outputs.enumerated() {
            // Get output position (center-relative) and size
            let posX = CGFloat(output.config.positionX ?? 0)
            let posY = CGFloat(output.config.positionY ?? 0)
            let outW = CGFloat(output.config.positionW ?? 1920)
            let outH = CGFloat(output.config.positionH ?? 1080)

            // Convert center-relative position to top-left corner on canvas
            let leftEdge = (canvasW / 2.0) + posX - (outW / 2.0)
            let topEdge = (canvasH / 2.0) + posY - (outH / 2.0)

            // Scale to preview size (flip Y for NSGraphicsContext)
            let rectX = leftEdge * scaleX
            let rectY = CGFloat(height) - (topEdge * scaleY) - (outH * scaleY)
            let rectW = outW * scaleX
            let rectH = outH * scaleY

            let rect = NSRect(x: rectX, y: rectY, width: rectW, height: rectH)

            // Draw border
            let color = colors[index % colors.count]
            color.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 12.0
            path.stroke()

            // Draw label background
            let labelText = output.config.name
            let fontSize: CGFloat = max(10, min(14, rectH * 0.1))
            let font = NSFont.boldSystemFont(ofSize: fontSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let textSize = labelText.size(withAttributes: attrs)
            let labelRect = NSRect(
                x: rectX + 2,
                y: rectY + rectH - textSize.height - 4,
                width: textSize.width + 6,
                height: textSize.height + 2
            )

            // Draw label background
            color.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 3, yRadius: 3).fill()

            // Draw label text
            labelText.draw(at: NSPoint(x: labelRect.minX + 3, y: labelRect.minY + 1), withAttributes: attrs)
        }
    }
}

// Helper extension
private extension Int {
    var nonZero: Int? {
        return self > 0 ? self : nil
    }
}

// MARK: - Draggable Output View

class DraggableOutputView: NSView {
    var outputIndex: Int = 0
    var scale: CGFloat = 1.0
    var canvasHeight: CGFloat = 1080
    weak var controller: OutputSettingsWindowController?

    private var isDragging = false
    private var hasDragged = false
    private var dragStartPoint: NSPoint = .zero
    private var originalX: Int = 0
    private var originalY: Int = 0

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        hasDragged = false
        dragStartPoint = convert(event.locationInWindow, from: nil)

        // Get current position from controller
        if let pos = controller?.getMemberPosition(index: outputIndex) {
            originalX = pos.x
            originalY = pos.y
        }

        // Visual feedback
        layer?.opacity = 0.8
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let deltaX = currentPoint.x - dragStartPoint.x
        let deltaY = currentPoint.y - dragStartPoint.y

        // Only count as drag if moved more than 3 pixels
        if abs(deltaX) > 3 || abs(deltaY) > 3 {
            hasDragged = true
        }

        // Convert screen delta to canvas pixels
        let canvasDeltaX = Int(deltaX / scale)
        // Y is inverted in AppKit (Y=0 at bottom)
        let canvasDeltaY = Int(-deltaY / scale)

        let newX = originalX + canvasDeltaX
        let newY = originalY + canvasDeltaY

        // Update the position fields
        controller?.setMemberPosition(index: outputIndex, x: newX, y: newY)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        layer?.opacity = 1.0

        if hasDragged {
            // Was a drag - update and save position
            controller?.updateCanvasPreview()
            controller?.updatePopOutOutputs()
            controller?.updateOverlapInfo()
            controller?.savePositionAfterDrag(index: outputIndex)
        } else {
            // Was a click - select this output
            controller?.selectPopOutOutput(index: outputIndex)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Draggable Corner Popup View

class DraggableCornerPopupView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - Output Settings Window Controller

class OutputSettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    private var outputs: [ManagedOutput] = []
    private var selectedOutputIndex: Int = -1

    // Left panel - Canvas and outputs
    private var canvasWidthField: NSTextField!
    private var canvasHeightField: NSTextField!
    private var canvasPreview: NSView!
    private var memberOutputsView: NSView!
    private var scaleField: NSTextField!
    private var panXField: NSTextField!
    private var panYField: NSTextField!
    private var blendEnabledCheck: NSButton!
    private var blendGammaField: NSTextField!
    private var blendPowerField: NSTextField!
    private var blackLevelField: NSTextField!
    private var redGammaField: NSTextField!
    private var greenGammaField: NSTextField!
    private var blueGammaField: NSTextField!
    private var overlapLabel: NSTextField!

    // Right panel - Output grid and config
    private var outputCells: [NSView] = []
    private var selectedOutputLabel: NSTextField!
    private var outputNameField: NSTextField!
    private var outputEnabledCheck: NSButton!
    private var outputWidthField: NSTextField!
    private var outputHeightField: NSTextField!
    private var widthStepper: NSStepper!
    private var heightStepper: NSStepper!
    private var displayPopup: NSPopUpButton!
    private var nativeResBtn: NSButton!
    private var removeOutputBtn: NSButton!

    // Edge blend fields for selected output
    private var blendLeftField: NSTextField!
    private var blendRightField: NSTextField!
    private var blendTopField: NSTextField!
    private var blendBottomField: NSTextField!
    private var blendLeftStepper: NSStepper!
    private var blendRightStepper: NSStepper!
    private var blendTopStepper: NSStepper!
    private var blendBottomStepper: NSStepper!

    // Geometric correction fields for selected output
    // Corners
    private var warpTLXField: NSTextField!
    private var warpTLYField: NSTextField!
    private var warpTRXField: NSTextField!
    private var warpTRYField: NSTextField!
    private var warpBLXField: NSTextField!
    private var warpBLYField: NSTextField!
    private var warpBRXField: NSTextField!
    private var warpBRYField: NSTextField!
    private var warpTLXStepper: NSStepper!
    private var warpTLYStepper: NSStepper!
    private var warpTRXStepper: NSStepper!
    private var warpTRYStepper: NSStepper!
    private var warpBLXStepper: NSStepper!
    private var warpBLYStepper: NSStepper!
    private var warpBRXStepper: NSStepper!
    private var warpBRYStepper: NSStepper!
    // Middles (for sphere/curved surface mapping)
    private var warpTMXField: NSTextField!
    private var warpTMYField: NSTextField!
    private var warpMLXField: NSTextField!
    private var warpMLYField: NSTextField!
    private var warpMRXField: NSTextField!
    private var warpMRYField: NSTextField!
    private var warpBMXField: NSTextField!
    private var warpBMYField: NSTextField!
    private var warpTMXStepper: NSStepper!
    private var warpTMYStepper: NSStepper!
    private var warpMLXStepper: NSStepper!
    private var warpMLYStepper: NSStepper!
    private var warpMRXStepper: NSStepper!
    private var warpMRYStepper: NSStepper!
    private var warpBMXStepper: NSStepper!
    private var warpBMYStepper: NSStepper!
    private var showMiddlesCheckbox: NSButton!
    private var middleWarpControls: [NSView] = []
    private var lensK1Field: NSTextField!
    private var lensK2Field: NSTextField!
    private var lensK1Slider: NSSlider!
    private var lensK2Slider: NSSlider!
    private var lensK1Stepper: NSStepper!
    private var lensK2Stepper: NSStepper!

    // Warp curvature controls
    private var curvatureField: NSTextField!
    private var curvatureSlider: NSSlider!
    private var curvatureStepper: NSStepper!

    // DMX Patch fields
    private var dmxUniverseField: NSTextField!
    private var dmxAddressField: NSTextField!
    private var dmxUniverseStepper: NSStepper!
    private var dmxAddressStepper: NSStepper!

    // Processing controls (frame rate + shader toggles)
    private var frameRatePopup: NSPopUpButton!
    private var enableEdgeBlendCheckbox: NSButton!
    private var enableWarpCheckbox: NSButton!
    private var enableLensCheckbox: NSButton!
    private var enableCurveCheckbox: NSButton!

    // Live preview
    private var livePreviewImageView: NSImageView?
    private var livePreviewTimer: Timer?

    // Canvas NDI Preview checkbox (actual NDI managed by CanvasNDIManager singleton)
    private var canvasNDICheckbox: NSButton?

    // Pop-out preview window
    private var popOutWindow: NSWindow?
    private var popOutImageView: NSImageView?
    private var popOutCanvasContainer: NSView?
    private var popOutOutputViews: [DraggableOutputView] = []
    private var popOutSelectedIndex: Int = -1
    private var popOutSettingsPanel: NSView?
    private var popOutOutputList: NSScrollView?

    // Pop-out settings fields
    private var popOutNameField: NSTextField?
    private var popOutEnabledCheck: NSButton?
    private var popOutPosXField: NSTextField?
    private var popOutPosYField: NSTextField?
    private var popOutWidthField: NSTextField?
    private var popOutHeightField: NSTextField?
    private var popOutBlendLField: NSTextField?
    private var popOutBlendRField: NSTextField?
    private var popOutBlendTField: NSTextField?
    private var popOutBlendBField: NSTextField?
    private var popOutSelectedLabel: NSTextField?

    // Pop-out steppers
    private var popOutPosXStepper: NSStepper?
    private var popOutPosYStepper: NSStepper?
    private var popOutWidthStepper: NSStepper?
    private var popOutHeightStepper: NSStepper?
    private var popOutBlendLStepper: NSStepper?
    private var popOutBlendRStepper: NSStepper?
    private var popOutBlendTStepper: NSStepper?
    private var popOutBlendBStepper: NSStepper?
    private var popOutZoom: CGFloat = 1.0  // 1.0 = fit to window, < 1.0 = zoom out
    private var popOutZoomLabel: NSTextField?
    private var popOutDeleteBtn: NSButton?

    // Show Borders alignment mode
    private var showBordersButton: NSButton?
    static var showBordersActive: Bool = false

    // Test Pattern alignment mode
    private var testPatternButton: NSButton?
    private var testPatternTextButton: NSButton?
    static var testPatternActive: Bool = false
    static var testPatternText: String = ""

    // Corner warp popup - shows active corner and position when adjusting
    private var cornerPopupPanel: NSPanel?
    private var cornerPopupCornerLabel: NSTextField?
    private var cornerPopupXLabel: NSTextField?
    private var cornerPopupYLabel: NSTextField?
    private var cornerPopupToggle: NSButton?
    private var cornerPopupEnabled: Bool = true
    private var activeCorner: String = "TL"  // TL, TR, BL, BR

    // Master Control DMX fields
    private var masterControlEnabledCheck: NSButton!
    private var masterControlUniverseField: NSTextField!
    private var masterControlAddressField: NSTextField!
    private var masterControlUniverseStepper: NSStepper!
    private var masterControlAddressStepper: NSStepper!

    // Global offset fields
    private var globalOffsetXField: NSTextField!
    private var globalOffsetYField: NSTextField!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 1020),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "◈ OUTPUT CONFIGURATION ◈"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 950, height: 980)

        // Apply retro theme to window
        RetroTheme.styleWindow(window)

        self.init(window: window)
        window.delegate = self
        buildUI()
        refresh()
    }

    func refresh() {
        outputs = OutputManager.shared.getAllOutputs()

        // Get canvas size from UserDefaults (set in main menu)
        let width = UserDefaults.standard.integer(forKey: "canvasWidth")
        let height = UserDefaults.standard.integer(forKey: "canvasHeight")
        canvasWidthField?.stringValue = "\(width > 0 ? width : 7680)"
        canvasHeightField?.stringValue = "\(height > 0 ? height : 1080)"

        updateOutputGrid()
        updateMemberOutputsList()
        updateCanvasPreview()
        updateOverlapInfo()
    }

    // MARK: - Build UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = RetroTheme.backgroundDeep.cgColor

        // Add subtle Tron-style grid pattern to background
        RetroTheme.addGridPattern(to: content, spacing: 40)

        // Main horizontal split
        let leftPanel = buildLeftPanel()
        leftPanel.frame = NSRect(x: 15, y: 15, width: 580, height: content.bounds.height - 30)
        content.addSubview(leftPanel)

        let rightPanel = buildRightPanel()
        rightPanel.frame = NSRect(x: 610, y: 15, width: 325, height: content.bounds.height - 30)
        content.addSubview(rightPanel)
    }

    private func buildLeftPanel() -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        var y: CGFloat = 960

        // === CANVAS SECTION ===
        let canvasHeader = RetroTheme.makeSectionHeader("◆ CANVAS", color: RetroTheme.sectionCanvas, width: 560)
        canvasHeader.frame = NSRect(x: 0, y: y, width: 560, height: 20)
        panel.addSubview(canvasHeader)
        y -= 28

        // Resolution display with neon styling
        let resBox = NSView(frame: NSRect(x: 0, y: y - 30, width: 220, height: 35))
        RetroTheme.styleCard(resBox, cornerRadius: 6)
        RetroTheme.applyNeonBorder(to: resBox.layer!, color: RetroTheme.sectionCanvas, width: 1)
        panel.addSubview(resBox)

        canvasWidthField = NSTextField(string: "7680")
        canvasWidthField.frame = NSRect(x: 12, y: 8, width: 70, height: 22)
        canvasWidthField.isEditable = true
        canvasWidthField.isBordered = true
        canvasWidthField.font = RetroTheme.numberFont(size: 16)
        canvasWidthField.backgroundColor = RetroTheme.backgroundInput
        canvasWidthField.textColor = RetroTheme.neonCyan
        canvasWidthField.alignment = .right
        canvasWidthField.target = self
        canvasWidthField.action = #selector(canvasSizeChanged(_:))
        resBox.addSubview(canvasWidthField)

        let xLabel = RetroTheme.makeLabel("×", style: .body, size: 16, color: RetroTheme.textSecondary)
        xLabel.frame = NSRect(x: 85, y: 8, width: 20, height: 22)
        xLabel.alignment = .center
        resBox.addSubview(xLabel)

        canvasHeightField = NSTextField(string: "1080")
        canvasHeightField.frame = NSRect(x: 108, y: 8, width: 60, height: 22)
        canvasHeightField.isEditable = true
        canvasHeightField.isBordered = true
        canvasHeightField.font = RetroTheme.numberFont(size: 16)
        canvasHeightField.backgroundColor = RetroTheme.backgroundInput
        canvasHeightField.textColor = RetroTheme.neonCyan
        canvasHeightField.target = self
        canvasHeightField.action = #selector(canvasSizeChanged(_:))
        resBox.addSubview(canvasHeightField)

        let pxLabel = RetroTheme.makeLabel("PX", style: .header, size: 9, color: RetroTheme.textSecondary)
        pxLabel.frame = NSRect(x: 175, y: 10, width: 25, height: 16)
        resBox.addSubview(pxLabel)
        y -= 50

        // Canvas preview with neon border
        canvasPreview = NSView(frame: NSRect(x: 0, y: y - 120, width: 520, height: 120))
        canvasPreview.wantsLayer = true
        canvasPreview.layer?.backgroundColor = RetroTheme.backgroundDeep.cgColor
        canvasPreview.layer?.cornerRadius = 8
        canvasPreview.layer?.masksToBounds = false  // Allow outputs outside canvas to be visible
        RetroTheme.applyNeonBorder(to: canvasPreview.layer!, color: RetroTheme.sectionCanvas.withAlphaComponent(0.4), width: 2)
        panel.addSubview(canvasPreview)

        // Pop-out button for larger preview
        let popOutBtn = NSButton(title: "⤢", target: self, action: #selector(popOutCanvasPreview))
        popOutBtn.frame = NSRect(x: 525, y: y - 120, width: 35, height: 35)
        popOutBtn.bezelStyle = .rounded
        popOutBtn.font = NSFont.systemFont(ofSize: 18)
        popOutBtn.toolTip = "Open larger preview window"
        RetroTheme.styleButton(popOutBtn, color: RetroTheme.neonCyan)
        panel.addSubview(popOutBtn)

        // Canvas NDI Preview checkbox
        canvasNDICheckbox = NSButton(checkboxWithTitle: "NDI Preview", target: self, action: #selector(toggleCanvasNDI(_:)))
        canvasNDICheckbox?.frame = NSRect(x: 525, y: y - 90, width: 100, height: 20)
        canvasNDICheckbox?.font = RetroTheme.headerFont(size: 9)
        canvasNDICheckbox?.attributedTitle = NSAttributedString(
            string: "NDI Preview",
            attributes: [
                .font: RetroTheme.headerFont(size: 9),
                .foregroundColor: RetroTheme.neonGreen
            ]
        )
        canvasNDICheckbox?.state = CanvasNDIManager.shared.isEnabled ? .on : .off
        canvasNDICheckbox?.toolTip = "Stream canvas preview via NDI (persists when window closed)"
        panel.addSubview(canvasNDICheckbox!)
        y -= 135

        // === OUTPUT POSITIONS SECTION ===
        let posHeader = RetroTheme.makeSectionHeader("◆ OUTPUT POSITIONS", color: RetroTheme.sectionPositions, width: 560)
        posHeader.frame = NSRect(x: 0, y: y, width: 560, height: 20)
        panel.addSubview(posHeader)
        y -= 28

        // Global offset controls
        let offsetLabel = RetroTheme.makeLabel("MOVE ALL:", style: .header, size: 10, color: RetroTheme.neonYellow)
        offsetLabel.frame = NSRect(x: 0, y: y, width: 70, height: 20)
        panel.addSubview(offsetLabel)

        let offsetXLbl = RetroTheme.makeLabel("X", style: .header, size: 10, color: RetroTheme.neonCyan)
        offsetXLbl.frame = NSRect(x: 75, y: y, width: 15, height: 20)
        panel.addSubview(offsetXLbl)

        globalOffsetXField = NSTextField(string: "0")
        globalOffsetXField.frame = NSRect(x: 90, y: y - 2, width: 60, height: 22)
        globalOffsetXField.font = RetroTheme.numberFont(size: 12)
        globalOffsetXField.backgroundColor = RetroTheme.backgroundInput
        globalOffsetXField.textColor = RetroTheme.neonCyan
        globalOffsetXField.alignment = .center
        panel.addSubview(globalOffsetXField)

        let offsetYLbl = RetroTheme.makeLabel("Y", style: .header, size: 10, color: RetroTheme.neonCyan)
        offsetYLbl.frame = NSRect(x: 160, y: y, width: 15, height: 20)
        panel.addSubview(offsetYLbl)

        globalOffsetYField = NSTextField(string: "0")
        globalOffsetYField.frame = NSRect(x: 175, y: y - 2, width: 60, height: 22)
        globalOffsetYField.font = RetroTheme.numberFont(size: 12)
        globalOffsetYField.backgroundColor = RetroTheme.backgroundInput
        globalOffsetYField.textColor = RetroTheme.neonCyan
        globalOffsetYField.alignment = .center
        panel.addSubview(globalOffsetYField)

        let applyOffsetBtn = NSButton(title: "▷ APPLY", target: self, action: #selector(applyGlobalOffset))
        applyOffsetBtn.bezelStyle = .rounded
        applyOffsetBtn.frame = NSRect(x: 245, y: y - 2, width: 70, height: 22)
        applyOffsetBtn.font = RetroTheme.headerFont(size: 9)
        RetroTheme.styleButton(applyOffsetBtn, color: RetroTheme.neonGreen)
        panel.addSubview(applyOffsetBtn)

        y -= 30

        memberOutputsView = NSView(frame: NSRect(x: 0, y: y - 130, width: 560, height: 130))
        memberOutputsView.wantsLayer = true
        memberOutputsView.layer?.backgroundColor = RetroTheme.backgroundCard.cgColor
        memberOutputsView.layer?.cornerRadius = 8
        RetroTheme.applyNeonBorder(to: memberOutputsView.layer!, color: RetroTheme.sectionPositions.withAlphaComponent(0.3), width: 1)
        panel.addSubview(memberOutputsView)
        y -= 145

        // === INPUT SCALING SECTION ===
        let scaleHeader = RetroTheme.makeSectionHeader("◆ INPUT SCALING", color: RetroTheme.sectionScale, width: 560)
        scaleHeader.frame = NSRect(x: 0, y: y, width: 560, height: 20)
        panel.addSubview(scaleHeader)
        y -= 25

        let scaleBox = makeInputScalingBox()
        scaleBox.frame = NSRect(x: 0, y: y - 70, width: 560, height: 70)
        panel.addSubview(scaleBox)
        y -= 85

        // === EDGE BLENDING SECTION ===
        let blendHeader = RetroTheme.makeSectionHeader("◆ EDGE BLENDING", color: RetroTheme.sectionBlend, width: 560)
        blendHeader.frame = NSRect(x: 0, y: y, width: 560, height: 20)
        panel.addSubview(blendHeader)
        y -= 20

        let blendBox = makeEdgeBlendBox()
        blendBox.frame = NSRect(x: 0, y: y - 200, width: 560, height: 200)
        panel.addSubview(blendBox)
        y -= 215

        // === MASTER CONTROL SECTION ===
        let masterHeader = RetroTheme.makeSectionHeader("◆ MASTER CONTROL DMX", color: RetroTheme.neonMagenta, width: 560)
        masterHeader.frame = NSRect(x: 0, y: y, width: 560, height: 20)
        panel.addSubview(masterHeader)
        y -= 25

        let masterBox = makeMasterControlBox()
        masterBox.frame = NSRect(x: 0, y: y - 55, width: 560, height: 55)
        panel.addSubview(masterBox)

        // === Buttons with neon styling ===
        let cancelBtn = NSButton(title: "◁ CANCEL", target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: 370, y: 10, width: 90, height: 28)
        cancelBtn.font = RetroTheme.headerFont(size: 10)
        RetroTheme.styleButton(cancelBtn, color: RetroTheme.textSecondary)
        panel.addSubview(cancelBtn)

        let saveBtn = NSButton(title: "▷ SAVE", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.frame = NSRect(x: 470, y: 10, width: 80, height: 28)
        saveBtn.font = RetroTheme.headerFont(size: 10)
        RetroTheme.styleButton(saveBtn, color: RetroTheme.neonGreen)
        panel.addSubview(saveBtn)

        return panel
    }

    private func makeSectionHeader(_ title: String, color: NSColor) -> NSView {
        // Legacy wrapper - now uses RetroTheme
        return RetroTheme.makeSectionHeader(title, color: color, width: 560)
    }

    private func buildRightPanel() -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = RetroTheme.backgroundPanel.cgColor
        panel.layer?.cornerRadius = 10
        RetroTheme.applyNeonBorder(to: panel.layer!, color: RetroTheme.sectionOutputs.withAlphaComponent(0.3), width: 1)

        var y: CGFloat = 950

        // === OUTPUTS HEADER ===
        let outputsHeader = RetroTheme.makeSectionHeader("◆ OUTPUTS", color: RetroTheme.sectionOutputs, width: 295)
        outputsHeader.frame = NSRect(x: 15, y: y, width: 295, height: 20)
        panel.addSubview(outputsHeader)
        y -= 35

        // === Add Buttons with neon styling ===
        let addNDIBtn = NSButton(title: "+ NDI", target: self, action: #selector(addNDI))
        addNDIBtn.bezelStyle = .rounded
        addNDIBtn.frame = NSRect(x: 15, y: y, width: 80, height: 26)
        addNDIBtn.font = RetroTheme.headerFont(size: 10)
        RetroTheme.styleButton(addNDIBtn, color: RetroTheme.neonBlue)
        panel.addSubview(addNDIBtn)

        let addDispBtn = NSButton(title: "+ DISPLAY", target: self, action: #selector(addDisplay))
        addDispBtn.bezelStyle = .rounded
        addDispBtn.frame = NSRect(x: 105, y: y, width: 100, height: 26)
        addDispBtn.font = RetroTheme.headerFont(size: 10)
        RetroTheme.styleButton(addDispBtn, color: RetroTheme.neonMagenta)
        panel.addSubview(addDispBtn)
        y -= 45

        // === Outputs Grid (8 cells, 4x2) ===
        for row in 0..<2 {
            for col in 0..<4 {
                let idx = row * 4 + col
                let cell = makeOutputCell(index: idx)
                cell.frame = NSRect(x: 15 + CGFloat(col) * 75, y: y - CGFloat(row) * 68 - 60, width: 70, height: 60)
                panel.addSubview(cell)
                outputCells.append(cell)
            }
        }
        y -= 160

        // === CONFIGURATION HEADER ===
        let configHeader = RetroTheme.makeSectionHeader("◆ CONFIGURATION", color: RetroTheme.sectionConfig, width: 295)
        configHeader.frame = NSRect(x: 15, y: y, width: 295, height: 20)
        panel.addSubview(configHeader)
        y -= 30

        // Config box with retro styling (expanded for geometric correction + curvature + DMX patch + processing)
        let configBox = NSView(frame: NSRect(x: 15, y: y - 700, width: 295, height: 700))
        RetroTheme.styleCard(configBox, cornerRadius: 8)
        RetroTheme.applyNeonBorder(to: configBox.layer!, color: RetroTheme.sectionConfig.withAlphaComponent(0.3), width: 1)
        panel.addSubview(configBox)

        var cy: CGFloat = 670

        // Selected output header
        selectedOutputLabel = RetroTheme.makeLabel("▸ SELECT AN OUTPUT", style: .header, size: 11, color: RetroTheme.textSecondary)
        selectedOutputLabel.frame = NSRect(x: 12, y: cy, width: 270, height: 18)
        configBox.addSubview(selectedOutputLabel)
        cy -= 30

        // Enabled checkbox
        outputEnabledCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(outputEnabledChanged(_:)))
        outputEnabledCheck.frame = NSRect(x: 12, y: cy, width: 100, height: 20)
        outputEnabledCheck.attributedTitle = NSAttributedString(
            string: "ENABLED",
            attributes: [
                .font: RetroTheme.headerFont(size: 10),
                .foregroundColor: RetroTheme.neonGreen
            ]
        )
        outputEnabledCheck.isEnabled = false
        configBox.addSubview(outputEnabledCheck)
        cy -= 30

        // Name field
        let nameLabel = RetroTheme.makeLabel("NAME", style: .header, size: 9, color: RetroTheme.neonCyan)
        nameLabel.frame = NSRect(x: 12, y: cy + 2, width: 50, height: 14)
        configBox.addSubview(nameLabel)

        outputNameField = NSTextField(string: "")
        outputNameField.placeholderString = "Output name"
        outputNameField.frame = NSRect(x: 60, y: cy, width: 220, height: 22)
        outputNameField.font = RetroTheme.bodyFont(size: 12)
        outputNameField.backgroundColor = RetroTheme.backgroundInput
        outputNameField.textColor = RetroTheme.textPrimary
        outputNameField.isEnabled = false
        outputNameField.target = self
        outputNameField.action = #selector(outputNameChanged(_:))
        configBox.addSubview(outputNameField)
        cy -= 35

        // Resolution with steppers
        let resLabel = RetroTheme.makeLabel("RESOLUTION", style: .header, size: 9, color: RetroTheme.neonCyan)
        resLabel.frame = NSRect(x: 12, y: cy + 2, width: 70, height: 14)
        configBox.addSubview(resLabel)

        outputWidthField = NSTextField(string: "1920")
        outputWidthField.frame = NSRect(x: 85, y: cy, width: 55, height: 22)
        outputWidthField.font = RetroTheme.numberFont(size: 12)
        outputWidthField.backgroundColor = RetroTheme.backgroundInput
        outputWidthField.textColor = RetroTheme.neonCyan
        outputWidthField.isEnabled = false
        outputWidthField.target = self
        outputWidthField.action = #selector(outputResolutionChanged(_:))
        outputWidthField.delegate = self  // Also handle focus loss
        configBox.addSubview(outputWidthField)

        widthStepper = NSStepper()
        widthStepper.frame = NSRect(x: 140, y: cy, width: 16, height: 22)
        widthStepper.minValue = 320
        widthStepper.maxValue = 7680
        widthStepper.increment = 160
        widthStepper.valueWraps = false
        widthStepper.target = self
        widthStepper.action = #selector(widthStepperChanged(_:))
        widthStepper.isEnabled = false
        configBox.addSubview(widthStepper)

        let xResLabel = RetroTheme.makeLabel("×", style: .body, size: 12, color: RetroTheme.neonCyan)
        xResLabel.frame = NSRect(x: 160, y: cy + 2, width: 15, height: 18)
        configBox.addSubview(xResLabel)

        outputHeightField = NSTextField(string: "1080")
        outputHeightField.frame = NSRect(x: 178, y: cy, width: 55, height: 22)
        outputHeightField.font = RetroTheme.numberFont(size: 12)
        outputHeightField.backgroundColor = RetroTheme.backgroundInput
        outputHeightField.textColor = RetroTheme.neonCyan
        outputHeightField.isEnabled = false
        outputHeightField.target = self
        outputHeightField.action = #selector(outputResolutionChanged(_:))
        outputHeightField.delegate = self  // Also handle focus loss
        configBox.addSubview(outputHeightField)

        heightStepper = NSStepper()
        heightStepper.frame = NSRect(x: 233, y: cy, width: 16, height: 22)
        heightStepper.minValue = 240
        heightStepper.maxValue = 4320
        heightStepper.increment = 90
        heightStepper.valueWraps = false
        heightStepper.target = self
        heightStepper.action = #selector(heightStepperChanged(_:))
        heightStepper.isEnabled = false
        configBox.addSubview(heightStepper)

        // Native resolution button
        nativeResBtn = NSButton(title: "NATIVE", target: self, action: #selector(resetToNativeResolution))
        nativeResBtn.bezelStyle = .rounded
        nativeResBtn.frame = NSRect(x: 255, y: cy - 1, width: 50, height: 22)
        nativeResBtn.font = RetroTheme.headerFont(size: 8)
        nativeResBtn.isEnabled = false
        RetroTheme.styleButton(nativeResBtn, color: RetroTheme.neonPurple)
        configBox.addSubview(nativeResBtn)
        cy -= 35

        // Display selection
        let dispLabel = RetroTheme.makeLabel("DISPLAY", style: .header, size: 9, color: RetroTheme.neonCyan)
        dispLabel.frame = NSRect(x: 12, y: cy + 2, width: 50, height: 14)
        configBox.addSubview(dispLabel)

        displayPopup = NSPopUpButton(frame: NSRect(x: 65, y: cy - 2, width: 215, height: 26), pullsDown: false)
        displayPopup.font = RetroTheme.bodyFont(size: 11)
        displayPopup.isEnabled = false
        displayPopup.target = self
        displayPopup.action = #selector(displaySelectionChanged(_:))
        configBox.addSubview(displayPopup)
        cy -= 35

        // DMX Patch section
        let dmxHeader = RetroTheme.makeLabel("◆ DMX PATCH (27CH)", style: .header, size: 9, color: RetroTheme.neonPurple)
        dmxHeader.frame = NSRect(x: 12, y: cy, width: 200, height: 14)
        configBox.addSubview(dmxHeader)
        cy -= 26

        // Universe field
        let universeLabel = RetroTheme.makeLabel("UNIV:", style: .header, size: 9, color: RetroTheme.neonPurple)
        universeLabel.frame = NSRect(x: 12, y: cy + 2, width: 35, height: 14)
        configBox.addSubview(universeLabel)

        dmxUniverseField = NSTextField(string: "0")
        dmxUniverseField.frame = NSRect(x: 50, y: cy, width: 45, height: 22)
        dmxUniverseField.font = RetroTheme.numberFont(size: 12)
        dmxUniverseField.backgroundColor = RetroTheme.backgroundInput
        dmxUniverseField.textColor = RetroTheme.neonPurple
        dmxUniverseField.isEnabled = false
        dmxUniverseField.placeholderString = "0"
        dmxUniverseField.target = self
        dmxUniverseField.action = #selector(dmxPatchChanged(_:))
        configBox.addSubview(dmxUniverseField)

        dmxUniverseStepper = NSStepper()
        dmxUniverseStepper.frame = NSRect(x: 97, y: cy, width: 15, height: 22)
        dmxUniverseStepper.minValue = 0
        dmxUniverseStepper.maxValue = 63999
        dmxUniverseStepper.increment = 1
        dmxUniverseStepper.valueWraps = false
        dmxUniverseStepper.isEnabled = false
        dmxUniverseStepper.target = self
        dmxUniverseStepper.action = #selector(dmxUniverseStepperChanged(_:))
        configBox.addSubview(dmxUniverseStepper)

        // Address field
        let addressLabel = RetroTheme.makeLabel("ADDR:", style: .header, size: 9, color: RetroTheme.neonPurple)
        addressLabel.frame = NSRect(x: 120, y: cy + 2, width: 35, height: 14)
        configBox.addSubview(addressLabel)

        dmxAddressField = NSTextField(string: "1")
        dmxAddressField.frame = NSRect(x: 158, y: cy, width: 45, height: 22)
        dmxAddressField.font = RetroTheme.numberFont(size: 12)
        dmxAddressField.backgroundColor = RetroTheme.backgroundInput
        dmxAddressField.textColor = RetroTheme.neonPurple
        dmxAddressField.isEnabled = false
        dmxAddressField.placeholderString = "1"
        dmxAddressField.target = self
        dmxAddressField.action = #selector(dmxPatchChanged(_:))
        configBox.addSubview(dmxAddressField)

        dmxAddressStepper = NSStepper()
        dmxAddressStepper.frame = NSRect(x: 205, y: cy, width: 15, height: 22)
        dmxAddressStepper.minValue = 1
        dmxAddressStepper.maxValue = 486  // 27ch fixture, max start = 486
        dmxAddressStepper.increment = 1
        dmxAddressStepper.valueWraps = false
        dmxAddressStepper.isEnabled = false
        dmxAddressStepper.target = self
        dmxAddressStepper.action = #selector(dmxAddressStepperChanged(_:))
        configBox.addSubview(dmxAddressStepper)

        // Universe 0 = disabled note
        let dmxNote = RetroTheme.makeLabel("(0=off)", style: .body, size: 8, color: RetroTheme.neonPurple.withAlphaComponent(0.7))
        dmxNote.frame = NSRect(x: 225, y: cy + 4, width: 50, height: 12)
        configBox.addSubview(dmxNote)
        cy -= 18

        // Patch point info
        let dmxPatchInfo = RetroTheme.makeLabel("PATCH GEODRAW@OUTPUT_27CH ON THIS UNIVERSE/ADDRESS IN MA3", style: .body, size: 8, color: RetroTheme.neonPurple.withAlphaComponent(0.6))
        dmxPatchInfo.frame = NSRect(x: 12, y: cy, width: 280, height: 12)
        configBox.addSubview(dmxPatchInfo)
        cy -= 22

        // PROCESSING section header
        let procHeader = RetroTheme.makeLabel("◆ PROCESSING", style: .header, size: 9, color: RetroTheme.neonYellow)
        procHeader.frame = NSRect(x: 12, y: cy, width: 100, height: 14)
        configBox.addSubview(procHeader)
        cy -= 22

        // Row 1: Frame rate dropdown + first two shader toggles
        let fpsLabel = RetroTheme.makeLabel("FPS:", style: .header, size: 9, color: RetroTheme.neonYellow)
        fpsLabel.frame = NSRect(x: 12, y: cy + 2, width: 30, height: 14)
        configBox.addSubview(fpsLabel)

        frameRatePopup = NSPopUpButton(frame: NSRect(x: 40, y: cy - 1, width: 70, height: 22), pullsDown: false)
        frameRatePopup.font = RetroTheme.headerFont(size: 10)
        frameRatePopup.addItems(withTitles: ["Unlimited", "30", "60"])
        frameRatePopup.target = self
        frameRatePopup.action = #selector(frameRateChanged(_:))
        frameRatePopup.isEnabled = false
        configBox.addSubview(frameRatePopup)

        enableEdgeBlendCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(shaderToggleChanged(_:)))
        enableEdgeBlendCheckbox.frame = NSRect(x: 115, y: cy, width: 85, height: 18)
        enableEdgeBlendCheckbox.attributedTitle = NSAttributedString(
            string: "Edge Blend",
            attributes: [.font: RetroTheme.headerFont(size: 9), .foregroundColor: RetroTheme.neonOrange]
        )
        enableEdgeBlendCheckbox.state = .on
        enableEdgeBlendCheckbox.isEnabled = false
        configBox.addSubview(enableEdgeBlendCheckbox)

        enableWarpCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(shaderToggleChanged(_:)))
        enableWarpCheckbox.frame = NSRect(x: 205, y: cy, width: 55, height: 18)
        enableWarpCheckbox.attributedTitle = NSAttributedString(
            string: "Warp",
            attributes: [.font: RetroTheme.headerFont(size: 9), .foregroundColor: RetroTheme.neonPurple]
        )
        enableWarpCheckbox.state = .on
        enableWarpCheckbox.isEnabled = false
        configBox.addSubview(enableWarpCheckbox)
        cy -= 20

        // Row 2: Remaining shader toggles
        enableLensCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(shaderToggleChanged(_:)))
        enableLensCheckbox.frame = NSRect(x: 115, y: cy, width: 95, height: 18)
        enableLensCheckbox.attributedTitle = NSAttributedString(
            string: "Lens",
            attributes: [.font: RetroTheme.headerFont(size: 9), .foregroundColor: RetroTheme.neonCyan]
        )
        enableLensCheckbox.state = .on
        enableLensCheckbox.isEnabled = false
        configBox.addSubview(enableLensCheckbox)

        enableCurveCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(shaderToggleChanged(_:)))
        enableCurveCheckbox.frame = NSRect(x: 175, y: cy, width: 70, height: 18)
        enableCurveCheckbox.attributedTitle = NSAttributedString(
            string: "Curve",
            attributes: [.font: RetroTheme.headerFont(size: 9), .foregroundColor: RetroTheme.neonMagenta]
        )
        enableCurveCheckbox.state = .on
        enableCurveCheckbox.isEnabled = false
        configBox.addSubview(enableCurveCheckbox)
        cy -= 24

        // Edge Blend section header with neon styling
        let blendHeader = RetroTheme.makeLabel("◆ EDGE BLEND OVERLAP (PX)", style: .header, size: 9, color: RetroTheme.sectionBlend)
        blendHeader.frame = NSRect(x: 12, y: cy, width: 200, height: 14)
        configBox.addSubview(blendHeader)
        cy -= 28

        // Edge blend fields - Left/Right row
        let leftLabel = RetroTheme.makeLabel("L:", style: .header, size: 11, color: RetroTheme.neonOrange)
        leftLabel.frame = NSRect(x: 12, y: cy + 2, width: 20, height: 14)
        configBox.addSubview(leftLabel)

        blendLeftField = NSTextField(string: "0")
        blendLeftField.frame = NSRect(x: 35, y: cy, width: 40, height: 22)
        blendLeftField.font = RetroTheme.numberFont(size: 12)
        blendLeftField.backgroundColor = RetroTheme.backgroundInput
        blendLeftField.textColor = RetroTheme.neonOrange
        blendLeftField.isEnabled = false
        blendLeftField.placeholderString = "0"
        blendLeftField.target = self
        blendLeftField.action = #selector(edgeBlendChanged(_:))
        configBox.addSubview(blendLeftField)

        blendLeftStepper = NSStepper()
        blendLeftStepper.frame = NSRect(x: 77, y: cy, width: 15, height: 22)
        blendLeftStepper.minValue = 0
        blendLeftStepper.maxValue = 1000
        blendLeftStepper.increment = 1
        blendLeftStepper.valueWraps = false
        blendLeftStepper.isEnabled = false
        blendLeftStepper.target = self
        blendLeftStepper.action = #selector(blendLeftStepperChanged(_:))
        configBox.addSubview(blendLeftStepper)

        let rightLabel = RetroTheme.makeLabel("R:", style: .header, size: 11, color: RetroTheme.neonOrange)
        rightLabel.frame = NSRect(x: 97, y: cy + 2, width: 20, height: 14)
        configBox.addSubview(rightLabel)

        blendRightField = NSTextField(string: "0")
        blendRightField.frame = NSRect(x: 115, y: cy, width: 40, height: 22)
        blendRightField.font = RetroTheme.numberFont(size: 12)
        blendRightField.backgroundColor = RetroTheme.backgroundInput
        blendRightField.textColor = RetroTheme.neonOrange
        blendRightField.isEnabled = false
        blendRightField.placeholderString = "0"
        blendRightField.target = self
        blendRightField.action = #selector(edgeBlendChanged(_:))
        configBox.addSubview(blendRightField)

        blendRightStepper = NSStepper()
        blendRightStepper.frame = NSRect(x: 157, y: cy, width: 15, height: 22)
        blendRightStepper.minValue = 0
        blendRightStepper.maxValue = 1000
        blendRightStepper.increment = 1
        blendRightStepper.valueWraps = false
        blendRightStepper.isEnabled = false
        blendRightStepper.target = self
        blendRightStepper.action = #selector(blendRightStepperChanged(_:))
        configBox.addSubview(blendRightStepper)

        // Buttons row: Auto | Reset | Reset All
        let autoBtn = NSButton(title: "AUTO", target: self, action: #selector(autoDetectEdgeBlend))
        autoBtn.bezelStyle = .rounded
        autoBtn.frame = NSRect(x: 175, y: cy - 1, width: 45, height: 22)
        autoBtn.font = RetroTheme.headerFont(size: 8)
        RetroTheme.styleButton(autoBtn, color: RetroTheme.neonCyan)
        configBox.addSubview(autoBtn)

        let resetBtn = NSButton(title: "0", target: self, action: #selector(resetEdgeBlend))
        resetBtn.bezelStyle = .rounded
        resetBtn.frame = NSRect(x: 222, y: cy - 1, width: 22, height: 22)
        resetBtn.font = RetroTheme.headerFont(size: 9)
        resetBtn.toolTip = "Reset selected output edge blend to 0"
        RetroTheme.styleButton(resetBtn, color: RetroTheme.textSecondary)
        configBox.addSubview(resetBtn)

        let resetAllBtn = NSButton(title: "0▪︎ALL", target: self, action: #selector(resetAllEdgeBlend))
        resetAllBtn.bezelStyle = .rounded
        resetAllBtn.frame = NSRect(x: 246, y: cy - 1, width: 45, height: 22)
        resetAllBtn.font = RetroTheme.headerFont(size: 8)
        resetAllBtn.toolTip = "Reset ALL outputs edge blend to 0"
        RetroTheme.styleButton(resetAllBtn, color: RetroTheme.textSecondary)
        configBox.addSubview(resetAllBtn)
        cy -= 28

        // Top/Bottom row
        let topLabel = RetroTheme.makeLabel("T:", style: .header, size: 11, color: RetroTheme.neonOrange)
        topLabel.frame = NSRect(x: 12, y: cy + 2, width: 20, height: 14)
        configBox.addSubview(topLabel)

        blendTopField = NSTextField(string: "0")
        blendTopField.frame = NSRect(x: 35, y: cy, width: 40, height: 22)
        blendTopField.font = RetroTheme.numberFont(size: 12)
        blendTopField.backgroundColor = RetroTheme.backgroundInput
        blendTopField.textColor = RetroTheme.neonOrange
        blendTopField.isEnabled = false
        blendTopField.placeholderString = "0"
        blendTopField.target = self
        blendTopField.action = #selector(edgeBlendChanged(_:))
        configBox.addSubview(blendTopField)

        blendTopStepper = NSStepper()
        blendTopStepper.frame = NSRect(x: 77, y: cy, width: 15, height: 22)
        blendTopStepper.minValue = 0
        blendTopStepper.maxValue = 1000
        blendTopStepper.increment = 1
        blendTopStepper.valueWraps = false
        blendTopStepper.isEnabled = false
        blendTopStepper.target = self
        blendTopStepper.action = #selector(blendTopStepperChanged(_:))
        configBox.addSubview(blendTopStepper)

        let bottomLabel = RetroTheme.makeLabel("B:", style: .header, size: 11, color: RetroTheme.neonOrange)
        bottomLabel.frame = NSRect(x: 97, y: cy + 2, width: 20, height: 14)
        configBox.addSubview(bottomLabel)

        blendBottomField = NSTextField(string: "0")
        blendBottomField.frame = NSRect(x: 115, y: cy, width: 40, height: 22)
        blendBottomField.font = RetroTheme.numberFont(size: 12)
        blendBottomField.backgroundColor = RetroTheme.backgroundInput
        blendBottomField.textColor = RetroTheme.neonOrange
        blendBottomField.isEnabled = false
        blendBottomField.placeholderString = "0"
        blendBottomField.target = self
        blendBottomField.action = #selector(edgeBlendChanged(_:))
        configBox.addSubview(blendBottomField)

        blendBottomStepper = NSStepper()
        blendBottomStepper.frame = NSRect(x: 157, y: cy, width: 15, height: 22)
        blendBottomStepper.minValue = 0
        blendBottomStepper.maxValue = 1000
        blendBottomStepper.increment = 1
        blendBottomStepper.valueWraps = false
        blendBottomStepper.isEnabled = false
        blendBottomStepper.target = self
        blendBottomStepper.action = #selector(blendBottomStepperChanged(_:))
        configBox.addSubview(blendBottomStepper)
        cy -= 30

        // === QUAD WARP (KEYSTONE) SECTION ===
        let warpHeader = RetroTheme.makeLabel("◆ WARP", style: .header, size: 9, color: RetroTheme.neonPurple)
        warpHeader.frame = NSRect(x: 12, y: cy, width: 50, height: 14)
        configBox.addSubview(warpHeader)

        let warpEditBtn = NSButton(title: "EDIT", target: self, action: #selector(openWarpEditor))
        warpEditBtn.bezelStyle = .rounded
        warpEditBtn.frame = NSRect(x: 65, y: cy - 2, width: 50, height: 18)
        warpEditBtn.font = RetroTheme.headerFont(size: 9)
        RetroTheme.styleButton(warpEditBtn, color: RetroTheme.neonCyan)
        configBox.addSubview(warpEditBtn)

        let warpResetBtn = NSButton(title: "RESET", target: self, action: #selector(resetQuadWarp))
        warpResetBtn.bezelStyle = .rounded
        warpResetBtn.frame = NSRect(x: 118, y: cy - 2, width: 55, height: 18)
        warpResetBtn.font = RetroTheme.headerFont(size: 9)
        RetroTheme.styleButton(warpResetBtn, color: RetroTheme.textSecondary)
        configBox.addSubview(warpResetBtn)

        // Corner popup toggle checkbox - styled like other checkboxes
        cornerPopupToggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCornerPopup(_:)))
        cornerPopupToggle?.frame = NSRect(x: 243, y: cy - 1, width: 18, height: 18)
        cornerPopupToggle?.state = cornerPopupEnabled ? .on : .off
        if let toggle = cornerPopupToggle {
            configBox.addSubview(toggle)
        }
        // Label for the checkbox
        let popupLabel = RetroTheme.makeLabel("POP", style: .header, size: 8, color: RetroTheme.neonPurple)
        popupLabel.frame = NSRect(x: 261, y: cy, width: 30, height: 14)
        configBox.addSubview(popupLabel)
        cy -= 22

        // Top Left / Top Right row
        let tlLabel = RetroTheme.makeLabel("TL:", style: .header, size: 9, color: RetroTheme.neonPurple)
        tlLabel.frame = NSRect(x: 12, y: cy + 2, width: 22, height: 14)
        configBox.addSubview(tlLabel)

        warpTLXField = NSTextField(string: "0")
        warpTLXField.frame = NSRect(x: 34, y: cy, width: 30, height: 20)
        warpTLXField.font = RetroTheme.numberFont(size: 10)
        warpTLXField.backgroundColor = RetroTheme.backgroundInput
        warpTLXField.textColor = RetroTheme.neonPurple
        warpTLXField.isEnabled = false
        warpTLXField.target = self
        warpTLXField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpTLXField)

        warpTLXStepper = NSStepper()
        warpTLXStepper.frame = NSRect(x: 64, y: cy, width: 15, height: 20)
        warpTLXStepper.minValue = -500
        warpTLXStepper.maxValue = 500
        warpTLXStepper.increment = 1
        warpTLXStepper.valueWraps = false
        warpTLXStepper.isEnabled = false
        warpTLXStepper.target = self
        warpTLXStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpTLXStepper)

        warpTLYField = NSTextField(string: "0")
        warpTLYField.frame = NSRect(x: 80, y: cy, width: 30, height: 20)
        warpTLYField.font = RetroTheme.numberFont(size: 10)
        warpTLYField.backgroundColor = RetroTheme.backgroundInput
        warpTLYField.textColor = RetroTheme.neonPurple
        warpTLYField.isEnabled = false
        warpTLYField.target = self
        warpTLYField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpTLYField)

        warpTLYStepper = NSStepper()
        warpTLYStepper.frame = NSRect(x: 110, y: cy, width: 15, height: 20)
        warpTLYStepper.minValue = -500
        warpTLYStepper.maxValue = 500
        warpTLYStepper.increment = 1
        warpTLYStepper.valueWraps = false
        warpTLYStepper.isEnabled = false
        warpTLYStepper.target = self
        warpTLYStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpTLYStepper)

        let trLabel = RetroTheme.makeLabel("TR:", style: .header, size: 9, color: RetroTheme.neonPurple)
        trLabel.frame = NSRect(x: 135, y: cy + 2, width: 22, height: 14)
        configBox.addSubview(trLabel)

        warpTRXField = NSTextField(string: "0")
        warpTRXField.frame = NSRect(x: 157, y: cy, width: 30, height: 20)
        warpTRXField.font = RetroTheme.numberFont(size: 10)
        warpTRXField.backgroundColor = RetroTheme.backgroundInput
        warpTRXField.textColor = RetroTheme.neonPurple
        warpTRXField.isEnabled = false
        warpTRXField.target = self
        warpTRXField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpTRXField)

        warpTRXStepper = NSStepper()
        warpTRXStepper.frame = NSRect(x: 187, y: cy, width: 15, height: 20)
        warpTRXStepper.minValue = -500
        warpTRXStepper.maxValue = 500
        warpTRXStepper.increment = 1
        warpTRXStepper.valueWraps = false
        warpTRXStepper.isEnabled = false
        warpTRXStepper.target = self
        warpTRXStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpTRXStepper)

        warpTRYField = NSTextField(string: "0")
        warpTRYField.frame = NSRect(x: 203, y: cy, width: 30, height: 20)
        warpTRYField.font = RetroTheme.numberFont(size: 10)
        warpTRYField.backgroundColor = RetroTheme.backgroundInput
        warpTRYField.textColor = RetroTheme.neonPurple
        warpTRYField.isEnabled = false
        warpTRYField.target = self
        warpTRYField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpTRYField)

        warpTRYStepper = NSStepper()
        warpTRYStepper.frame = NSRect(x: 233, y: cy, width: 15, height: 20)
        warpTRYStepper.minValue = -500
        warpTRYStepper.maxValue = 500
        warpTRYStepper.increment = 1
        warpTRYStepper.valueWraps = false
        warpTRYStepper.isEnabled = false
        warpTRYStepper.target = self
        warpTRYStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpTRYStepper)
        cy -= 24

        // Bottom Left / Bottom Right row
        let blLabel = RetroTheme.makeLabel("BL:", style: .header, size: 9, color: RetroTheme.neonPurple)
        blLabel.frame = NSRect(x: 12, y: cy + 2, width: 22, height: 14)
        configBox.addSubview(blLabel)

        warpBLXField = NSTextField(string: "0")
        warpBLXField.frame = NSRect(x: 34, y: cy, width: 30, height: 20)
        warpBLXField.font = RetroTheme.numberFont(size: 10)
        warpBLXField.backgroundColor = RetroTheme.backgroundInput
        warpBLXField.textColor = RetroTheme.neonPurple
        warpBLXField.isEnabled = false
        warpBLXField.target = self
        warpBLXField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpBLXField)

        warpBLXStepper = NSStepper()
        warpBLXStepper.frame = NSRect(x: 64, y: cy, width: 15, height: 20)
        warpBLXStepper.minValue = -500
        warpBLXStepper.maxValue = 500
        warpBLXStepper.increment = 1
        warpBLXStepper.valueWraps = false
        warpBLXStepper.isEnabled = false
        warpBLXStepper.target = self
        warpBLXStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpBLXStepper)

        warpBLYField = NSTextField(string: "0")
        warpBLYField.frame = NSRect(x: 80, y: cy, width: 30, height: 20)
        warpBLYField.font = RetroTheme.numberFont(size: 10)
        warpBLYField.backgroundColor = RetroTheme.backgroundInput
        warpBLYField.textColor = RetroTheme.neonPurple
        warpBLYField.isEnabled = false
        warpBLYField.target = self
        warpBLYField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpBLYField)

        warpBLYStepper = NSStepper()
        warpBLYStepper.frame = NSRect(x: 110, y: cy, width: 15, height: 20)
        warpBLYStepper.minValue = -500
        warpBLYStepper.maxValue = 500
        warpBLYStepper.increment = 1
        warpBLYStepper.valueWraps = false
        warpBLYStepper.isEnabled = false
        warpBLYStepper.target = self
        warpBLYStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpBLYStepper)

        let brLabel = RetroTheme.makeLabel("BR:", style: .header, size: 9, color: RetroTheme.neonPurple)
        brLabel.frame = NSRect(x: 135, y: cy + 2, width: 22, height: 14)
        configBox.addSubview(brLabel)

        warpBRXField = NSTextField(string: "0")
        warpBRXField.frame = NSRect(x: 157, y: cy, width: 30, height: 20)
        warpBRXField.font = RetroTheme.numberFont(size: 10)
        warpBRXField.backgroundColor = RetroTheme.backgroundInput
        warpBRXField.textColor = RetroTheme.neonPurple
        warpBRXField.isEnabled = false
        warpBRXField.target = self
        warpBRXField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpBRXField)

        warpBRXStepper = NSStepper()
        warpBRXStepper.frame = NSRect(x: 187, y: cy, width: 15, height: 20)
        warpBRXStepper.minValue = -500
        warpBRXStepper.maxValue = 500
        warpBRXStepper.increment = 1
        warpBRXStepper.valueWraps = false
        warpBRXStepper.isEnabled = false
        warpBRXStepper.target = self
        warpBRXStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpBRXStepper)

        warpBRYField = NSTextField(string: "0")
        warpBRYField.frame = NSRect(x: 203, y: cy, width: 30, height: 20)
        warpBRYField.font = RetroTheme.numberFont(size: 10)
        warpBRYField.backgroundColor = RetroTheme.backgroundInput
        warpBRYField.textColor = RetroTheme.neonPurple
        warpBRYField.isEnabled = false
        warpBRYField.target = self
        warpBRYField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpBRYField)

        warpBRYStepper = NSStepper()
        warpBRYStepper.frame = NSRect(x: 233, y: cy, width: 15, height: 20)
        warpBRYStepper.minValue = -500
        warpBRYStepper.maxValue = 500
        warpBRYStepper.increment = 1
        warpBRYStepper.valueWraps = false
        warpBRYStepper.isEnabled = false
        warpBRYStepper.target = self
        warpBRYStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpBRYStepper)

        // XY labels
        let xyLabel1 = RetroTheme.makeLabel("X      Y", style: .body, size: 7, color: RetroTheme.textDisabled)
        xyLabel1.frame = NSRect(x: 34, y: cy - 12, width: 80, height: 10)
        configBox.addSubview(xyLabel1)

        let xyLabel2 = RetroTheme.makeLabel("X      Y", style: .body, size: 7, color: RetroTheme.textDisabled)
        xyLabel2.frame = NSRect(x: 157, y: cy - 12, width: 80, height: 10)
        configBox.addSubview(xyLabel2)
        cy -= 30

        // === MIDDLE POINTS (for sphere/curved surface mapping) ===
        middleWarpControls = []  // Reset array

        showMiddlesCheckbox = NSButton(checkboxWithTitle: "◇ MIDDLES (curved)", target: self, action: #selector(toggleMiddleWarpControls(_:)))
        showMiddlesCheckbox.frame = NSRect(x: 10, y: cy - 2, width: 150, height: 18)
        showMiddlesCheckbox.font = RetroTheme.headerFont(size: 8)
        showMiddlesCheckbox.state = .off
        showMiddlesCheckbox.isEnabled = false
        (showMiddlesCheckbox.cell as? NSButtonCell)?.attributedTitle = NSAttributedString(
            string: "◇ MIDDLES (curved)",
            attributes: [
                .foregroundColor: RetroTheme.neonPurple.withAlphaComponent(0.7),
                .font: RetroTheme.headerFont(size: 8)
            ]
        )
        configBox.addSubview(showMiddlesCheckbox)
        cy -= 20

        // Top Middle / Bottom Middle row
        let tmLabel = RetroTheme.makeLabel("TM:", style: .header, size: 9, color: RetroTheme.neonPurple)
        tmLabel.frame = NSRect(x: 12, y: cy + 2, width: 22, height: 14)
        configBox.addSubview(tmLabel)

        warpTMXField = NSTextField(string: "0")
        warpTMXField.frame = NSRect(x: 34, y: cy, width: 30, height: 20)
        warpTMXField.font = RetroTheme.numberFont(size: 10)
        warpTMXField.backgroundColor = RetroTheme.backgroundInput
        warpTMXField.textColor = RetroTheme.neonPurple
        warpTMXField.isEnabled = false
        warpTMXField.target = self
        warpTMXField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpTMXField)

        warpTMXStepper = NSStepper()
        warpTMXStepper.frame = NSRect(x: 64, y: cy, width: 15, height: 20)
        warpTMXStepper.minValue = -500
        warpTMXStepper.maxValue = 500
        warpTMXStepper.increment = 1
        warpTMXStepper.valueWraps = false
        warpTMXStepper.isEnabled = false
        warpTMXStepper.target = self
        warpTMXStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpTMXStepper)

        warpTMYField = NSTextField(string: "0")
        warpTMYField.frame = NSRect(x: 80, y: cy, width: 30, height: 20)
        warpTMYField.font = RetroTheme.numberFont(size: 10)
        warpTMYField.backgroundColor = RetroTheme.backgroundInput
        warpTMYField.textColor = RetroTheme.neonPurple
        warpTMYField.isEnabled = false
        warpTMYField.target = self
        warpTMYField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpTMYField)

        warpTMYStepper = NSStepper()
        warpTMYStepper.frame = NSRect(x: 110, y: cy, width: 15, height: 20)
        warpTMYStepper.minValue = -500
        warpTMYStepper.maxValue = 500
        warpTMYStepper.increment = 1
        warpTMYStepper.valueWraps = false
        warpTMYStepper.isEnabled = false
        warpTMYStepper.target = self
        warpTMYStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpTMYStepper)

        let bmLabel = RetroTheme.makeLabel("BM:", style: .header, size: 9, color: RetroTheme.neonPurple)
        bmLabel.frame = NSRect(x: 135, y: cy + 2, width: 22, height: 14)
        configBox.addSubview(bmLabel)

        warpBMXField = NSTextField(string: "0")
        warpBMXField.frame = NSRect(x: 157, y: cy, width: 30, height: 20)
        warpBMXField.font = RetroTheme.numberFont(size: 10)
        warpBMXField.backgroundColor = RetroTheme.backgroundInput
        warpBMXField.textColor = RetroTheme.neonPurple
        warpBMXField.isEnabled = false
        warpBMXField.target = self
        warpBMXField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpBMXField)

        warpBMXStepper = NSStepper()
        warpBMXStepper.frame = NSRect(x: 187, y: cy, width: 15, height: 20)
        warpBMXStepper.minValue = -500
        warpBMXStepper.maxValue = 500
        warpBMXStepper.increment = 1
        warpBMXStepper.valueWraps = false
        warpBMXStepper.isEnabled = false
        warpBMXStepper.target = self
        warpBMXStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpBMXStepper)

        warpBMYField = NSTextField(string: "0")
        warpBMYField.frame = NSRect(x: 203, y: cy, width: 30, height: 20)
        warpBMYField.font = RetroTheme.numberFont(size: 10)
        warpBMYField.backgroundColor = RetroTheme.backgroundInput
        warpBMYField.textColor = RetroTheme.neonPurple
        warpBMYField.isEnabled = false
        warpBMYField.target = self
        warpBMYField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpBMYField)

        warpBMYStepper = NSStepper()
        warpBMYStepper.frame = NSRect(x: 233, y: cy, width: 15, height: 20)
        warpBMYStepper.minValue = -500
        warpBMYStepper.maxValue = 500
        warpBMYStepper.increment = 1
        warpBMYStepper.valueWraps = false
        warpBMYStepper.isEnabled = false
        warpBMYStepper.target = self
        warpBMYStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpBMYStepper)
        cy -= 24

        // Middle Left / Middle Right row
        let mlLabel = RetroTheme.makeLabel("ML:", style: .header, size: 9, color: RetroTheme.neonPurple)
        mlLabel.frame = NSRect(x: 12, y: cy + 2, width: 22, height: 14)
        configBox.addSubview(mlLabel)

        warpMLXField = NSTextField(string: "0")
        warpMLXField.frame = NSRect(x: 34, y: cy, width: 30, height: 20)
        warpMLXField.font = RetroTheme.numberFont(size: 10)
        warpMLXField.backgroundColor = RetroTheme.backgroundInput
        warpMLXField.textColor = RetroTheme.neonPurple
        warpMLXField.isEnabled = false
        warpMLXField.target = self
        warpMLXField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpMLXField)

        warpMLXStepper = NSStepper()
        warpMLXStepper.frame = NSRect(x: 64, y: cy, width: 15, height: 20)
        warpMLXStepper.minValue = -500
        warpMLXStepper.maxValue = 500
        warpMLXStepper.increment = 1
        warpMLXStepper.valueWraps = false
        warpMLXStepper.isEnabled = false
        warpMLXStepper.target = self
        warpMLXStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpMLXStepper)

        warpMLYField = NSTextField(string: "0")
        warpMLYField.frame = NSRect(x: 80, y: cy, width: 30, height: 20)
        warpMLYField.font = RetroTheme.numberFont(size: 10)
        warpMLYField.backgroundColor = RetroTheme.backgroundInput
        warpMLYField.textColor = RetroTheme.neonPurple
        warpMLYField.isEnabled = false
        warpMLYField.target = self
        warpMLYField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpMLYField)

        warpMLYStepper = NSStepper()
        warpMLYStepper.frame = NSRect(x: 110, y: cy, width: 15, height: 20)
        warpMLYStepper.minValue = -500
        warpMLYStepper.maxValue = 500
        warpMLYStepper.increment = 1
        warpMLYStepper.valueWraps = false
        warpMLYStepper.isEnabled = false
        warpMLYStepper.target = self
        warpMLYStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpMLYStepper)

        let mrLabel = RetroTheme.makeLabel("MR:", style: .header, size: 9, color: RetroTheme.neonPurple)
        mrLabel.frame = NSRect(x: 135, y: cy + 2, width: 22, height: 14)
        configBox.addSubview(mrLabel)

        warpMRXField = NSTextField(string: "0")
        warpMRXField.frame = NSRect(x: 157, y: cy, width: 30, height: 20)
        warpMRXField.font = RetroTheme.numberFont(size: 10)
        warpMRXField.backgroundColor = RetroTheme.backgroundInput
        warpMRXField.textColor = RetroTheme.neonPurple
        warpMRXField.isEnabled = false
        warpMRXField.target = self
        warpMRXField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpMRXField)

        warpMRXStepper = NSStepper()
        warpMRXStepper.frame = NSRect(x: 187, y: cy, width: 15, height: 20)
        warpMRXStepper.minValue = -500
        warpMRXStepper.maxValue = 500
        warpMRXStepper.increment = 1
        warpMRXStepper.valueWraps = false
        warpMRXStepper.isEnabled = false
        warpMRXStepper.target = self
        warpMRXStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpMRXStepper)

        warpMRYField = NSTextField(string: "0")
        warpMRYField.frame = NSRect(x: 203, y: cy, width: 30, height: 20)
        warpMRYField.font = RetroTheme.numberFont(size: 10)
        warpMRYField.backgroundColor = RetroTheme.backgroundInput
        warpMRYField.textColor = RetroTheme.neonPurple
        warpMRYField.isEnabled = false
        warpMRYField.target = self
        warpMRYField.action = #selector(warpChanged(_:))
        configBox.addSubview(warpMRYField)

        warpMRYStepper = NSStepper()
        warpMRYStepper.frame = NSRect(x: 233, y: cy, width: 15, height: 20)
        warpMRYStepper.minValue = -500
        warpMRYStepper.maxValue = 500
        warpMRYStepper.increment = 1
        warpMRYStepper.valueWraps = false
        warpMRYStepper.isEnabled = false
        warpMRYStepper.target = self
        warpMRYStepper.action = #selector(warpStepperChanged(_:))
        configBox.addSubview(warpMRYStepper)

        // Add all middle controls to the array for toggling
        middleWarpControls = [
            tmLabel, warpTMXField, warpTMXStepper, warpTMYField, warpTMYStepper,
            bmLabel, warpBMXField, warpBMXStepper, warpBMYField, warpBMYStepper,
            mlLabel, warpMLXField, warpMLXStepper, warpMLYField, warpMLYStepper,
            mrLabel, warpMRXField, warpMRXStepper, warpMRYField, warpMRYStepper
        ]
        // Hide all middle controls by default
        for control in middleWarpControls {
            control.isHidden = true
        }
        cy -= 30

        // === LENS CORRECTION (PINCUSHION/BARREL) SECTION ===
        let lensHeader = RetroTheme.makeLabel("◆ LENS CORRECTION", style: .header, size: 9, color: RetroTheme.neonCyan)
        lensHeader.frame = NSRect(x: 12, y: cy, width: 150, height: 14)
        configBox.addSubview(lensHeader)

        let lensResetBtn = NSButton(title: "RESET", target: self, action: #selector(resetLensCorrection))
        lensResetBtn.bezelStyle = .rounded
        lensResetBtn.frame = NSRect(x: 225, y: cy - 2, width: 55, height: 18)
        lensResetBtn.font = RetroTheme.headerFont(size: 8)
        RetroTheme.styleButton(lensResetBtn, color: RetroTheme.textSecondary)
        configBox.addSubview(lensResetBtn)
        cy -= 22

        // K1 slider row
        let k1Label = RetroTheme.makeLabel("K1", style: .header, size: 9, color: RetroTheme.neonCyan)
        k1Label.frame = NSRect(x: 12, y: cy + 2, width: 20, height: 14)
        configBox.addSubview(k1Label)

        lensK1Slider = NSSlider(value: 0, minValue: -0.5, maxValue: 0.5, target: self, action: #selector(lensSliderChanged(_:)))
        lensK1Slider.frame = NSRect(x: 32, y: cy, width: 160, height: 20)
        lensK1Slider.isEnabled = false
        configBox.addSubview(lensK1Slider)

        lensK1Field = NSTextField(string: "0.00")
        lensK1Field.frame = NSRect(x: 195, y: cy, width: 45, height: 20)
        lensK1Field.font = RetroTheme.numberFont(size: 10)
        lensK1Field.backgroundColor = RetroTheme.backgroundInput
        lensK1Field.textColor = RetroTheme.neonCyan
        lensK1Field.isEnabled = false
        lensK1Field.target = self
        lensK1Field.action = #selector(lensFieldChanged(_:))
        configBox.addSubview(lensK1Field)

        lensK1Stepper = NSStepper()
        lensK1Stepper.frame = NSRect(x: 242, y: cy, width: 15, height: 20)
        lensK1Stepper.minValue = -0.5
        lensK1Stepper.maxValue = 0.5
        lensK1Stepper.increment = 0.01
        lensK1Stepper.valueWraps = false
        lensK1Stepper.isEnabled = false
        lensK1Stepper.target = self
        lensK1Stepper.action = #selector(lensStepperChanged(_:))
        configBox.addSubview(lensK1Stepper)
        cy -= 24

        // K2 slider row
        let k2Label = RetroTheme.makeLabel("K2", style: .header, size: 9, color: RetroTheme.neonCyan)
        k2Label.frame = NSRect(x: 12, y: cy + 2, width: 20, height: 14)
        configBox.addSubview(k2Label)

        lensK2Slider = NSSlider(value: 0, minValue: -0.5, maxValue: 0.5, target: self, action: #selector(lensSliderChanged(_:)))
        lensK2Slider.frame = NSRect(x: 32, y: cy, width: 160, height: 20)
        lensK2Slider.isEnabled = false
        configBox.addSubview(lensK2Slider)

        lensK2Field = NSTextField(string: "0.00")
        lensK2Field.frame = NSRect(x: 195, y: cy, width: 45, height: 20)
        lensK2Field.font = RetroTheme.numberFont(size: 10)
        lensK2Field.backgroundColor = RetroTheme.backgroundInput
        lensK2Field.textColor = RetroTheme.neonCyan
        lensK2Field.isEnabled = false
        lensK2Field.target = self
        lensK2Field.action = #selector(lensFieldChanged(_:))
        configBox.addSubview(lensK2Field)

        lensK2Stepper = NSStepper()
        lensK2Stepper.frame = NSRect(x: 242, y: cy, width: 15, height: 20)
        lensK2Stepper.minValue = -0.5
        lensK2Stepper.maxValue = 0.5
        lensK2Stepper.increment = 0.01
        lensK2Stepper.valueWraps = false
        lensK2Stepper.isEnabled = false
        lensK2Stepper.target = self
        lensK2Stepper.action = #selector(lensStepperChanged(_:))
        configBox.addSubview(lensK2Stepper)

        // Help text
        let lensHelp = RetroTheme.makeLabel("(-) BARREL  |  (+) PINCUSHION", style: .body, size: 7, color: RetroTheme.textDisabled)
        lensHelp.frame = NSRect(x: 32, y: cy - 12, width: 200, height: 10)
        configBox.addSubview(lensHelp)
        cy -= 30

        // Warp Curvature section header
        let curvatureHeader = RetroTheme.makeLabel("▸ CURVE WARP (SPHERE)", style: .header, size: 10, color: RetroTheme.neonGreen)
        curvatureHeader.frame = NSRect(x: 12, y: cy, width: 200, height: 16)
        configBox.addSubview(curvatureHeader)

        let curvatureResetBtn = NSButton(title: "RESET", target: self, action: #selector(resetCurvature))
        curvatureResetBtn.bezelStyle = .rounded
        curvatureResetBtn.frame = NSRect(x: 225, y: cy - 2, width: 55, height: 18)
        curvatureResetBtn.font = RetroTheme.headerFont(size: 8)
        RetroTheme.styleButton(curvatureResetBtn, color: RetroTheme.textSecondary)
        configBox.addSubview(curvatureResetBtn)
        cy -= 22

        // Curvature slider row
        let curveLabel = RetroTheme.makeLabel("CURVE", style: .header, size: 9, color: RetroTheme.neonGreen)
        curveLabel.frame = NSRect(x: 12, y: cy + 2, width: 40, height: 14)
        configBox.addSubview(curveLabel)

        curvatureSlider = NSSlider(value: 0, minValue: -1.0, maxValue: 1.0, target: self, action: #selector(curvatureSliderChanged(_:)))
        curvatureSlider.frame = NSRect(x: 52, y: cy, width: 140, height: 20)
        curvatureSlider.isEnabled = false
        configBox.addSubview(curvatureSlider)

        curvatureField = NSTextField(string: "0.00")
        curvatureField.frame = NSRect(x: 195, y: cy, width: 45, height: 20)
        curvatureField.font = RetroTheme.numberFont(size: 10)
        curvatureField.backgroundColor = RetroTheme.backgroundInput
        curvatureField.textColor = RetroTheme.neonGreen
        curvatureField.isEnabled = false
        curvatureField.target = self
        curvatureField.action = #selector(curvatureFieldChanged(_:))
        configBox.addSubview(curvatureField)

        curvatureStepper = NSStepper()
        curvatureStepper.frame = NSRect(x: 242, y: cy, width: 15, height: 20)
        curvatureStepper.minValue = -1.0
        curvatureStepper.maxValue = 1.0
        curvatureStepper.increment = 0.05
        curvatureStepper.valueWraps = false
        curvatureStepper.isEnabled = false
        curvatureStepper.target = self
        curvatureStepper.action = #selector(curvatureStepperChanged(_:))
        configBox.addSubview(curvatureStepper)

        // Help text
        let curveHelp = RetroTheme.makeLabel("(-) CONCAVE  |  (+) CONVEX", style: .body, size: 7, color: RetroTheme.textDisabled)
        curveHelp.frame = NSRect(x: 52, y: cy - 12, width: 200, height: 10)
        configBox.addSubview(curveHelp)
        cy -= 30

        // Neon separator line
        let sep = NSView(frame: NSRect(x: 12, y: cy + 5, width: 270, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = RetroTheme.borderDefault.cgColor
        configBox.addSubview(sep)
        cy -= 15

        // Remove button with neon red styling
        removeOutputBtn = NSButton(title: "✕ REMOVE OUTPUT", target: self, action: #selector(removeSelectedOutput))
        removeOutputBtn.bezelStyle = .rounded
        removeOutputBtn.frame = NSRect(x: 12, y: cy - 20, width: 140, height: 26)
        removeOutputBtn.font = RetroTheme.headerFont(size: 10)
        removeOutputBtn.isEnabled = false
        RetroTheme.styleButton(removeOutputBtn, color: RetroTheme.neonRed)
        configBox.addSubview(removeOutputBtn)

        return panel
    }

    private func makeInputScalingBox() -> NSView {
        let box = NSView()
        RetroTheme.styleCard(box, cornerRadius: 6)
        RetroTheme.applyNeonBorder(to: box.layer!, color: RetroTheme.sectionScale.withAlphaComponent(0.3), width: 1)

        let scaleLabel = RetroTheme.makeLabel("SCALE %", style: .header, size: 9, color: RetroTheme.neonGreen)
        scaleLabel.frame = NSRect(x: 15, y: 42, width: 60, height: 14)
        box.addSubview(scaleLabel)

        scaleField = NSTextField(string: "100")
        scaleField.frame = NSRect(x: 15, y: 18, width: 80, height: 22)
        scaleField.font = RetroTheme.numberFont(size: 14)
        scaleField.backgroundColor = RetroTheme.backgroundInput
        scaleField.textColor = RetroTheme.neonPurple
        box.addSubview(scaleField)

        let panXLabel = RetroTheme.makeLabel("PAN X (PX)", style: .header, size: 9, color: RetroTheme.neonGreen)
        panXLabel.frame = NSRect(x: 115, y: 42, width: 70, height: 14)
        box.addSubview(panXLabel)

        panXField = NSTextField(string: "0")
        panXField.frame = NSRect(x: 115, y: 18, width: 80, height: 22)
        panXField.font = RetroTheme.numberFont(size: 14)
        panXField.backgroundColor = RetroTheme.backgroundInput
        panXField.textColor = RetroTheme.neonPurple
        box.addSubview(panXField)

        let panYLabel = RetroTheme.makeLabel("PAN Y (PX)", style: .header, size: 9, color: RetroTheme.neonGreen)
        panYLabel.frame = NSRect(x: 215, y: 42, width: 70, height: 14)
        box.addSubview(panYLabel)

        panYField = NSTextField(string: "0")
        panYField.frame = NSRect(x: 215, y: 18, width: 80, height: 22)
        panYField.font = RetroTheme.numberFont(size: 14)
        panYField.backgroundColor = RetroTheme.backgroundInput
        panYField.textColor = RetroTheme.neonPurple
        box.addSubview(panYField)

        // Help text
        let helpText = RetroTheme.makeLabel("100% = FILL | >100% = ZOOM IN | <100% = LETTERBOX | PAN = OFFSET VIEW", style: .body, size: 8, color: RetroTheme.textDisabled)
        helpText.frame = NSRect(x: 15, y: 2, width: 530, height: 12)
        box.addSubview(helpText)

        return box
    }

    private func makeEdgeBlendBox() -> NSView {
        let box = NSView()
        RetroTheme.styleCard(box, cornerRadius: 6)
        RetroTheme.applyNeonBorder(to: box.layer!, color: RetroTheme.sectionBlend.withAlphaComponent(0.3), width: 1)

        var y: CGFloat = 150

        blendEnabledCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(blendToggled))
        blendEnabledCheck.frame = NSRect(x: 15, y: y, width: 220, height: 18)
        blendEnabledCheck.attributedTitle = NSAttributedString(
            string: "ENABLE AUTO EDGE BLENDING",
            attributes: [
                .font: RetroTheme.headerFont(size: 10),
                .foregroundColor: RetroTheme.neonOrange
            ]
        )
        box.addSubview(blendEnabledCheck)
        y -= 30

        overlapLabel = RetroTheme.makeLabel("▸ POSITION OUTPUTS WITH OVERLAP TO SEE ZONES", style: .body, size: 9, color: RetroTheme.neonGreen)
        overlapLabel.frame = NSRect(x: 15, y: y, width: 530, height: 14)
        overlapLabel.wantsLayer = true
        overlapLabel.layer?.backgroundColor = RetroTheme.backgroundDeep.cgColor
        overlapLabel.layer?.cornerRadius = 3
        box.addSubview(overlapLabel)
        y -= 35

        // Row 1: Gamma, Power, Black Level
        let gammaLabel = RetroTheme.makeLabel("BLEND GAMMA", style: .header, size: 9, color: RetroTheme.neonOrange)
        gammaLabel.frame = NSRect(x: 15, y: y, width: 100, height: 14)
        box.addSubview(gammaLabel)

        let powerLabel = RetroTheme.makeLabel("BLEND POWER", style: .header, size: 9, color: RetroTheme.neonOrange)
        powerLabel.frame = NSRect(x: 130, y: y, width: 100, height: 14)
        box.addSubview(powerLabel)

        let blackLabel = RetroTheme.makeLabel("BLACK LEVEL %", style: .header, size: 9, color: RetroTheme.neonOrange)
        blackLabel.frame = NSRect(x: 245, y: y, width: 100, height: 14)
        box.addSubview(blackLabel)
        y -= 24

        blendGammaField = NSTextField(string: "2.2")
        blendGammaField.frame = NSRect(x: 15, y: y, width: 80, height: 22)
        blendGammaField.font = RetroTheme.numberFont(size: 14)
        blendGammaField.backgroundColor = RetroTheme.backgroundInput
        blendGammaField.textColor = RetroTheme.neonOrange
        box.addSubview(blendGammaField)

        blendPowerField = NSTextField(string: "1")
        blendPowerField.frame = NSRect(x: 130, y: y, width: 80, height: 22)
        blendPowerField.font = RetroTheme.numberFont(size: 14)
        blendPowerField.backgroundColor = RetroTheme.backgroundInput
        blendPowerField.textColor = RetroTheme.neonOrange
        box.addSubview(blendPowerField)

        blackLevelField = NSTextField(string: "0")
        blackLevelField.frame = NSRect(x: 245, y: y, width: 80, height: 22)
        blackLevelField.font = RetroTheme.numberFont(size: 14)
        blackLevelField.backgroundColor = RetroTheme.backgroundInput
        blackLevelField.textColor = RetroTheme.neonOrange
        box.addSubview(blackLevelField)
        y -= 35

        // Row 2: RGB Gamma
        let redLabel = RetroTheme.makeLabel("RED GAMMA", style: .header, size: 9, color: RetroTheme.neonRed)
        redLabel.frame = NSRect(x: 15, y: y, width: 80, height: 14)
        box.addSubview(redLabel)

        let greenLabel = RetroTheme.makeLabel("GREEN GAMMA", style: .header, size: 9, color: RetroTheme.neonGreen)
        greenLabel.frame = NSRect(x: 130, y: y, width: 90, height: 14)
        box.addSubview(greenLabel)

        let blueLabel = RetroTheme.makeLabel("BLUE GAMMA", style: .header, size: 9, color: RetroTheme.neonBlue)
        blueLabel.frame = NSRect(x: 245, y: y, width: 80, height: 14)
        box.addSubview(blueLabel)
        y -= 24

        redGammaField = NSTextField(string: "1")
        redGammaField.frame = NSRect(x: 15, y: y, width: 80, height: 22)
        redGammaField.font = RetroTheme.numberFont(size: 14)
        redGammaField.backgroundColor = RetroTheme.backgroundInput
        redGammaField.textColor = RetroTheme.neonRed
        box.addSubview(redGammaField)

        greenGammaField = NSTextField(string: "1")
        greenGammaField.frame = NSRect(x: 130, y: y, width: 80, height: 22)
        greenGammaField.font = RetroTheme.numberFont(size: 14)
        greenGammaField.backgroundColor = RetroTheme.backgroundInput
        greenGammaField.textColor = RetroTheme.neonGreen
        box.addSubview(greenGammaField)

        blueGammaField = NSTextField(string: "1")
        blueGammaField.frame = NSRect(x: 245, y: y, width: 80, height: 22)
        blueGammaField.font = RetroTheme.numberFont(size: 14)
        blueGammaField.backgroundColor = RetroTheme.backgroundInput
        blueGammaField.textColor = RetroTheme.neonBlue
        box.addSubview(blueGammaField)
        y -= 30

        // Help text
        let helpText = RetroTheme.makeLabel("AUTO-FEATHER OVERLAPS | GAMMA=BLEND CURVE | RGB=COLOR MATCH", style: .body, size: 8, color: RetroTheme.textDisabled)
        helpText.frame = NSRect(x: 15, y: 5, width: 530, height: 24)
        helpText.maximumNumberOfLines = 2
        box.addSubview(helpText)

        return box
    }

    private func makeMasterControlBox() -> NSView {
        let box = NSView()
        RetroTheme.styleCard(box, cornerRadius: 6)
        RetroTheme.applyNeonBorder(to: box.layer!, color: RetroTheme.neonMagenta.withAlphaComponent(0.3), width: 1)

        // Enable checkbox
        masterControlEnabledCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(masterControlToggled))
        masterControlEnabledCheck.frame = NSRect(x: 15, y: 25, width: 180, height: 18)
        masterControlEnabledCheck.attributedTitle = NSAttributedString(
            string: "ENABLE MASTER CONTROL",
            attributes: [
                .font: RetroTheme.headerFont(size: 10),
                .foregroundColor: RetroTheme.neonMagenta
            ]
        )
        masterControlEnabledCheck.state = UserDefaults.standard.bool(forKey: "masterControlEnabled") ? .on : .off
        box.addSubview(masterControlEnabledCheck)

        // Universe label and field
        let univLabel = RetroTheme.makeLabel("UNIVERSE", style: .header, size: 9, color: RetroTheme.neonOrange)
        univLabel.frame = NSRect(x: 220, y: 30, width: 60, height: 14)
        box.addSubview(univLabel)

        masterControlUniverseField = NSTextField(string: "\(UserDefaults.standard.integer(forKey: "masterControlUniverse"))")
        masterControlUniverseField.frame = NSRect(x: 280, y: 25, width: 50, height: 22)
        masterControlUniverseField.font = RetroTheme.numberFont(size: 14)
        masterControlUniverseField.backgroundColor = RetroTheme.backgroundInput
        masterControlUniverseField.textColor = RetroTheme.neonMagenta
        masterControlUniverseField.alignment = .center
        masterControlUniverseField.target = self
        masterControlUniverseField.action = #selector(masterControlChanged)
        box.addSubview(masterControlUniverseField)

        masterControlUniverseStepper = NSStepper()
        masterControlUniverseStepper.frame = NSRect(x: 330, y: 25, width: 16, height: 22)
        masterControlUniverseStepper.minValue = 0
        masterControlUniverseStepper.maxValue = 63999
        masterControlUniverseStepper.increment = 1
        masterControlUniverseStepper.valueWraps = false
        masterControlUniverseStepper.integerValue = UserDefaults.standard.integer(forKey: "masterControlUniverse")
        masterControlUniverseStepper.target = self
        masterControlUniverseStepper.action = #selector(masterControlUniverseStepperChanged)
        box.addSubview(masterControlUniverseStepper)

        // Address label and field
        let addrLabel = RetroTheme.makeLabel("ADDRESS", style: .header, size: 9, color: RetroTheme.neonOrange)
        addrLabel.frame = NSRect(x: 370, y: 30, width: 55, height: 14)
        box.addSubview(addrLabel)

        let addr = UserDefaults.standard.integer(forKey: "masterControlAddress")
        masterControlAddressField = NSTextField(string: "\(addr > 0 ? addr : 1)")
        masterControlAddressField.frame = NSRect(x: 425, y: 25, width: 50, height: 22)
        masterControlAddressField.font = RetroTheme.numberFont(size: 14)
        masterControlAddressField.backgroundColor = RetroTheme.backgroundInput
        masterControlAddressField.textColor = RetroTheme.neonMagenta
        masterControlAddressField.alignment = .center
        masterControlAddressField.target = self
        masterControlAddressField.action = #selector(masterControlChanged)
        box.addSubview(masterControlAddressField)

        masterControlAddressStepper = NSStepper()
        masterControlAddressStepper.frame = NSRect(x: 475, y: 25, width: 16, height: 22)
        masterControlAddressStepper.minValue = 1
        masterControlAddressStepper.maxValue = 512
        masterControlAddressStepper.increment = 1
        masterControlAddressStepper.valueWraps = false
        masterControlAddressStepper.integerValue = addr > 0 ? addr : 1
        masterControlAddressStepper.target = self
        masterControlAddressStepper.action = #selector(masterControlAddressStepperChanged)
        box.addSubview(masterControlAddressStepper)

        // Help text
        let helpText = RetroTheme.makeLabel("PATCH GEODRAW@MASTER_CONTROL_121CH ON THIS UNIVERSE/ADDRESS IN MA3", style: .body, size: 8, color: RetroTheme.textDisabled)
        helpText.frame = NSRect(x: 15, y: 5, width: 530, height: 14)
        box.addSubview(helpText)

        return box
    }

    private func makeOutputCell(index: Int) -> NSView {
        let cell = NSView()
        cell.wantsLayer = true
        cell.layer?.backgroundColor = RetroTheme.backgroundCard.cgColor
        cell.layer?.cornerRadius = 8
        cell.layer?.borderWidth = 2
        cell.layer?.borderColor = RetroTheme.borderDefault.cgColor

        // Slot number with retro styling
        let numLabel = RetroTheme.makeLabel("\(index + 1)", style: .number, size: 20, color: RetroTheme.textDisabled)
        numLabel.alignment = .center
        numLabel.frame = NSRect(x: 0, y: 22, width: 70, height: 24)
        cell.addSubview(numLabel)

        // Output name (truncated)
        let nameLabel = RetroTheme.makeLabel("—", style: .body, size: 9, color: RetroTheme.textDisabled)
        nameLabel.alignment = .center
        nameLabel.tag = 100 + index
        nameLabel.frame = NSRect(x: 4, y: 6, width: 62, height: 14)
        nameLabel.cell?.lineBreakMode = .byTruncatingTail
        cell.addSubview(nameLabel)

        // Click handler
        let click = NSClickGestureRecognizer(target: self, action: #selector(outputCellClicked(_:)))
        cell.addGestureRecognizer(click)

        return cell
    }

    private func makeLabel(_ text: String, bold: Bool, size: CGFloat, color: NSColor) -> NSTextField {
        // Legacy wrapper - prefer RetroTheme.makeLabel
        let label = NSTextField(labelWithString: text)
        label.font = bold ? RetroTheme.headerFont(size: size) : RetroTheme.bodyFont(size: size)
        label.textColor = color
        return label
    }

    // MARK: - Updates

    private func updateOutputGrid() {
        for (i, cell) in outputCells.enumerated() {
            let isSelected = (i == selectedOutputIndex)

            if i < outputs.count {
                let output = outputs[i]
                // Use neon colors for output types
                let typeColor = output.type == .NDI ? RetroTheme.neonBlue : RetroTheme.neonMagenta

                cell.layer?.backgroundColor = typeColor.withAlphaComponent(0.1).cgColor
                cell.layer?.borderWidth = isSelected ? 3 : 2
                cell.layer?.borderColor = isSelected ? RetroTheme.neonYellow.cgColor : typeColor.cgColor

                // Add glow effect when selected
                if isSelected {
                    cell.layer?.shadowColor = RetroTheme.neonYellow.cgColor
                    cell.layer?.shadowRadius = 6
                    cell.layer?.shadowOpacity = 0.8
                    cell.layer?.shadowOffset = .zero
                } else {
                    cell.layer?.shadowOpacity = 0
                }

                if let nameLabel = cell.viewWithTag(100 + i) as? NSTextField {
                    nameLabel.stringValue = output.name
                    nameLabel.textColor = RetroTheme.textPrimary
                }
            } else {
                cell.layer?.backgroundColor = RetroTheme.backgroundCard.cgColor
                cell.layer?.borderWidth = 2
                cell.layer?.borderColor = RetroTheme.borderDefault.cgColor
                cell.layer?.shadowOpacity = 0

                if let nameLabel = cell.viewWithTag(100 + i) as? NSTextField {
                    nameLabel.stringValue = "—"
                    nameLabel.textColor = .tertiaryLabelColor
                }
            }
        }
    }

    private func updateMemberOutputsList() {
        memberOutputsView.subviews.forEach { $0.removeFromSuperview() }

        // Get canvas height for output defaults
        let canvasH = Int(canvasHeightField?.stringValue ?? "1080") ?? 1080

        // Calculate X positions based on cumulative output widths (for defaults)
        var xOffset = 0
        var y: CGFloat = memberOutputsView.bounds.height - 8
        for (i, output) in outputs.enumerated() {
            y -= 28

            // Use stored positions from config if available, otherwise calculate default
            let storedX = output.config.positionX
            let storedY = output.config.positionY
            let storedW = output.config.positionW
            let storedH = output.config.positionH

            let row = makeOutputRow(
                output: output,
                index: i,
                xOffset: storedX ?? xOffset,
                yOffset: storedY ?? 0,
                width: storedW ?? Int(output.width),
                height: storedH ?? Int(output.height),  // Use output's native resolution, not canvas height
                y: y
            )
            memberOutputsView.addSubview(row)
            xOffset += Int(output.width)
        }
    }

    private func makeOutputRow(output: ManagedOutput, index: Int, xOffset: Int, yOffset: Int = 0, width: Int? = nil, height: Int? = nil, y: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 8, y: y, width: 544, height: 26))
        row.identifier = NSUserInterfaceItemIdentifier("output_row_\(index)")

        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(memberCheckboxChanged(_:)))
        check.state = .on
        check.tag = index
        check.frame = NSRect(x: 0, y: 3, width: 18, height: 18)
        row.addSubview(check)

        let name = makeLabel(output.name, bold: false, size: 11, color: .white)
        name.frame = NSRect(x: 22, y: 3, width: 120, height: 18)
        row.addSubview(name)

        // Use provided values (from stored config) or defaults
        let outputW = width ?? Int(output.width)
        let outputH = height ?? Int(output.height)

        // X, Y, W, H fields with live updates
        let fields: [(String, String, Int, String)] = [
            ("X:", "\(xOffset)", 150, "pos_x_\(index)"),
            ("Y:", "\(yOffset)", 230, "pos_y_\(index)"),
            ("W:", "\(outputW)", 310, "pos_w_\(index)"),
            ("H:", "\(outputH)", 390, "pos_h_\(index)")
        ]

        for (label, value, x, identifier) in fields {
            let lbl = makeLabel(label, bold: false, size: 10, color: .secondaryLabelColor)
            lbl.frame = NSRect(x: CGFloat(x), y: 4, width: 16, height: 16)
            row.addSubview(lbl)

            let field = NSTextField(string: value)
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            field.frame = NSRect(x: CGFloat(x + 18), y: 2, width: 55, height: 20)
            field.target = self
            field.action = #selector(positionFieldChanged(_:))
            row.addSubview(field)
        }

        return row
    }

    @objc private func memberCheckboxChanged(_ sender: NSButton) {
        updateCanvasPreview()
        updateOverlapInfo()
    }

    @objc private func positionFieldChanged(_ sender: NSTextField) {
        updateCanvasPreview()
        updateOverlapInfo()

        // Auto-save position changes
        autoSavePositions()
    }

    @objc private func canvasSizeChanged(_ sender: NSTextField) {
        let width = Int(canvasWidthField.stringValue) ?? 7680
        let height = Int(canvasHeightField.stringValue) ?? 1080

        // Save to UserDefaults immediately
        UserDefaults.standard.set(width, forKey: "canvasWidth")
        UserDefaults.standard.set(height, forKey: "canvasHeight")

        updateCanvasPreview()
        updateOverlapInfo()

        // Re-save all positions with new canvas size
        autoSavePositions()
    }

    /// Save all output positions to OutputManager
    private func autoSavePositions() {
        for (i, output) in outputs.enumerated() {
            // Read directly from UI fields to avoid circular dependency with config
            let pos = getPositionFromUIFields(index: i)
            OutputManager.shared.updatePosition(id: output.id, x: pos.x, y: pos.y, w: pos.w, h: pos.h)
        }
    }

    /// Read position directly from UI fields (bypasses config to get current UI values)
    private func getPositionFromUIFields(index: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        // Calculate defaults
        var defaultX = 0
        for i in 0..<index {
            if i < outputs.count {
                defaultX += Int(outputs[i].width)
            }
        }
        let defaultW = index < outputs.count ? Int(outputs[index].width) : 1920
        let defaultH = index < outputs.count ? Int(outputs[index].height) : 1080

        // Read from UI fields
        for subview in memberOutputsView.subviews {
            if subview.identifier?.rawValue == "output_row_\(index)" {
                var x = defaultX, y = 0, w = defaultW, h = defaultH
                for child in subview.subviews {
                    if let field = child as? NSTextField {
                        let id = field.identifier?.rawValue ?? ""
                        if id == "pos_x_\(index)" { x = Int(field.stringValue) ?? x }
                        if id == "pos_y_\(index)" { y = Int(field.stringValue) ?? y }
                        if id == "pos_w_\(index)" { w = Int(field.stringValue) ?? w }
                        if id == "pos_h_\(index)" { h = Int(field.stringValue) ?? h }
                    }
                }
                return (x, y, w, h)
            }
        }
        return (defaultX, 0, defaultW, defaultH)
    }

    /// Save position for a single output after drag
    func savePositionAfterDrag(index: Int) {
        guard index >= 0 && index < outputs.count else { return }
        let output = outputs[index]
        let pos = getPositionFromUIFields(index: index)
        OutputManager.shared.updatePosition(id: output.id, x: pos.x, y: pos.y, w: pos.w, h: pos.h)

        // Auto-update edge blend for all outputs after position change
        autoUpdateAllEdgeBlends()
    }

    /// Auto-update edge blend for all outputs based on current positions
    private func autoUpdateAllEdgeBlends() {
        // Only run if auto edge blending is enabled
        guard blendEnabledCheck.state == .on else { return }

        for (i, output) in outputs.enumerated() {
            let (left, right, top, bottom) = calculateOverlapsForOutput(i)

            OutputManager.shared.updateEdgeBlend(
                id: output.id,
                left: Float(left),
                right: Float(right),
                top: Float(top),
                bottom: Float(bottom),
                gamma: output.config.edgeBlendGamma,
                power: output.config.edgeBlendPower,
                blackLevel: output.config.edgeBlendBlackLevel
            )
        }
        // Refresh outputs to get updated values
        outputs = OutputManager.shared.getAllOutputs()

        // Update the selected output's UI fields if one is selected
        if selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count {
            let (left, right, top, bottom) = calculateOverlapsForOutput(selectedOutputIndex)
            blendLeftField?.stringValue = "\(left)"
            blendRightField?.stringValue = "\(right)"
            blendTopField?.stringValue = "\(top)"
            blendBottomField?.stringValue = "\(bottom)"

            // Sync steppers
            blendLeftStepper?.doubleValue = Double(left)
            blendRightStepper?.doubleValue = Double(right)
            blendTopStepper?.doubleValue = Double(top)
            blendBottomStepper?.doubleValue = Double(bottom)
        }
    }

    func updateCanvasPreview() {
        canvasPreview.subviews.forEach { $0.removeFromSuperview() }

        let canvasW = CGFloat(Int(canvasWidthField?.stringValue ?? "1920") ?? 1920)
        let canvasH = CGFloat(Int(canvasHeightField?.stringValue ?? "1080") ?? 1080)

        // Calculate scale to fit canvas in preview area with padding
        let previewW = canvasPreview.bounds.width - 8
        let previewH = canvasPreview.bounds.height - 8
        let scale = min(previewW / canvasW, previewH / canvasH)

        // Canvas dimensions in preview coordinates
        let scaledW = canvasW * scale
        let scaledH = canvasH * scale

        // Center the canvas in preview
        let offsetX = (canvasPreview.bounds.width - scaledW) / 2
        let offsetY = (canvasPreview.bounds.height - scaledH) / 2

        // Draw canvas background
        let canvasBg = NSView(frame: NSRect(x: offsetX, y: offsetY, width: scaledW, height: scaledH))
        canvasBg.wantsLayer = true
        canvasBg.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor
        canvasBg.layer?.borderWidth = 1
        canvasBg.layer?.borderColor = NSColor(white: 0.4, alpha: 1.0).cgColor
        canvasBg.layer?.masksToBounds = false  // Allow outputs outside canvas to be visible/draggable
        canvasPreview.addSubview(canvasBg)

        // Add live preview image view (fills canvas background exactly)
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: scaledW, height: scaledH))
        imageView.imageScaling = .scaleAxesIndependently  // Fill entire view - aspect ratio already correct
        imageView.wantsLayer = true
        livePreviewImageView = imageView
        canvasBg.addSubview(imageView)

        // Initial capture
        updateLivePreviewImage()

        // Draw grid lines
        let gridColor = NSColor(white: 0.25, alpha: 1.0).cgColor
        for gridX in stride(from: 0, through: canvasW, by: canvasW / 4) {
            let line = NSView(frame: NSRect(x: gridX * scale, y: 0, width: 1, height: scaledH))
            line.wantsLayer = true
            line.layer?.backgroundColor = gridColor
            canvasBg.addSubview(line)
        }
        for gridY in stride(from: 0, through: canvasH, by: canvasH / 4) {
            let line = NSView(frame: NSRect(x: 0, y: gridY * scale, width: scaledW, height: 1))
            line.wantsLayer = true
            line.layer?.backgroundColor = gridColor
            canvasBg.addSubview(line)
        }

        let colors: [NSColor] = [.systemBlue, .systemPurple, .systemGreen, .systemOrange,
                                  .systemRed, .systemYellow, .systemTeal, .systemPink]

        // Draw output rectangles at their pixel positions (draggable)
        for (i, output) in outputs.enumerated() {
            let member = getMemberPosition(index: i)
            if !member.enabled { continue }

            // Convert CENTER-RELATIVE offset to top-left pixel position
            // Position x/y are OFFSETS from canvas center (0 = centered)
            let leftEdge = (canvasW / 2.0) + CGFloat(member.x) - (CGFloat(member.w) / 2.0)
            let topEdge = (canvasH / 2.0) + CGFloat(member.y) - (CGFloat(member.h) / 2.0)

            // Convert to preview coordinates (AppKit Y=0 is bottom, canvas Y=0 is top)
            let x = leftEdge * scale
            let y = scaledH - (topEdge + CGFloat(member.h)) * scale  // Flip Y
            let w = CGFloat(member.w) * scale
            let h = CGFloat(member.h) * scale

            // Use DraggableOutputView for interactive positioning
            let rect = DraggableOutputView(frame: NSRect(x: x, y: y, width: w, height: h))
            rect.outputIndex = i
            rect.scale = scale
            rect.canvasHeight = canvasH
            rect.controller = self
            rect.wantsLayer = true
            rect.layer?.backgroundColor = colors[i % colors.count].withAlphaComponent(0.35).cgColor
            rect.layer?.borderWidth = 2
            rect.layer?.borderColor = colors[i % colors.count].cgColor
            canvasBg.addSubview(rect)

            // Drag handle indicator (4 dots in center)
            let handleSize: CGFloat = 16
            let handleView = NSView(frame: NSRect(x: (w - handleSize) / 2, y: (h - handleSize) / 2, width: handleSize, height: handleSize))
            handleView.wantsLayer = true
            for dx in [0, 8] as [CGFloat] {
                for dy in [0, 8] as [CGFloat] {
                    let dot = NSView(frame: NSRect(x: dx, y: dy, width: 4, height: 4))
                    dot.wantsLayer = true
                    dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
                    dot.layer?.cornerRadius = 2
                    handleView.addSubview(dot)
                }
            }
            rect.addSubview(handleView)

            // Output label
            let label = makeLabel(output.name, bold: true, size: 9, color: .white)
            label.alignment = .center
            label.frame = NSRect(x: 2, y: h/2 + 10, width: w - 4, height: 14)
            label.cell?.lineBreakMode = .byTruncatingTail
            rect.addSubview(label)

            // Position info
            let posLabel = makeLabel("\(member.x),\(member.y)", bold: false, size: 8, color: NSColor.white.withAlphaComponent(0.7))
            posLabel.frame = NSRect(x: 2, y: 2, width: w - 4, height: 12)
            rect.addSubview(posLabel)
        }

        // Dimensions label
        let dimLabel = makeLabel("\(Int(canvasW)) × \(Int(canvasH))", bold: false, size: 10, color: .tertiaryLabelColor)
        dimLabel.frame = NSRect(x: canvasPreview.bounds.width - 90, y: 4, width: 85, height: 14)
        dimLabel.alignment = .right
        canvasPreview.addSubview(dimLabel)
    }

    // Called by DraggableOutputView during drag
    func setMemberPosition(index: Int, x: Int, y: Int) {
        // Find the row for this output
        for subview in memberOutputsView.subviews {
            if subview.identifier?.rawValue == "output_row_\(index)" {
                for child in subview.subviews {
                    if let field = child as? NSTextField {
                        let id = field.identifier?.rawValue ?? ""
                        if id == "pos_x_\(index)" {
                            field.stringValue = "\(x)"
                        }
                        if id == "pos_y_\(index)" {
                            field.stringValue = "\(y)"
                        }
                    }
                }
                break
            }
        }
        // Live update the preview during drag
        updateCanvasPreviewLive()

        // Auto-update edge blend values for selected output
        if selectedOutputIndex >= 0 {
            autoUpdateEdgeBlendSilent()
        }
    }

    // Lightweight preview update for dragging (doesn't recreate all views)
    private func updateCanvasPreviewLive() {
        // Just update existing views' positions based on field values
        guard let canvasBg = canvasPreview.subviews.first else { return }

        let canvasW = CGFloat(Int(canvasWidthField?.stringValue ?? "7680") ?? 7680)
        let canvasH = CGFloat(Int(canvasHeightField?.stringValue ?? "1080") ?? 1080)
        let previewW = canvasPreview.bounds.width - 8
        let previewH = canvasPreview.bounds.height - 8
        let scale = min(previewW / canvasW, previewH / canvasH)
        let scaledH = canvasH * scale

        // Update draggable output positions
        for subview in canvasBg.subviews {
            if let draggable = subview as? DraggableOutputView {
                let member = getMemberPosition(index: draggable.outputIndex)
                let x = CGFloat(member.x) * scale
                let y = scaledH - CGFloat(member.y + member.h) * scale
                draggable.frame.origin = NSPoint(x: x, y: y)

                // Update position label
                for child in draggable.subviews {
                    if let label = child as? NSTextField, child.frame.origin.y < 10 {
                        label.stringValue = "\(member.x),\(member.y)"
                    }
                }
            }
        }
    }

    func getMemberPosition(index: Int) -> (x: Int, y: Int, w: Int, h: Int, enabled: Bool) {
        // Calculate default X offset based on output widths before this index
        var defaultX = 0
        for i in 0..<index {
            if i < outputs.count {
                defaultX += Int(outputs[i].width)
            }
        }

        // Default W and H from output's native resolution
        let defaultW = index < outputs.count ? Int(outputs[index].width) : 1920
        let defaultH = index < outputs.count ? Int(outputs[index].height) : 1080

        // First check if output config has positions set (e.g., from DMX)
        if index < outputs.count {
            let config = outputs[index].config
            if let configX = config.positionX, let configY = config.positionY,
               let configW = config.positionW, let configH = config.positionH {
                return (configX, configY, configW, configH, config.enabled)
            }
        }

        // Fall back to UI fields
        for subview in memberOutputsView.subviews {
            if subview.identifier?.rawValue == "output_row_\(index)" {
                var x = defaultX, y = 0, w = defaultW, h = defaultH
                var enabled = true

                for child in subview.subviews {
                    if let checkbox = child as? NSButton, checkbox.tag == index {
                        enabled = checkbox.state == .on
                    }
                    if let field = child as? NSTextField {
                        let id = field.identifier?.rawValue ?? ""
                        if id == "pos_x_\(index)" { x = Int(field.stringValue) ?? x }
                        if id == "pos_y_\(index)" { y = Int(field.stringValue) ?? y }
                        if id == "pos_w_\(index)" { w = Int(field.stringValue) ?? w }
                        if id == "pos_h_\(index)" { h = Int(field.stringValue) ?? h }
                    }
                }
                return (x, y, w, h, enabled)
            }
        }
        return (defaultX, 0, defaultW, defaultH, true)
    }

    func updateOverlapInfo() {
        guard let label = overlapLabel else { return }

        // Collect member positions
        var members: [(name: String, x: Int, y: Int, w: Int, h: Int)] = []
        for (i, output) in outputs.enumerated() {
            let pos = getMemberPosition(index: i)
            if pos.enabled {
                members.append((output.name, pos.x, pos.y, pos.w, pos.h))
            }
        }

        if members.count < 2 {
            label.stringValue = "Add 2+ outputs with overlapping positions to enable auto edge blending"
            label.textColor = .secondaryLabelColor
            return
        }

        // Calculate overlaps
        var overlapInfo: [String] = []
        for (i, memberA) in members.enumerated() {
            var featherL = 0, featherR = 0, featherT = 0, featherB = 0

            for (j, memberB) in members.enumerated() {
                if i == j { continue }

                // Calculate the overlap region dimensions
                let overlapLeft = max(memberA.x, memberB.x)
                let overlapRight = min(memberA.x + memberA.w, memberB.x + memberB.w)
                let overlapTop = max(memberA.y, memberB.y)
                let overlapBottom = min(memberA.y + memberA.h, memberB.y + memberB.h)

                let overlapWidth = max(0, overlapRight - overlapLeft)
                let overlapHeight = max(0, overlapBottom - overlapTop)

                // Skip if no actual overlap
                if overlapWidth <= 0 || overlapHeight <= 0 { continue }

                // Determine seam type: vertical seam (side-by-side) vs horizontal seam (stacked)
                let isVerticalSeam = overlapHeight > overlapWidth

                if isVerticalSeam {
                    // Vertical seam -> apply LEFT/RIGHT feathering
                    if memberB.x < memberA.x && memberB.x + memberB.w > memberA.x {
                        featherL = max(featherL, (memberB.x + memberB.w) - memberA.x)
                    }
                    if memberB.x > memberA.x && memberB.x < memberA.x + memberA.w {
                        featherR = max(featherR, (memberA.x + memberA.w) - memberB.x)
                    }
                } else {
                    // Horizontal seam -> apply TOP/BOTTOM feathering
                    if memberB.y < memberA.y && memberB.y + memberB.h > memberA.y {
                        featherT = max(featherT, (memberB.y + memberB.h) - memberA.y)
                    }
                    if memberB.y > memberA.y && memberB.y < memberA.y + memberA.h {
                        featherB = max(featherB, (memberA.y + memberA.h) - memberB.y)
                    }
                }
            }

            if featherL > 0 || featherR > 0 || featherT > 0 || featherB > 0 {
                var edges: [String] = []
                if featherL > 0 { edges.append("L:\(featherL)px") }
                if featherR > 0 { edges.append("R:\(featherR)px") }
                if featherT > 0 { edges.append("T:\(featherT)px") }
                if featherB > 0 { edges.append("B:\(featherB)px") }
                overlapInfo.append("\(memberA.name): \(edges.joined(separator: ", "))")
            }
        }

        if overlapInfo.isEmpty {
            label.stringValue = "No overlaps detected. Position outputs with overlap for edge blending."
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = "Auto-detected: " + overlapInfo.joined(separator: " | ")
            label.textColor = NSColor.systemGreen
        }
    }

    // MARK: - Actions

    @objc private func addNDI() {
        let count = outputs.filter { $0.type == .NDI }.count + 1
        if let id = OutputManager.shared.addNDIOutput(sourceName: "GeoDraw NDI \(count)") {
            OutputManager.shared.enableOutput(id: id, enabled: true)
            refresh()
        }
    }

    @objc private func addDisplay() {
        let displays = OutputManager.shared.getAvailableDisplays()
        guard !displays.isEmpty else { return }

        let menu = NSMenu()
        for display in displays {
            let item = NSMenuItem(title: "\(display.name) (\(display.width)×\(display.height))",
                                  action: #selector(displaySelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display
            menu.addItem(item)
        }

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: window!.contentView!)
        }
    }

    @objc private func displaySelected(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? GDDisplayInfo else { return }
        if let id = OutputManager.shared.addDisplayOutput(displayId: display.displayId, name: display.name) {
            OutputManager.shared.enableOutput(id: id, enabled: true)
            refresh()
        }
    }

    @objc private func outputCellClicked(_ gesture: NSGestureRecognizer) {
        guard let view = gesture.view else { return }
        guard let index = outputCells.firstIndex(of: view) else { return }

        // Select this output
        if index < outputs.count {
            selectedOutputIndex = index
            updateSelectedOutputUI()
        } else {
            selectedOutputIndex = -1
            updateSelectedOutputUI()
        }
    }

    private func updateSelectedOutputUI() {
        // Update grid highlighting
        updateOutputGrid()

        // Populate display popup
        displayPopup.removeAllItems()
        let displays = OutputManager.shared.getAvailableDisplays()
        for display in displays {
            displayPopup.addItem(withTitle: "\(display.name) (\(display.width)x\(display.height))")
            displayPopup.lastItem?.tag = Int(display.displayId)
        }

        // Update config panel
        if selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count {
            let output = outputs[selectedOutputIndex]
            let typeStr = output.type == .NDI ? "NDI" : "Display"
            let typeColor = output.type == .NDI ? NSColor.systemBlue : NSColor.systemPurple

            selectedOutputLabel.stringValue = "\(typeStr) #\(selectedOutputIndex + 1): \(output.name)"
            selectedOutputLabel.textColor = typeColor

            // Enabled
            outputEnabledCheck.state = output.isRunning ? .on : .off
            outputEnabledCheck.isEnabled = true

            // Name
            outputNameField.stringValue = output.name
            outputNameField.isEnabled = true

            // Resolution - editable for both NDI and Display
            outputWidthField.stringValue = "\(output.width)"
            outputHeightField.stringValue = "\(output.height)"
            outputWidthField.isEnabled = true
            outputHeightField.isEnabled = true
            widthStepper.isEnabled = true
            heightStepper.isEnabled = true
            widthStepper.doubleValue = Double(output.width)
            heightStepper.doubleValue = Double(output.height)

            // Show native resolution hint and enable Native button for display outputs
            if output.type == .display {
                let native = "Native: \(output.nativeWidth)×\(output.nativeHeight)"
                outputWidthField.placeholderString = native
                nativeResBtn.isEnabled = true
            } else {
                outputWidthField.placeholderString = ""
                nativeResBtn.isEnabled = false
            }

            // Display popup - only for Display type
            displayPopup.isEnabled = (output.type == .display)
            if output.type == .display, let displayId = output.config.displayId {
                displayPopup.selectItem(withTag: Int(displayId))
            }

            // DMX Patch values
            dmxUniverseField.stringValue = "\(output.config.dmxUniverse)"
            dmxAddressField.stringValue = "\(output.config.dmxAddress)"
            dmxUniverseStepper.intValue = Int32(output.config.dmxUniverse)
            dmxAddressStepper.intValue = Int32(output.config.dmxAddress)
            dmxUniverseField.isEnabled = true
            dmxAddressField.isEnabled = true
            dmxUniverseStepper.isEnabled = true
            dmxAddressStepper.isEnabled = true

            // Processing controls (frame rate + shader toggles)
            let fps = output.config.targetFrameRate
            if fps == 0 {
                frameRatePopup.selectItem(withTitle: "Unlimited")
            } else if fps == 30 {
                frameRatePopup.selectItem(withTitle: "30")
            } else if fps == 60 {
                frameRatePopup.selectItem(withTitle: "60")
            } else {
                frameRatePopup.selectItem(withTitle: "Unlimited")
            }
            frameRatePopup.isEnabled = true

            enableEdgeBlendCheckbox.state = output.config.enableEdgeBlend ? .on : .off
            enableWarpCheckbox.state = output.config.enableWarp ? .on : .off
            enableLensCheckbox.state = output.config.enableLensCorrection ? .on : .off
            enableCurveCheckbox.state = output.config.enableCurveWarp ? .on : .off
            enableEdgeBlendCheckbox.isEnabled = true
            enableWarpCheckbox.isEnabled = true
            enableLensCheckbox.isEnabled = true
            enableCurveCheckbox.isEnabled = true

            // Edge blend values - show stored values from config (not auto-calculated)
            let left = Int(output.config.edgeBlendLeft)
            let right = Int(output.config.edgeBlendRight)
            let top = Int(output.config.edgeBlendTop)
            let bottom = Int(output.config.edgeBlendBottom)
            blendLeftField.stringValue = "\(left)"
            blendRightField.stringValue = "\(right)"
            blendTopField.stringValue = "\(top)"
            blendBottomField.stringValue = "\(bottom)"
            blendLeftField.isEnabled = true
            blendRightField.isEnabled = true
            blendTopField.isEnabled = true
            blendBottomField.isEnabled = true

            // Sync steppers
            blendLeftStepper?.doubleValue = Double(left)
            blendRightStepper?.doubleValue = Double(right)
            blendTopStepper?.doubleValue = Double(top)
            blendBottomStepper?.doubleValue = Double(bottom)
            blendLeftStepper?.isEnabled = true
            blendRightStepper?.isEnabled = true
            blendTopStepper?.isEnabled = true
            blendBottomStepper?.isEnabled = true

            // Quad warp values
            warpTLXField.stringValue = String(format: "%.0f", output.config.warpTopLeftX)
            warpTLYField.stringValue = String(format: "%.0f", output.config.warpTopLeftY)
            warpTRXField.stringValue = String(format: "%.0f", output.config.warpTopRightX)
            warpTRYField.stringValue = String(format: "%.0f", output.config.warpTopRightY)
            warpBLXField.stringValue = String(format: "%.0f", output.config.warpBottomLeftX)
            warpBLYField.stringValue = String(format: "%.0f", output.config.warpBottomLeftY)
            warpBRXField.stringValue = String(format: "%.0f", output.config.warpBottomRightX)
            warpBRYField.stringValue = String(format: "%.0f", output.config.warpBottomRightY)
            warpTLXStepper.doubleValue = Double(output.config.warpTopLeftX)
            warpTLYStepper.doubleValue = Double(output.config.warpTopLeftY)
            warpTRXStepper.doubleValue = Double(output.config.warpTopRightX)
            warpTRYStepper.doubleValue = Double(output.config.warpTopRightY)
            warpBLXStepper.doubleValue = Double(output.config.warpBottomLeftX)
            warpBLYStepper.doubleValue = Double(output.config.warpBottomLeftY)
            warpBRXStepper.doubleValue = Double(output.config.warpBottomRightX)
            warpBRYStepper.doubleValue = Double(output.config.warpBottomRightY)

            // Set stepper ranges based on output resolution
            let outW = Double(output.width)
            let outH = Double(output.height)
            // X steppers: range = ±width
            warpTLXStepper.minValue = -outW
            warpTLXStepper.maxValue = outW
            warpTRXStepper.minValue = -outW
            warpTRXStepper.maxValue = outW
            warpBLXStepper.minValue = -outW
            warpBLXStepper.maxValue = outW
            warpBRXStepper.minValue = -outW
            warpBRXStepper.maxValue = outW
            // Y steppers: range = ±height
            warpTLYStepper.minValue = -outH
            warpTLYStepper.maxValue = outH
            warpTRYStepper.minValue = -outH
            warpTRYStepper.maxValue = outH
            warpBLYStepper.minValue = -outH
            warpBLYStepper.maxValue = outH
            warpBRYStepper.minValue = -outH
            warpBRYStepper.maxValue = outH

            warpTLXField.isEnabled = true
            warpTLYField.isEnabled = true
            warpTRXField.isEnabled = true
            warpTRYField.isEnabled = true
            warpBLXField.isEnabled = true
            warpBLYField.isEnabled = true
            warpBRXField.isEnabled = true
            warpBRYField.isEnabled = true
            warpTLXStepper.isEnabled = true
            warpTLYStepper.isEnabled = true
            warpTRXStepper.isEnabled = true
            warpTRYStepper.isEnabled = true
            warpBLXStepper.isEnabled = true
            warpBLYStepper.isEnabled = true
            warpBRXStepper.isEnabled = true
            warpBRYStepper.isEnabled = true

            // Middle point warp values (for curved surfaces)
            warpTMXField.stringValue = String(format: "%.0f", output.config.warpTopMiddleX)
            warpTMYField.stringValue = String(format: "%.0f", output.config.warpTopMiddleY)
            warpMLXField.stringValue = String(format: "%.0f", output.config.warpMiddleLeftX)
            warpMLYField.stringValue = String(format: "%.0f", output.config.warpMiddleLeftY)
            warpMRXField.stringValue = String(format: "%.0f", output.config.warpMiddleRightX)
            warpMRYField.stringValue = String(format: "%.0f", output.config.warpMiddleRightY)
            warpBMXField.stringValue = String(format: "%.0f", output.config.warpBottomMiddleX)
            warpBMYField.stringValue = String(format: "%.0f", output.config.warpBottomMiddleY)
            warpTMXStepper.doubleValue = Double(output.config.warpTopMiddleX)
            warpTMYStepper.doubleValue = Double(output.config.warpTopMiddleY)
            warpMLXStepper.doubleValue = Double(output.config.warpMiddleLeftX)
            warpMLYStepper.doubleValue = Double(output.config.warpMiddleLeftY)
            warpMRXStepper.doubleValue = Double(output.config.warpMiddleRightX)
            warpMRYStepper.doubleValue = Double(output.config.warpMiddleRightY)
            warpBMXStepper.doubleValue = Double(output.config.warpBottomMiddleX)
            warpBMYStepper.doubleValue = Double(output.config.warpBottomMiddleY)
            // Middle steppers ranges
            warpTMXStepper.minValue = -outW
            warpTMXStepper.maxValue = outW
            warpTMYStepper.minValue = -outH
            warpTMYStepper.maxValue = outH
            warpMLXStepper.minValue = -outW
            warpMLXStepper.maxValue = outW
            warpMLYStepper.minValue = -outH
            warpMLYStepper.maxValue = outH
            warpMRXStepper.minValue = -outW
            warpMRXStepper.maxValue = outW
            warpMRYStepper.minValue = -outH
            warpMRYStepper.maxValue = outH
            warpBMXStepper.minValue = -outW
            warpBMXStepper.maxValue = outW
            warpBMYStepper.minValue = -outH
            warpBMYStepper.maxValue = outH
            // Enable middle fields/steppers
            warpTMXField.isEnabled = true
            warpTMYField.isEnabled = true
            warpMLXField.isEnabled = true
            warpMLYField.isEnabled = true
            warpMRXField.isEnabled = true
            warpMRYField.isEnabled = true
            warpBMXField.isEnabled = true
            warpBMYField.isEnabled = true
            warpTMXStepper.isEnabled = true
            warpTMYStepper.isEnabled = true
            warpMLXStepper.isEnabled = true
            warpMLYStepper.isEnabled = true
            warpMRXStepper.isEnabled = true
            warpMRYStepper.isEnabled = true
            warpBMXStepper.isEnabled = true
            warpBMYStepper.isEnabled = true

            // Enable middles checkbox and auto-show if any middle values are non-zero
            showMiddlesCheckbox.isEnabled = true
            let hasMiddleValues = output.config.warpTopMiddleX != 0 || output.config.warpTopMiddleY != 0 ||
                                  output.config.warpMiddleLeftX != 0 || output.config.warpMiddleLeftY != 0 ||
                                  output.config.warpMiddleRightX != 0 || output.config.warpMiddleRightY != 0 ||
                                  output.config.warpBottomMiddleX != 0 || output.config.warpBottomMiddleY != 0
            showMiddlesCheckbox.state = hasMiddleValues ? .on : .off
            for control in middleWarpControls {
                control.isHidden = !hasMiddleValues
            }

            // Lens correction values
            lensK1Field.stringValue = String(format: "%.2f", output.config.lensK1)
            lensK2Field.stringValue = String(format: "%.2f", output.config.lensK2)
            lensK1Slider.doubleValue = Double(output.config.lensK1)
            lensK2Slider.doubleValue = Double(output.config.lensK2)
            lensK1Stepper.doubleValue = Double(output.config.lensK1)
            lensK2Stepper.doubleValue = Double(output.config.lensK2)
            lensK1Field.isEnabled = true
            lensK2Field.isEnabled = true
            lensK1Slider.isEnabled = true
            lensK2Slider.isEnabled = true
            lensK1Stepper.isEnabled = true
            lensK2Stepper.isEnabled = true

            // Curvature values
            curvatureField.stringValue = String(format: "%.2f", output.config.warpCurvature)
            curvatureSlider.doubleValue = Double(output.config.warpCurvature)
            curvatureStepper.doubleValue = Double(output.config.warpCurvature)
            curvatureField.isEnabled = true
            curvatureSlider.isEnabled = true
            curvatureStepper.isEnabled = true

            removeOutputBtn.isEnabled = true
        } else {
            selectedOutputLabel.stringValue = "Click an output to configure"
            selectedOutputLabel.textColor = .tertiaryLabelColor
            outputEnabledCheck.state = .off
            outputEnabledCheck.isEnabled = false
            outputNameField.stringValue = ""
            outputNameField.isEnabled = false
            outputWidthField.stringValue = ""
            outputHeightField.stringValue = ""
            outputWidthField.isEnabled = false
            outputHeightField.isEnabled = false
            widthStepper.isEnabled = false
            heightStepper.isEnabled = false
            widthStepper.doubleValue = 1920
            heightStepper.doubleValue = 1080
            nativeResBtn.isEnabled = false
            displayPopup.isEnabled = false
            dmxUniverseField.stringValue = "0"
            dmxAddressField.stringValue = "1"
            dmxUniverseStepper.intValue = 0
            dmxAddressStepper.intValue = 1
            dmxUniverseField.isEnabled = false
            dmxAddressField.isEnabled = false
            dmxUniverseStepper.isEnabled = false
            dmxAddressStepper.isEnabled = false

            // Reset processing controls
            frameRatePopup.selectItem(at: 0)  // "Unlimited"
            frameRatePopup.isEnabled = false
            enableEdgeBlendCheckbox.state = .on
            enableEdgeBlendCheckbox.isEnabled = false
            enableWarpCheckbox.state = .on
            enableWarpCheckbox.isEnabled = false
            enableLensCheckbox.state = .on
            enableLensCheckbox.isEnabled = false
            enableCurveCheckbox.state = .on
            enableCurveCheckbox.isEnabled = false

            blendLeftField.stringValue = "0"
            blendRightField.stringValue = "0"
            blendTopField.stringValue = "0"
            blendBottomField.stringValue = "0"
            blendLeftField.isEnabled = false
            blendRightField.isEnabled = false
            blendTopField.isEnabled = false
            blendBottomField.isEnabled = false
            blendLeftStepper?.doubleValue = 0
            blendRightStepper?.doubleValue = 0
            blendTopStepper?.doubleValue = 0
            blendBottomStepper?.doubleValue = 0
            blendLeftStepper?.isEnabled = false
            blendRightStepper?.isEnabled = false
            blendTopStepper?.isEnabled = false
            blendBottomStepper?.isEnabled = false

            // Reset warp fields and steppers
            warpTLXField.stringValue = "0"
            warpTLYField.stringValue = "0"
            warpTRXField.stringValue = "0"
            warpTRYField.stringValue = "0"
            warpBLXField.stringValue = "0"
            warpBLYField.stringValue = "0"
            warpBRXField.stringValue = "0"
            warpBRYField.stringValue = "0"
            warpTLXStepper.doubleValue = 0
            warpTLYStepper.doubleValue = 0
            warpTRXStepper.doubleValue = 0
            warpTRYStepper.doubleValue = 0
            warpBLXStepper.doubleValue = 0
            warpBLYStepper.doubleValue = 0
            warpBRXStepper.doubleValue = 0
            warpBRYStepper.doubleValue = 0
            warpTLXField.isEnabled = false
            warpTLYField.isEnabled = false
            warpTRXField.isEnabled = false
            warpTRYField.isEnabled = false
            warpBLXField.isEnabled = false
            warpBLYField.isEnabled = false
            warpBRXField.isEnabled = false
            warpBRYField.isEnabled = false
            warpTLXStepper.isEnabled = false
            warpTLYStepper.isEnabled = false
            warpTRXStepper.isEnabled = false
            warpTRYStepper.isEnabled = false
            warpBLXStepper.isEnabled = false
            warpBLYStepper.isEnabled = false
            warpBRXStepper.isEnabled = false
            warpBRYStepper.isEnabled = false

            // Reset middle warp fields and steppers
            warpTMXField.stringValue = "0"
            warpTMYField.stringValue = "0"
            warpMLXField.stringValue = "0"
            warpMLYField.stringValue = "0"
            warpMRXField.stringValue = "0"
            warpMRYField.stringValue = "0"
            warpBMXField.stringValue = "0"
            warpBMYField.stringValue = "0"
            warpTMXStepper.doubleValue = 0
            warpTMYStepper.doubleValue = 0
            warpMLXStepper.doubleValue = 0
            warpMLYStepper.doubleValue = 0
            warpMRXStepper.doubleValue = 0
            warpMRYStepper.doubleValue = 0
            warpBMXStepper.doubleValue = 0
            warpBMYStepper.doubleValue = 0
            warpTMXField.isEnabled = false
            warpTMYField.isEnabled = false
            warpMLXField.isEnabled = false
            warpMLYField.isEnabled = false
            warpMRXField.isEnabled = false
            warpMRYField.isEnabled = false
            warpBMXField.isEnabled = false
            warpBMYField.isEnabled = false
            warpTMXStepper.isEnabled = false
            warpTMYStepper.isEnabled = false
            warpMLXStepper.isEnabled = false
            warpMLYStepper.isEnabled = false
            warpMRXStepper.isEnabled = false
            warpMRYStepper.isEnabled = false
            warpBMXStepper.isEnabled = false
            warpBMYStepper.isEnabled = false

            // Disable middles checkbox and hide controls
            showMiddlesCheckbox.isEnabled = false
            showMiddlesCheckbox.state = .off
            for control in middleWarpControls {
                control.isHidden = true
            }

            // Reset lens fields
            lensK1Field.stringValue = "0.00"
            lensK2Field.stringValue = "0.00"
            lensK1Slider.doubleValue = 0
            lensK2Slider.doubleValue = 0
            lensK1Stepper.doubleValue = 0
            lensK2Stepper.doubleValue = 0
            lensK1Field.isEnabled = false
            lensK2Field.isEnabled = false
            lensK1Slider.isEnabled = false
            lensK2Slider.isEnabled = false
            lensK1Stepper.isEnabled = false
            lensK2Stepper.isEnabled = false

            // Reset curvature fields
            curvatureField.stringValue = "0.00"
            curvatureSlider.doubleValue = 0
            curvatureStepper.doubleValue = 0
            curvatureField.isEnabled = false
            curvatureSlider.isEnabled = false
            curvatureStepper.isEnabled = false

            removeOutputBtn.isEnabled = false
        }
    }

    @objc private func edgeBlendChanged(_ sender: NSTextField) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let left = Float(blendLeftField.stringValue) ?? 0
        let right = Float(blendRightField.stringValue) ?? 0
        let top = Float(blendTopField.stringValue) ?? 0
        let bottom = Float(blendBottomField.stringValue) ?? 0

        OutputManager.shared.updateEdgeBlend(
            id: output.id,
            left: left,
            right: right,
            top: top,
            bottom: bottom,
            gamma: output.config.edgeBlendGamma,
            power: output.config.edgeBlendPower,
            blackLevel: output.config.edgeBlendBlackLevel
        )

        // Refresh to update UI
        outputs = OutputManager.shared.getAllOutputs()

        // Sync steppers
        blendLeftStepper?.doubleValue = Double(left)
        blendRightStepper?.doubleValue = Double(right)
        blendTopStepper?.doubleValue = Double(top)
        blendBottomStepper?.doubleValue = Double(bottom)
    }

    @objc private func blendLeftStepperChanged(_ sender: NSStepper) {
        blendLeftField.stringValue = "\(Int(sender.doubleValue))"
        edgeBlendChanged(blendLeftField)
    }

    @objc private func blendRightStepperChanged(_ sender: NSStepper) {
        blendRightField.stringValue = "\(Int(sender.doubleValue))"
        edgeBlendChanged(blendRightField)
    }

    @objc private func blendTopStepperChanged(_ sender: NSStepper) {
        blendTopField.stringValue = "\(Int(sender.doubleValue))"
        edgeBlendChanged(blendTopField)
    }

    @objc private func blendBottomStepperChanged(_ sender: NSStepper) {
        blendBottomField.stringValue = "\(Int(sender.doubleValue))"
        edgeBlendChanged(blendBottomField)
    }

    // MARK: - Quad Warp Handlers

    @objc private func warpChanged(_ sender: NSTextField) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        // Track which corner is being adjusted (if directly editing field)
        setActiveCorner(from: sender)

        // Corner values
        let tlX = Float(warpTLXField.stringValue) ?? 0
        let tlY = Float(warpTLYField.stringValue) ?? 0
        let trX = Float(warpTRXField.stringValue) ?? 0
        let trY = Float(warpTRYField.stringValue) ?? 0
        let blX = Float(warpBLXField.stringValue) ?? 0
        let blY = Float(warpBLYField.stringValue) ?? 0
        let brX = Float(warpBRXField.stringValue) ?? 0
        let brY = Float(warpBRYField.stringValue) ?? 0

        // Middle point values (for curved surface mapping)
        let tmX = Float(warpTMXField.stringValue) ?? 0
        let tmY = Float(warpTMYField.stringValue) ?? 0
        let mlX = Float(warpMLXField.stringValue) ?? 0
        let mlY = Float(warpMLYField.stringValue) ?? 0
        let mrX = Float(warpMRXField.stringValue) ?? 0
        let mrY = Float(warpMRYField.stringValue) ?? 0
        let bmX = Float(warpBMXField.stringValue) ?? 0
        let bmY = Float(warpBMYField.stringValue) ?? 0

        // 8-point warp: 4 corners + 4 edge midpoints
        OutputManager.shared.updateQuadWarp(
            id: output.id,
            topLeftX: tlX, topLeftY: tlY,
            topMiddleX: tmX, topMiddleY: tmY,
            topRightX: trX, topRightY: trY,
            middleLeftX: mlX, middleLeftY: mlY,
            middleRightX: mrX, middleRightY: mrY,
            bottomLeftX: blX, bottomLeftY: blY,
            bottomMiddleX: bmX, bottomMiddleY: bmY,
            bottomRightX: brX, bottomRightY: brY
        )

        // Sync corner steppers
        warpTLXStepper.doubleValue = Double(tlX)
        warpTLYStepper.doubleValue = Double(tlY)
        warpTRXStepper.doubleValue = Double(trX)
        warpTRYStepper.doubleValue = Double(trY)
        warpBLXStepper.doubleValue = Double(blX)
        warpBLYStepper.doubleValue = Double(blY)
        warpBRXStepper.doubleValue = Double(brX)
        warpBRYStepper.doubleValue = Double(brY)

        // Sync middle steppers
        warpTMXStepper.doubleValue = Double(tmX)
        warpTMYStepper.doubleValue = Double(tmY)
        warpMLXStepper.doubleValue = Double(mlX)
        warpMLYStepper.doubleValue = Double(mlY)
        warpMRXStepper.doubleValue = Double(mrX)
        warpMRYStepper.doubleValue = Double(mrY)
        warpBMXStepper.doubleValue = Double(bmX)
        warpBMYStepper.doubleValue = Double(bmY)

        // Refresh to update UI
        outputs = OutputManager.shared.getAllOutputs()

        // Update corner popup and on-screen overlay
        updateCornerPopup()
        updateCornerOverlay()
    }

    @objc private func warpStepperChanged(_ sender: NSStepper) {
        // Track which corner is being adjusted
        setActiveCorner(from: sender)

        // Update the corresponding field based on which stepper was changed
        // Corners
        if sender === warpTLXStepper {
            warpTLXField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpTLYStepper {
            warpTLYField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpTRXStepper {
            warpTRXField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpTRYStepper {
            warpTRYField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpBLXStepper {
            warpBLXField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpBLYStepper {
            warpBLYField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpBRXStepper {
            warpBRXField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpBRYStepper {
            warpBRYField.stringValue = "\(Int(sender.doubleValue))"
        }
        // Middles
        else if sender === warpTMXStepper {
            warpTMXField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpTMYStepper {
            warpTMYField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpMLXStepper {
            warpMLXField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpMLYStepper {
            warpMLYField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpMRXStepper {
            warpMRXField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpMRYStepper {
            warpMRYField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpBMXStepper {
            warpBMXField.stringValue = "\(Int(sender.doubleValue))"
        } else if sender === warpBMYStepper {
            warpBMYField.stringValue = "\(Int(sender.doubleValue))"
        }
        warpChanged(warpTLXField)  // Trigger update

        // Show/update corner popup
        showCornerPopup()
    }

    @objc private func openWarpEditor() {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]
        WarpWindowManager.shared.showWarpWindow(for: output.id, name: output.name)
    }

    @objc private func resetQuadWarp() {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        OutputManager.shared.resetQuadWarp(id: output.id)

        // Update corner fields and steppers
        warpTLXField.stringValue = "0"
        warpTLYField.stringValue = "0"
        warpTRXField.stringValue = "0"
        warpTRYField.stringValue = "0"
        warpBLXField.stringValue = "0"
        warpBLYField.stringValue = "0"
        warpBRXField.stringValue = "0"
        warpBRYField.stringValue = "0"
        warpTLXStepper.doubleValue = 0
        warpTLYStepper.doubleValue = 0
        warpTRXStepper.doubleValue = 0
        warpTRYStepper.doubleValue = 0
        warpBLXStepper.doubleValue = 0
        warpBLYStepper.doubleValue = 0
        warpBRXStepper.doubleValue = 0
        warpBRYStepper.doubleValue = 0

        // Update middle fields and steppers
        warpTMXField.stringValue = "0"
        warpTMYField.stringValue = "0"
        warpMLXField.stringValue = "0"
        warpMLYField.stringValue = "0"
        warpMRXField.stringValue = "0"
        warpMRYField.stringValue = "0"
        warpBMXField.stringValue = "0"
        warpBMYField.stringValue = "0"
        warpTMXStepper.doubleValue = 0
        warpTMYStepper.doubleValue = 0
        warpMLXStepper.doubleValue = 0
        warpMLYStepper.doubleValue = 0
        warpMRXStepper.doubleValue = 0
        warpMRYStepper.doubleValue = 0
        warpBMXStepper.doubleValue = 0
        warpBMYStepper.doubleValue = 0

        outputs = OutputManager.shared.getAllOutputs()
    }

    @objc private func toggleMiddleWarpControls(_ sender: NSButton) {
        let show = sender.state == .on
        for control in middleWarpControls {
            control.isHidden = !show
        }
    }

    // MARK: - Lens Correction Handlers

    @objc private func lensSliderChanged(_ sender: NSSlider) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let k1: Float
        let k2: Float

        if sender === lensK1Slider {
            k1 = Float(sender.doubleValue)
            k2 = output.config.lensK2
            lensK1Field.stringValue = String(format: "%.2f", k1)
        } else {
            k1 = output.config.lensK1
            k2 = Float(sender.doubleValue)
            lensK2Field.stringValue = String(format: "%.2f", k2)
        }

        OutputManager.shared.updateLensCorrection(
            id: output.id,
            k1: k1,
            k2: k2,
            centerX: 0.5,
            centerY: 0.5
        )

        outputs = OutputManager.shared.getAllOutputs()
    }

    @objc private func lensFieldChanged(_ sender: NSTextField) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let k1 = Float(lensK1Field.stringValue) ?? 0
        let k2 = Float(lensK2Field.stringValue) ?? 0

        // Clamp and update sliders and steppers
        let clampedK1 = max(-0.5, min(0.5, k1))
        let clampedK2 = max(-0.5, min(0.5, k2))
        lensK1Slider.doubleValue = Double(clampedK1)
        lensK2Slider.doubleValue = Double(clampedK2)
        lensK1Stepper.doubleValue = Double(clampedK1)
        lensK2Stepper.doubleValue = Double(clampedK2)

        OutputManager.shared.updateLensCorrection(
            id: output.id,
            k1: clampedK1,
            k2: clampedK2,
            centerX: 0.5,
            centerY: 0.5
        )

        outputs = OutputManager.shared.getAllOutputs()
    }

    @objc private func lensStepperChanged(_ sender: NSStepper) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let k1: Float
        let k2: Float

        if sender === lensK1Stepper {
            k1 = Float(sender.doubleValue)
            k2 = output.config.lensK2
            lensK1Field.stringValue = String(format: "%.2f", k1)
            lensK1Slider.doubleValue = Double(k1)
        } else {
            k1 = output.config.lensK1
            k2 = Float(sender.doubleValue)
            lensK2Field.stringValue = String(format: "%.2f", k2)
            lensK2Slider.doubleValue = Double(k2)
        }

        OutputManager.shared.updateLensCorrection(
            id: output.id,
            k1: k1,
            k2: k2,
            centerX: 0.5,
            centerY: 0.5
        )

        outputs = OutputManager.shared.getAllOutputs()
    }

    @objc private func resetLensCorrection() {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        OutputManager.shared.resetLensCorrection(id: output.id)

        // Update fields, sliders and steppers
        lensK1Field.stringValue = "0.00"
        lensK2Field.stringValue = "0.00"
        lensK1Slider.doubleValue = 0
        lensK2Slider.doubleValue = 0
        lensK1Stepper.doubleValue = 0
        lensK2Stepper.doubleValue = 0

        outputs = OutputManager.shared.getAllOutputs()
    }

    // MARK: - Curvature Controls

    @objc private func curvatureSliderChanged(_ sender: NSSlider) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let curvature = Float(sender.doubleValue)
        curvatureField.stringValue = String(format: "%.2f", curvature)
        curvatureStepper.doubleValue = sender.doubleValue

        // Update the output config
        output.config.warpCurvature = curvature

        // Re-apply edge blend to push curvature to the shader
        OutputManager.shared.updateEdgeBlend(
            id: output.id,
            left: output.config.edgeBlendLeft,
            right: output.config.edgeBlendRight,
            top: output.config.edgeBlendTop,
            bottom: output.config.edgeBlendBottom,
            gamma: output.config.edgeBlendGamma,
            power: output.config.edgeBlendPower,
            blackLevel: output.config.edgeBlendBlackLevel
        )

        outputs = OutputManager.shared.getAllOutputs()
    }

    @objc private func curvatureFieldChanged(_ sender: NSTextField) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let curvature = max(-1.0, min(1.0, Float(sender.stringValue) ?? 0))
        curvatureSlider.doubleValue = Double(curvature)
        curvatureStepper.doubleValue = Double(curvature)
        sender.stringValue = String(format: "%.2f", curvature)

        // Update the output config
        output.config.warpCurvature = curvature

        // Re-apply edge blend
        OutputManager.shared.updateEdgeBlend(
            id: output.id,
            left: output.config.edgeBlendLeft,
            right: output.config.edgeBlendRight,
            top: output.config.edgeBlendTop,
            bottom: output.config.edgeBlendBottom,
            gamma: output.config.edgeBlendGamma,
            power: output.config.edgeBlendPower,
            blackLevel: output.config.edgeBlendBlackLevel
        )

        outputs = OutputManager.shared.getAllOutputs()
    }

    @objc private func curvatureStepperChanged(_ sender: NSStepper) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let curvature = Float(sender.doubleValue)
        curvatureField.stringValue = String(format: "%.2f", curvature)
        curvatureSlider.doubleValue = sender.doubleValue

        // Update the output config
        output.config.warpCurvature = curvature

        // Re-apply edge blend
        OutputManager.shared.updateEdgeBlend(
            id: output.id,
            left: output.config.edgeBlendLeft,
            right: output.config.edgeBlendRight,
            top: output.config.edgeBlendTop,
            bottom: output.config.edgeBlendBottom,
            gamma: output.config.edgeBlendGamma,
            power: output.config.edgeBlendPower,
            blackLevel: output.config.edgeBlendBlackLevel
        )

        outputs = OutputManager.shared.getAllOutputs()
    }

    @objc private func resetCurvature() {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        // Reset curvature to 0
        output.config.warpCurvature = 0

        // Update UI
        curvatureField.stringValue = "0.00"
        curvatureSlider.doubleValue = 0
        curvatureStepper.doubleValue = 0

        // Re-apply edge blend
        OutputManager.shared.updateEdgeBlend(
            id: output.id,
            left: output.config.edgeBlendLeft,
            right: output.config.edgeBlendRight,
            top: output.config.edgeBlendTop,
            bottom: output.config.edgeBlendBottom,
            gamma: output.config.edgeBlendGamma,
            power: output.config.edgeBlendPower,
            blackLevel: output.config.edgeBlendBlackLevel
        )

        outputs = OutputManager.shared.getAllOutputs()
    }

    // MARK: - Master Control DMX

    @objc private func masterControlToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "masterControlEnabled")
    }

    @objc private func masterControlChanged(_ sender: NSTextField) {
        let universe = masterControlUniverseField.integerValue
        let address = max(1, masterControlAddressField.integerValue)

        UserDefaults.standard.set(universe, forKey: "masterControlUniverse")
        UserDefaults.standard.set(address, forKey: "masterControlAddress")

        // Sync steppers
        masterControlUniverseStepper.integerValue = universe
        masterControlAddressStepper.integerValue = address
    }

    @objc private func masterControlUniverseStepperChanged(_ sender: NSStepper) {
        let value = sender.integerValue
        masterControlUniverseField.stringValue = "\(value)"
        UserDefaults.standard.set(value, forKey: "masterControlUniverse")
    }

    @objc private func masterControlAddressStepperChanged(_ sender: NSStepper) {
        let value = sender.integerValue
        masterControlAddressField.stringValue = "\(value)"
        UserDefaults.standard.set(value, forKey: "masterControlAddress")
    }

    // MARK: - Global Offset

    @objc private func applyGlobalOffset() {
        let offsetX = globalOffsetXField.integerValue
        let offsetY = globalOffsetYField.integerValue

        guard offsetX != 0 || offsetY != 0 else { return }

        // Apply offset to all outputs
        for output in outputs {
            let currentX = output.config.positionX ?? 0
            let currentY = output.config.positionY ?? 0

            output.config.positionX = currentX + offsetX
            output.config.positionY = currentY + offsetY

            // Update the output in OutputManager
            OutputManager.shared.updatePosition(
                id: output.id,
                x: output.config.positionX!,
                y: output.config.positionY!,
                w: output.config.positionW ?? 1920,
                h: output.config.positionH ?? 1080
            )
        }

        // Reset offset fields to 0
        globalOffsetXField.stringValue = "0"
        globalOffsetYField.stringValue = "0"

        // Refresh the display
        outputs = OutputManager.shared.getAllOutputs()
        updateMemberOutputsList()
        updateCanvasPreview()
        updatePopOutOutputs()
    }

    // Silent version for live updates during drag
    private func autoUpdateEdgeBlendSilent() {
        // Only run if auto edge blending is enabled
        guard blendEnabledCheck.state == .on else { return }
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }

        let (left, right, top, bottom) = calculateOverlapsForOutput(selectedOutputIndex)

        // Update fields only
        blendLeftField.stringValue = "\(left)"
        blendRightField.stringValue = "\(right)"
        blendTopField.stringValue = "\(top)"
        blendBottomField.stringValue = "\(bottom)"
    }

    // Calculate overlaps for a given output index
    // Uses seam detection: only apply L/R for vertical seams, T/B for horizontal seams
    private func calculateOverlapsForOutput(_ index: Int) -> (left: Int, right: Int, top: Int, bottom: Int) {
        let memberA = getMemberPosition(index: index)
        var featherL = 0, featherR = 0, featherT = 0, featherB = 0

        for (i, _) in outputs.enumerated() {
            if i == index { continue }

            let memberB = getMemberPosition(index: i)
            if !memberB.enabled { continue }

            // Calculate the overlap bounding box
            let overlapLeft = max(memberA.x, memberB.x)
            let overlapRight = min(memberA.x + memberA.w, memberB.x + memberB.w)
            let overlapTop = max(memberA.y, memberB.y)
            let overlapBottom = min(memberA.y + memberA.h, memberB.y + memberB.h)

            let overlapWidth = max(0, overlapRight - overlapLeft)
            let overlapHeight = max(0, overlapBottom - overlapTop)

            // Skip if no actual overlap
            if overlapWidth <= 0 || overlapHeight <= 0 {
                continue
            }

            // SEAM DETECTION: Determine if this is a vertical seam (side-by-side) or horizontal seam (stacked)
            // Vertical seam = overlap taller than wide → apply LEFT/RIGHT feathering
            // Horizontal seam = overlap wider than tall → apply TOP/BOTTOM feathering
            let isVerticalSeam = overlapHeight > overlapWidth

            if isVerticalSeam {
                // Side-by-side outputs → apply LEFT or RIGHT feathering
                if memberB.x < memberA.x && memberB.x + memberB.w > memberA.x {
                    let overlap = (memberB.x + memberB.w) - memberA.x
                    featherL = max(featherL, overlap)
                }
                if memberB.x > memberA.x && memberA.x + memberA.w > memberB.x {
                    let overlap = (memberA.x + memberA.w) - memberB.x
                    featherR = max(featherR, overlap)
                }
            } else {
                // Stacked outputs → apply TOP or BOTTOM feathering
                if memberB.y < memberA.y && memberB.y + memberB.h > memberA.y {
                    let overlap = (memberB.y + memberB.h) - memberA.y
                    featherT = max(featherT, overlap)
                }
                if memberB.y > memberA.y && memberA.y + memberA.h > memberB.y {
                    let overlap = (memberA.y + memberA.h) - memberB.y
                    featherB = max(featherB, overlap)
                }
            }
        }

        return (featherL, featherR, featherT, featherB)
    }

    @objc private func autoDetectEdgeBlend() {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }

        // Use shared overlap calculation with seam detection
        let (featherL, featherR, featherT, featherB) = calculateOverlapsForOutput(selectedOutputIndex)

        // Update fields
        blendLeftField.stringValue = "\(featherL)"
        blendRightField.stringValue = "\(featherR)"
        blendTopField.stringValue = "\(featherT)"
        blendBottomField.stringValue = "\(featherB)"

        // Sync steppers
        blendLeftStepper?.doubleValue = Double(featherL)
        blendRightStepper?.doubleValue = Double(featherR)
        blendTopStepper?.doubleValue = Double(featherT)
        blendBottomStepper?.doubleValue = Double(featherB)

        // Apply to output
        let output = outputs[selectedOutputIndex]
        OutputManager.shared.updateEdgeBlend(
            id: output.id,
            left: Float(featherL),
            right: Float(featherR),
            top: Float(featherT),
            bottom: Float(featherB),
            gamma: output.config.edgeBlendGamma,
            power: output.config.edgeBlendPower,
            blackLevel: output.config.edgeBlendBlackLevel
        )

        outputs = OutputManager.shared.getAllOutputs()
    }

    @objc private func resetEdgeBlend() {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        // Reset all feather values to 0
        OutputManager.shared.resetEdgeBlend(id: output.id)

        // Update UI fields
        blendLeftField.stringValue = "0"
        blendRightField.stringValue = "0"
        blendTopField.stringValue = "0"
        blendBottomField.stringValue = "0"

        // Sync steppers
        blendLeftStepper?.doubleValue = 0
        blendRightStepper?.doubleValue = 0
        blendTopStepper?.doubleValue = 0
        blendBottomStepper?.doubleValue = 0

        outputs = OutputManager.shared.getAllOutputs()
    }

    @objc private func resetAllEdgeBlend() {
        // Reset edge blend for ALL outputs
        OutputManager.shared.resetAllEdgeBlend()

        // Update UI fields
        blendLeftField.stringValue = "0"
        blendRightField.stringValue = "0"
        blendTopField.stringValue = "0"
        blendBottomField.stringValue = "0"

        // Sync steppers
        blendLeftStepper?.doubleValue = 0
        blendRightStepper?.doubleValue = 0
        blendTopStepper?.doubleValue = 0
        blendBottomStepper?.doubleValue = 0

        outputs = OutputManager.shared.getAllOutputs()
    }

    @objc private func outputNameChanged(_ sender: NSTextField) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]
        let newName = sender.stringValue
        if !newName.isEmpty {
            OutputManager.shared.renameOutput(id: output.id, name: newName)
            updateOutputGrid()
        }
    }

    @objc private func dmxPatchChanged(_ sender: NSTextField) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let universe = Int(dmxUniverseField.stringValue) ?? 0
        let address = Int(dmxAddressField.stringValue) ?? 1

        // Sync steppers with text fields
        dmxUniverseStepper.intValue = Int32(universe)
        dmxAddressStepper.intValue = Int32(address)

        OutputManager.shared.updateDMXPatch(id: output.id, universe: universe, address: address)
    }

    @objc private func dmxUniverseStepperChanged(_ sender: NSStepper) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let universe = Int(sender.intValue)
        dmxUniverseField.stringValue = "\(universe)"

        let address = Int(dmxAddressField.stringValue) ?? 1
        OutputManager.shared.updateDMXPatch(id: output.id, universe: universe, address: address)
    }

    @objc private func dmxAddressStepperChanged(_ sender: NSStepper) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let address = Int(sender.intValue)
        dmxAddressField.stringValue = "\(address)"

        let universe = Int(dmxUniverseField.stringValue) ?? 0
        OutputManager.shared.updateDMXPatch(id: output.id, universe: universe, address: address)
    }

    @objc private func frameRateChanged(_ sender: NSPopUpButton) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let selectedTitle = sender.titleOfSelectedItem ?? "Unlimited"
        let fps: Float
        switch selectedTitle {
        case "30": fps = 30
        case "60": fps = 60
        default: fps = 0  // Unlimited
        }

        OutputManager.shared.setOutputFrameRate(id: output.id, fps: fps)
    }

    @objc private func shaderToggleChanged(_ sender: NSButton) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        // Determine which checkbox was toggled
        if sender === enableEdgeBlendCheckbox {
            OutputManager.shared.setEdgeBlendEnabled(id: output.id, enabled: sender.state == .on)
        } else if sender === enableWarpCheckbox {
            OutputManager.shared.setWarpEnabled(id: output.id, enabled: sender.state == .on)
        } else if sender === enableLensCheckbox {
            OutputManager.shared.setLensCorrectionEnabled(id: output.id, enabled: sender.state == .on)
        } else if sender === enableCurveCheckbox {
            OutputManager.shared.setCurveWarpEnabled(id: output.id, enabled: sender.state == .on)
        }
    }

    @objc private func outputEnabledChanged(_ sender: NSButton) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]
        let enabled = sender.state == .on

        if enabled {
            OutputManager.shared.startOutput(output)
        } else {
            OutputManager.shared.stopOutput(output)
        }

        // Refresh to update status
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func outputResolutionChanged(_ sender: NSTextField) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else {
            NSLog("Resolution changed but no output selected")
            return
        }
        let output = outputs[selectedOutputIndex]

        let width = UInt32(outputWidthField.stringValue) ?? 1920
        let height = UInt32(outputHeightField.stringValue) ?? 1080

        NSLog("Resolution changed to %dx%d for output %@ (type: %d)", width, height, output.name, output.type.rawValue)

        // Sync steppers with text fields
        widthStepper.doubleValue = Double(width)
        heightStepper.doubleValue = Double(height)

        // Call appropriate method based on output type
        if output.type == .NDI {
            OutputManager.shared.setNDIResolution(id: output.id, width: width, height: height)
        } else if output.type == .display {
            OutputManager.shared.setDisplayResolution(id: output.id, width: width, height: height)
        }

        // Refresh to update member outputs list
        outputs = OutputManager.shared.getAllOutputs()

        // Debug: log what the output now reports
        if let updatedOutput = outputs.first(where: { $0.id == output.id }) {
            NSLog("After setResolution: output reports %dx%d", updatedOutput.width, updatedOutput.height)
        }

        // Don't call updateMemberOutputsList here - it would trigger another refresh
        updateCanvasPreview()
    }

    @objc private func widthStepperChanged(_ sender: NSStepper) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let width = UInt32(sender.intValue)
        outputWidthField.stringValue = "\(width)"

        let height = UInt32(outputHeightField.stringValue) ?? 1080

        // Call appropriate method based on output type
        if output.type == .NDI {
            OutputManager.shared.setNDIResolution(id: output.id, width: width, height: height)
        } else if output.type == .display {
            OutputManager.shared.setDisplayResolution(id: output.id, width: width, height: height)
        }

        // Refresh to update member outputs list
        outputs = OutputManager.shared.getAllOutputs()
        updateMemberOutputsList()
        updateCanvasPreview()
    }

    @objc private func heightStepperChanged(_ sender: NSStepper) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        let height = UInt32(sender.intValue)
        outputHeightField.stringValue = "\(height)"

        let width = UInt32(outputWidthField.stringValue) ?? 1920

        // Call appropriate method based on output type
        if output.type == .NDI {
            OutputManager.shared.setNDIResolution(id: output.id, width: width, height: height)
        } else if output.type == .display {
            OutputManager.shared.setDisplayResolution(id: output.id, width: width, height: height)
        }

        // Refresh to update member outputs list
        outputs = OutputManager.shared.getAllOutputs()
        updateMemberOutputsList()
        updateCanvasPreview()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let textField = notification.object as? NSTextField else { return }

        // Handle resolution field edits when user clicks away (not just Enter)
        if textField === outputWidthField || textField === outputHeightField {
            outputResolutionChanged(textField)
        }
    }

    @objc private func displaySelectionChanged(_ sender: NSPopUpButton) {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        // Only Display type can change display
        guard output.type == .display else { return }

        guard let selectedItem = sender.selectedItem else { return }
        let displayId = UInt32(selectedItem.tag)

        OutputManager.shared.setDisplayId(id: output.id, displayId: displayId)
    }

    @objc private func resetToNativeResolution() {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        // Only Display type can reset to native
        guard output.type == .display else { return }

        OutputManager.shared.resetDisplayToNative(id: output.id)

        // Refresh to show native resolution
        outputs = OutputManager.shared.getAllOutputs()
        updateSelectedOutputUI()
        updateMemberOutputsList()
        updateCanvasPreview()
    }

    @objc private func removeSelectedOutput() {
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]
        OutputManager.shared.removeOutput(id: output.id)
        selectedOutputIndex = -1
        refresh()
    }

    @objc private func removeOutput(_ sender: NSMenuItem) {
        let index = sender.tag
        if index < outputs.count {
            OutputManager.shared.removeOutput(id: outputs[index].id)
            selectedOutputIndex = -1
            refresh()
        }
    }

    @objc private func canvasChanged() {
        updateMemberOutputsList()
        updateCanvasPreview()
        updateOverlapInfo()
    }

    @objc private func blendToggled() {
        updateOverlapInfo()
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    // MARK: - Canvas NDI Preview (delegates to CanvasNDIManager singleton)

    @objc private func toggleCanvasNDI(_ sender: NSButton) {
        // Use the singleton manager - NDI continues even when this window closes
        CanvasNDIManager.shared.toggle()
        sender.state = CanvasNDIManager.shared.isEnabled ? .on : .off
    }

    // Legacy methods removed - CanvasNDIManager handles everything now
    // The manager captures directly from sharedMetalRenderView, so it works
    // regardless of whether this window is open or closed.

    // captureViewToBitmap is kept for pop-out preview window
    private func captureViewToBitmap(_ view: NSView, width: Int, height: Int) -> NSBitmapImageRep? {
        // Create bitmap with target size
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [.thirtyTwoBitLittleEndian],  // BGRA format
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else { return nil }

        // Create graphics context
        guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // Scale to fit
        let scaleX = CGFloat(width) / view.bounds.width
        let scaleY = CGFloat(height) / view.bounds.height

        // Scale to target size (no flip needed)
        context.cgContext.scaleBy(x: scaleX, y: scaleY)

        // Render the view
        view.displayIgnoringOpacity(view.bounds, in: context)

        NSGraphicsContext.restoreGraphicsState()

        return bitmapRep
    }

    @objc private func popOutCanvasPreview() {
        // If window already exists, bring it to front and refresh
        if let existingWindow = popOutWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            updatePopOutOutputs()
            return
        }

        // Calculate window size based on canvas aspect ratio
        let canvasW = CGFloat(Int(canvasWidthField.stringValue) ?? 7680)
        let canvasH = CGFloat(Int(canvasHeightField.stringValue) ?? 1080)

        // Window with left panel (280px) + canvas area
        let panelWidth: CGFloat = 280
        let canvasAreaWidth: CGFloat = 900
        let windowW: CGFloat = panelWidth + canvasAreaWidth + 30
        let windowH: CGFloat = 600

        let popWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowW, height: windowH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        popWindow.title = "◈ CANVAS EDITOR ◈"
        popWindow.center()
        popWindow.isReleasedWhenClosed = false
        popWindow.minSize = NSSize(width: 800, height: 500)
        RetroTheme.styleWindow(popWindow)

        let contentView = NSView(frame: popWindow.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        RetroTheme.styleContentView(contentView, withGrid: false)

        // === LEFT PANEL - Settings ===
        let settingsPanel = NSView(frame: NSRect(x: 10, y: 10, width: panelWidth, height: contentView.bounds.height - 20))
        settingsPanel.wantsLayer = true
        settingsPanel.layer?.backgroundColor = RetroTheme.backgroundPanel.cgColor
        settingsPanel.layer?.cornerRadius = 8
        RetroTheme.applyNeonBorder(to: settingsPanel.layer!, color: RetroTheme.borderDefault, width: 1)
        settingsPanel.autoresizingMask = [.height]
        contentView.addSubview(settingsPanel)
        popOutSettingsPanel = settingsPanel

        buildPopOutSettingsPanel(settingsPanel)

        // === RIGHT SIDE - Canvas ===
        let canvasX = panelWidth + 20

        // Canvas size label
        let sizeLabel = RetroTheme.makeLabel("CANVAS: \(Int(canvasW)) × \(Int(canvasH))", style: .header, size: 12, color: RetroTheme.neonCyan)
        sizeLabel.frame = NSRect(x: canvasX, y: contentView.bounds.height - 30, width: 300, height: 20)
        sizeLabel.autoresizingMask = [.minYMargin]
        contentView.addSubview(sizeLabel)

        let dragLabel = RetroTheme.makeLabel("DRAG TO REPOSITION • SCROLL TO ZOOM", style: .body, size: 10, color: RetroTheme.textSecondary)
        dragLabel.frame = NSRect(x: canvasX + 310, y: contentView.bounds.height - 28, width: 280, height: 16)
        dragLabel.autoresizingMask = [.minYMargin]
        contentView.addSubview(dragLabel)

        // Zoom controls
        let zoomOutBtn = NSButton(title: "−", target: self, action: #selector(canvasZoomOut))
        zoomOutBtn.frame = NSRect(x: contentView.bounds.width - 150, y: contentView.bounds.height - 32, width: 28, height: 22)
        zoomOutBtn.bezelStyle = .rounded
        zoomOutBtn.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        zoomOutBtn.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(zoomOutBtn)

        let zoomLabel = RetroTheme.makeLabel("100%", style: .number, size: 10, color: RetroTheme.neonCyan)
        zoomLabel.frame = NSRect(x: contentView.bounds.width - 118, y: contentView.bounds.height - 28, width: 50, height: 16)
        zoomLabel.alignment = .center
        zoomLabel.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(zoomLabel)
        popOutZoomLabel = zoomLabel

        let zoomInBtn = NSButton(title: "+", target: self, action: #selector(canvasZoomIn))
        zoomInBtn.frame = NSRect(x: contentView.bounds.width - 65, y: contentView.bounds.height - 32, width: 28, height: 22)
        zoomInBtn.bezelStyle = .rounded
        zoomInBtn.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        zoomInBtn.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(zoomInBtn)

        let resetZoomBtn = NSButton(title: "FIT", target: self, action: #selector(canvasZoomReset))
        resetZoomBtn.frame = NSRect(x: contentView.bounds.width - 35, y: contentView.bounds.height - 32, width: 30, height: 22)
        resetZoomBtn.bezelStyle = .rounded
        resetZoomBtn.font = RetroTheme.headerFont(size: 8)
        resetZoomBtn.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(resetZoomBtn)

        // Container for canvas and outputs
        let canvasContainer = NSView(frame: NSRect(x: canvasX, y: 10, width: contentView.bounds.width - canvasX - 10, height: contentView.bounds.height - 50))
        canvasContainer.wantsLayer = true
        canvasContainer.layer?.backgroundColor = RetroTheme.backgroundDeep.cgColor
        canvasContainer.layer?.cornerRadius = 8
        RetroTheme.applyNeonBorder(to: canvasContainer.layer!, color: RetroTheme.sectionCanvas.withAlphaComponent(0.5), width: 2)
        canvasContainer.autoresizingMask = [.width, .height]
        contentView.addSubview(canvasContainer)

        // Image view for live preview (fills container)
        let imageView = NSImageView(frame: canvasContainer.bounds)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        canvasContainer.addSubview(imageView)

        popWindow.contentView = contentView
        popOutWindow = popWindow
        popOutImageView = imageView
        popOutCanvasContainer = canvasContainer

        // Show window
        popWindow.makeKeyAndOrderFront(nil)

        // Draw output overlays
        updatePopOutOutputs()

        // Initial preview update
        updatePopOutPreview()

        // Select first output if available
        if !outputs.isEmpty {
            popOutSelectedIndex = 0
            updatePopOutSettingsForSelection()
        }
    }

    private func buildPopOutSettingsPanel(_ panel: NSView) {
        var y = panel.bounds.height - 20

        // === OUTPUTS LIST ===
        let listHeader = RetroTheme.makeSectionHeader("◆ OUTPUTS", color: RetroTheme.neonMagenta, width: 260)
        listHeader.frame = NSRect(x: 10, y: y, width: 260, height: 20)
        panel.addSubview(listHeader)
        y -= 25

        // Output list (scrollable)
        let listScroll = NSScrollView(frame: NSRect(x: 10, y: y - 100, width: 260, height: 100))
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.borderType = .noBorder
        listScroll.backgroundColor = RetroTheme.backgroundCard

        let listContent = NSView(frame: NSRect(x: 0, y: 0, width: 244, height: max(100, CGFloat(outputs.count * 28))))

        let colors: [NSColor] = [RetroTheme.neonBlue, RetroTheme.neonPurple, RetroTheme.neonGreen, RetroTheme.neonOrange,
                                  RetroTheme.neonRed, RetroTheme.neonYellow, RetroTheme.neonCyan, RetroTheme.neonMagenta]

        for (i, output) in outputs.enumerated() {
            let rowY = listContent.bounds.height - CGFloat((i + 1) * 28)
            let row = NSButton(title: "  \(output.name)", target: self, action: #selector(popOutOutputSelected(_:)))
            row.tag = i
            row.frame = NSRect(x: 0, y: rowY, width: 244, height: 26)
            row.bezelStyle = .rounded
            row.alignment = .left
            row.font = RetroTheme.bodyFont(size: 11)
            row.contentTintColor = colors[i % colors.count]
            row.wantsLayer = true
            if i == popOutSelectedIndex {
                row.layer?.backgroundColor = colors[i % colors.count].withAlphaComponent(0.2).cgColor
            }
            listContent.addSubview(row)
        }

        listScroll.documentView = listContent
        panel.addSubview(listScroll)
        popOutOutputList = listScroll
        y -= 115

        // === SELECTED OUTPUT ===
        let selHeader = RetroTheme.makeSectionHeader("◆ SELECTED OUTPUT", color: RetroTheme.neonCyan, width: 260)
        selHeader.frame = NSRect(x: 10, y: y, width: 260, height: 20)
        panel.addSubview(selHeader)
        y -= 25

        let selectedLabel = RetroTheme.makeLabel("None selected", style: .header, size: 12, color: RetroTheme.textPrimary)
        selectedLabel.frame = NSRect(x: 10, y: y, width: 260, height: 18)
        panel.addSubview(selectedLabel)
        popOutSelectedLabel = selectedLabel
        y -= 25

        // Enabled checkbox
        let enabledCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(popOutEnabledChanged(_:)))
        enabledCheck.frame = NSRect(x: 10, y: y, width: 100, height: 20)
        enabledCheck.attributedTitle = NSAttributedString(
            string: "ENABLED",
            attributes: [
                .font: RetroTheme.headerFont(size: 10),
                .foregroundColor: RetroTheme.neonGreen
            ]
        )
        panel.addSubview(enabledCheck)
        popOutEnabledCheck = enabledCheck
        y -= 30

        // === POSITION ===
        let posHeader = RetroTheme.makeSectionHeader("◆ POSITION", color: RetroTheme.sectionPositions, width: 260)
        posHeader.frame = NSRect(x: 10, y: y, width: 260, height: 20)
        panel.addSubview(posHeader)
        y -= 25

        // X, Y with steppers
        let xLabel = RetroTheme.makeLabel("X:", style: .body, size: 11, color: RetroTheme.textSecondary)
        xLabel.frame = NSRect(x: 10, y: y, width: 20, height: 20)
        panel.addSubview(xLabel)

        let posXField = NSTextField(string: "0")
        posXField.frame = NSRect(x: 28, y: y, width: 50, height: 22)
        posXField.font = RetroTheme.numberFont(size: 12)
        posXField.backgroundColor = RetroTheme.backgroundInput
        posXField.textColor = RetroTheme.neonCyan
        posXField.target = self
        posXField.action = #selector(popOutPositionChanged(_:))
        panel.addSubview(posXField)
        popOutPosXField = posXField

        let xStepper = NSStepper()
        xStepper.frame = NSRect(x: 80, y: y, width: 15, height: 22)
        xStepper.minValue = 0
        xStepper.maxValue = 10000
        xStepper.increment = 1
        xStepper.valueWraps = false
        xStepper.target = self
        xStepper.action = #selector(popOutPosXStepperChanged(_:))
        panel.addSubview(xStepper)
        popOutPosXStepper = xStepper

        let yLabel = RetroTheme.makeLabel("Y:", style: .body, size: 11, color: RetroTheme.textSecondary)
        yLabel.frame = NSRect(x: 105, y: y, width: 20, height: 20)
        panel.addSubview(yLabel)

        let posYField = NSTextField(string: "0")
        posYField.frame = NSRect(x: 123, y: y, width: 50, height: 22)
        posYField.font = RetroTheme.numberFont(size: 12)
        posYField.backgroundColor = RetroTheme.backgroundInput
        posYField.textColor = RetroTheme.neonCyan
        posYField.target = self
        posYField.action = #selector(popOutPositionChanged(_:))
        panel.addSubview(posYField)
        popOutPosYField = posYField

        let yStepper = NSStepper()
        yStepper.frame = NSRect(x: 175, y: y, width: 15, height: 22)
        yStepper.minValue = 0
        yStepper.maxValue = 10000
        yStepper.increment = 1
        yStepper.valueWraps = false
        yStepper.target = self
        yStepper.action = #selector(popOutPosYStepperChanged(_:))
        panel.addSubview(yStepper)
        popOutPosYStepper = yStepper
        y -= 30

        // Width, Height with steppers
        let wLabel = RetroTheme.makeLabel("W:", style: .body, size: 11, color: RetroTheme.textSecondary)
        wLabel.frame = NSRect(x: 10, y: y, width: 22, height: 20)
        panel.addSubview(wLabel)

        let widthField = NSTextField(string: "1920")
        widthField.frame = NSRect(x: 28, y: y, width: 50, height: 22)
        widthField.font = RetroTheme.numberFont(size: 12)
        widthField.backgroundColor = RetroTheme.backgroundInput
        widthField.textColor = RetroTheme.neonCyan
        widthField.target = self
        widthField.action = #selector(popOutSizeChanged(_:))
        panel.addSubview(widthField)
        popOutWidthField = widthField

        let wStepper = NSStepper()
        wStepper.frame = NSRect(x: 80, y: y, width: 15, height: 22)
        wStepper.minValue = 100
        wStepper.maxValue = 10000
        wStepper.increment = 1
        wStepper.valueWraps = false
        wStepper.target = self
        wStepper.action = #selector(popOutWidthStepperChanged(_:))
        panel.addSubview(wStepper)
        popOutWidthStepper = wStepper

        let hLabel = RetroTheme.makeLabel("H:", style: .body, size: 11, color: RetroTheme.textSecondary)
        hLabel.frame = NSRect(x: 105, y: y, width: 20, height: 20)
        panel.addSubview(hLabel)

        let heightField = NSTextField(string: "1080")
        heightField.frame = NSRect(x: 123, y: y, width: 50, height: 22)
        heightField.font = RetroTheme.numberFont(size: 12)
        heightField.backgroundColor = RetroTheme.backgroundInput
        heightField.textColor = RetroTheme.neonCyan
        heightField.target = self
        heightField.action = #selector(popOutSizeChanged(_:))

        let hStepper = NSStepper()
        hStepper.frame = NSRect(x: 175, y: y, width: 15, height: 22)
        hStepper.minValue = 100
        hStepper.maxValue = 10000
        hStepper.increment = 1
        hStepper.valueWraps = false
        hStepper.target = self
        hStepper.action = #selector(popOutHeightStepperChanged(_:))
        panel.addSubview(hStepper)
        popOutHeightStepper = hStepper
        panel.addSubview(heightField)
        popOutHeightField = heightField
        y -= 35

        // === EDGE BLEND ===
        let blendHeader = RetroTheme.makeSectionHeader("◆ EDGE BLEND", color: RetroTheme.sectionBlend, width: 260)
        blendHeader.frame = NSRect(x: 10, y: y, width: 260, height: 20)
        panel.addSubview(blendHeader)
        y -= 25

        // Left, Right with steppers
        let lLabel = RetroTheme.makeLabel("L:", style: .body, size: 11, color: RetroTheme.textSecondary)
        lLabel.frame = NSRect(x: 10, y: y, width: 18, height: 20)
        panel.addSubview(lLabel)

        let blendLField = NSTextField(string: "0")
        blendLField.frame = NSRect(x: 26, y: y, width: 40, height: 22)
        blendLField.font = RetroTheme.numberFont(size: 12)
        blendLField.backgroundColor = RetroTheme.backgroundInput
        blendLField.textColor = RetroTheme.neonOrange
        blendLField.target = self
        blendLField.action = #selector(popOutBlendChanged(_:))
        panel.addSubview(blendLField)
        popOutBlendLField = blendLField

        let lStepper = NSStepper()
        lStepper.frame = NSRect(x: 68, y: y, width: 15, height: 22)
        lStepper.minValue = 0
        lStepper.maxValue = 1000
        lStepper.increment = 1
        lStepper.valueWraps = false
        lStepper.target = self
        lStepper.action = #selector(popOutBlendLStepperChanged(_:))
        panel.addSubview(lStepper)
        popOutBlendLStepper = lStepper

        let rLabel = RetroTheme.makeLabel("R:", style: .body, size: 11, color: RetroTheme.textSecondary)
        rLabel.frame = NSRect(x: 95, y: y, width: 18, height: 20)
        panel.addSubview(rLabel)

        let blendRField = NSTextField(string: "0")
        blendRField.frame = NSRect(x: 111, y: y, width: 40, height: 22)
        blendRField.font = RetroTheme.numberFont(size: 12)
        blendRField.backgroundColor = RetroTheme.backgroundInput
        blendRField.textColor = RetroTheme.neonOrange
        blendRField.target = self
        blendRField.action = #selector(popOutBlendChanged(_:))
        panel.addSubview(blendRField)
        popOutBlendRField = blendRField

        let rStepper = NSStepper()
        rStepper.frame = NSRect(x: 153, y: y, width: 15, height: 22)
        rStepper.minValue = 0
        rStepper.maxValue = 1000
        rStepper.increment = 1
        rStepper.valueWraps = false
        rStepper.target = self
        rStepper.action = #selector(popOutBlendRStepperChanged(_:))
        panel.addSubview(rStepper)
        popOutBlendRStepper = rStepper
        y -= 28

        // Top, Bottom with steppers
        let tLabel = RetroTheme.makeLabel("T:", style: .body, size: 11, color: RetroTheme.textSecondary)
        tLabel.frame = NSRect(x: 10, y: y, width: 18, height: 20)
        panel.addSubview(tLabel)

        let blendTField = NSTextField(string: "0")
        blendTField.frame = NSRect(x: 26, y: y, width: 40, height: 22)
        blendTField.font = RetroTheme.numberFont(size: 12)
        blendTField.backgroundColor = RetroTheme.backgroundInput
        blendTField.textColor = RetroTheme.neonOrange
        blendTField.target = self
        blendTField.action = #selector(popOutBlendChanged(_:))
        panel.addSubview(blendTField)
        popOutBlendTField = blendTField

        let tStepper = NSStepper()
        tStepper.frame = NSRect(x: 68, y: y, width: 15, height: 22)
        tStepper.minValue = 0
        tStepper.maxValue = 1000
        tStepper.increment = 1
        tStepper.valueWraps = false
        tStepper.target = self
        tStepper.action = #selector(popOutBlendTStepperChanged(_:))
        panel.addSubview(tStepper)
        popOutBlendTStepper = tStepper

        let bLabel = RetroTheme.makeLabel("B:", style: .body, size: 11, color: RetroTheme.textSecondary)
        bLabel.frame = NSRect(x: 95, y: y, width: 18, height: 20)
        panel.addSubview(bLabel)

        let blendBField = NSTextField(string: "0")
        blendBField.frame = NSRect(x: 111, y: y, width: 40, height: 22)
        blendBField.font = RetroTheme.numberFont(size: 12)
        blendBField.backgroundColor = RetroTheme.backgroundInput
        blendBField.textColor = RetroTheme.neonOrange
        blendBField.target = self
        blendBField.action = #selector(popOutBlendChanged(_:))
        panel.addSubview(blendBField)
        popOutBlendBField = blendBField

        let bStepper = NSStepper()
        bStepper.frame = NSRect(x: 153, y: y, width: 15, height: 22)
        bStepper.minValue = 0
        bStepper.maxValue = 1000
        bStepper.increment = 1
        bStepper.valueWraps = false
        bStepper.target = self
        bStepper.action = #selector(popOutBlendBStepperChanged(_:))
        panel.addSubview(bStepper)
        popOutBlendBStepper = bStepper
        y -= 35

        // Auto detect button
        let autoBtn = NSButton(title: "AUTO DETECT", target: self, action: #selector(popOutAutoBlend))
        autoBtn.frame = NSRect(x: 10, y: y, width: 120, height: 24)
        autoBtn.bezelStyle = .rounded
        RetroTheme.styleButton(autoBtn, color: RetroTheme.neonCyan)
        panel.addSubview(autoBtn)

        let resetBtn = NSButton(title: "RESET", target: self, action: #selector(popOutResetBlend))
        resetBtn.frame = NSRect(x: 140, y: y, width: 70, height: 24)
        resetBtn.bezelStyle = .rounded
        RetroTheme.styleButton(resetBtn, color: RetroTheme.textSecondary)
        panel.addSubview(resetBtn)
        y -= 40

        // === ALIGNMENT ===
        let alignHeader = RetroTheme.makeSectionHeader("◆ ALIGNMENT", color: RetroTheme.neonYellow, width: 260)
        alignHeader.frame = NSRect(x: 10, y: y, width: 260, height: 20)
        panel.addSubview(alignHeader)
        y -= 30

        let bordersBtn = NSButton(title: "SHOW BORDERS", target: self, action: #selector(toggleShowBorders))
        bordersBtn.frame = NSRect(x: 10, y: y, width: 130, height: 26)
        bordersBtn.bezelStyle = .rounded
        bordersBtn.font = RetroTheme.headerFont(size: 11)
        RetroTheme.styleButton(bordersBtn, color: OutputSettingsWindowController.showBordersActive ? RetroTheme.neonGreen : RetroTheme.neonYellow)
        panel.addSubview(bordersBtn)
        showBordersButton = bordersBtn

        // Test Pattern button
        let patternBtn = NSButton(title: "TEST PATTERN", target: self, action: #selector(toggleTestPattern))
        patternBtn.frame = NSRect(x: 150, y: y, width: 130, height: 26)
        patternBtn.bezelStyle = .rounded
        patternBtn.font = RetroTheme.headerFont(size: 11)
        RetroTheme.styleButton(patternBtn, color: OutputSettingsWindowController.testPatternActive ? RetroTheme.neonGreen : RetroTheme.neonCyan)
        panel.addSubview(patternBtn)
        testPatternButton = patternBtn
        y -= 30

        // Set Text button for test pattern (on new row)
        let textBtn = NSButton(title: "SET PATTERN TEXT", target: self, action: #selector(setTestPatternText))
        textBtn.frame = NSRect(x: 10, y: y, width: 150, height: 26)
        textBtn.bezelStyle = .rounded
        textBtn.font = RetroTheme.headerFont(size: 11)
        RetroTheme.styleButton(textBtn, color: RetroTheme.neonMagenta)
        panel.addSubview(textBtn)
        testPatternTextButton = textBtn
        y -= 50

        // === DELETE OUTPUT ===
        let deleteBtn = NSButton(title: "✕ DELETE OUTPUT", target: self, action: #selector(popOutDeleteOutput))
        deleteBtn.frame = NSRect(x: 10, y: y, width: 260, height: 30)
        deleteBtn.bezelStyle = .rounded
        deleteBtn.font = RetroTheme.headerFont(size: 12)
        RetroTheme.styleButton(deleteBtn, color: RetroTheme.neonRed)
        panel.addSubview(deleteBtn)
        popOutDeleteBtn = deleteBtn
    }

    private func updatePopOutSettingsForSelection() {
        guard popOutSelectedIndex >= 0 && popOutSelectedIndex < outputs.count else {
            popOutSelectedLabel?.stringValue = "None selected"
            return
        }

        let output = outputs[popOutSelectedIndex]
        let pos = getMemberPosition(index: popOutSelectedIndex)

        popOutSelectedLabel?.stringValue = output.name
        popOutSelectedLabel?.textColor = [RetroTheme.neonBlue, RetroTheme.neonPurple, RetroTheme.neonGreen, RetroTheme.neonOrange,
                                           RetroTheme.neonRed, RetroTheme.neonYellow, RetroTheme.neonCyan, RetroTheme.neonMagenta][popOutSelectedIndex % 8]

        popOutEnabledCheck?.state = pos.enabled ? .on : .off
        popOutPosXField?.stringValue = "\(pos.x)"
        popOutPosYField?.stringValue = "\(pos.y)"
        popOutWidthField?.stringValue = "\(pos.w)"
        popOutHeightField?.stringValue = "\(pos.h)"

        // Sync position steppers
        popOutPosXStepper?.doubleValue = Double(pos.x)
        popOutPosYStepper?.doubleValue = Double(pos.y)
        popOutWidthStepper?.doubleValue = Double(pos.w)
        popOutHeightStepper?.doubleValue = Double(pos.h)

        // Get edge blend values from config
        popOutBlendLField?.stringValue = "\(Int(output.config.edgeBlendLeft))"
        popOutBlendRField?.stringValue = "\(Int(output.config.edgeBlendRight))"
        popOutBlendTField?.stringValue = "\(Int(output.config.edgeBlendTop))"
        popOutBlendBField?.stringValue = "\(Int(output.config.edgeBlendBottom))"

        // Sync edge blend steppers
        popOutBlendLStepper?.doubleValue = Double(output.config.edgeBlendLeft)
        popOutBlendRStepper?.doubleValue = Double(output.config.edgeBlendRight)
        popOutBlendTStepper?.doubleValue = Double(output.config.edgeBlendTop)
        popOutBlendBStepper?.doubleValue = Double(output.config.edgeBlendBottom)

        // Update list selection highlighting
        refreshPopOutOutputList()
    }

    private func refreshPopOutOutputList() {
        guard let listScroll = popOutOutputList, let listContent = listScroll.documentView else { return }

        let colors: [NSColor] = [RetroTheme.neonBlue, RetroTheme.neonPurple, RetroTheme.neonGreen, RetroTheme.neonOrange,
                                  RetroTheme.neonRed, RetroTheme.neonYellow, RetroTheme.neonCyan, RetroTheme.neonMagenta]

        for subview in listContent.subviews {
            if let btn = subview as? NSButton {
                let i = btn.tag
                if i == popOutSelectedIndex {
                    btn.layer?.backgroundColor = colors[i % colors.count].withAlphaComponent(0.3).cgColor
                } else {
                    btn.layer?.backgroundColor = nil
                }
            }
        }
    }

    @objc private func popOutOutputSelected(_ sender: NSButton) {
        popOutSelectedIndex = sender.tag
        updatePopOutSettingsForSelection()
        updatePopOutOutputs()
    }

    @objc private func popOutEnabledChanged(_ sender: NSButton) {
        guard popOutSelectedIndex >= 0 && popOutSelectedIndex < outputs.count else { return }
        let output = outputs[popOutSelectedIndex]
        let enabled = sender.state == .on
        OutputManager.shared.enableOutput(id: output.id, enabled: enabled)
        refresh()
        updateCanvasPreview()
        updatePopOutOutputs()
    }

    @objc private func popOutPositionChanged(_ sender: NSTextField) {
        guard popOutSelectedIndex >= 0 else { return }
        let x = Int(popOutPosXField?.stringValue ?? "0") ?? 0
        let y = Int(popOutPosYField?.stringValue ?? "0") ?? 0
        setMemberPosition(index: popOutSelectedIndex, x: x, y: y)
        savePositionAfterDrag(index: popOutSelectedIndex)
        updateCanvasPreview()
        updatePopOutOutputs()
    }

    @objc private func popOutSizeChanged(_ sender: NSTextField) {
        guard popOutSelectedIndex >= 0 && popOutSelectedIndex < outputs.count else { return }
        let w = Int(popOutWidthField?.stringValue ?? "1920") ?? 1920
        let h = Int(popOutHeightField?.stringValue ?? "1080") ?? 1080
        let pos = getMemberPosition(index: popOutSelectedIndex)
        let output = outputs[popOutSelectedIndex]
        // Update position with new size
        OutputManager.shared.updatePosition(id: output.id, x: pos.x, y: pos.y, w: w, h: h)
        refresh()
        updateCanvasPreview()
        updatePopOutOutputs()
    }

    @objc private func popOutBlendChanged(_ sender: NSTextField) {
        guard popOutSelectedIndex >= 0 && popOutSelectedIndex < outputs.count else { return }
        let output = outputs[popOutSelectedIndex]
        let l = Float(popOutBlendLField?.stringValue ?? "0") ?? 0
        let r = Float(popOutBlendRField?.stringValue ?? "0") ?? 0
        let t = Float(popOutBlendTField?.stringValue ?? "0") ?? 0
        let b = Float(popOutBlendBField?.stringValue ?? "0") ?? 0
        OutputManager.shared.updateEdgeBlend(id: output.id, left: l, right: r, top: t, bottom: b, gamma: 2.2)
        // Sync steppers
        popOutBlendLStepper?.doubleValue = Double(l)
        popOutBlendRStepper?.doubleValue = Double(r)
        popOutBlendTStepper?.doubleValue = Double(t)
        popOutBlendBStepper?.doubleValue = Double(b)
        refresh()
    }

    // Pop-out stepper handlers - Position
    @objc private func popOutPosXStepperChanged(_ sender: NSStepper) {
        popOutPosXField?.stringValue = "\(Int(sender.doubleValue))"
        popOutPositionChanged(popOutPosXField!)
    }

    @objc private func popOutPosYStepperChanged(_ sender: NSStepper) {
        popOutPosYField?.stringValue = "\(Int(sender.doubleValue))"
        popOutPositionChanged(popOutPosYField!)
    }

    @objc private func popOutWidthStepperChanged(_ sender: NSStepper) {
        popOutWidthField?.stringValue = "\(Int(sender.doubleValue))"
        popOutSizeChanged(popOutWidthField!)
    }

    @objc private func popOutHeightStepperChanged(_ sender: NSStepper) {
        popOutHeightField?.stringValue = "\(Int(sender.doubleValue))"
        popOutSizeChanged(popOutHeightField!)
    }

    // Pop-out stepper handlers - Edge Blend
    @objc private func popOutBlendLStepperChanged(_ sender: NSStepper) {
        popOutBlendLField?.stringValue = "\(Int(sender.doubleValue))"
        popOutBlendChanged(popOutBlendLField!)
    }

    @objc private func popOutBlendRStepperChanged(_ sender: NSStepper) {
        popOutBlendRField?.stringValue = "\(Int(sender.doubleValue))"
        popOutBlendChanged(popOutBlendRField!)
    }

    @objc private func popOutBlendTStepperChanged(_ sender: NSStepper) {
        popOutBlendTField?.stringValue = "\(Int(sender.doubleValue))"
        popOutBlendChanged(popOutBlendTField!)
    }

    @objc private func popOutBlendBStepperChanged(_ sender: NSStepper) {
        popOutBlendBField?.stringValue = "\(Int(sender.doubleValue))"
        popOutBlendChanged(popOutBlendBField!)
    }

    @objc private func popOutAutoBlend() {
        autoDetectEdgeBlend()
        updatePopOutSettingsForSelection()
    }

    @objc private func popOutResetBlend() {
        guard popOutSelectedIndex >= 0 && popOutSelectedIndex < outputs.count else { return }
        let output = outputs[popOutSelectedIndex]
        OutputManager.shared.updateEdgeBlend(id: output.id, left: 0, right: 0, top: 0, bottom: 0, gamma: 2.2)
        refresh()
        updatePopOutSettingsForSelection()
    }

    @objc private func canvasZoomIn() {
        popOutZoom = min(popOutZoom * 1.25, 3.0)  // Max 300%
        updateZoomLabel()
        updatePopOutOutputs()
    }

    @objc private func canvasZoomOut() {
        popOutZoom = max(popOutZoom * 0.8, 0.1)  // Min 10%
        updateZoomLabel()
        updatePopOutOutputs()
    }

    @objc private func canvasZoomReset() {
        popOutZoom = 1.0
        updateZoomLabel()
        updatePopOutOutputs()
    }

    private func updateZoomLabel() {
        popOutZoomLabel?.stringValue = "\(Int(popOutZoom * 100))%"
    }

    @objc private func popOutDeleteOutput() {
        guard popOutSelectedIndex >= 0 && popOutSelectedIndex < outputs.count else { return }
        let output = outputs[popOutSelectedIndex]

        // Confirm deletion
        let alert = NSAlert()
        alert.messageText = "Delete Output?"
        alert.informativeText = "Are you sure you want to delete '\(output.name)'?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            OutputManager.shared.removeOutput(id: output.id)
            popOutSelectedIndex = -1
            refresh()
            rebuildPopOutOutputList()
            updatePopOutOutputs()
            updatePopOutSettingsForSelection()
        }
    }

    private func rebuildPopOutOutputList() {
        guard let panel = popOutSettingsPanel else { return }
        // Remove and rebuild the output list
        popOutOutputList?.removeFromSuperview()
        outputs = OutputManager.shared.getAllOutputs()
        buildPopOutSettingsPanel(panel)
    }

    @objc private func toggleShowBorders() {
        OutputSettingsWindowController.showBordersActive.toggle()
        let active = OutputSettingsWindowController.showBordersActive

        // Update button appearance
        if active {
            showBordersButton?.title = "HIDE BORDERS"
            RetroTheme.styleButton(showBordersButton!, color: RetroTheme.neonGreen)
        } else {
            showBordersButton?.title = "SHOW BORDERS"
            RetroTheme.styleButton(showBordersButton!, color: RetroTheme.neonYellow)
        }

    }

    @objc private func toggleTestPattern() {
        OutputSettingsWindowController.testPatternActive.toggle()
        let active = OutputSettingsWindowController.testPatternActive

        // Update button appearance
        if active {
            testPatternButton?.title = "HIDE PATTERN"
            RetroTheme.styleButton(testPatternButton!, color: RetroTheme.neonGreen)
        } else {
            testPatternButton?.title = "TEST PATTERN"
            RetroTheme.styleButton(testPatternButton!, color: RetroTheme.neonCyan)
        }

    }

    @objc private func setTestPatternText() {
        // Create alert with text input
        let alert = NSAlert()
        alert.messageText = "Test Pattern Text"
        alert.informativeText = "Enter text to display in the center of the test pattern:"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")

        // Create text field
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = OutputSettingsWindowController.testPatternText
        textField.placeholderString = "Enter text here..."
        alert.accessoryView = textField

        // Style the alert
        alert.window.appearance = NSAppearance(named: .darkAqua)

        // Show alert
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // OK - set the text
            OutputSettingsWindowController.testPatternText = textField.stringValue
        } else if response == .alertThirdButtonReturn {
            // Clear - remove text
            OutputSettingsWindowController.testPatternText = ""
        }
    }

    /// Update draggable output rectangles in pop-out window
    func updatePopOutOutputs() {
        guard let container = popOutCanvasContainer else { return }

        // Remove old output views
        for view in popOutOutputViews {
            view.removeFromSuperview()
        }
        popOutOutputViews.removeAll()

        let canvasW = CGFloat(Int(canvasWidthField?.stringValue ?? "7680") ?? 7680)
        let canvasH = CGFloat(Int(canvasHeightField?.stringValue ?? "1080") ?? 1080)

        // Calculate scale to fit canvas in container with padding, then apply zoom
        let containerW = container.bounds.width - 8
        let containerH = container.bounds.height - 8
        let fitScale = min(containerW / canvasW, containerH / canvasH)
        let scale = fitScale * popOutZoom  // Apply zoom factor

        let scaledW = canvasW * scale
        let scaledH = canvasH * scale
        let offsetX = (container.bounds.width - scaledW) / 2
        let offsetY = (container.bounds.height - scaledH) / 2

        let colors: [NSColor] = [RetroTheme.neonBlue, RetroTheme.neonPurple, RetroTheme.neonGreen, RetroTheme.neonOrange,
                                  RetroTheme.neonRed, RetroTheme.neonYellow, RetroTheme.neonCyan, RetroTheme.neonMagenta]

        // Draw output rectangles
        for (i, output) in outputs.enumerated() {
            let member = getMemberPosition(index: i)
            if !member.enabled { continue }

            // Convert CENTER-RELATIVE offset to top-left pixel position
            // Position x/y are OFFSETS from canvas center (0 = centered)
            let leftEdge = (canvasW / 2.0) + CGFloat(member.x) - (CGFloat(member.w) / 2.0)
            let topEdge = (canvasH / 2.0) + CGFloat(member.y) - (CGFloat(member.h) / 2.0)

            // Convert to preview coordinates (AppKit Y=0 is bottom, canvas Y=0 is top)
            let x = offsetX + leftEdge * scale
            let y = offsetY + scaledH - (topEdge + CGFloat(member.h)) * scale
            let w = CGFloat(member.w) * scale
            let h = CGFloat(member.h) * scale

            let isSelected = (i == popOutSelectedIndex)
            let color = colors[i % colors.count]

            // Create draggable output view
            let rect = DraggableOutputView(frame: NSRect(x: x, y: y, width: w, height: h))
            rect.outputIndex = i
            rect.scale = scale
            rect.canvasHeight = canvasH
            rect.controller = self
            rect.wantsLayer = true

            // Highlight selected output
            if isSelected {
                rect.layer?.backgroundColor = color.withAlphaComponent(0.45).cgColor
                rect.layer?.borderWidth = 4
                rect.layer?.borderColor = color.cgColor
                rect.layer?.shadowColor = color.cgColor
                rect.layer?.shadowRadius = 8
                rect.layer?.shadowOpacity = 0.8
                rect.layer?.shadowOffset = .zero
            } else {
                rect.layer?.backgroundColor = color.withAlphaComponent(0.25).cgColor
                rect.layer?.borderWidth = 2
                rect.layer?.borderColor = color.withAlphaComponent(0.7).cgColor
            }
            container.addSubview(rect)
            popOutOutputViews.append(rect)

            // Drag handle indicator (4 dots in center)
            let handleSize: CGFloat = 20
            let handleView = NSView(frame: NSRect(x: (w - handleSize) / 2, y: (h - handleSize) / 2, width: handleSize, height: handleSize))
            handleView.wantsLayer = true
            for dx in [0, 10] as [CGFloat] {
                for dy in [0, 10] as [CGFloat] {
                    let dot = NSView(frame: NSRect(x: dx, y: dy, width: 6, height: 6))
                    dot.wantsLayer = true
                    dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(isSelected ? 0.9 : 0.5).cgColor
                    dot.layer?.cornerRadius = 3
                    handleView.addSubview(dot)
                }
            }
            rect.addSubview(handleView)

            // Output label
            let label = RetroTheme.makeLabel(output.name, style: .header, size: 11, color: .white)
            label.alignment = .center
            label.frame = NSRect(x: 4, y: h/2 + 12, width: w - 8, height: 16)
            label.cell?.lineBreakMode = .byTruncatingTail
            rect.addSubview(label)

            // Position info
            let posLabel = RetroTheme.makeLabel("\(member.x), \(member.y)  [\(member.w)×\(member.h)]", style: .body, size: 10, color: NSColor.white.withAlphaComponent(0.8))
            posLabel.frame = NSRect(x: 4, y: 4, width: w - 8, height: 14)
            rect.addSubview(posLabel)
        }
    }

    /// Called when an output is clicked in the pop-out canvas
    func selectPopOutOutput(index: Int) {
        popOutSelectedIndex = index
        updatePopOutSettingsForSelection()
        updatePopOutOutputs()
    }

    private func updatePopOutPreview() {
        // Initial update when window opens - timer will keep it updated
        guard let imageView = popOutImageView else { return }
        guard let renderView = sharedMetalRenderView else { return }

        if let image = renderView.capturePreviewFrame() {
            imageView.image = image
        }
    }

    @objc private func saveClicked() {
        let canvasW = Float(canvasWidthField.stringValue) ?? 1920
        let canvasH = Float(canvasHeightField.stringValue) ?? 1080

        // Read actual positions from fields and calculate normalized crop values
        for (i, output) in outputs.enumerated() {
            let pos = getMemberPosition(index: i)
            if !pos.enabled { continue }

            // Convert pixel positions to normalized crop (0-1)
            let cropX = Float(pos.x) / canvasW
            let cropY = Float(pos.y) / canvasH
            let cropW = Float(pos.w) / canvasW
            let cropH = Float(pos.h) / canvasH

            OutputManager.shared.updateCrop(id: output.id, x: cropX, y: cropY, width: cropW, height: cropH)

            // Apply edge blending based on detected overlaps
            if output.type == .display && blendEnabledCheck.state == .on {
                let gamma = Float(blendGammaField?.stringValue ?? "2.2") ?? 2.2

                // Calculate feather values from overlaps
                var featherL: Float = 0, featherR: Float = 0, featherT: Float = 0, featherB: Float = 0

                for j in 0..<outputs.count {
                    if i == j { continue }
                    let otherPos = getMemberPosition(index: j)
                    if !otherPos.enabled { continue }

                    // Left overlap
                    if otherPos.x < pos.x && otherPos.x + otherPos.w > pos.x {
                        featherL = max(featherL, Float(otherPos.x + otherPos.w - pos.x))
                    }
                    // Right overlap
                    if otherPos.x > pos.x && otherPos.x < pos.x + pos.w {
                        featherR = max(featherR, Float(pos.x + pos.w - otherPos.x))
                    }

                    // Only check vertical overlaps if there's horizontal overlap
                    let horizontalOverlap = !(pos.x + pos.w <= otherPos.x || otherPos.x + otherPos.w <= pos.x)
                    if horizontalOverlap {
                        // Top overlap
                        if otherPos.y < pos.y && otherPos.y + otherPos.h > pos.y {
                            featherT = max(featherT, Float(otherPos.y + otherPos.h - pos.y))
                        }
                        // Bottom overlap
                        if otherPos.y > pos.y && otherPos.y < pos.y + pos.h {
                            featherB = max(featherB, Float(pos.y + pos.h - otherPos.y))
                        }
                    }
                }

                OutputManager.shared.updateEdgeBlend(
                    id: output.id,
                    left: featherL, right: featherR,
                    top: featherT, bottom: featherB,
                    gamma: gamma
                )
            }
        }

        window?.close()
    }

    // MARK: - Live Preview

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Refresh after window appears to ensure correct dimensions
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
            self?.startLivePreviewTimer()
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopLivePreviewTimer()
        // Canvas NDI now managed by CanvasNDIManager singleton - keeps running when window closes
    }

    private func startLivePreviewTimer() {
        stopLivePreviewTimer()
        // Update at ~10 fps for smooth preview without too much overhead
        livePreviewTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateLivePreviewImage()
            // Also refresh canvas preview to show DMX position changes
            self?.refreshCanvasPreviewFromDMX()
        }
    }

    /// Refresh canvas preview if output positions changed via DMX
    private var lastOutputPositions: [UUID: (Int, Int)] = [:]

    private func refreshCanvasPreviewFromDMX() {
        // Check if any output positions changed from what we last saw
        let currentOutputs = OutputManager.shared.getAllOutputs()
        var needsRefresh = false

        for output in currentOutputs {
            let configX = output.config.positionX ?? 0
            let configY = output.config.positionY ?? 0

            if let lastPos = lastOutputPositions[output.id] {
                if lastPos.0 != configX || lastPos.1 != configY {
                    needsRefresh = true
                }
            }
            lastOutputPositions[output.id] = (configX, configY)
        }

        if needsRefresh {
            outputs = currentOutputs
            updateCanvasPreview()
            updatePopOutOutputs()  // Also update pop-out window
        }
    }

    private func stopLivePreviewTimer() {
        livePreviewTimer?.invalidate()
        livePreviewTimer = nil
    }

    private func updateLivePreviewImage() {
        guard let renderView = sharedMetalRenderView else {
            NSLog("LivePreview: No sharedMetalRenderView")
            return
        }

        // Find imageView from hierarchy (reference can become stale when updateCanvasPreview recreates views)
        guard let canvasBg = canvasPreview.subviews.first else {
            NSLog("LivePreview: No canvasBg subview")
            return
        }

        guard let imageView = canvasBg.subviews.first as? NSImageView else {
            NSLog("LivePreview: No NSImageView found in canvasBg (has %d subviews, first is %@)",
                  canvasBg.subviews.count,
                  canvasBg.subviews.first.map { String(describing: type(of: $0)) } ?? "nil")
            return
        }

        // Use optimized preview capture (reusable buffer, 1/4 resolution, skip if busy)
        if let image = renderView.capturePreviewFrame() {
            imageView.image = image
            // Also update pop-out window if visible
            popOutImageView?.image = image
        }
        // Note: capturePreviewFrame returns nil when busy - this is expected and helps reduce CPU
    }

    // MARK: - Corner Popup for Quad Warp

    @objc private func toggleCornerPopup(_ sender: NSButton) {
        cornerPopupEnabled = (sender.state == .on)
        if cornerPopupEnabled {
            showCornerPopup()
            updateCornerOverlay()
        } else {
            hideCornerPopup()
            // Clear all corner overlays on all outputs
            OutputManager.shared.clearAllActiveCorners()
        }
    }

    private func showCornerPopup() {
        guard cornerPopupEnabled else { return }

        if cornerPopupPanel == nil {
            createCornerPopupPanel()
        }

        // Position popup in bottom-left of screen
        if let screen = NSScreen.main {
            let popupFrame = NSRect(x: 20, y: 80, width: 140, height: 80)
            cornerPopupPanel?.setFrame(popupFrame, display: true)
        }

        cornerPopupPanel?.orderFront(nil)
        updateCornerPopup()
    }

    private func hideCornerPopup() {
        cornerPopupPanel?.orderOut(nil)
    }

    private func createCornerPopupPanel() {
        // Create a small floating panel with retro theme - movable
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 80),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = RetroTheme.backgroundDeep
        panel.hasShadow = true
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true  // Make draggable anywhere

        // Content view with retro styling
        let contentView = DraggableCornerPopupView(frame: NSRect(x: 0, y: 0, width: 140, height: 80))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = RetroTheme.backgroundDeep.withAlphaComponent(0.95).cgColor
        contentView.layer?.cornerRadius = 8
        contentView.layer?.borderWidth = 2
        contentView.layer?.borderColor = RetroTheme.neonPurple.cgColor

        // Title label
        let titleLabel = RetroTheme.makeLabel("CORNER", style: .header, size: 9, color: RetroTheme.textSecondary)
        titleLabel.frame = NSRect(x: 10, y: 56, width: 60, height: 16)
        contentView.addSubview(titleLabel)

        // Corner name label (big, prominent)
        let cornerLabel = NSTextField(labelWithString: "TL")
        cornerLabel.frame = NSRect(x: 70, y: 50, width: 60, height: 26)
        cornerLabel.font = RetroTheme.numberFont(size: 22)
        cornerLabel.textColor = RetroTheme.neonPurple
        cornerLabel.alignment = .right
        contentView.addSubview(cornerLabel)
        cornerPopupCornerLabel = cornerLabel

        // X position
        let xTitleLabel = RetroTheme.makeLabel("X:", style: .header, size: 10, color: RetroTheme.textSecondary)
        xTitleLabel.frame = NSRect(x: 10, y: 28, width: 18, height: 16)
        contentView.addSubview(xTitleLabel)

        let xLabel = NSTextField(labelWithString: "0")
        xLabel.frame = NSRect(x: 28, y: 28, width: 50, height: 16)
        xLabel.font = RetroTheme.numberFont(size: 14)
        xLabel.textColor = RetroTheme.neonCyan
        xLabel.alignment = .left
        contentView.addSubview(xLabel)
        cornerPopupXLabel = xLabel

        // Y position
        let yTitleLabel = RetroTheme.makeLabel("Y:", style: .header, size: 10, color: RetroTheme.textSecondary)
        yTitleLabel.frame = NSRect(x: 80, y: 28, width: 18, height: 16)
        contentView.addSubview(yTitleLabel)

        let yLabel = NSTextField(labelWithString: "0")
        yLabel.frame = NSRect(x: 98, y: 28, width: 40, height: 16)
        yLabel.font = RetroTheme.numberFont(size: 14)
        yLabel.textColor = RetroTheme.neonCyan
        yLabel.alignment = .left
        contentView.addSubview(yLabel)
        cornerPopupYLabel = yLabel

        // Output name at bottom
        let outputLabel = RetroTheme.makeLabel("", style: .header, size: 8, color: RetroTheme.textSecondary.withAlphaComponent(0.7))
        outputLabel.frame = NSRect(x: 10, y: 6, width: 120, height: 14)
        outputLabel.alignment = .center
        outputLabel.tag = 999  // Tag to find it later
        contentView.addSubview(outputLabel)

        panel.contentView = contentView
        cornerPopupPanel = panel
    }

    private func updateCornerPopup() {
        guard cornerPopupEnabled, let panel = cornerPopupPanel else { return }
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        // Update corner name
        cornerPopupCornerLabel?.stringValue = activeCorner

        // Get current values for active corner
        let x: Float
        let y: Float
        switch activeCorner {
        case "TL":
            x = Float(warpTLXField.stringValue) ?? 0
            y = Float(warpTLYField.stringValue) ?? 0
        case "TR":
            x = Float(warpTRXField.stringValue) ?? 0
            y = Float(warpTRYField.stringValue) ?? 0
        case "BL":
            x = Float(warpBLXField.stringValue) ?? 0
            y = Float(warpBLYField.stringValue) ?? 0
        case "BR":
            x = Float(warpBRXField.stringValue) ?? 0
            y = Float(warpBRYField.stringValue) ?? 0
        default:
            x = 0
            y = 0
        }

        cornerPopupXLabel?.stringValue = String(format: "%.0f", x)
        cornerPopupYLabel?.stringValue = String(format: "%.0f", y)

        // Update output name in the popup
        if let outputLabel = panel.contentView?.viewWithTag(999) as? NSTextField {
            outputLabel.stringValue = output.config.name
        }

        // Make sure popup is visible
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func setActiveCorner(from sender: Any?) {
        // Determine which corner is being adjusted
        if let stepper = sender as? NSStepper {
            if stepper === warpTLXStepper || stepper === warpTLYStepper {
                activeCorner = "TL"
            } else if stepper === warpTRXStepper || stepper === warpTRYStepper {
                activeCorner = "TR"
            } else if stepper === warpBLXStepper || stepper === warpBLYStepper {
                activeCorner = "BL"
            } else if stepper === warpBRXStepper || stepper === warpBRYStepper {
                activeCorner = "BR"
            }
        } else if let field = sender as? NSTextField {
            if field === warpTLXField || field === warpTLYField {
                activeCorner = "TL"
            } else if field === warpTRXField || field === warpTRYField {
                activeCorner = "TR"
            } else if field === warpBLXField || field === warpBLYField {
                activeCorner = "BL"
            } else if field === warpBRXField || field === warpBRYField {
                activeCorner = "BR"
            }
        }
    }

    private func updateCornerOverlay() {
        guard cornerPopupEnabled else {
            // Clear overlay if popup disabled
            if selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count {
                let output = outputs[selectedOutputIndex]
                OutputManager.shared.setActiveCorner(id: output.id, corner: 0)
            }
            return
        }
        guard selectedOutputIndex >= 0 && selectedOutputIndex < outputs.count else { return }
        let output = outputs[selectedOutputIndex]

        // Convert corner string to int (1=TL, 2=TR, 3=BL, 4=BR)
        let cornerInt: Int32
        switch activeCorner {
        case "TL": cornerInt = 1
        case "TR": cornerInt = 2
        case "BL": cornerInt = 3
        case "BR": cornerInt = 4
        default: cornerInt = 0
        }

        OutputManager.shared.setActiveCorner(id: output.id, corner: cornerInt)
    }
}

// MARK: - Window Management

nonisolated(unsafe) private var outputSettingsWindow: OutputSettingsWindowController?

@MainActor
func showOutputSettingsWindow() {
    if outputSettingsWindow == nil {
        outputSettingsWindow = OutputSettingsWindowController()
    }
    outputSettingsWindow?.refresh()
    outputSettingsWindow?.showWindow(nil)
    outputSettingsWindow?.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

@MainActor
func refreshOutputSettingsWindowIfVisible() {
    outputSettingsWindow?.refresh()
}
