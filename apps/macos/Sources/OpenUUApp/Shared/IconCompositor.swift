import AppKit
import Foundation

enum IconCompositor {
    /// Official OpenUU app icon loaded from the `.app` bundle resources (or workspace `Resources/` during CLI runs).
    @MainActor
    static let rawAppIcon: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let img = Bundle.main.image(forResource: "AppIcon") {
            return img
        }

        // Fallback search paths when launched directly via `swift run` or `.build/release/OpenUUApp`
        let fm = FileManager.default
        var candidates: [URL] = [
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("apps/macos/Resources/AppIcon.png"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.png"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("apps/macos/Resources/AppIcon.icns"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.icns"),
        ]
        if let execURL = Bundle.main.executableURL {
            var dir = execURL.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(dir.appendingPathComponent("Resources/AppIcon.png"))
                candidates.append(dir.appendingPathComponent("Resources/AppIcon.icns"))
                candidates.append(dir.appendingPathComponent("apps/macos/Resources/AppIcon.png"))
                candidates.append(dir.appendingPathComponent("apps/macos/Resources/AppIcon.icns"))
                dir.deleteLastPathComponent()
            }
        }
        for url in candidates where fm.fileExists(atPath: url.path) {
            if let img = NSImage(contentsOf: url) {
                return img
            }
        }
        return nil
    }()

    /// Precomputed 2x Retina cropped squircle (`824/1024` visible macOS icon body without outer canvas margin)
    /// and matching continuous-superellipse white silhouette mask for crisp UI logos & Dock badges.
    @MainActor
    private static let brandAssets: (squircle: NSImage, whiteMask: NSImage)? = {
        guard let src = rawAppIcon else { return nil }
        let ptSize: CGFloat = 256
        let pxSize = 512
        let dstRect = NSRect(x: 0, y: 0, width: ptSize, height: ptSize)

        // Standard macOS 1024x1024 icon canvas has 100px padding around the 824x824 squircle body.
        let insetFraction: CGFloat = 100.0 / 1024.0

        guard let croppedRep = makeBitmapRep(points: ptSize, pixels: pxSize) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: croppedRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let srcSize = src.size
        let insetX = srcSize.width * insetFraction
        let insetY = srcSize.height * insetFraction
        let srcRect = NSRect(x: insetX, y: insetY, width: srcSize.width - insetX * 2, height: srcSize.height - insetY * 2)
        src.draw(in: dstRect, from: srcRect, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let croppedImg = NSImage(size: dstRect.size)
        croppedImg.addRepresentation(croppedRep)

        guard let maskRep = makeBitmapRep(points: ptSize, pixels: pxSize) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: maskRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        croppedImg.draw(in: dstRect, from: .zero, operation: .copy, fraction: 1.0)
        NSColor.white.setFill()
        dstRect.fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()

        let maskImg = NSImage(size: dstRect.size)
        maskImg.addRepresentation(maskRep)
        return (croppedImg, maskImg)
    }()

    /// Tightly cropped OpenUU squircle icon ready for in-app headers, toolbars, and about views.
    @MainActor
    static var brandSquircleIcon: NSImage {
        brandAssets?.squircle ?? rawAppIcon ?? NSApp.applicationIconImage
    }

    private static func makeBitmapRep(points: CGFloat, pixels: Int) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        rep?.size = NSSize(width: points, height: points)
        return rep
    }

    /// Host-side: Encode an NSImage (e.g. `NSRunningApplication.icon`) to a compact 128x128 PNG base64 string.
    @MainActor
    static func encodeIconToBase64PNG(_ image: NSImage?, size: CGFloat = 128) -> String {
        guard let image, let rep = makeBitmapRep(points: size, pixels: Int(size)) else { return "" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: NSSize(width: size, height: size)), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return png.base64EncodedString()
    }

    /// Client-side: Decode base64 PNG back to NSImage.
    static func decodeBase64PNG(_ b64: String) -> NSImage? {
        guard !b64.isEmpty, let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    /// Client-side: Redraw the remote app icon at 256x256 (512x512 @2x) with the official OpenUU icon badge overlaid in the bottom-right corner.
    @MainActor
    static func compositeWithOpenUUBadge(_ baseIcon: NSImage?) -> NSImage {
        let canvasSize: CGFloat = 256
        let fullRect = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)

        guard let rep = makeBitmapRep(points: canvasSize, pixels: 512) else {
            return baseIcon ?? brandSquircleIcon
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        // 1. Draw base remote app icon (or a sleek fallback squircle)
        if let baseIcon {
            baseIcon.draw(in: fullRect.insetBy(dx: 8, dy: 8), from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            let fallbackRect = fullRect.insetBy(dx: 20, dy: 20)
            let bg = NSBezierPath(roundedRect: fallbackRect, xRadius: 46, yRadius: 46)
            NSColor.controlAccentColor.setFill()
            bg.fill()
        }

        // 2. Draw official OpenUU app icon badge in the bottom-right corner so macOS's native red unread badge
        //    (which always sits at the top-right corner of the Dock icon) never overlaps it.
        let badgeSize: CGFloat = canvasSize * 0.38
        let badgeMargin: CGFloat = 8
        let badgeRect = NSRect(
            x: canvasSize - badgeSize - badgeMargin,
            y: badgeMargin,
            width: badgeSize,
            height: badgeSize
        )

        if let assets = brandAssets {
            // Soft drop shadow + continuous-squircle white rim so the dark OpenUU icon stands out on both light and dark base icons
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.shadowBlurRadius = 8
            shadow.set()
            assets.whiteMask.draw(
                in: badgeRect.insetBy(dx: -3, dy: -3),
                from: .zero,
                operation: .sourceOver,
                fraction: 0.95
            )
            NSGraphicsContext.restoreGraphicsState()

            assets.squircle.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            let ringPath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeSize * 0.24, yRadius: badgeSize * 0.24)
            NSColor.systemCyan.setFill()
            ringPath.fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: fullRect.size)
        out.addRepresentation(rep)
        return out
    }

    /// Save composited NSImage to a temporary PNG file and return its path.
    @MainActor
    static func saveTempPNG(_ image: NSImage, key: String) -> String? {
        let safeKey = key.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
        let path = "/tmp/openuu-dock-\(safeKey).png"
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        try? png.write(to: URL(fileURLWithPath: path))
        return path
    }
}
