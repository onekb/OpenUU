import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Extracts the live runtime Dock icon & Dock title of a running macOS process/window (e.g. WeChat Mini Programs
/// running under `WeChatAppEx`, which set a custom `NSApp.applicationIconImage` at runtime that
/// `NSRunningApplication.icon` does NOT reflect).
enum LiveDockIconExtractor {
    struct Request: Sendable {
        let windowID: UInt32
        let pid: pid_t
        let rawBundleID: String
        let appName: String
        let windowTitle: String
        let primaryAppName: String
        let primaryBundleURLPath: String?
    }

    struct Result: Sendable {
        let iconB64: String?
        let dockTitle: String?
    }

    private struct DockTileInfo {
        let title: String
        let url: URL?
        let frame: CGRect
    }

    /// Captures live Dock icons & Dock titles for a batch of helper/custom-icon windows with a single AX + SC query.
    @MainActor
    static func captureBatch(requests: [Request]) async -> [UInt32: Result] {
        guard !requests.isEmpty else { return [:] }

        let dockTiles = fetchRunningDockTiles()
        var matchedByWindowID: [UInt32: (tile: DockTileInfo, iconSquare: CGRect)] = [:]
        var results: [UInt32: Result] = [:]

        for req in requests {
            let runningApp = NSRunningApplication(processIdentifier: req.pid)
            let appBundleURL = runningApp?.bundleURL?.standardizedFileURL
            let primaryBundleURL = req.primaryBundleURLPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let appLocalizedName = runningApp?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if let tile = matchDockTile(
                in: dockTiles,
                windowTitle: req.windowTitle,
                appName: req.appName,
                appLocalizedName: appLocalizedName,
                appBundleURL: appBundleURL,
                primaryAppName: req.primaryAppName,
                primaryBundleURL: primaryBundleURL
            ) {
                let dockTitle = tile.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if let iconSquare = computeVisibleIconSquare(for: tile.frame) {
                    matchedByWindowID[req.windowID] = (tile, iconSquare)
                }
                results[req.windowID] = Result(
                    iconB64: nil,
                    dockTitle: dockTitle.isEmpty ? nil : dockTitle
                )
            }
        }

        if !matchedByWindowID.isEmpty,
           let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
            let dockWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.apple.dock" && $0.frame.width >= 40 && $0.frame.height >= 40
            }

            if !dockWindows.isEmpty {
                for (winID, match) in matchedByWindowID {
                    if let cgImg = await captureTileImage(iconSquare: match.iconSquare, dockWindows: dockWindows),
                       let cleaned = stripDockBackdropAndNormalize(cgImg, targetSize: 128) {
                        let b64 = IconCompositor.encodeIconToBase64PNG(cleaned, size: 128)
                        if !b64.isEmpty {
                            let existingTitle = results[winID]?.dockTitle
                            results[winID] = Result(iconB64: b64, dockTitle: existingTitle)
                        }
                    }
                }
            }
        }

        // Fallback to NSRunningApplication.icon / NSWorkspace.icon(forFile:) when live Dock capture wasn't available
        // (e.g. Dock auto-hidden off-screen or Accessibility permission unavailable).
        for req in requests {
            let existing = results[req.windowID]
            if let b64 = existing?.iconB64, !b64.isEmpty {
                continue
            }
            if let fallback = fallbackProcessIcon(pid: req.pid) {
                let b64 = IconCompositor.encodeIconToBase64PNG(fallback, size: 128)
                if !b64.isEmpty {
                    results[req.windowID] = Result(iconB64: b64, dockTitle: existing?.dockTitle)
                }
            }
        }

        return results
    }

    /// Lightweight AX-only lookup for a Dock title when we just need the real display name without screenshotting.
    static func lookupDockTitle(
        pid: pid_t,
        windowTitle: String,
        appName: String,
        primaryAppName: String,
        primaryBundleURLPath: String?
    ) -> String? {
        let dockTiles = fetchRunningDockTiles()
        guard !dockTiles.isEmpty else { return nil }
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let appBundleURL = runningApp?.bundleURL?.standardizedFileURL
        let primaryBundleURL = primaryBundleURLPath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let appLocalizedName = runningApp?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matched = matchDockTile(
            in: dockTiles,
            windowTitle: windowTitle,
            appName: appName,
            appLocalizedName: appLocalizedName,
            appBundleURL: appBundleURL,
            primaryAppName: primaryAppName,
            primaryBundleURL: primaryBundleURL
        )
        let title = matched?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    // MARK: - 1. Dock Accessibility Enumeration & Matching

    private static func fetchRunningDockTiles() -> [DockTileInfo] {
        guard AXIsProcessTrusted(),
              let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return []
        }
        let axDock = AXUIElementCreateApplication(dockApp.processIdentifier)
        guard let children = axAttr(axDock, kAXChildrenAttribute) as? [AXUIElement] else {
            return []
        }

        var tiles: [DockTileInfo] = []
        for list in children {
            guard let items = axAttr(list, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for item in items {
                let subrole = (axAttr(item, kAXSubroleAttribute) as? String) ?? ""
                guard subrole == "AXApplicationDockItem" else { continue }
                let isRunning = (axAttr(item, "AXIsApplicationRunning") as? NSNumber)?.boolValue ?? false
                guard isRunning else { continue }

                guard let frame = axFrame(of: item), frame.width >= 20, frame.height >= 20 else { continue }
                let title = ((axAttr(item, kAXTitleAttribute) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let url = (axAttr(item, kAXURLAttribute) as? URL)?.standardizedFileURL
                tiles.append(DockTileInfo(title: title, url: url, frame: frame))
            }
        }
        return tiles
    }

    private static func isGenericHelperName(_ value: String, primaryAppName: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        if lower == "wechatappex" || lower == "wechatappex helper" { return true }
        if !primaryAppName.isEmpty && trimmed.caseInsensitiveCompare(primaryAppName) == .orderedSame {
            return true
        }
        return false
    }

    private static func matchDockTile(
        in tiles: [DockTileInfo],
        windowTitle: String,
        appName: String,
        appLocalizedName: String,
        appBundleURL: URL?,
        primaryAppName: String,
        primaryBundleURL: URL?
    ) -> DockTileInfo? {
        guard !tiles.isEmpty else { return nil }

        let cleanWinTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        for raw in [cleanWinTitle, appLocalizedName, appName] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isGenericHelperName(trimmed, primaryAppName: primaryAppName),
               !candidates.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                candidates.append(trimmed)
            }
        }

        let isDifferentFromPrimaryBundle: Bool = {
            guard let appBundleURL else { return false }
            guard let primaryBundleURL else { return true }
            return appBundleURL != primaryBundleURL
        }()

        // Tier 1: Exact title + exact bundleURL match
        if let appBundleURL, !candidates.isEmpty {
            if let hit = tiles.first(where: { tile in
                tile.url == appBundleURL &&
                candidates.contains(where: { $0.caseInsensitiveCompare(tile.title) == .orderedSame })
            }) {
                return hit
            }
        }

        // Tier 2: Exact non-generic title match (never picking the parent app's own Dock tile!)
        if !candidates.isEmpty {
            if let hit = tiles.first(where: { tile in
                guard !tile.title.isEmpty else { return false }
                if isDifferentFromPrimaryBundle, let primaryBundleURL, tile.url == primaryBundleURL {
                    return false
                }
                return candidates.contains(where: { $0.caseInsensitiveCompare(tile.title) == .orderedSame })
            }) {
                return hit
            }
        }

        // Tier 3: Title prefix/contains match within the exact same helper bundleURL
        if let appBundleURL, !candidates.isEmpty {
            if let hit = tiles.first(where: { tile in
                guard tile.url == appBundleURL, !tile.title.isEmpty else { return false }
                return candidates.contains(where: { cand in
                    cand.localizedCaseInsensitiveContains(tile.title) ||
                    tile.title.localizedCaseInsensitiveContains(cand)
                })
            }) {
                return hit
            }
        }

        // Tier 4: Unique running helper tile with the same bundleURL (e.g. single open Mini Program while title is still loading)
        if isDifferentFromPrimaryBundle, let appBundleURL {
            let sameBundleTiles = tiles.filter { $0.url == appBundleURL }
            if sameBundleTiles.count == 1 {
                return sameBundleTiles[0]
            }
        }

        return nil
    }

    // MARK: - 2. Dock Tile Geometry & ScreenCaptureKit Capture

    private static func computeVisibleIconSquare(for tileFrame: CGRect) -> CGRect? {
        let displayBounds = containingDisplayCGBounds(for: tileFrame)
        let iconSquare: CGRect
        if tileFrame.height >= tileFrame.width {
            // Bottom Dock: running dot sits in the bottom margin; icon is top-aligned square.
            let side = tileFrame.width
            iconSquare = CGRect(x: tileFrame.minX, y: tileFrame.minY, width: side, height: side)
        } else if tileFrame.midX < displayBounds.midX {
            // Left Dock: running dot sits on the left; icon is right-aligned square.
            let side = tileFrame.height
            iconSquare = CGRect(x: tileFrame.maxX - side, y: tileFrame.minY, width: side, height: side)
        } else {
            // Right Dock: running dot sits on the right; icon is left-aligned square.
            let side = tileFrame.height
            iconSquare = CGRect(x: tileFrame.minX, y: tileFrame.minY, width: side, height: side)
        }

        let visible = iconSquare.intersection(displayBounds)
        let totalArea = max(1, iconSquare.width * iconSquare.height)
        let visibleRatio = (visible.width * visible.height) / totalArea
        guard visibleRatio >= 0.80 else {
            // Dock is likely auto-hidden off-screen
            return nil
        }
        return iconSquare
    }

    private static func containingDisplayCGBounds(for rect: CGRect) -> CGRect {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        if displayCount > 0 {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
            if CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                for did in displays {
                    let b = CGDisplayBounds(did)
                    if b.contains(center) || b.intersects(rect) {
                        return b
                    }
                }
            }
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    @MainActor
    private static func captureTileImage(iconSquare: CGRect, dockWindows: [SCWindow]) async -> CGImage? {
        // Prefer the main Dock bar window (layer 20) that contains the tile rect.
        let sorted = dockWindows.sorted { lhs, rhs in
            let lIsBar = lhs.windowLayer == 20
            let rIsBar = rhs.windowLayer == 20
            if lIsBar != rIsBar { return lIsBar }
            let lInter = lhs.frame.intersection(iconSquare)
            let rInter = rhs.frame.intersection(iconSquare)
            return (lInter.width * lInter.height) > (rInter.width * rInter.height)
        }
        guard let dockWin = sorted.first else { return nil }

        let dockBounds = CGRect(origin: .zero, size: dockWin.frame.size)
        let localRect = CGRect(
            x: iconSquare.minX - dockWin.frame.minX,
            y: iconSquare.minY - dockWin.frame.minY,
            width: iconSquare.width,
            height: iconSquare.height
        ).intersection(dockBounds)
        guard localRect.width >= 20, localRect.height >= 20 else { return nil }

        let cfg = SCStreamConfiguration()
        cfg.sourceRect = localRect
        let targetPx = max(128, min(256, Int(round(max(localRect.width, localRect.height) * 2.0))))
        cfg.width = targetPx
        cfg.height = targetPx
        cfg.scalesToFit = true
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.backgroundColor = .clear
        cfg.ignoreShadowsSingleWindow = true

        let filter = SCContentFilter(desktopIndependentWindow: dockWin)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    // MARK: - 3. Dock Shelf Backdrop Removal & Normalization

    /// Removes the translucent Dock glass shelf around the captured icon via adaptive border flood-fill,
    /// tightly crops the icon silhouette, and normalizes it into a crisp `targetSize × targetSize` image
    /// with standard macOS icon inset proportions.
    @MainActor
    static func stripDockBackdropAndNormalize(_ cgImage: CGImage, targetSize: Int = 128) -> NSImage? {
        let w = cgImage.width
        let h = cgImage.height
        guard w >= 24, h >= 24 else { return nil }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        @inline(__always)
        func pixelRGBA(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let idx = (y * w + x) * 4
            let a = Int(pixels[idx + 3])
            if a == 0 { return (0, 0, 0, 0) }
            // Unpremultiply for accurate color distance comparisons
            let r = min(255, Int(pixels[idx]) * 255 / a)
            let g = min(255, Int(pixels[idx + 1]) * 255 / a)
            let b = min(255, Int(pixels[idx + 2]) * 255 / a)
            return (r, g, b, a)
        }

        // Sample corner pixels (in CG top-down buffer coordinates, y=h-1 is bottom edge where Dock shelf always sits).
        let cornerCoords: [(Int, Int)] = [
            (1, h - 2), (2, h - 2), (w - 2, h - 2), (w - 3, h - 2),
            (1, 1), (2, 1), (w - 2, 1), (w - 3, 1),
        ]
        let nonTransparentCorners = cornerCoords
            .map { pixelRGBA($0.0, $0.1) }
            .filter { $0.a > 16 }

        if !nonTransparentCorners.isEmpty {
            // Prefer bottom corner shelf samples when available; they reliably capture the Dock glass shelf.
            let bottomShelfSamples = cornerCoords.prefix(4)
                .map { pixelRGBA($0.0, $0.1) }
                .filter { $0.a > 16 }
            let refSamples = bottomShelfSamples.isEmpty ? nonTransparentCorners : bottomShelfSamples

            let refR = refSamples.reduce(0) { $0 + $1.r } / refSamples.count
            let refG = refSamples.reduce(0) { $0 + $1.g } / refSamples.count
            let refB = refSamples.reduce(0) { $0 + $1.b } / refSamples.count
            let refA = refSamples.reduce(0) { $0 + $1.a } / refSamples.count

            // Only strip if the corners are either semi-transparent (Dock shelf without wallpaper) OR
            // consistent across corners (uniform shelf backdrop).
            let maxCornerSpread = refSamples.map {
                abs($0.r - refR) + abs($0.g - refG) + abs($0.b - refB) + abs($0.a - refA)
            }.max() ?? 999

            let shouldFloodStrip = (refA < 225) || (maxCornerSpread <= 60)

            if shouldFloodStrip {
                var visited = [UInt8](repeating: 0, count: w * h)
                var queue: [Int] = []
                queue.reserveCapacity(w * 4 + h * 4)

                @inline(__always)
                func isShelfPixel(_ x: Int, _ y: Int) -> Bool {
                    let p = pixelRGBA(x, y)
                    if p.a <= 20 { return true }
                    // Semi-transparent glass pixels well below full icon opacity
                    if refA <= 205 && p.a <= min(195, refA + 32) {
                        let colorDist = abs(p.r - refR) + abs(p.g - refG) + abs(p.b - refB)
                        if colorDist <= 105 { return true }
                    }
                    let alphaDiff = abs(p.a - refA)
                    let colorDist = abs(p.r - refR) + abs(p.g - refG) + abs(p.b - refB)
                    return alphaDiff <= 38 && colorDist <= 78
                }

                func tryEnqueue(_ x: Int, _ y: Int) {
                    let pos = y * w + x
                    guard visited[pos] == 0 else { return }
                    if isShelfPixel(x, y) {
                        visited[pos] = 1
                        queue.append(pos)
                    }
                }

                for x in 0..<w {
                    tryEnqueue(x, 0)
                    tryEnqueue(x, h - 1)
                }
                for y in 0..<h {
                    tryEnqueue(0, y)
                    tryEnqueue(w - 1, y)
                }

                var head = 0
                while head < queue.count {
                    let pos = queue[head]
                    head += 1
                    let x = pos % w
                    let y = pos / w
                    if x > 0 { tryEnqueue(x - 1, y) }
                    if x + 1 < w { tryEnqueue(x + 1, y) }
                    if y > 0 { tryEnqueue(x, y - 1) }
                    if y + 1 < h { tryEnqueue(x, y + 1) }
                }

                // Clear background pixels to full transparency
                for pos in queue {
                    let idx = pos * 4
                    pixels[idx] = 0
                    pixels[idx + 1] = 0
                    pixels[idx + 2] = 0
                    pixels[idx + 3] = 0
                }

                // Soft 1-pixel anti-alias cleanup on pixels directly touching removed shelf pixels
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) {
                        let pos = y * w + x
                        guard visited[pos] == 0 else { continue }
                        let touchesBG = visited[pos - 1] == 1 || visited[pos + 1] == 1 ||
                            visited[pos - w] == 1 || visited[pos + w] == 1
                        guard touchesBG else { continue }
                        let p = pixelRGBA(x, y)
                        if refA <= 205 && p.a < 220 {
                            let colorDist = abs(p.r - refR) + abs(p.g - refG) + abs(p.b - refB)
                            if colorDist < 95 {
                                let idx = pos * 4
                                let scale = max(0, min(1.0, Double(colorDist) / 95.0))
                                pixels[idx] = UInt8(Double(pixels[idx]) * scale)
                                pixels[idx + 1] = UInt8(Double(pixels[idx + 1]) * scale)
                                pixels[idx + 2] = UInt8(Double(pixels[idx + 2]) * scale)
                                pixels[idx + 3] = UInt8(Double(pixels[idx + 3]) * scale)
                            }
                        }
                    }
                }
            }
        }

        // Compute tight bounding box of remaining opaque/visible icon pixels
        var minX = w
        var minY = h
        var maxX = -1
        var maxY = -1
        var minLum = 255
        var maxLum = 0
        var visibleCount = 0

        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let a = Int(pixels[idx + 3])
                guard a >= 32 else { continue }
                visibleCount += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                let lum = (Int(pixels[idx]) * 299 + Int(pixels[idx + 1]) * 587 + Int(pixels[idx + 2]) * 114) / max(1, a * 1000 / 255)
                if lum < minLum { minLum = lum }
                if lum > maxLum { maxLum = lum }
            }
        }

        let boxW = maxX - minX + 1
        let boxH = maxY - minY + 1
        // Sanity check: must contain a real icon silhouette, not an empty/hidden/uniformly-blank tile
        guard visibleCount >= (w * h) / 10,
              boxW >= Int(Double(w) * 0.35),
              boxH >= Int(Double(h) * 0.35),
              (maxLum - minLum) >= 8 else {
            return nil
        }

        guard let cleanedFull = ctx.makeImage(),
              let cropped = cleanedFull.cropping(to: CGRect(x: minX, y: minY, width: boxW, height: boxH)) else {
            return nil
        }

        // Normalize into standard macOS icon canvas (82% visible body centered in 128×128, matching NSRunningApplication.icon)
        let sizeF = CGFloat(targetSize)
        guard let outRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetSize,
            pixelsHigh: targetSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        outRep.size = NSSize(width: sizeF, height: sizeF)

        let bodyMax = sizeF * 0.82
        let scale = min(bodyMax / CGFloat(boxW), bodyMax / CGFloat(boxH))
        let drawW = CGFloat(boxW) * scale
        let drawH = CGFloat(boxH) * scale
        let drawRect = NSRect(
            x: (sizeF - drawW) / 2.0,
            y: (sizeF - drawH) / 2.0,
            width: drawW,
            height: drawH
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let croppedNS = NSImage(cgImage: cropped, size: NSSize(width: boxW, height: boxH))
        croppedNS.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let outImg = NSImage(size: NSSize(width: sizeF, height: sizeF))
        outImg.addRepresentation(outRep)
        return outImg
    }

    // MARK: - Helpers

    private static func fallbackProcessIcon(pid: pid_t) -> NSImage? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if let url = app.bundleURL {
            if let eff = (try? url.resourceValues(forKeys: [.effectiveIconKey]))?.effectiveIcon as? NSImage {
                return eff
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return app.icon
    }

    private static func axAttr(_ el: AXUIElement, _ key: String) -> AnyObject? {
        var val: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, key as CFString, &val)
        return err == .success ? val : nil
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(), CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}
