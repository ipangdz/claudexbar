import AppKit

/// A custom menu-row view for a provider's enable checkbox. Unlike a plain
/// `NSMenuItem`, clicking it toggles the provider **without closing the menu**,
/// so you can flip providers like a settings checklist. It draws a native-style
/// checkmark + name + usage hint and highlights on hover.
final class ProviderToggleView: NSView {
    private let label: String
    private let hint: String
    private let badge: String?
    private let isEnabled: () -> Bool
    private let onToggle: () -> Void
    private var highlighted = false

    // Layout (approximates a standard checkmark menu item).
    private let rowHeight: CGFloat = 22
    private let checkX: CGFloat = 7
    private let nameX: CGFloat = 22
    private let badgeWidth: CGFloat = 23
    private let hintGap: CGFloat = 18
    private let rightPad: CGFloat = 24
    private var font: NSFont { NSFont.menuFont(ofSize: 0) }

    init(label: String, hint: String, badge: String? = nil, isEnabled: @escaping () -> Bool, onToggle: @escaping () -> Void) {
        self.label = label
        self.hint = hint
        self.badge = badge
        self.isEnabled = isEnabled
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: rowHeight))
        frame.size.width = intrinsicWidth()
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func textWidth(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    private func intrinsicWidth() -> CGFloat {
        let hintW = hint.isEmpty ? 0 : textWidth(hint) + hintGap
        let badgeW = badge == nil ? 0 : badgeWidth
        return nameX + badgeW + textWidth(label) + hintW + rightPad
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { highlighted = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { highlighted = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        // Only act if released inside the row; keep the menu open afterwards.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
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

        func draw(_ string: String, at x: CGFloat, color: NSColor) {
            let attr = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            let size = attr.size()
            attr.draw(at: NSPoint(x: x, y: (h - size.height) / 2))
        }

        if isEnabled() {
            draw("✓", at: checkX, color: primary)
        }
        let labelX: CGFloat
        if let badge {
            drawBadge(badge, at: NSRect(x: nameX, y: (h - 13) / 2, width: 19, height: 13), highlighted: highlighted)
            labelX = nameX + badgeWidth
        } else {
            labelX = nameX
        }
        draw(label, at: labelX, color: primary)
        if !hint.isEmpty {
            draw(hint, at: labelX + textWidth(label) + hintGap, color: secondary)
        }
    }

    private func drawBadge(_ value: String, at rect: NSRect, highlighted: Bool) {
        let background = highlighted ? NSColor.white.withAlphaComponent(0.22) : NSColor.controlAccentColor
        let foreground = highlighted ? NSColor.white : NSColor.white
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: foreground
        ]
        let text = String(value.prefix(2)).uppercased() as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
