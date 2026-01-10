// RetroTheme.swift - 80s Retro Sci-Fi UI Theme
// Centralized theme for consistent look across all windows

import AppKit

/// Centralized theme for 80s retro sci-fi aesthetic
/// Apply to all menus and windows for consistent look
@MainActor
struct RetroTheme {
    // MARK: - Core Colors

    /// Deep space black with blue undertone
    static let backgroundDeep = NSColor(red: 0.02, green: 0.02, blue: 0.06, alpha: 1.0)
    /// Panel background - slightly lighter
    static let backgroundPanel = NSColor(red: 0.04, green: 0.04, blue: 0.10, alpha: 1.0)
    /// Card/cell background
    static let backgroundCard = NSColor(red: 0.06, green: 0.06, blue: 0.14, alpha: 1.0)
    /// Input field background
    static let backgroundInput = NSColor(red: 0.08, green: 0.08, blue: 0.16, alpha: 1.0)

    // MARK: - Neon Accent Colors

    /// Primary neon cyan - main accent
    static let neonCyan = NSColor(red: 0.0, green: 1.0, blue: 1.0, alpha: 1.0)
    /// Hot magenta/pink - secondary accent
    static let neonMagenta = NSColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0)
    /// Electric purple
    static let neonPurple = NSColor(red: 0.6, green: 0.0, blue: 1.0, alpha: 1.0)
    /// Laser orange - warnings/active
    static let neonOrange = NSColor(red: 1.0, green: 0.4, blue: 0.0, alpha: 1.0)
    /// Neon green - success/enabled
    static let neonGreen = NSColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1.0)
    /// Neon red - errors/remove
    static let neonRed = NSColor(red: 1.0, green: 0.1, blue: 0.3, alpha: 1.0)
    /// Neon blue - NDI outputs
    static let neonBlue = NSColor(red: 0.0, green: 0.6, blue: 1.0, alpha: 1.0)
    /// Neon yellow - selection highlight
    static let neonYellow = NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0)

    // MARK: - Grid Colors

    /// Grid line color (Tron-style)
    static let gridLine = NSColor(red: 0.0, green: 0.3, blue: 0.4, alpha: 0.5)
    /// Grid line bright (for emphasis)
    static let gridLineBright = NSColor(red: 0.0, green: 0.5, blue: 0.6, alpha: 0.8)

    // MARK: - Text Colors

    /// Primary text - bright white with slight cyan tint
    static let textPrimary = NSColor(red: 0.9, green: 1.0, blue: 1.0, alpha: 1.0)
    /// Secondary text - dimmer
    static let textSecondary = NSColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 1.0)
    /// Disabled text
    static let textDisabled = NSColor(red: 0.3, green: 0.35, blue: 0.4, alpha: 1.0)

    // MARK: - Border Colors

    /// Default border - subtle
    static let borderDefault = NSColor(red: 0.15, green: 0.2, blue: 0.3, alpha: 1.0)
    /// Glow border - neon effect
    static func borderGlow(_ color: NSColor) -> NSColor {
        return color.withAlphaComponent(0.8)
    }

    // MARK: - Fonts

    /// Header font - bold, digital look
    static func headerFont(size: CGFloat) -> NSFont {
        return NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
    }

    /// Body font - clean monospace
    static func bodyFont(size: CGFloat) -> NSFont {
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Number font - monospaced digits
    static func numberFont(size: CGFloat) -> NSFont {
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }

    // MARK: - Section Header Colors

    static let sectionCanvas = neonCyan
    static let sectionOutputs = neonMagenta
    static let sectionConfig = neonGreen
    static let sectionBlend = neonOrange
    static let sectionScale = neonPurple
    static let sectionPositions = neonBlue
    static let sectionMedia = neonMagenta
    static let sectionLayout = neonCyan
    static let sectionDMX = neonOrange
    static let sectionGobo = neonPurple
    static let sectionColor = neonGreen

    // MARK: - UI Helpers

    /// Apply neon border effect to a layer
    static func applyNeonBorder(to layer: CALayer, color: NSColor, width: CGFloat = 2.0) {
        layer.borderWidth = width
        layer.borderColor = color.cgColor
        layer.shadowColor = color.cgColor
        layer.shadowRadius = 4
        layer.shadowOpacity = 0.6
        layer.shadowOffset = .zero
    }

    /// Create a styled panel background
    static func stylePanel(_ view: NSView, cornerRadius: CGFloat = 10) {
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundPanel.cgColor
        view.layer?.cornerRadius = cornerRadius
        applyNeonBorder(to: view.layer!, color: borderDefault, width: 1)
    }

    /// Create a styled card/cell background
    static func styleCard(_ view: NSView, cornerRadius: CGFloat = 8) {
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundCard.cgColor
        view.layer?.cornerRadius = cornerRadius
        view.layer?.borderWidth = 2
        view.layer?.borderColor = borderDefault.cgColor
    }

    /// Style a text field with retro look
    static func styleTextField(_ field: NSTextField, isNumeric: Bool = false, color: NSColor = textPrimary) {
        field.wantsLayer = true
        field.backgroundColor = backgroundInput
        field.textColor = color
        field.font = isNumeric ? numberFont(size: 14) : bodyFont(size: 12)
        field.layer?.cornerRadius = 4
        field.layer?.borderWidth = 1
        field.layer?.borderColor = borderDefault.cgColor
    }

    /// Style a button with neon effect
    static func styleButton(_ button: NSButton, color: NSColor) {
        button.wantsLayer = true
        button.contentTintColor = color
        button.font = headerFont(size: 11)
        button.layer?.cornerRadius = 4
    }

    /// Style a popup button
    static func stylePopup(_ popup: NSPopUpButton) {
        popup.font = bodyFont(size: 11)
    }

    /// Style a checkbox
    static func styleCheckbox(_ checkbox: NSButton, color: NSColor = textPrimary) {
        checkbox.font = headerFont(size: 10)
    }

    /// Style a slider
    static func styleSlider(_ slider: NSSlider, color: NSColor = neonCyan) {
        slider.wantsLayer = true
    }

    /// Style a stepper
    static func styleStepper(_ stepper: NSStepper) {
        stepper.wantsLayer = true
    }

    /// Create a section header with retro styling
    static func makeSectionHeader(_ title: String, color: NSColor, width: CGFloat) -> NSView {
        let header = NSView()
        header.wantsLayer = true

        // Glowing label
        let label = NSTextField(labelWithString: title)
        label.font = headerFont(size: 10)
        label.textColor = color
        label.frame = NSRect(x: 0, y: 2, width: 200, height: 16)
        // Add shadow for glow effect
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: 0)
        label.shadow = shadow
        header.addSubview(label)

        // Neon underline
        let line = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = color.withAlphaComponent(0.6).cgColor
        // Add glow line below
        let glowLine = NSView(frame: NSRect(x: 0, y: -1, width: width, height: 2))
        glowLine.wantsLayer = true
        glowLine.layer?.backgroundColor = color.withAlphaComponent(0.2).cgColor
        header.addSubview(glowLine)
        header.addSubview(line)

        return header
    }

    /// Create a styled label
    static func makeLabel(_ text: String, style: LabelStyle, size: CGFloat, color: NSColor? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)

        switch style {
        case .header:
            label.font = headerFont(size: size)
            label.textColor = color ?? textPrimary
        case .body:
            label.font = bodyFont(size: size)
            label.textColor = color ?? textSecondary
        case .number:
            label.font = numberFont(size: size)
            label.textColor = color ?? textPrimary
        }

        // Add subtle glow for headers
        if style == .header, let glowColor = color {
            let shadow = NSShadow()
            shadow.shadowColor = glowColor.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = .zero
            label.shadow = shadow
        }

        return label
    }

    enum LabelStyle {
        case header
        case body
        case number
    }

    /// Add grid pattern to a view (Tron-style)
    static func addGridPattern(to view: NSView, spacing: CGFloat = 20) {
        guard view.layer != nil else { return }
        let gridLayer = CAShapeLayer()
        gridLayer.frame = view.bounds

        let path = CGMutablePath()
        let bounds = view.bounds

        // Vertical lines
        var x: CGFloat = 0
        while x <= bounds.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: bounds.height))
            x += spacing
        }

        // Horizontal lines
        var y: CGFloat = 0
        while y <= bounds.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
            y += spacing
        }

        gridLayer.path = path
        gridLayer.strokeColor = gridLine.cgColor
        gridLayer.lineWidth = 0.5
        gridLayer.fillColor = nil

        view.layer?.insertSublayer(gridLayer, at: 0)
    }

    /// Style the main window
    static func styleWindow(_ window: NSWindow) {
        window.backgroundColor = backgroundDeep
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
    }

    /// Style content view of a window
    static func styleContentView(_ view: NSView, withGrid: Bool = true) {
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundDeep.cgColor
        if withGrid {
            addGridPattern(to: view, spacing: 40)
        }
    }

    /// Create a horizontal separator line
    static func makeSeparator(width: CGFloat, color: NSColor = borderDefault) -> NSView {
        let sep = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = color.cgColor
        return sep
    }

    /// Create a tab button
    static func makeTabButton(_ title: String, tag: Int, target: AnyObject?, action: Selector?) -> NSButton {
        let btn = NSButton(title: title, target: target, action: action)
        btn.bezelStyle = .rounded
        btn.tag = tag
        btn.font = headerFont(size: 11)
        styleButton(btn, color: textSecondary)
        return btn
    }

    /// Update tab button for selected state
    static func updateTabButton(_ button: NSButton, selected: Bool, color: NSColor) {
        if selected {
            button.contentTintColor = color
            button.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        } else {
            button.contentTintColor = textSecondary
            button.layer?.backgroundColor = nil
        }
    }
}
