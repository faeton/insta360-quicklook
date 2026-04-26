// Generates AppIcon.icns at icon/AppIcon.icns.
//
// Design: rounded-rect tile, deep-blue radial background, two side-by-side
// fisheye lenses (dark glass with cyan rim highlight) — visual reference
// to Insta360's dual-fisheye output. Renders all macOS icon sizes via
// CoreGraphics, then `iconutil` packs into .icns.
//
// Run: swift icon/make-icon.swift
import AppKit
import CoreGraphics

let iconsetDir = "icon/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Rounded-rect tile clip — modern macOS app-icon shape.
    let tileInset: CGFloat = s * 0.085
    let tileRect = CGRect(x: tileInset, y: tileInset, width: s - 2*tileInset, height: s - 2*tileInset)
    let cornerRadius = tileRect.width * 0.225
    let tilePath = CGPath(roundedRect: tileRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Background: radial gradient from a vibrant teal-blue to deep navy.
    let colors = [
        CGColor(red: 0.13, green: 0.42, blue: 0.74, alpha: 1.0),
        CGColor(red: 0.04, green: 0.12, blue: 0.30, alpha: 1.0),
    ] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(grad,
        startCenter: CGPoint(x: s*0.5, y: s*0.62), startRadius: 0,
        endCenter:   CGPoint(x: s*0.5, y: s*0.4),  endRadius: s*0.7,
        options: [])

    // Two fisheye lenses, side by side, slightly overlapping.
    let lensRadius = s * 0.215
    let cy = s * 0.5
    let leftCx  = s * 0.30
    let rightCx = s * 0.70

    for cx in [leftCx, rightCx] {
        let lensRect = CGRect(x: cx - lensRadius, y: cy - lensRadius,
                              width: lensRadius * 2, height: lensRadius * 2)

        // Outer rim ring (cyan).
        ctx.setFillColor(CGColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 1.0))
        ctx.fillEllipse(in: lensRect)

        // Inner glass — dark gradient.
        let innerInset = lensRadius * 0.13
        let innerRect = lensRect.insetBy(dx: innerInset, dy: innerInset)
        let glassColors = [
            CGColor(red: 0.07, green: 0.18, blue: 0.35, alpha: 1.0),
            CGColor(red: 0.01, green: 0.03, blue: 0.08, alpha: 1.0),
        ] as CFArray
        let glassGrad = CGGradient(colorsSpace: cs, colors: glassColors, locations: [0.0, 1.0])!
        ctx.saveGState()
        ctx.addEllipse(in: innerRect)
        ctx.clip()
        ctx.drawRadialGradient(glassGrad,
            startCenter: CGPoint(x: innerRect.midX - innerRect.width*0.15,
                                 y: innerRect.midY + innerRect.height*0.2),
            startRadius: 0,
            endCenter:   CGPoint(x: innerRect.midX, y: innerRect.midY),
            endRadius:   innerRect.width * 0.6,
            options: [])
        ctx.restoreGState()

        // Specular highlight — small bright crescent top-left of each lens.
        let highlightRadius = lensRadius * 0.32
        let highlightCenter = CGPoint(x: cx - lensRadius*0.32, y: cy + lensRadius*0.45)
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        let hiColors = [
            CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.55),
            CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0),
        ] as CFArray
        let hiGrad = CGGradient(colorsSpace: cs, colors: hiColors, locations: [0.0, 1.0])!
        ctx.drawRadialGradient(hiGrad,
            startCenter: highlightCenter, startRadius: 0,
            endCenter:   highlightCenter, endRadius:   highlightRadius,
            options: [])
        ctx.restoreGState()

        // Tiny center dot — sensor pinprick, just for character.
        let dotR = lensRadius * 0.05
        ctx.setFillColor(CGColor(red: 0.05, green: 0.10, blue: 0.18, alpha: 1.0))
        ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR*2, height: dotR*2))
    }

    ctx.restoreGState()

    // Subtle inner stroke around tile for extra crispness.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()

    return ctx.makeImage()!
}

for entry in sizes {
    let cg = render(size: entry.px)
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: entry.px, height: entry.px)
    let png = rep.representation(using: .png, properties: [:])!
    let url = URL(fileURLWithPath: "\(iconsetDir)/\(entry.name)")
    try png.write(to: url)
    print("wrote \(entry.name) (\(png.count) bytes)")
}

// Pack into .icns
let iconutil = Process()
iconutil.launchPath = "/usr/bin/iconutil"
iconutil.arguments = ["-c", "icns", iconsetDir, "-o", "icon/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print("AppIcon.icns built — exit \(iconutil.terminationStatus)")
