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
#endif
