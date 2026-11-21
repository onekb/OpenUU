#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootDir = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

let srcIconURL = rootDir.appendingPathComponent("apps/macos/Resources/AppIcon.png")
guard let srcImageSource = CGImageSourceCreateWithURL(srcIconURL as CFURL, nil),
      let srcCGImage = CGImageSourceCreateImageAtIndex(srcImageSource, 0, nil) else {
    fputs("ERROR: Failed to load source icon at \(srcIconURL.path)\n", stderr)
    exit(1)
}

let srcW = CGFloat(srcCGImage.width)
let srcH = CGFloat(srcCGImage.height)
print("Loaded source AppIcon.png: \(Int(srcW))x\(Int(srcH))")

let bgR: CGFloat = 10.0 / 255.0   // #0A0F1D
let bgG: CGFloat = 15.0 / 255.0
let bgB: CGFloat = 29.0 / 255.0

func cropImage(_ image: CGImage, insetMin: CGFloat, insetMax: CGFloat) -> CGImage {
    let scaleX = CGFloat(image.width) / 1024.0
    let scaleY = CGFloat(image.height) / 1024.0
    let x = (insetMin * scaleX).rounded()
    let y = (insetMin * scaleY).rounded()
    let w = ((insetMax - insetMin) * scaleX).rounded()
    let h = ((insetMax - insetMin) * scaleY).rounded()
    let rect = CGRect(x: x, y: y, width: w, height: h)
    guard let cropped = image.cropping(to: rect) else {
        fputs("ERROR: Failed to crop image to \(rect)\n", stderr)
        exit(1)
    }
    return cropped
}

func savePNG(_ image: CGImage, to url: URL) {
    let dir = url.deletingLastPathComponent()
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fputs("ERROR: Failed to create PNG destination at \(url.path)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        fputs("ERROR: Failed to finalize PNG at \(url.path)\n", stderr)
        exit(1)
    }
    print("  -> Wrote \(url.path) (\(image.width)x\(image.height))")
}

func renderRGBA(size: Int, draw: (CGContext, CGRect) -> Void) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fputs("ERROR: Failed to allocate RGBA CGContext (\(size)x\(size))\n", stderr)
        exit(1)
    }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    draw(ctx, rect)
    guard let out = ctx.makeImage() else {
        fputs("ERROR: Failed to make CGImage from RGBA context\n", stderr)
        exit(1)
    }
    return out
}

func renderOpaqueRGB(size: Int, draw: (CGContext, CGRect) -> Void) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fputs("ERROR: Failed to allocate opaque RGB CGContext (\(size)x\(size))\n", stderr)
        exit(1)
    }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    draw(ctx, rect)
    guard let out = ctx.makeImage() else {
        fputs("ERROR: Failed to make opaque CGImage\n", stderr)
        exit(1)
    }
    return out
}

/// Generates a soft circularly-feathered alpha mask so the cropped dark-navy interior
/// blends seamlessly into Android's `#0A0F1D` adaptive icon background with zero square seams.
func makeFeatheredCircleMask(size: Int, innerFraction: CGFloat, outerFraction: CGFloat) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else {
        fputs("ERROR: Failed to allocate grayscale mask context\n", stderr)
        exit(1)
    }
    let s = CGFloat(size)
    let center = CGPoint(x: s / 2.0, y: s / 2.0)
    ctx.setFillColor(gray: 0.0, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    let locations: [CGFloat] = [0.0, innerFraction, outerFraction, 1.0]
    let colors = [
        CGColor(gray: 1.0, alpha: 1.0),
        CGColor(gray: 1.0, alpha: 1.0),
        CGColor(gray: 0.0, alpha: 1.0),
        CGColor(gray: 0.0, alpha: 1.0),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
        ctx.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: s / 2.0,
            options: [.drawsAfterEndLocation]
        )
    }
    guard let mask = ctx.makeImage() else {
        fputs("ERROR: Failed to create radial mask image\n", stderr)
        exit(1)
    }
    return mask
}

// Cropped source regions matching apps/macos/Sources/OpenUUApp/Shared/IconCompositor.swift
let squircleCrop = cropImage(srcCGImage, insetMin: 100, insetMax: 924)   // 824x824 macOS squircle body
let fullBleedCrop = cropImage(srcCGImage, insetMin: 130, insetMax: 894)  // 764x764 inside bevel for iOS / round
let interiorCrop = cropImage(srcCGImage, insetMin: 144, insetMax: 880)   // 736x736 pure interior artwork for Android adaptive foreground

// =========================================================================
// 1. ANDROID ASSETS
// =========================================================================
print("\n[Android] Syncing official OpenUU brand icons...")
let androidResDir = rootDir.appendingPathComponent("apps/android/app/src/main/res")

// 1a. Remove legacy generic eye foreground vector if present
let wrongEyeForeground = androidResDir.appendingPathComponent("drawable/ic_launcher_foreground.xml")
if fm.fileExists(atPath: wrongEyeForeground.path) {
    try fm.removeItem(at: wrongEyeForeground)
    print("  -> Removed wrong eye vector: \(wrongEyeForeground.path)")
}

