#if DEBUG
import AnneProKit
import AppKit
import SwiftUI

/// `AnnePro --render-previews <dir>` writes PNGs of the main views and exits.
/// Debug builds only; used to check layouts without clicking through the app.
@MainActor
enum PreviewRenderer {
    static func renderIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-previews"), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel(startBluetooth: false)
        model.lighting = .horizontalRainbow()
        model.layout = .windowsArrows

        render(MenuBarView().environmentObject(model), size: CGSize(width: 340, height: 480), to: directory, name: "menu")
        render(
            LightingEditorView().environmentObject(model).frame(width: 900, height: 520).background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 900, height: 520), to: directory, name: "lighting"
        )
        render(
            LayoutEditorView().environmentObject(model).frame(width: 900, height: 560).background(Color(nsColor: .windowBackgroundColor)),
            size: CGSize(width: 900, height: 560), to: directory, name: "layout"
        )
        exit(0)
    }

    private static func render(_ view: some View, size: CGSize, to directory: URL, name: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return print("Couldn't render \(name)") }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
        print("Rendered \(name).png")
    }
}

/// `AnnePro --screenshots <dir>` opens the real windows with sample data, saves each one
/// as PNG in light and dark mode, and quits. Debug builds only; used for the README.
@MainActor
enum ScreenshotMaker {
    static var directory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--screenshots"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel.shared
        model.prepareForScreenshots()
        while model.openWindowAction == nil { try? await Task.sleep(for: .milliseconds(100)) }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for id in ["main", "lighting", "layout"] { model.openWindowAction?(id: id) }
            try? await Task.sleep(for: .seconds(2))
            for window in NSApp.windows where window.isVisible {
                let name: String
                switch window.title {
                case "Anne Pro": name = "menu"
                case "Lighting": name = "lighting"
                case "Custom Layout": name = "layout"
                default: continue
                }
                // The menu panel without its title bar; editors with their toolbar.
                guard let view = name == "menu" ? window.contentView : window.contentView?.superview else { continue }
                // The menu panel without the (empty) title bar strip; editors with their toolbar.
                var rect = view.bounds
                if name == "menu" {
                    let layout = window.contentLayoutRect // window coordinates, origin bottom-left
                    rect = NSRect(
                        x: layout.minX, y: view.isFlipped ? view.bounds.height - layout.maxY : layout.minY,
                        width: layout.width, height: layout.height
                    )
                }
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ) else { continue }
                rep.size = rect.size // Retina-resolution capture
                if name == "menu" {
                    // Without its window frame the panel has no background; paint one first.
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill()
                        NSRect(origin: .zero, size: rect.size).fill()
                    }
                    NSGraphicsContext.restoreGraphicsState()
                }
                view.cacheDisplay(in: rect, to: rep)
                let url = directory.appendingPathComponent("\(name)-\(suffix).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("Saved \(url.lastPathComponent)")
            }
        }
        exit(0)
    }
}
#endif
