import AnneProKit
import SwiftUI

struct LightingEditorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var stroking = LocalState(false)
    @StateObject private var hoveredKey = LocalState<PhysicalKey.ID?>(nil)

    private static let palette: [RGB] = [
        RGB(255, 0, 0), RGB(255, 100, 0), RGB(255, 200, 0), RGB(120, 255, 0), RGB(0, 255, 60),
        RGB(0, 255, 200), RGB(0, 160, 255), RGB(0, 40, 255), RGB(130, 0, 255), RGB(255, 0, 200),
        RGB(255, 60, 120), RGB(150, 150, 150), RGB(0, 0, 0),
    ]

    var body: some View {
        VStack(spacing: 18) {
            KeyboardCase {
                GeometryReader { geometry in
                    KeyboardCanvas { key, _ in
                        LitKeycap(
                            label: key.label,
                            color: model.lighting[key].asStoredByKeyboard,
                            isHighlighted: hoveredKey.value == key.id
                        )
                    }
                    .contentShape(Rectangle())
                    .gesture(paintGesture(in: geometry.size))
                    .onContinuousHover { phase in
                        if case let .active(point) = phase {
                            hoveredKey.value = KeyboardCanvas<EmptyView>.key(at: point, in: geometry.size)?.id
                        } else {
                            hoveredKey.value = nil
                        }
                    }
                }
                .aspectRatio(AnnePro.width / Double(AnnePro.rows), contentMode: .fit)
            }

            brushRow
            fillRow

            Text("Click or drag across keys to paint. Hold ⌥ and click to pick up a key's colour. The keyboard dims very bright colours (like white) to protect its LEDs; the preview shows what it will display.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            StatusBar()
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 470)
        .toolbar {
            ToolbarItemGroup {
                Button { model.undoLighting() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndoLighting)
                Button { model.importLighting() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button { model.exportLighting() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Button { model.readLighting() } label: { Label("Read from Keyboard", systemImage: "arrow.down.circle") }
                    .disabled(!model.isConnected || model.isBusy)
                    .help("Load the custom lighting stored on the keyboard")
                Button { model.sendLighting() } label: { Label("Send to Keyboard", systemImage: "paperplane.fill") }
                    .disabled(!model.isConnected || model.isBusy)
                    .keyboardShortcut(.return)
                    .help("Save these colours on the keyboard and switch to Custom lighting")
            }
        }
        .navigationTitle("Lighting")
    }

    private var brushRow: some View {
        HStack(spacing: 10) {
            Text("Brush").font(.headline).frame(width: 64, alignment: .leading)
            ColorPicker("Brush colour", selection: Binding(
                get: { model.brush.color },
                set: { if let rgb = RGB($0) { model.brush = rgb } }
            ), supportsOpacity: false)
            .labelsHidden()
            ForEach(Self.palette, id: \.self) { color in
                Button { model.brush = color } label: {
                    Circle()
                        .fill(color.color)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                        .overlay(Circle().strokeBorder(model.brush == color ? Color.accentColor : .clear, lineWidth: 2).padding(-3))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(color == .black ? "Off" : color.hex)
            }
            Spacer()
            if model.brush.exceedsPowerBudget {
                Label("Shown dimmed", systemImage: "sun.max.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("R+G+B above 450 is shown at 60% by the keyboard")
            }
        }
    }

    private var fillRow: some View {
        HStack(spacing: 8) {
            Text("Fill").font(.headline).frame(width: 64, alignment: .leading)
            Button("All Keys") { model.fill(AnnePro.keys, with: model.brush) }
            Button("Letters") { model.fill(AnnePro.keys(in: .letter), with: model.brush) }
            Button("Numbers") { model.fill(AnnePro.keys(in: .number), with: model.brush) }
            Button("Modifiers") { model.fill(AnnePro.keys(in: .modifier), with: model.brush) }
            Divider().frame(height: 18)
            Menu("Presets") {
                Button("Rainbow, left to right") { model.applyPreset(.horizontalRainbow()) }
                Button("Rainbow, top to bottom") { model.applyPreset(.verticalRainbow()) }
                Button("Sunset") { model.applyPreset(.gradient(from: RGB(255, 40, 0), to: RGB(120, 0, 255))) }
                Button("Ocean") { model.applyPreset(.gradient(from: RGB(0, 255, 160), to: RGB(0, 40, 255))) }
                Button("Brush colour with white modifiers") { model.applyPreset(.accent(base: model.brush, accent: RGB(150, 150, 150))) }
                Divider()
                Button("All off") { model.applyPreset(LightingProfile(repeating: .black)) }
            }
            .fixedSize()
            Spacer()
        }
    }

    private func paintGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let key = KeyboardCanvas<EmptyView>.key(at: value.location, in: size) else { return }
                if NSEvent.modifierFlags.contains(.option) {
                    model.brush = model.lighting[key]
                    return
                }
                if !stroking.value {
                    stroking.value = true
                    model.checkpointLighting()
                }
                model.paint(key)
            }
            .onEnded { _ in stroking.value = false }
    }
}

/// Busy spinner or the latest message, shown at the bottom of editor windows.
struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy)
            } else if let notice = model.notice {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.isError ? Color.orange : Color.green)
                Text(notice.text)
            } else {
                Image(systemName: model.isConnected ? "circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(model.isConnected ? Color.green : Color.secondary)
                Text(model.device.state.summary)
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: 20)
    }
}