// 1b. Update ic_launcher_background.xml to solid #0A0F1D
let androidBgXML = """
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#FF0A0F1D"
        android:pathData="M0,0h108v108h-108z" />
</vector>
"""
let androidBgURL = androidResDir.appendingPathComponent("drawable/ic_launcher_background.xml")
try? fm.createDirectory(at: androidBgURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try androidBgXML.write(to: androidBgURL, atomically: true, encoding: .utf8)
print("  -> Updated \(androidBgURL.path) (#0A0F1D)")

// 1c. Adaptive launcher foreground (432x432 xxxhdpi):
// Center the 736x736 interior artwork inside 316x316 (with soft feathered edge from 80%..100%)
// so the chameleon+window sits comfortably within Android's 66% (285px) safe zone on all masks.
let adaptiveSize = 432
let artBox: CGFloat = 316
let artOffset = (CGFloat(adaptiveSize) - artBox) / 2.0
let featheredMask = makeFeatheredCircleMask(size: Int(artBox), innerFraction: 0.80, outerFraction: 0.99)
let adaptiveFg = renderRGBA(size: adaptiveSize) { ctx, rect in
    ctx.clear(rect)
    let targetRect = CGRect(x: artOffset, y: artOffset, width: artBox, height: artBox)
    ctx.saveGState()
    ctx.clip(to: targetRect, mask: featheredMask)
    ctx.draw(interiorCrop, in: targetRect)
    ctx.restoreGState()
}
savePNG(adaptiveFg, to: androidResDir.appendingPathComponent("drawable-xxxhdpi/ic_launcher_foreground.png"))

// 1d. Legacy & round launcher mipmaps (mdpi..xxxhdpi)
let mipmapSpecs: [(String, Int)] = [
    ("mipmap-mdpi", 48),
    ("mipmap-hdpi", 72),
    ("mipmap-xhdpi", 96),
    ("mipmap-xxhdpi", 144),
    ("mipmap-xxxhdpi", 192),
]

for (folder, px) in mipmapSpecs {
    let legacyIcon = renderRGBA(size: px) { ctx, rect in
        ctx.clear(rect)
        ctx.draw(squircleCrop, in: rect)
    }
    savePNG(legacyIcon, to: androidResDir.appendingPathComponent("\(folder)/ic_launcher.png"))

    let roundIcon = renderRGBA(size: px) { ctx, rect in
        ctx.clear(rect)
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.setFillColor(red: bgR, green: bgG, blue: bgB, alpha: 1.0)
        ctx.fill(rect)
        ctx.draw(fullBleedCrop, in: rect)
        ctx.restoreGState()
    }
    savePNG(roundIcon, to: androidResDir.appendingPathComponent("\(folder)/ic_launcher_round.png"))
}

// 1e. In-app Android brand icon (256x256 squircle, identical to macOS IconCompositor.brandSquircleIcon)
let androidBrandIcon = renderRGBA(size: 256) { ctx, rect in
    ctx.clear(rect)
    ctx.draw(squircleCrop, in: rect)
}
savePNG(androidBrandIcon, to: androidResDir.appendingPathComponent("drawable-nodpi/openuu_brand_icon.png"))

// =========================================================================
// 2. iOS ASSETS
// =========================================================================
print("\n[iOS] Syncing official OpenUU brand icons...")
let iosAssetsDir = rootDir.appendingPathComponent("apps/ios/Resources/Assets.xcassets")

// 2a. iOS AppIcon (1024x1024 opaque #0A0F1D + center 130..894 scaled cleanly to 1024x1024)
let iosAppIcon = renderOpaqueRGB(size: 1024) { ctx, rect in
    ctx.setFillColor(red: bgR, green: bgG, blue: bgB, alpha: 1.0)
    ctx.fill(rect)
    ctx.draw(fullBleedCrop, in: rect)
}
savePNG(iosAppIcon, to: iosAssetsDir.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))

// 2b. iOS in-app BrandIcon.imageset (256x256 cropped squircle 100..924 + Contents.json)
let iosBrandDir = iosAssetsDir.appendingPathComponent("BrandIcon.imageset")
try? fm.createDirectory(at: iosBrandDir, withIntermediateDirectories: true)

let iosBrandIcon = renderRGBA(size: 256) { ctx, rect in
    ctx.clear(rect)
    ctx.draw(squircleCrop, in: rect)
}
savePNG(iosBrandIcon, to: iosBrandDir.appendingPathComponent("BrandIcon.png"))

let brandContentsJSON = """
{
  "images" : [
    {
      "filename" : "BrandIcon.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try brandContentsJSON.write(
    to: iosBrandDir.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)
print("  -> Wrote \(iosBrandDir.appendingPathComponent("Contents.json").path)")
print("\nAll Android & iOS brand icons synced successfully!")
