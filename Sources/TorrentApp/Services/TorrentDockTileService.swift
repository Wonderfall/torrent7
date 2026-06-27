import AppKit
import Foundation

@MainActor
protocol TorrentDockTileServicing: AnyObject {
    func updateTransferRates(downloadRate: Int64, uploadRate: Int64)
    func updateCompletionBadge(count: Int)
}

@MainActor
final class TorrentDockTileService: TorrentDockTileServicing {
    private let dockTile: NSDockTile
    private var contentView: TransferRateDockTileView?
    private var downloadLabel: String?
    private var uploadLabel: String?
    private var completionBadgeCount = 0

    init(dockTile: NSDockTile = NSApplication.shared.dockTile) {
        self.dockTile = dockTile
    }

    func updateTransferRates(downloadRate: Int64, uploadRate: Int64) {
        let downloadRate = max(0, downloadRate)
        let uploadRate = max(0, uploadRate)
        let downloadLabel = Self.label(for: downloadRate)
        let uploadLabel = Self.label(for: uploadRate)
        guard downloadLabel != self.downloadLabel || uploadLabel != self.uploadLabel else {
            return
        }

        self.downloadLabel = downloadLabel
        self.uploadLabel = uploadLabel

        guard downloadLabel != nil || uploadLabel != nil else {
            contentView = nil
            dockTile.contentView = nil
            dockTile.display()
            return
        }

        let view = contentView ?? TransferRateDockTileView(icon: Self.applicationIcon())
        contentView = view
        view.frame = NSRect(origin: .zero, size: effectiveDockTileSize)
        view.update(downloadLabel: downloadLabel, uploadLabel: uploadLabel)
        dockTile.contentView = view
        dockTile.display()
    }

    func updateCompletionBadge(count: Int) {
        let count = max(0, count)
        guard count != completionBadgeCount else {
            return
        }

        completionBadgeCount = count
        dockTile.showsApplicationBadge = count > 0
        dockTile.badgeLabel = count > 0 ? String(count) : nil
        dockTile.display()
    }

    private var effectiveDockTileSize: NSSize {
        let size = dockTile.size
        guard size.width > 0, size.height > 0 else {
            return NSSize(width: 128, height: 128)
        }
        return size
    }

    private static func applicationIcon() -> NSImage {
        if let icon = NSApplication.shared.applicationIconImage {
            return icon
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    private static func label(for bytesPerSecond: Int64) -> String? {
        bytesPerSecond > 0 ? TransferRateDockTileView.compactRate(bytesPerSecond) : nil
    }
}

private final class TransferRateDockTileView: NSView {
    private struct RateBadge {
        let label: String
        let color: NSColor
    }

    private let icon: NSImage
    private var downloadLabel: String?
    private var uploadLabel: String?

    init(icon: NSImage) {
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(downloadLabel: String?, uploadLabel: String?) {
        self.downloadLabel = downloadLabel
        self.uploadLabel = uploadLabel
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        icon.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        let badges = rateBadges
        guard !badges.isEmpty else {
            return
        }

        let badgeHeight = max(29, bounds.height * 0.27)
        let spacing = max(2, bounds.height * 0.02)
        let badgeWidth = min(bounds.width - 10, max(104, bounds.width * 0.88))
        let totalHeight = CGFloat(badges.count) * badgeHeight + CGFloat(max(0, badges.count - 1)) * spacing
        var y = bounds.minY + 1 + totalHeight - badgeHeight

        for badge in badges {
            drawBadge(
                badge,
                in: NSRect(
                    x: bounds.midX - badgeWidth / 2,
                    y: y,
                    width: badgeWidth,
                    height: badgeHeight
                )
            )
            y -= badgeHeight + spacing
        }
    }

    private var rateBadges: [RateBadge] {
        var badges: [RateBadge] = []
        if let downloadLabel {
            badges.append(RateBadge(label: "↓ \(downloadLabel)", color: NSColor(red: 0.02, green: 0.24, blue: 0.72, alpha: 1)))
        }
        if let uploadLabel {
            badges.append(RateBadge(label: "↑ \(uploadLabel)", color: NSColor(red: 0.0, green: 0.38, blue: 0.16, alpha: 1)))
        }
        return badges
    }

    private func drawBadge(_ badge: RateBadge, in rect: NSRect) {
        let radius = rect.height / 2
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        badge.color.withAlphaComponent(0.94).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSColor.white.withAlphaComponent(0.24).setStroke()
        path.lineWidth = max(1, rect.height * 0.05)
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingMiddle

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(16, rect.height * 0.6), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
        let lineHeight = font.ascender - font.descender
        let insetRect = rect.insetBy(dx: 7, dy: (rect.height - lineHeight) / 2)
        badge.label.draw(in: insetRect, withAttributes: attributes)
    }

    fileprivate static func compactRate(_ bytesPerSecond: Int64) -> String {
        let units = [
            (1_000_000_000_000.0, "T/s"),
            (1_000_000_000.0, "G/s"),
            (1_000_000.0, "M/s"),
            (1_000.0, "K/s")
        ]

        let value = Double(bytesPerSecond)
        for (unitValue, suffix) in units where value >= unitValue {
            let scaled = value / unitValue
            let formatted = scaled >= 10 ? String(Int(scaled.rounded())) : oneDecimal(scaled)
            return "\(formatted) \(suffix)"
        }

        return "\(bytesPerSecond)B/s"
    }

    private static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}
