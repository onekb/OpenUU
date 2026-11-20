import AppKit
import Foundation

enum IconCompositor {
    /// Host-side: Encode an NSImage (e.g. `NSRunningApplication.icon`) to a compact 128x128 PNG base64 string.
    @MainActor
    static func encodeIconToBase64PNG(_ image: NSImage?, size: CGFloat = 128) -> String {
        guard let image else { return "" }
        let targetSize = NSSize(width: size, height: size)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size),
            pixelsHigh: Int(size),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return "" }
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return png.base64EncodedString()
    }

    /// Client-side: Decode base64 PNG back to NSImage.
    static func decodeBase64PNG(_ b64: String) -> NSImage? {
        guard !b64.isEmpty, let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    /// Client-side: Redraw the remote app icon at 256x256 with the Chameye logo badge overlaid in the top-right corner.
    @MainActor
    static func compositeWithChameyeBadge(_ baseIcon: NSImage?) -> NSImage {
        let canvasSize: CGFloat = 256
        let out = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
        out.lockFocus()
        defer { out.unlockFocus() }

        let fullRect = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)

        // 1. Draw base remote app icon (or a sleek fallback icon)
        if let baseIcon {
            baseIcon.draw(in: fullRect.insetBy(dx: 8, dy: 8), from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            let fallbackRect = fullRect.insetBy(dx: 20, dy: 20)
            let bg = NSBezierPath(roundedRect: fallbackRect, xRadius: 44, yRadius: 44)
            NSColor.controlAccentColor.setFill()
            bg.fill()
        }

        // 2. Draw Chameye badge in the bottom-right corner so macOS's native red unread badge
        //    (which always sits at the top-right corner of the Dock icon) never overlaps it.
        let badgeDiameter: CGFloat = canvasSize * 0.36
        let badgeMargin: CGFloat = 8
        let badgeRect = NSRect(
            x: canvasSize - badgeDiameter - badgeMargin,
            y: badgeMargin,
            width: badgeDiameter,
            height: badgeDiameter
        )

        // Soft drop shadow for the badge
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowBlurRadius = 8
        shadow.set()

        // Outer white ring
        let ringPath = NSBezierPath(ovalIn: badgeRect)
        NSColor.white.setFill()
        ringPath.fill()

        // Reset shadow for crisp inner drawing
        NSShadow().set()

        // Inner chameleon teal-to-blue gradient circle
        let innerRect = badgeRect.insetBy(dx: 5.5, dy: 5.5)
        let innerPath = NSBezierPath(ovalIn: innerRect)
        if let gradient = NSGradient(
            starting: NSColor(calibratedRed: 0.0, green: 0.82, blue: 0.68, alpha: 1.0),
            ending: NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.98, alpha: 1.0)
        ) {
            gradient.draw(in: innerPath, angle: -45)
        } else {
            NSColor.systemTeal.setFill()
            innerPath.fill()
        }

        // Stylized Chameye eye emblem inside the badge
        let cx = innerRect.midX
        let cy = innerRect.midY
        let eyeW = innerRect.width * 0.64
        let eyeH = innerRect.height * 0.38

        let eyePath = NSBezierPath()
        eyePath.move(to: NSPoint(x: cx - eyeW / 2, y: cy))
        eyePath.curve(
            to: NSPoint(x: cx + eyeW / 2, y: cy),
            controlPoint1: NSPoint(x: cx - eyeW * 0.22, y: cy + eyeH),
            controlPoint2: NSPoint(x: cx + eyeW * 0.22, y: cy + eyeH)
        )
        eyePath.curve(
            to: NSPoint(x: cx - eyeW / 2, y: cy),
            controlPoint1: NSPoint(x: cx + eyeW * 0.22, y: cy - eyeH),
            controlPoint2: NSPoint(x: cx - eyeW * 0.22, y: cy - eyeH)
        )
        eyePath.close()
        NSColor.white.setFill()
        eyePath.fill()

        // Iris + pupil
        let irisR = innerRect.width * 0.14
        let irisRect = NSRect(x: cx - irisR, y: cy - irisR, width: irisR * 2, height: irisR * 2)
        NSColor(calibratedRed: 0.04, green: 0.48, blue: 0.92, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: irisRect).fill()

        let pupilR = innerRect.width * 0.06
        let pupilRect = NSRect(x: cx - pupilR, y: cy - pupilR, width: pupilR * 2, height: pupilR * 2)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: pupilRect).fill()

        return out
    }

    /// Save composited NSImage to a temporary PNG file and return its path.
    @MainActor
    static func saveTempPNG(_ image: NSImage, key: String) -> String? {
        let safeKey = key.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
        let path = "/tmp/chameye-dock-\(safeKey).png"
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        try? png.write(to: URL(fileURLWithPath: path))
        return path
    }
}
