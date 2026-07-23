import AppKit

enum ProviderVersionState {
    case current
    case outdated
    case unknown
}

struct ProviderVersionBadge {
    let text: String
    let state: ProviderVersionState
}

/// A custom menu-row view for a provider's enable checkbox. Unlike a plain
/// `NSMenuItem`, clicking it toggles the provider **without closing the menu**,
/// so you can flip providers like a settings checklist. It draws a native-style
/// checkmark + name + usage hint and highlights on hover.
final class ProviderToggleView: NSView {
    private let label: String
    private let version: ProviderVersionBadge?
    private let hint: String
    private let isEnabled: () -> Bool
    private let onToggle: () -> Void
    private var highlighted = false

    // Layout (approximates a standard checkmark menu item).
    private let rowHeight: CGFloat = 22
    private let checkX: CGFloat = 7
    private let nameX: CGFloat = 22
    private let versionGap: CGFloat = 6
    private let hintGap: CGFloat = 14
    private let rightPad: CGFloat = 24
    private var font: NSFont { NSFont.menuFont(ofSize: 0) }
    private var versionFont: NSFont {
        NSFont.systemFont(ofSize: max(7, font.pointSize * 0.58), weight: .semibold)
    }

    init(
        label: String,
        version: ProviderVersionBadge?,
        hint: String,
        isEnabled: @escaping () -> Bool,
        onToggle: @escaping () -> Void
    ) {
        self.label = label
        self.version = version
        self.hint = hint
        self.isEnabled = isEnabled
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: rowHeight))
        frame.size.width = intrinsicWidth()
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func textWidth(_ s: String, font: NSFont? = nil) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font ?? self.font]).width
    }

    private func intrinsicWidth() -> CGFloat {
        let versionW = version.map { versionGap + textWidth($0.text, font: versionFont) } ?? 0
        let hintW = hint.isEmpty ? 0 : hintGap + textWidth(hint)
        return nameX + textWidth(label) + versionW + hintW + rightPad
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        highlighted = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Only act if released inside the row; keep the menu open afterwards.
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onToggle()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height

        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }

        let primary: NSColor = highlighted ? .white : .labelColor
        let secondary: NSColor = highlighted ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor

        func draw(_ string: String, at x: CGFloat, font: NSFont, color: NSColor) {
            let attr = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            let size = attr.size()
            attr.draw(at: NSPoint(x: x, y: (h - size.height) / 2))
        }

        if isEnabled() {
            draw("✓", at: checkX, font: font, color: primary)
        }
        let labelX = nameX
        draw(label, at: labelX, font: font, color: primary)

        var trailingX = labelX + textWidth(label)
        if let version {
            trailingX += versionGap
            let versionColor: NSColor
            if highlighted {
                versionColor = NSColor.white.withAlphaComponent(0.9)
            } else {
                switch version.state {
                case .current: versionColor = .systemGreen
                case .outdated: versionColor = .systemOrange
                case .unknown: versionColor = .secondaryLabelColor
                }
            }
            draw(version.text, at: trailingX, font: versionFont, color: versionColor)
            trailingX += textWidth(version.text, font: versionFont)
        }

        if !hint.isEmpty {
            draw(hint, at: trailingX + hintGap, font: font, color: secondary)
        }
    }
}
