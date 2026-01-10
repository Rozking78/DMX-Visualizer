// WarpWindowController.swift - Dedicated quad warp/keystone adjustment window
// Provides visual corner dragging and numeric controls for output warping

import Cocoa
import Metal

// MARK: - Warp Handle View (for both corners and middles)
class WarpHandle: NSView {
    var handleIndex: Int = 0  // 0-3=corners (TL,TR,BL,BR), 4-7=middles (TM,MR,BM,ML)
    var isCorner: Bool = true
    var isActive = false
    var onDrag: ((CGPoint) -> Void)?
    var onSelect: (() -> Void)?

    private var isDragging = false
    private var dragStart: CGPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func updateAppearance() {
        if isActive {
            layer?.backgroundColor = NSColor.cyan.cgColor
            layer?.borderColor = NSColor.white.cgColor
            layer?.borderWidth = 2
        } else if isCorner {
            layer?.backgroundColor = NSColor.yellow.withAlphaComponent(0.8).cgColor
            layer?.borderColor = NSColor.black.cgColor
            layer?.borderWidth = 1
        } else {
            // Middle points - purple/magenta color
            layer?.backgroundColor = NSColor.magenta.withAlphaComponent(0.8).cgColor
            layer?.borderColor = NSColor.black.cgColor
            layer?.borderWidth = 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStart = convert(event.locationInWindow, from: nil)
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let current = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: current.x - dragStart.x, y: current.y - dragStart.y)
        onDrag?(delta)
        dragStart = current
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}

// MARK: - Warp Preview View with 8-point support
class WarpPreviewView: NSView {
    var texture: MTLTexture?
    // Corner offsets: TL, TR, BL, BR
    var cornerOffsets: [CGPoint] = [.zero, .zero, .zero, .zero]
    // Middle offsets: TM, MR, BM, ML
    var middleOffsets: [CGPoint] = [.zero, .zero, .zero, .zero]

    var cornerHandles: [WarpHandle] = []
    var middleHandles: [WarpHandle] = []
    var showMiddles: Bool = false
    var activeHandle: Int = -1  // 0-3=corners, 4-7=middles

    var onHandleDrag: ((Int, CGPoint) -> Void)?
    var onHandleSelect: ((Int) -> Void)?

    private let handleSize: CGFloat = 20
    private let middleHandleSize: CGFloat = 16
    private var draggingHandle: Int = -1
    private var lastDragLocation: CGPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.darkGray.cgColor
        layer?.borderColor = NSColor.gray.cgColor
        layer?.borderWidth = 1

        // Create corner handles (0-3)
        for i in 0..<4 {
            let handle = WarpHandle(frame: NSRect(x: 0, y: 0, width: handleSize, height: handleSize))
            handle.handleIndex = i
            handle.isCorner = true
            handle.onDrag = { [weak self] delta in
                self?.onHandleDrag?(i, delta)
            }
            handle.onSelect = { [weak self] in
                self?.startDragging(handle: i)
                self?.onHandleSelect?(i)
            }
            cornerHandles.append(handle)
            addSubview(handle)
        }

        // Create middle handles (4-7: TM, MR, BM, ML)
        for i in 0..<4 {
            let handle = WarpHandle(frame: NSRect(x: 0, y: 0, width: middleHandleSize, height: middleHandleSize))
            handle.handleIndex = i + 4
            handle.isCorner = false
            handle.onDrag = { [weak self] delta in
                self?.onHandleDrag?(i + 4, delta)
            }
            handle.onSelect = { [weak self] in
                self?.startDragging(handle: i + 4)
                self?.onHandleSelect?(i + 4)
            }
            middleHandles.append(handle)
            addSubview(handle)
            handle.isHidden = true  // Hidden by default
        }

