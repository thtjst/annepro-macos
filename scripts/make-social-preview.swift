// Composes the 1280×640 social preview image (GitHub link cards, Reddit) from the app icon
// and the lighting editor screenshot.
// Usage: swift scripts/make-social-preview.swift promo/social-preview.png
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "promo/social-preview.png"
let size = NSSize(width: 1280, height: 640)
let scale: CGFloat = 1

guard let icon = NSImage(contentsOfFile: "Resources/AppIcon.png"),
      let screenshot = NSImage(contentsOfFile: "docs/screenshots/lighting-dark.png") else {
    fatalError("Run from the repository root after scripts/screenshots.sh")
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background.
NSGradient(colors: [NSColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1), NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: -90)

// Rainbow glow behind the screenshot.
let glow = NSGradient(colors: [
    NSColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.35), NSColor(red: 0.1, green: 1, blue: 0.4, alpha: 0.3),
    NSColor(red: 0.2, green: 0.4, blue: 1, alpha: 0.35), NSColor(red: 0.8, green: 0.1, blue: 1, alpha: 0.35),
])!
glow.draw(in: NSBezierPath(ovalIn: NSRect(x: 560, y: 80, width: 760, height: 480)), angle: 0)

// Screenshot, right side.
let shotWidth: CGFloat = 690
let shotHeight = shotWidth * screenshot.size.height / screenshot.size.width
let shotRect = NSRect(x: size.width - shotWidth - 40, y: (size.height - shotHeight) / 2, width: shotWidth, height: shotHeight)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSBezierPath(roundedRect: shotRect, xRadius: 12, yRadius: 12).fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: shotRect, xRadius: 12, yRadius: 12).addClip()
screenshot.draw(in: shotRect)
NSGraphicsContext.restoreGraphicsState()

// Text, left side.
icon.draw(in: NSRect(x: 50, y: 400, width: 170, height: 170))
func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, width: CGFloat = 470) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let bounds = string.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin])
    string.draw(with: NSRect(x: point.x, y: point.y - bounds.height, width: width, height: bounds.height), options: [.usesLineFragmentOrigin])
}
draw("Anne Pro for Mac", at: NSPoint(x: 70, y: 395), size: 54, weight: .bold, color: .white)
draw("Lighting and layouts for the original Anne Pro keyboard, over Bluetooth. Apple Silicon and Intel.",
     at: NSPoint(x: 70, y: 315), size: 25, weight: .regular, color: NSColor(white: 0.78, alpha: 1))
draw("Free and open source · github.com/thtjst/annepro-macos",
     at: NSPoint(x: 70, y: 105), size: 18, weight: .medium, color: NSColor(white: 0.55, alpha: 1))

NSGraphicsContext.restoreGraphicsState()
try! FileManager.default.createDirectory(at: URL(fileURLWithPath: output).deletingLastPathComponent(), withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
