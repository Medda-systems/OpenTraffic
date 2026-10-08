import AppKit

/// Provider marks drawn at an even visual weight. Marks come in very different shapes (Tailscale's
/// dots fill a square, ngrok is a thin wordmark, Cloudflare a wide cloud), so each one's visible ink
/// is measured and scaled to about the same area, then centred on a fixed canvas.
enum LogoFitting {
    struct Style: Hashable, Sendable {
        let canvas: NSSize
        /// Area of ink, in points², every mark gets (about a square mark filling `maximumInk.height`).
        let inkArea: CGFloat
        let maximumInk: NSSize

        /// Settings tabs: toolbars fit item images into about 30 × 30 points, beside SF Symbols.
        static let toolbar = Style(canvas: NSSize(width: 30, height: 30), inkArea: 400, maximumInk: NSSize(width: 30, height: 20))
        /// In the app's own views: a slot 1.6 times as wide as it is tall, so wide marks aren't
        /// shrunk to fit a square. A square mark fills the height.
        static let inline = Style(canvas: NSSize(width: 32, height: 20), inkArea: 400, maximumInk: NSSize(width: 32, height: 20))
        /// Menu items: every item gets the same width, so titles line up.
        static let menu = Style(canvas: NSSize(width: 24, height: 16), inkArea: 196, maximumInk: NSSize(width: 24, height: 14))
    }

    static func fitted(_ image: NSImage, style: Style) -> NSImage {
        guard let ink = inkBounds(of: image), ink.width > 0, ink.height > 0 else { return image }
        let scale = min(
            (style.inkArea / (ink.width * ink.height)).squareRoot(),
            style.maximumInk.width / ink.width,
            style.maximumInk.height / ink.height
        )
        let target = NSRect(
            x: (style.canvas.width - ink.width * scale) / 2,
            y: (style.canvas.height - ink.height * scale) / 2,
            width: ink.width * scale,
            height: ink.height * scale
        )
        let fitted = NSImage(size: style.canvas, flipped: false) { _ in
            image.draw(in: target, from: ink, operation: .sourceOver, fraction: 1)
            return true
        }
        fitted.isTemplate = image.isTemplate
        fitted.accessibilityDescription = image.accessibilityDescription
        return fitted
    }

    /// The part of `image` (in its own coordinates) that has any ink.
    static func inkBounds(of image: NSImage, resolution: Int = 256) -> NSRect? {
        let size = image.size
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: resolution, pixelsHigh: resolution,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: resolution, height: resolution))
        NSGraphicsContext.restoreGraphicsState()
        var minX = resolution, minY = resolution, maxX = -1, maxY = -1
        for y in 0..<resolution {
            for x in 0..<resolution where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        // Bitmap rows run top to bottom; image coordinates bottom to top.
        let unitX = size.width / CGFloat(resolution), unitY = size.height / CGFloat(resolution)
        return NSRect(
            x: CGFloat(minX) * unitX,
            y: CGFloat(resolution - 1 - maxY) * unitY,
            width: CGFloat(maxX - minX + 1) * unitX,
            height: CGFloat(maxY - minY + 1) * unitY
        )
    }
}