        updateHandlePositions()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func startDragging(handle: Int) {
        draggingHandle = handle
        if let window = window {
            lastDragLocation = window.mouseLocationOutsideOfEventStream
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingHandle >= 0 else { return }
        let current = event.locationInWindow
        let delta = CGPoint(x: current.x - lastDragLocation.x, y: current.y - lastDragLocation.y)
        lastDragLocation = current
        onHandleDrag?(draggingHandle, delta)
    }

    override func mouseUp(with event: NSEvent) {
        draggingHandle = -1
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateHandlePositions() {
        let inset: CGFloat = 30
        let w = bounds.width
        let h = bounds.height

        // Base corner positions (in view coords - Y is flipped)
        let baseCorners: [CGPoint] = [
            CGPoint(x: inset, y: h - inset),           // TL
            CGPoint(x: w - inset, y: h - inset),       // TR
            CGPoint(x: inset, y: inset),               // BL
            CGPoint(x: w - inset, y: inset)            // BR
        ]

        // Base middle positions
        let baseMiddles: [CGPoint] = [
            CGPoint(x: w / 2, y: h - inset),           // TM
            CGPoint(x: w - inset, y: h / 2),           // MR
            CGPoint(x: w / 2, y: inset),               // BM
            CGPoint(x: inset, y: h / 2)                // ML
        ]

        // Scale factor for warp offsets (pixels to view coords)
        let scale: CGFloat = min((w - 2 * inset) / 1920.0, (h - 2 * inset) / 1080.0)

        // Update corner handles
        for (i, handle) in cornerHandles.enumerated() {
            let base = baseCorners[i]
            let offset = cornerOffsets[i]
            let pos = CGPoint(
                x: base.x + offset.x * scale,
                y: base.y - offset.y * scale
            )
            handle.frame = NSRect(
                x: pos.x - handleSize / 2,
                y: pos.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            handle.isActive = (activeHandle == i)
            handle.updateAppearance()
        }

        // Update middle handles
        for (i, handle) in middleHandles.enumerated() {
            let base = baseMiddles[i]
            let offset = middleOffsets[i]
            let pos = CGPoint(
                x: base.x + offset.x * scale,
                y: base.y - offset.y * scale
            )
            handle.frame = NSRect(
                x: pos.x - middleHandleSize / 2,
                y: pos.y - middleHandleSize / 2,
                width: middleHandleSize,
                height: middleHandleSize
            )
            handle.isHidden = !showMiddles
            handle.isActive = (activeHandle == i + 4)
            handle.updateAppearance()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let inset: CGFloat = 30
        let w = bounds.width
        let h = bounds.height
        let scale: CGFloat = min((w - 2 * inset) / 1920.0, (h - 2 * inset) / 1080.0)

        // Calculate actual corner positions
        let corners: [CGPoint] = [
            CGPoint(x: inset + cornerOffsets[0].x * scale, y: h - inset - cornerOffsets[0].y * scale),  // TL
            CGPoint(x: w - inset + cornerOffsets[1].x * scale, y: h - inset - cornerOffsets[1].y * scale),  // TR
            CGPoint(x: w - inset + cornerOffsets[3].x * scale, y: inset - cornerOffsets[3].y * scale),  // BR
            CGPoint(x: inset + cornerOffsets[2].x * scale, y: inset - cornerOffsets[2].y * scale)   // BL
        ]

        // Calculate middle positions
        let middles: [CGPoint] = [
            CGPoint(x: w / 2 + middleOffsets[0].x * scale, y: h - inset - middleOffsets[0].y * scale),  // TM
            CGPoint(x: w - inset + middleOffsets[1].x * scale, y: h / 2 - middleOffsets[1].y * scale),  // MR
            CGPoint(x: w / 2 + middleOffsets[2].x * scale, y: inset - middleOffsets[2].y * scale),      // BM
            CGPoint(x: inset + middleOffsets[3].x * scale, y: h / 2 - middleOffsets[3].y * scale)       // ML
        ]

        // Fill with dark color - draw curved path if middles are active
        context.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor)

        if showMiddles {
            // Draw with curved edges using quadratic bezier through middles
            context.move(to: corners[0])  // TL
            context.addQuadCurve(to: corners[1], control: middles[0])  // Top edge through TM
            context.addQuadCurve(to: corners[2], control: middles[1])  // Right edge through MR
            context.addQuadCurve(to: corners[3], control: middles[2])  // Bottom edge through BM
            context.addQuadCurve(to: corners[0], control: middles[3])  // Left edge through ML
        } else {
            context.move(to: corners[0])
            for corner in corners.dropFirst() {
                context.addLine(to: corner)
            }
            context.closePath()
        }
        context.fillPath()

        // Draw grid lines
        context.setStrokeColor(NSColor(white: 0.3, alpha: 1).cgColor)
        context.setLineWidth(1)

        // Vertical grid lines (simplified for curved mode)
        for i in 1..<4 {
            let t = CGFloat(i) / 4.0
            let top = CGPoint(
                x: corners[0].x + (corners[1].x - corners[0].x) * t,
                y: corners[0].y + (corners[1].y - corners[0].y) * t
            )
            let bottom = CGPoint(
                x: corners[3].x + (corners[2].x - corners[3].x) * t,
                y: corners[3].y + (corners[2].y - corners[3].y) * t
            )
            context.move(to: top)
            context.addLine(to: bottom)
        }

        // Horizontal grid lines
        for i in 1..<3 {
            let t = CGFloat(i) / 3.0
            let left = CGPoint(
                x: corners[0].x + (corners[3].x - corners[0].x) * t,
                y: corners[0].y + (corners[3].y - corners[0].y) * t
            )
            let right = CGPoint(
                x: corners[1].x + (corners[2].x - corners[1].x) * t,
                y: corners[1].y + (corners[2].y - corners[1].y) * t
            )
            context.move(to: left)
            context.addLine(to: right)
        }
        context.strokePath()

        // Draw quad border (curved or straight)
        context.setStrokeColor(NSColor.cyan.cgColor)
        context.setLineWidth(2)

        if showMiddles {
            context.move(to: corners[0])
            context.addQuadCurve(to: corners[1], control: middles[0])
            context.addQuadCurve(to: corners[2], control: middles[1])
            context.addQuadCurve(to: corners[3], control: middles[2])
            context.addQuadCurve(to: corners[0], control: middles[3])
        } else {
            context.move(to: corners[0])
            for corner in corners.dropFirst() {
                context.addLine(to: corner)
            }
            context.closePath()
        }
        context.strokePath()

        // Draw corner labels
        let cornerLabels = ["TL", "TR", "BL", "BR"]
        let labelPositions = [corners[0], corners[1], corners[3], corners[2]]
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        for (i, pos) in labelPositions.enumerated() {
            let str = NSAttributedString(string: cornerLabels[i], attributes: attrs)
            let offset: CGFloat = i < 2 ? 15 : -25
            str.draw(at: CGPoint(x: pos.x - 8, y: pos.y + offset))
        }

        // Draw middle labels if visible
        if showMiddles {
            let middleLabels = ["TM", "MR", "BM", "ML"]
            let middleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.magenta
            ]
            for (i, pos) in middles.enumerated() {
                let str = NSAttributedString(string: middleLabels[i], attributes: middleAttrs)
                str.draw(at: CGPoint(x: pos.x - 8, y: pos.y + 12))
            }
        }
    }

    override func layout() {
        super.layout()
        updateHandlePositions()
    }
}

// MARK: - Warp Window Controller
class WarpWindowController: NSWindowController, NSWindowDelegate {

    private var outputId: UUID?
    private var outputName: String = ""

    private var previewView: WarpPreviewView!
    private var activeHandleLabel: NSTextField!
    private var showMiddlesCheckbox: NSButton!

    // Corner value fields (TL, TR, BL, BR)
    private var tlxField: NSTextField!
    private var tlyField: NSTextField!
    private var trxField: NSTextField!
    private var tryField: NSTextField!
    private var blxField: NSTextField!
    private var blyField: NSTextField!
    private var brxField: NSTextField!
    private var bryField: NSTextField!

    // Middle value fields (TM, MR, BM, ML)
    private var tmxField: NSTextField!
    private var tmyField: NSTextField!
    private var mrxField: NSTextField!
    private var mryField: NSTextField!
    private var bmxField: NSTextField!
    private var bmyField: NSTextField!
    private var mlxField: NSTextField!
    private var mlyField: NSTextField!

    // Steppers
    private var tlxStepper: NSStepper!
    private var tlyStepper: NSStepper!
    private var trxStepper: NSStepper!
    private var tryStepper: NSStepper!
    private var blxStepper: NSStepper!
    private var blyStepper: NSStepper!
    private var brxStepper: NSStepper!
    private var bryStepper: NSStepper!

    private var tmxStepper: NSStepper!
    private var tmyStepper: NSStepper!
    private var mrxStepper: NSStepper!
    private var mryStepper: NSStepper!
    private var bmxStepper: NSStepper!
    private var bmyStepper: NSStepper!
    private var mlxStepper: NSStepper!
    private var mlyStepper: NSStepper!

    private var cornerFields: [NSTextField] = []
    private var cornerSteppers: [NSStepper] = []
    private var middleFields: [NSTextField] = []
    private var middleSteppers: [NSStepper] = []
    private var middleControls: [NSView] = []  // For toggling visibility

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quad Warp / Keystone"
        window.minSize = NSSize(width: 400, height: 520)
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)

        self.init(window: window)
        window.delegate = self

        setupUI()
    }

