// Draws the app icon: a 60% keyboard with rainbow-lit keys on a dark squircle.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let rows: [[Double]] = [
    [1] + Array(repeating: 1, count: 12) + [2],
    [1.5] + Array(repeating: 1, count: 12) + [1.5],
    [1.75] + Array(repeating: 1, count: 11) + [2.25],
    [2.25] + Array(repeating: 1, count: 10) + [2.75],
    [1.25, 1.25, 1.25, 6.25, 1.25, 1.25, 1.25, 1.25],
]

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(size) / 1024

    // Squircle background (Big Sur grid: 824pt body inside a 1024 canvas).
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.20, green: 0.21, blue: 0.25, alpha: 1).cgColor,
        NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Keyboard case.
    let unit = 46 * s
    let boardWidth = 15 * unit, boardHeight = 5 * unit
    let origin = CGPoint(x: (CGFloat(size) - boardWidth) / 2, y: (CGFloat(size) - boardHeight) / 2 - 8 * s)
    let caseRect = CGRect(x: origin.x - 18 * s, y: origin.y - 18 * s, width: boardWidth + 36 * s, height: boardHeight + 36 * s)
    ctx.addPath(CGPath(roundedRect: caseRect, cornerWidth: 26 * s, cornerHeight: 26 * s, transform: nil))
    ctx.setFillColor(NSColor(white: 0.04, alpha: 1).cgColor)
    ctx.fillPath()

    // Keys, lit in a diagonal rainbow.
    let gap = 5 * s
    for (rowIndex, widths) in rows.enumerated() {
        var x = 0.0
        for width in widths {
            let centre = (x + width / 2) / 15 + Double(rowIndex) * 0.04
            let colour = NSColor(hue: CGFloat(centre * 0.82).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 1, alpha: 1)
            let rect = CGRect(
                x: origin.x + CGFloat(x) * unit + gap / 2,
                y: origin.y + CGFloat(4 - rowIndex) * unit + gap / 2,
                width: CGFloat(width) * unit - gap, height: unit - gap
            )
            let key = CGPath(roundedRect: rect, cornerWidth: 8 * s, cornerHeight: 8 * s, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 18 * s, color: colour.withAlphaComponent(0.9).cgColor)
            ctx.addPath(key)
            ctx.setFillColor(colour.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 6 * s, dy: 6 * s), cornerWidth: 5 * s, cornerHeight: 5 * s, transform: nil))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            ctx.fillPath()
            x += width
        }
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
