import AnneProBluetooth
import AnneProKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var menuBar = MenuBarVisibility.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            if let update = updates.available {
                Divider()
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    Text("Version \(update.version) is available")
                        .font(.callout)
                    Spacer()
                    Button("Download") { NSWorkspace.shared.open(update.page) }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                lightingSection
                layoutSection
            }
            .padding(14)
            .disabled(!model.isConnected)
            .opacity(model.isConnected ? 1 : 0.45)
            if let notice = model.notice {
                Divider()
                Text(notice.text)
                    .font(.callout)
                    .foregroundStyle(notice.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        .task { await model.refreshStatus() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 22))
                .foregroundStyle(model.isConnected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Anne Pro").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let battery = model.device.batteryLevel {
                Label("\(battery)%", systemImage: batterySymbol(battery))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Battery")
            }
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var statusText: String {
        if let busy = model.busy { return busy }
        switch model.device.state {
        case .connected:
            return "Connected · \(model.device.deviceName ?? "")"
        case .unauthorized:
            return "Allow Bluetooth in System Settings → Privacy & Security → Bluetooth"
        case .searching:
            return model.device.problem ?? "Looking for your keyboard… Press a key to wake it."
        default:
            return model.device.state.summary
        }
    }

    private var lightingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Lighting")
            HStack(spacing: 6) {
                ForEach([LightingMode.off] + LightingMode.solidColors) { mode in
                    SwatchButton(mode: mode, isSelected: model.lightingMode == mode) {
                        model.setLightingMode(mode)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(LightingMode.effects) { mode in
                    ChipButton(title: mode.name, isSelected: model.lightingMode == mode) {
                        model.setLightingMode(mode)
                    }
                    .help(mode.detail)
                }
            }
            HStack(spacing: 6) {
                ChipButton(title: "Custom", systemImage: "paintpalette", isSelected: model.lightingMode == .custom) {
                    model.setLightingMode(.custom)
                }
                .help("Your per-key colours stored on the keyboard")
                Button("Edit Colours…") { open("lighting") }
                    .controlSize(.small)
            }
            if !model.savedDesigns.isEmpty {
                Menu {
                    ForEach(model.savedDesigns) { design in
                        Button(design.name) { model.applyDesign(design) }
                    }
                } label: {
                    Label("Apply a Saved Design", systemImage: "square.stack")
                }
                .controlSize(.small)
                .fixedSize()
                .help("Send one of your saved designs to the keyboard")
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: $model.brightness, in: 1...10, step: 1) { editing in
                    if !editing { model.sendBrightness() }
                }
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
            }
            .help("Brightness")
        }
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Layout")
            HStack(spacing: 6) {
                ForEach(LayoutMode.allCases) { mode in
                    ChipButton(title: mode.name, isSelected: model.layoutMode == mode) {
                        model.setLayoutMode(mode)
                    }
                    .help(mode.detail)
                }
            }
            Button("Edit Custom Layout…") { open("layout") }
                .controlSize(.small)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Toggle("Show in Menu Bar", isOn: Binding(
                    get: { menuBar.isShown },
                    set: { show in
                        menuBar.set(show)
                        // Hiding the icon turns this into a regular app; keep a window open so it's not lost.
                        if !show { open("main") }
                    }
                ))
                .help("Turn off to use Anne Pro like a normal app: open it when you need it, from Applications or Spotlight.")
                if menuBar.isShown {
                    Toggle("Open at Login", isOn: Binding(get: { model.opensAtLogin }, set: { model.opensAtLogin = $0 }))
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            HStack {
                Toggle("Check for Updates", isOn: $updates.isEnabled)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Once a day, ask GitHub whether a newer version exists. Nothing about you is sent.")
                Spacer()
                Button("About") { showAbout() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .keyboardShortcut("q")
            }
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func showAbout() {
        let credits = NSMutableAttributedString(string: """
        Control the original Anne Pro keyboard over Bluetooth.

        Built on the protocol work of msvisser/AnnePro-mac, kprinssu/anne-keyboard-windows and ah-/anne-key. Not affiliated with Obins.
        """)
        credits.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct SwatchButton: View {
    let mode: LightingMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(mode.swatch?.color ?? .gray)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                if mode == .off {
                    Image(systemName: "power").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 21, height: 21)
            .padding(2)
            .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(mode.name)
        .accessibilityLabel(mode.name)
    }
}

private struct ChipButton: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