    func configure(outputId: UUID, name: String) {
        self.outputId = outputId
        self.outputName = name
        window?.title = "Quad Warp - \(name)"
        loadCurrentValues()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        var y = contentView.bounds.height - 30

        // Title
        let title = NSTextField(labelWithString: "QUAD WARP / KEYSTONE ADJUSTMENT")
        title.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        title.textColor = .cyan
        title.frame = NSRect(x: 20, y: y, width: 400, height: 20)
        contentView.addSubview(title)
        y -= 25

        // Active handle label
        activeHandleLabel = NSTextField(labelWithString: "Click a point to select, then drag or use fields below")
        activeHandleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        activeHandleLabel.textColor = .lightGray
        activeHandleLabel.frame = NSRect(x: 20, y: y, width: 350, height: 16)
        contentView.addSubview(activeHandleLabel)

        // Show Middles checkbox
        showMiddlesCheckbox = NSButton(checkboxWithTitle: "Show Middles (curved)", target: self, action: #selector(toggleMiddles(_:)))
        showMiddlesCheckbox.frame = NSRect(x: 350, y: y - 2, width: 140, height: 20)
        showMiddlesCheckbox.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        contentView.addSubview(showMiddlesCheckbox)
        y -= 280

        // Preview area
        previewView = WarpPreviewView(frame: NSRect(x: 20, y: y, width: 460, height: 260))
        previewView.autoresizingMask = [.width]
        previewView.onHandleDrag = { [weak self] handle, delta in
            self?.handleDrag(handle: handle, delta: delta)
        }
        previewView.onHandleSelect = { [weak self] handle in
            self?.selectHandle(handle)
        }
        contentView.addSubview(previewView)
        y -= 30

        // Corner controls section
        let cornerHeader = NSTextField(labelWithString: "◆ CORNERS")
        cornerHeader.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        cornerHeader.textColor = .yellow
        cornerHeader.frame = NSRect(x: 20, y: y, width: 100, height: 14)
        contentView.addSubview(cornerHeader)
        y -= 22

        // Create corner fields
        var result = createCornerRow(at: y, contentView: contentView,
                                     leftName: "Top-Left:", rightName: "Top-Right:")
        y = result.yPos
        tlxField = result.leftF.0; tlyField = result.leftF.1
        tlxStepper = result.leftS.0; tlyStepper = result.leftS.1
        trxField = result.rightF.0; tryField = result.rightF.1
        trxStepper = result.rightS.0; tryStepper = result.rightS.1

        result = createCornerRow(at: y, contentView: contentView,
                                 leftName: "Bottom-Left:", rightName: "Bottom-Right:")
        y = result.yPos
        blxField = result.leftF.0; blyField = result.leftF.1
        blxStepper = result.leftS.0; blyStepper = result.leftS.1
        brxField = result.rightF.0; bryField = result.rightF.1
        brxStepper = result.rightS.0; bryStepper = result.rightS.1

        cornerFields = [tlxField, tlyField, trxField, tryField, blxField, blyField, brxField, bryField]
        cornerSteppers = [tlxStepper, tlyStepper, trxStepper, tryStepper, blxStepper, blyStepper, brxStepper, bryStepper]

        // Link corner steppers/fields
        for (i, stepper) in cornerSteppers.enumerated() {
            stepper.tag = i
            stepper.target = self
            stepper.action = #selector(cornerStepperChanged(_:))
        }
        for (i, field) in cornerFields.enumerated() {
            field.tag = i
            field.target = self
            field.action = #selector(cornerFieldChanged(_:))
        }

        y -= 15

        // Middle controls section (togglable)
        let middleHeader = NSTextField(labelWithString: "◇ MIDDLES (for curved surfaces)")
        middleHeader.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        middleHeader.textColor = .magenta
        middleHeader.frame = NSRect(x: 20, y: y, width: 200, height: 14)
        contentView.addSubview(middleHeader)
        middleControls.append(middleHeader)
        y -= 22

        // Create middle fields
        var midResult = createMiddleRow(at: y, contentView: contentView,
                                        leftName: "Top-Mid:", rightName: "Bot-Mid:")
        y = midResult.yPos
        tmxField = midResult.leftF.0; tmyField = midResult.leftF.1
        tmxStepper = midResult.leftS.0; tmyStepper = midResult.leftS.1
        bmxField = midResult.rightF.0; bmyField = midResult.rightF.1
        bmxStepper = midResult.rightS.0; bmyStepper = midResult.rightS.1

        midResult = createMiddleRow(at: y, contentView: contentView,
                                    leftName: "Mid-Left:", rightName: "Mid-Right:")
        y = midResult.yPos
        mlxField = midResult.leftF.0; mlyField = midResult.leftF.1
        mlxStepper = midResult.leftS.0; mlyStepper = midResult.leftS.1
        mrxField = midResult.rightF.0; mryField = midResult.rightF.1
        mrxStepper = midResult.rightS.0; mryStepper = midResult.rightS.1

        middleFields = [tmxField, tmyField, mrxField, mryField, bmxField, bmyField, mlxField, mlyField]
        middleSteppers = [tmxStepper, tmyStepper, mrxStepper, mryStepper, bmxStepper, bmyStepper, mlxStepper, mlyStepper]

        // Link middle steppers/fields (tags 0-7 for TM, MR, BM, ML x/y)
        for (i, stepper) in middleSteppers.enumerated() {
            stepper.tag = i
            stepper.target = self
            stepper.action = #selector(middleStepperChanged(_:))
        }
        for (i, field) in middleFields.enumerated() {
            field.tag = i
            field.target = self
            field.action = #selector(middleFieldChanged(_:))
        }

        // Hide middle controls by default
        for control in middleControls {
            control.isHidden = true
        }

        y -= 20

        // Buttons
        let resetBtn = NSButton(title: "Reset All", target: self, action: #selector(resetAll))
        resetBtn.bezelStyle = .rounded
        resetBtn.frame = NSRect(x: 20, y: 20, width: 80, height: 28)
        contentView.addSubview(resetBtn)

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeBtn.bezelStyle = .rounded
        closeBtn.frame = NSRect(x: 400, y: 20, width: 80, height: 28)
        contentView.addSubview(closeBtn)
    }

    private func createCornerRow(at yPos: CGFloat, contentView: NSView,
                                  leftName: String, rightName: String) -> (yPos: CGFloat, leftF: (NSTextField, NSTextField), leftS: (NSStepper, NSStepper), rightF: (NSTextField, NSTextField), rightS: (NSStepper, NSStepper)) {
        let fieldWidth: CGFloat = 50
        let stepperWidth: CGFloat = 19

        // Left corner
        let leftLabel = NSTextField(labelWithString: leftName)
        leftLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        leftLabel.textColor = .yellow
        leftLabel.frame = NSRect(x: 20, y: yPos, width: 75, height: 16)
        contentView.addSubview(leftLabel)

        let lf0 = createField(at: NSRect(x: 95, y: yPos - 2, width: fieldWidth, height: 20), in: contentView)
        let ls0 = createStepper(at: NSRect(x: 147, y: yPos - 2, width: stepperWidth, height: 20), in: contentView)
        let lf1 = createField(at: NSRect(x: 170, y: yPos - 2, width: fieldWidth, height: 20), in: contentView)
        let ls1 = createStepper(at: NSRect(x: 222, y: yPos - 2, width: stepperWidth, height: 20), in: contentView)

        // Right corner
        let rightLabel = NSTextField(labelWithString: rightName)
        rightLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        rightLabel.textColor = .yellow
        rightLabel.frame = NSRect(x: 250, y: yPos, width: 75, height: 16)
        contentView.addSubview(rightLabel)

        let rf0 = createField(at: NSRect(x: 325, y: yPos - 2, width: fieldWidth, height: 20), in: contentView)
        let rs0 = createStepper(at: NSRect(x: 377, y: yPos - 2, width: stepperWidth, height: 20), in: contentView)
        let rf1 = createField(at: NSRect(x: 400, y: yPos - 2, width: fieldWidth, height: 20), in: contentView)
        let rs1 = createStepper(at: NSRect(x: 452, y: yPos - 2, width: stepperWidth, height: 20), in: contentView)

        return (yPos - 28, (lf0, lf1), (ls0, ls1), (rf0, rf1), (rs0, rs1))
    }

    private func createMiddleRow(at yPos: CGFloat, contentView: NSView,
                                  leftName: String, rightName: String) -> (yPos: CGFloat, leftF: (NSTextField, NSTextField), leftS: (NSStepper, NSStepper), rightF: (NSTextField, NSTextField), rightS: (NSStepper, NSStepper)) {
        let fieldWidth: CGFloat = 50
        let stepperWidth: CGFloat = 19

        // Left
        let leftLabel = NSTextField(labelWithString: leftName)
        leftLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        leftLabel.textColor = .magenta
        leftLabel.frame = NSRect(x: 20, y: yPos, width: 75, height: 16)
        contentView.addSubview(leftLabel)
        middleControls.append(leftLabel)

        let lf0 = createField(at: NSRect(x: 95, y: yPos - 2, width: fieldWidth, height: 20), in: contentView)
        let ls0 = createStepper(at: NSRect(x: 147, y: yPos - 2, width: stepperWidth, height: 20), in: contentView)
        let lf1 = createField(at: NSRect(x: 170, y: yPos - 2, width: fieldWidth, height: 20), in: contentView)
        let ls1 = createStepper(at: NSRect(x: 222, y: yPos - 2, width: stepperWidth, height: 20), in: contentView)

        middleControls.append(contentsOf: [lf0, lf1, ls0, ls1])

        // Right
        let rightLabel = NSTextField(labelWithString: rightName)
        rightLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        rightLabel.textColor = .magenta
        rightLabel.frame = NSRect(x: 250, y: yPos, width: 75, height: 16)
        contentView.addSubview(rightLabel)
        middleControls.append(rightLabel)

        let rf0 = createField(at: NSRect(x: 325, y: yPos - 2, width: fieldWidth, height: 20), in: contentView)
        let rs0 = createStepper(at: NSRect(x: 377, y: yPos - 2, width: stepperWidth, height: 20), in: contentView)
        let rf1 = createField(at: NSRect(x: 400, y: yPos - 2, width: fieldWidth, height: 20), in: contentView)
        let rs1 = createStepper(at: NSRect(x: 452, y: yPos - 2, width: stepperWidth, height: 20), in: contentView)

        middleControls.append(contentsOf: [rf0, rf1, rs0, rs1])

        return (yPos - 28, (lf0, lf1), (ls0, ls1), (rf0, rf1), (rs0, rs1))
    }

    private func createField(at frame: NSRect, in view: NSView) -> NSTextField {
        let field = NSTextField(string: "0")
        field.frame = frame
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.backgroundColor = NSColor(white: 0.2, alpha: 1)
        field.textColor = .white
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.alignment = .right
        view.addSubview(field)
        return field
    }

    private func createStepper(at frame: NSRect, in view: NSView) -> NSStepper {
        let stepper = NSStepper()
        stepper.frame = frame
        stepper.minValue = -500
        stepper.maxValue = 500
        stepper.increment = 1
        stepper.valueWraps = false
        view.addSubview(stepper)
        return stepper
    }

    @objc private func toggleMiddles(_ sender: NSButton) {
        let show = sender.state == .on
        previewView.showMiddles = show
        previewView.updateHandlePositions()
        previewView.needsDisplay = true

        for control in middleControls {
            control.isHidden = !show
        }
    }

    private func loadCurrentValues() {
        guard let id = outputId, let output = OutputManager.shared.getOutput(id: id) else { return }

        let config = output.config

        // Corner values
        tlxField.floatValue = config.warpTopLeftX
        tlyField.floatValue = config.warpTopLeftY
        trxField.floatValue = config.warpTopRightX
        tryField.floatValue = config.warpTopRightY
        blxField.floatValue = config.warpBottomLeftX
        blyField.floatValue = config.warpBottomLeftY
        brxField.floatValue = config.warpBottomRightX
        bryField.floatValue = config.warpBottomRightY

        // Corner steppers
        tlxStepper.floatValue = config.warpTopLeftX
        tlyStepper.floatValue = config.warpTopLeftY
        trxStepper.floatValue = config.warpTopRightX
        tryStepper.floatValue = config.warpTopRightY
        blxStepper.floatValue = config.warpBottomLeftX
        blyStepper.floatValue = config.warpBottomLeftY
        brxStepper.floatValue = config.warpBottomRightX
        bryStepper.floatValue = config.warpBottomRightY

        // Middle values
        tmxField.floatValue = config.warpTopMiddleX
        tmyField.floatValue = config.warpTopMiddleY
        mrxField.floatValue = config.warpMiddleRightX
        mryField.floatValue = config.warpMiddleRightY
        bmxField.floatValue = config.warpBottomMiddleX
        bmyField.floatValue = config.warpBottomMiddleY
        mlxField.floatValue = config.warpMiddleLeftX
        mlyField.floatValue = config.warpMiddleLeftY

        // Middle steppers
        tmxStepper.floatValue = config.warpTopMiddleX
        tmyStepper.floatValue = config.warpTopMiddleY
        mrxStepper.floatValue = config.warpMiddleRightX
        mryStepper.floatValue = config.warpMiddleRightY
        bmxStepper.floatValue = config.warpBottomMiddleX
        bmyStepper.floatValue = config.warpBottomMiddleY
        mlxStepper.floatValue = config.warpMiddleLeftX
        mlyStepper.floatValue = config.warpMiddleLeftY

        // Auto-show middles if any middle values are non-zero
        let hasMiddleValues = config.warpTopMiddleX != 0 || config.warpTopMiddleY != 0 ||
                              config.warpMiddleRightX != 0 || config.warpMiddleRightY != 0 ||
                              config.warpBottomMiddleX != 0 || config.warpBottomMiddleY != 0 ||
                              config.warpMiddleLeftX != 0 || config.warpMiddleLeftY != 0
        if hasMiddleValues {
            showMiddlesCheckbox.state = .on
            toggleMiddles(showMiddlesCheckbox)
        }

        updatePreview()
    }

    private func updatePreview() {
        previewView.cornerOffsets = [
            CGPoint(x: CGFloat(tlxField.floatValue), y: CGFloat(tlyField.floatValue)),
            CGPoint(x: CGFloat(trxField.floatValue), y: CGFloat(tryField.floatValue)),
            CGPoint(x: CGFloat(blxField.floatValue), y: CGFloat(blyField.floatValue)),
            CGPoint(x: CGFloat(brxField.floatValue), y: CGFloat(bryField.floatValue))
        ]
        previewView.middleOffsets = [
            CGPoint(x: CGFloat(tmxField.floatValue), y: CGFloat(tmyField.floatValue)),  // TM
            CGPoint(x: CGFloat(mrxField.floatValue), y: CGFloat(mryField.floatValue)),  // MR
            CGPoint(x: CGFloat(bmxField.floatValue), y: CGFloat(bmyField.floatValue)),  // BM
            CGPoint(x: CGFloat(mlxField.floatValue), y: CGFloat(mlyField.floatValue))   // ML
        ]
        previewView.updateHandlePositions()
        previewView.needsDisplay = true
    }

    private func applyToOutput() {
        guard let id = outputId else { return }

        OutputManager.shared.updateQuadWarp(
            id: id,
            topLeftX: tlxField.floatValue,
            topLeftY: tlyField.floatValue,
            topMiddleX: tmxField.floatValue,
            topMiddleY: tmyField.floatValue,
            topRightX: trxField.floatValue,
            topRightY: tryField.floatValue,
            middleLeftX: mlxField.floatValue,
            middleLeftY: mlyField.floatValue,
            middleRightX: mrxField.floatValue,
            middleRightY: mryField.floatValue,
            bottomLeftX: blxField.floatValue,
            bottomLeftY: blyField.floatValue,
            bottomMiddleX: bmxField.floatValue,
            bottomMiddleY: bmyField.floatValue,
            bottomRightX: brxField.floatValue,
            bottomRightY: bryField.floatValue
        )
    }

    private func selectHandle(_ handle: Int) {
        previewView.activeHandle = handle
        previewView.updateHandlePositions()

        // Set active corner overlay on output (only for corners 0-3)
        if let id = outputId {
            if handle < 4 {
                OutputManager.shared.setActiveCorner(id: id, corner: Int32(handle + 1))
            } else {
                OutputManager.shared.setActiveCorner(id: id, corner: 0)  // Clear for middles
            }
        }

        let names = ["Top-Left", "Top-Right", "Bottom-Left", "Bottom-Right", "Top-Middle", "Middle-Right", "Bottom-Middle", "Middle-Left"]
        activeHandleLabel.stringValue = "Active: \(names[handle]) - Drag or use fields"
        activeHandleLabel.textColor = handle < 4 ? .cyan : .magenta
    }

    private func handleDrag(handle: Int, delta: CGPoint) {
        let scale: CGFloat = 3.0
        let dx = Float(delta.x * scale)
        let dy = Float(-delta.y * scale)

        if handle < 4 {
            // Corner drag
            switch handle {
            case 0:  // TL
                tlxField.floatValue += dx; tlyField.floatValue += dy
                tlxStepper.doubleValue = Double(tlxField.floatValue)
                tlyStepper.doubleValue = Double(tlyField.floatValue)
            case 1:  // TR
                trxField.floatValue += dx; tryField.floatValue += dy
                trxStepper.doubleValue = Double(trxField.floatValue)
                tryStepper.doubleValue = Double(tryField.floatValue)
            case 2:  // BL
                blxField.floatValue += dx; blyField.floatValue += dy
                blxStepper.doubleValue = Double(blxField.floatValue)
                blyStepper.doubleValue = Double(blyField.floatValue)
            case 3:  // BR
                brxField.floatValue += dx; bryField.floatValue += dy
                brxStepper.doubleValue = Double(brxField.floatValue)
                bryStepper.doubleValue = Double(bryField.floatValue)
            default: break
            }
        } else {
            // Middle drag (4=TM, 5=MR, 6=BM, 7=ML)
            switch handle {
            case 4:  // TM
                tmxField.floatValue += dx; tmyField.floatValue += dy
                tmxStepper.doubleValue = Double(tmxField.floatValue)
                tmyStepper.doubleValue = Double(tmyField.floatValue)
            case 5:  // MR
                mrxField.floatValue += dx; mryField.floatValue += dy
                mrxStepper.doubleValue = Double(mrxField.floatValue)
                mryStepper.doubleValue = Double(mryField.floatValue)
            case 6:  // BM
                bmxField.floatValue += dx; bmyField.floatValue += dy
                bmxStepper.doubleValue = Double(bmxField.floatValue)
                bmyStepper.doubleValue = Double(bmyField.floatValue)
            case 7:  // ML
                mlxField.floatValue += dx; mlyField.floatValue += dy
                mlxStepper.doubleValue = Double(mlxField.floatValue)
                mlyStepper.doubleValue = Double(mlyField.floatValue)
            default: break
            }
        }

        updatePreview()
        applyToOutput()
    }

    @objc private func cornerStepperChanged(_ sender: NSStepper) {
        let value = Float(sender.doubleValue)
        cornerFields[sender.tag].floatValue = value
        updatePreview()
        applyToOutput()
    }

    @objc private func cornerFieldChanged(_ sender: NSTextField) {
        let value = sender.floatValue
        cornerSteppers[sender.tag].doubleValue = Double(value)
        updatePreview()
        applyToOutput()
    }

    @objc private func middleStepperChanged(_ sender: NSStepper) {
        let value = Float(sender.doubleValue)
        middleFields[sender.tag].floatValue = value
        updatePreview()
        applyToOutput()
    }

    @objc private func middleFieldChanged(_ sender: NSTextField) {
        let value = sender.floatValue
        middleSteppers[sender.tag].doubleValue = Double(value)
        updatePreview()
        applyToOutput()
    }

    @objc private func resetAll() {
        for field in cornerFields { field.floatValue = 0 }
        for stepper in cornerSteppers { stepper.doubleValue = 0 }
        for field in middleFields { field.floatValue = 0 }
        for stepper in middleSteppers { stepper.doubleValue = 0 }

        updatePreview()
        applyToOutput()

        if let id = outputId {
            OutputManager.shared.setActiveCorner(id: id, corner: 0)
        }
        previewView.activeHandle = -1
        previewView.updateHandlePositions()
        activeHandleLabel.stringValue = "Click a point to select, then drag or use fields below"
        activeHandleLabel.textColor = .lightGray
    }

    @objc private func closeWindow() {
        if let id = outputId {
            OutputManager.shared.setActiveCorner(id: id, corner: 0)
        }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let id = outputId {
            OutputManager.shared.setActiveCorner(id: id, corner: 0)
        }
    }
}

// MARK: - Global Warp Window Manager
@MainActor
class WarpWindowManager {
    static let shared = WarpWindowManager()
    nonisolated init() {}
    private var windows: [UUID: WarpWindowController] = [:]

    func showWarpWindow(for outputId: UUID, name: String) {
        if let existing = windows[outputId] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = WarpWindowController()
        controller.configure(outputId: outputId, name: name)
        controller.window?.center()
        controller.showWindow(nil)
        windows[outputId] = controller
    }

    func closeAll() {
        for (_, controller) in windows {
            controller.window?.close()
        }
        windows.removeAll()
    }
}
