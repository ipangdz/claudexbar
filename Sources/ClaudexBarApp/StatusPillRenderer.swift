import AppKit
import ClaudexBarCore

enum StatusPillRenderer {
    private static let itemWidth: CGFloat = 128
    private static let itemHeight: CGFloat = 26

    static func image(provider: ProviderID, snapshot: UsageSnapshot, codexInitials: String? = nil, now: Date = Date()) -> NSImage {
        let primary = UsageFormatter.display(for: snapshot.primary, now: now)
        let secondary = UsageFormatter.display(for: snapshot.secondary, now: now)
        return image(
            provider: provider,
            codexInitials: codexInitials,
            primaryLabel: primary.label,
            primaryRemaining: primary.remainingPercent,
            secondaryLabel: secondary.label,
            secondaryRemaining: secondary.remainingPercent
        )
    }

    static func image(provider: ProviderID, status: String, codexInitials: String? = nil) -> NSImage {
        let colors = themeColors()
        let image = baseImage(backgroundColor: colors.background)
        image.lockFocus()
        drawIcon(provider: provider, in: NSRect(x: 8, y: 5, width: 16, height: 16), color: colors.foreground)
        if provider == .codex, let codexInitials {
            drawBadge(codexInitials, at: NSRect(x: 25.5, y: 7.5, width: 14, height: 11), colors: colors)
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: colors.foreground
        ]
        NSString(string: status).draw(
            in: NSRect(x: 42, y: 5.5, width: itemWidth - 49, height: 18),
            withAttributes: attributes
        )

        image.unlockFocus()
        return image
    }

    static func pausedImage() -> NSImage {
        let colors = themeColors()
        let image = baseImage(backgroundColor: colors.background)
        image.lockFocus()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: colors.foreground
        ]
        NSString(string: "off").draw(
            in: NSRect(x: 16, y: 5.5, width: itemWidth - 32, height: 18),
            withAttributes: attributes
        )

        image.unlockFocus()
        return image
    }

    private static func image(
        provider: ProviderID,
        codexInitials: String?,
        primaryLabel: String,
        primaryRemaining: Int,
        secondaryLabel: String,
        secondaryRemaining: Int
    ) -> NSImage {
        let colors = themeColors()
        let image = baseImage(backgroundColor: colors.background)
        image.lockFocus()
        drawIcon(provider: provider, in: NSRect(x: 8, y: 5, width: 16, height: 16), color: colors.foreground)
        if provider == .codex, let codexInitials {
            drawBadge(codexInitials, at: NSRect(x: 25.5, y: 7.5, width: 14, height: 11), colors: colors)
        }
        drawMetric(
            label: primaryLabel,
            value: "\(primaryRemaining)%",
            x: 42,
            foregroundColor: colors.foreground,
            secondaryForegroundColor: colors.secondaryForeground
        )
        drawMetric(
            label: secondaryLabel,
            value: "\(secondaryRemaining)%",
            x: 84,
            foregroundColor: colors.foreground,
            secondaryForegroundColor: colors.secondaryForeground
        )
        image.unlockFocus()
        return image
    }

    private static func baseImage(backgroundColor: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: itemWidth, height: itemHeight))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()

        backgroundColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 1, y: 1, width: itemWidth - 2, height: itemHeight - 2),
            xRadius: 6,
            yRadius: 6
        ).fill()
        image.unlockFocus()
        return image
    }

    private static func themeColors() -> (background: NSColor, foreground: NSColor, secondaryForeground: NSColor) {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        if appearance == .darkAqua {
            return (
                background: NSColor(calibratedWhite: 0.96, alpha: 0.94),
                foreground: NSColor(calibratedWhite: 0.08, alpha: 1),
                secondaryForeground: NSColor(calibratedWhite: 0.08, alpha: 0.65)
            )
        }

        return (
            background: NSColor(calibratedWhite: 0.08, alpha: 0.92),
            foreground: .white,
            secondaryForeground: NSColor.white.withAlphaComponent(0.72)
        )
    }

    private static func drawIcon(provider: ProviderID, in rect: NSRect, color: NSColor) {
        if provider == .claude {
            drawClaudeCodeIcon(in: rect, color: color)
            return
        }

        color.setStroke()
        let chevron = NSBezierPath()
        chevron.lineWidth = 2.25
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.move(to: NSPoint(x: rect.minX + 3.5, y: rect.maxY - 3.2))
        chevron.line(to: NSPoint(x: rect.minX + 8, y: rect.midY))
        chevron.line(to: NSPoint(x: rect.minX + 3.5, y: rect.minY + 3.2))
        chevron.stroke()

        let underline = NSBezierPath()
        underline.lineWidth = 2.25
        underline.lineCapStyle = .round
        underline.move(to: NSPoint(x: rect.minX + 10.2, y: rect.minY + 3.7))
        underline.line(to: NSPoint(x: rect.maxX - 1.5, y: rect.minY + 3.7))
        underline.stroke()
    }

    private static func drawClaudeCodeIcon(in rect: NSRect, color: NSColor) {
        color.setFill()

        func draw(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            let scaleX = rect.width / 24
            let scaleY = rect.height / 24
            NSRect(
                x: rect.minX + x * scaleX,
                y: rect.minY + (24 - y - height) * scaleY,
                width: width * scaleX,
                height: height * scaleY
            ).fill()
        }

        draw(3, 5, 18, 12)
        draw(0, 10.9, 3, 3.2)
        draw(21, 10.9, 3, 3.2)
        draw(4.5, 17, 1.6, 3)
        draw(7.5, 17, 1.6, 3)
        draw(15, 17, 1.6, 3)
        draw(18, 17, 1.6, 3)

        themeColors().background.setFill()
        draw(6, 8.1, 1.55, 2.9)
        draw(16.45, 8.1, 1.55, 2.9)
    }

    private static func drawBadge(
        _ initials: String,
        at rect: NSRect,
        colors: (background: NSColor, foreground: NSColor, secondaryForeground: NSColor)
    ) {
        let palette = badgeColor(for: initials)
        palette.background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6.2, weight: .bold),
            .foregroundColor: palette.foreground,
            .kern: 0
        ]
        let text = String(initials.prefix(2)).uppercased() as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private static func badgeColor(for initials: String) -> (background: NSColor, foreground: NSColor) {
        let palettes: [(NSColor, NSColor)] = [
            (NSColor(calibratedRed: 0.12, green: 0.62, blue: 0.34, alpha: 1), .white),
            (NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.16, alpha: 1), NSColor(calibratedWhite: 0.08, alpha: 1)),
            (NSColor(calibratedRed: 0.18, green: 0.45, blue: 0.82, alpha: 1), .white),
            (NSColor(calibratedRed: 0.72, green: 0.22, blue: 0.45, alpha: 1), .white)
        ]
        let value = initials.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palettes[value % palettes.count]
    }

    private static func drawMetric(
        label: String,
        value: String,
        x: CGFloat,
        foregroundColor: NSColor,
        secondaryForegroundColor: NSColor
    ) {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: secondaryForegroundColor,
            .kern: 0
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            .foregroundColor: foregroundColor,
            .kern: 0
        ]

        NSString(string: label).draw(
            in: NSRect(x: x, y: 14.6, width: 38, height: 10),
            withAttributes: labelAttributes
        )
        NSString(string: value).draw(
            in: NSRect(x: x, y: 1.8, width: 45, height: 16),
            withAttributes: valueAttributes
        )
    }
}
