#!/usr/bin/env swift
// Regenerate both application icons and the About-window brand mark with:
//   swift scripts/generate-app-icons.swift
//
// The artwork below is drawn entirely with original CoreGraphics paths.
// In particular, the chart mark is not sourced from SF Symbols.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum IconCanvas {
    case iphone
    case mac
    case brandMark
}

private let imageSize = 1024
private let phoneIcon = "Apps/Mobile/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
private let macIconDirectory = "Apps/Mac/Assets.xcassets/AppIcon.appiconset"
private let brandMark = "Apps/Mac/Assets.xcassets/StatsBrandMark.imageset/StatsBrandMark.png"
private let statusMarkDirectory = "Apps/Mac/Assets.xcassets/StatsStatusMark.imageset"

private func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [red / 255, green / 255, blue / 255, alpha])!
}

private func drawRoundedBar(_ context: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
                           cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
    context.fillPath()
}

/// Draws the same symbol and blue field for all three canvases.
/// The only differences are the platform's treatment of the outer corners and margins.
private func drawArtwork(_ context: CGContext, tile: CGRect, roundCorners: Bool) {
    context.saveGState()
    context.translateBy(x: tile.minX, y: tile.minY)
    context.scaleBy(x: tile.width / 1024, y: tile.height / 1024)

    let tilePath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                          cornerWidth: roundCorners ? 224 : 0,
                          cornerHeight: roundCorners ? 224 : 0, transform: nil)
    context.addPath(tilePath)
    context.clip()
    context.setFillColor(rgb(28, 79, 209))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let blueGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(45, 207, 253), rgb(29, 139, 241), rgb(28, 79, 209)] as CFArray,
        locations: [0, 0.49, 1]
    )!
    context.drawLinearGradient(blueGradient,
                               start: CGPoint(x: 55, y: 4),
                               end: CGPoint(x: 950, y: 1060),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // A broad soft spot of light adds depth without relying on platform effects.
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(207, 249, 255, alpha: 0.21), rgb(207, 249, 255, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(glow,
                               startCenter: CGPoint(x: 190, y: 128), startRadius: 0,
                               endCenter: CGPoint(x: 190, y: 128), endRadius: 720,
                               options: [])

    // Three quiet columns establish the chart context underneath the rising curve.
    context.setFillColor(rgb(255, 255, 255, alpha: 0.18))
    drawRoundedBar(context, x: 279, y: 604, width: 70, height: 166)
    drawRoundedBar(context, x: 471, y: 554, width: 70, height: 216)
    drawRoundedBar(context, x: 663, y: 434, width: 70, height: 336)

    // A custom asymmetric activity curve. Its inflection and final large node are
    // deliberately independent of the SF Symbols chart family.
    let line = CGMutablePath()
    line.move(to: CGPoint(x: 234, y: 660))
    line.addCurve(to: CGPoint(x: 378, y: 527),
                  control1: CGPoint(x: 287, y: 647), control2: CGPoint(x: 338, y: 526))
    line.addCurve(to: CGPoint(x: 527, y: 596),
                  control1: CGPoint(x: 430, y: 524), control2: CGPoint(x: 468, y: 617))
    line.addCurve(to: CGPoint(x: 761, y: 326),
                  control1: CGPoint(x: 617, y: 586), control2: CGPoint(x: 668, y: 368))
    context.addPath(line)
    context.setLineWidth(64)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(rgb(255, 255, 255))
    context.strokePath()

    context.setFillColor(rgb(255, 255, 255))
    context.fillEllipse(in: CGRect(x: 729, y: 294, width: 64, height: 64))

    context.restoreGState()
}

private func image(size: Int, style: IconCanvas) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    // iOS app icons must not contain an alpha channel; macOS uses alpha for
    // the transparent breathing room around its rounded-square tile.
    let alphaInfo: CGImageAlphaInfo = style == .iphone ? .noneSkipLast : .premultipliedLast
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: alphaInfo.rawValue) else {
        fatalError("Unable to create RGBA image context")
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // All art coordinates use a 1024-point canvas with top-left origin.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)

    switch style {
    case .iphone:
        // A square opaque image: iOS owns the final home-screen corner mask.
        drawArtwork(context, tile: CGRect(x: 0, y: 0, width: 1024, height: 1024), roundCorners: false)
    case .brandMark:
        drawArtwork(context, tile: CGRect(x: 0, y: 0, width: 1024, height: 1024), roundCorners: true)
    case .mac:
        // The native macOS icon retains a little breathing room and a soft shadow.
        let tile = CGRect(x: 93, y: 82, width: 838, height: 838)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 11), blur: 25,
                          color: rgb(6, 32, 82, alpha: 0.17))
        context.setFillColor(rgb(25, 100, 214))
        context.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 224 / 1024,
                               cornerHeight: tile.height * 224 / 1024, transform: nil))
        context.fillPath()
        context.restoreGState()
        drawArtwork(context, tile: tile, roundCorners: true)
    }

    guard let output = context.makeImage() else { fatalError("Unable to render icon") }
    return output
}

private func save(_ renderedImage: CGImage, to relativePath: String) {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            UTType.png.identifier as CFString,
                                                            1, nil) else {
        fatalError("Unable to write \(relativePath)")
    }
    CGImageDestinationAddImage(destination, renderedImage, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Unable to finalize \(relativePath)") }
    print(relativePath)
}

save(image(size: imageSize, style: .iphone), to: phoneIcon)
save(image(size: imageSize, style: .brandMark), to: brandMark)

// Menu-bar graphics use the same blue chart artwork, rasterized directly at
// standard display scales so the tiny status item stays sharp on Retina Macs.
for (size, filename) in [(18, "StatsStatusMark.png"),
                         (36, "StatsStatusMark@2x.png"),
                         (54, "StatsStatusMark@3x.png")] {
    save(image(size: size, style: .brandMark), to: "\(statusMarkDirectory)/\(filename)")
}

// Render every required macOS scale at its native resolution, keeping 16-pixel
// views as crisp as the 1024-pixel icon.
let macSizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (size, filename) in macSizes {
    save(image(size: size, style: .mac), to: "\(macIconDirectory)/\(filename)")
}
