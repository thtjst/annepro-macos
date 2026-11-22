import AnneProBluetooth
import AnneProKit
import AppKit
import Combine
import os
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

/// App state shared by the menu bar panel and the editor windows.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel(startBluetooth: !CommandLine.arguments.contains("--render-previews") && !CommandLine.arguments.contains("--screenshots"))

    /// SwiftUI's `openWindow`, captured from a live view so AppKit code can open scenes.
    var openWindowAction: OpenWindowAction?

    func showMainWindow() {
        openWindowAction?(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    struct Notice: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    let device = AnneProDevice()

    /// The custom lighting being edited. Saved locally on every change.
    @Published var lighting: LightingProfile {
        didSet { save(lighting.jsonData, key: Keys.lighting) }
    }

    /// The custom layout being edited. Saved locally on every change.
    @Published var layout: KeyLayout {
        didSet { save(layout.jsonData, key: Keys.layout) }
    }

    @Published var brush: RGB {
        didSet { save({ try JSONEncoder().encode(self.brush) }, key: Keys.brush) }
    }

    /// The keyboard can't report brightness, so this is the last value we set.
    @Published var brightness: Double {
        didSet { UserDefaults.standard.set(brightness, forKey: Keys.brightness) }
    }

    @Published private(set) var savedDesigns: [SavedDesign] {
        didSet { save({ try JSONEncoder().encode(self.savedDesigns) }, key: Keys.savedDesigns) }
    }

    @Published private(set) var lightingMode: LightingMode?
    @Published private(set) var layoutMode: LayoutMode?
    @Published private(set) var busy: String?
    @Published private(set) var notice: Notice?
    @Published private(set) var canUndoLighting = false
    @Published private(set) var canUndoLayout = false

    private var lightingHistory: [LightingProfile] = []
    private var layoutHistory: [KeyLayout] = []
    private var cancellables: Set<AnyCancellable> = []
    private var lastStatusRefresh = Date.distantPast
    private let batteryAlerts = BatteryAlerts()
    private let logger = Logger(subsystem: "io.github.thtjst.AnnePro", category: "keyboard")

    private enum Keys {
        static let lighting = "lighting"
        static let layout = "layout"
        static let brush = "brush"
        static let brightness = "brightness"
        static let savedDesigns = "savedDesigns"
    }


    init(startBluetooth: Bool = true) {
        let defaults = UserDefaults.standard
        lighting = defaults.data(forKey: Keys.lighting).flatMap { try? LightingProfile(jsonData: $0) } ?? .horizontalRainbow()
        layout = defaults.data(forKey: Keys.layout).flatMap { try? KeyLayout(jsonData: $0) } ?? .mac
        brush = defaults.data(forKey: Keys.brush).flatMap { try? JSONDecoder().decode(RGB.self, from: $0) } ?? RGB(0, 160, 255)
        brightness = defaults.object(forKey: Keys.brightness) as? Double ?? 10
        savedDesigns = defaults.data(forKey: Keys.savedDesigns).flatMap { try? JSONDecoder().decode([SavedDesign].self, from: $0) } ?? []

        let logger = self.logger
        device.logHandler = { logger.debug("\($0, privacy: .public)") }
        device.unsolicitedHandler = { logger.info("Unsolicited: \($0.description, privacy: .public)") }

        // Re-publish device changes so views that only observe the model stay current.
        device.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        device.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard state.isConnected else {
                    self?.lightingMode = nil
                    self?.layoutMode = nil
                    return
                }
                Task { await self?.refreshStatus(force: true) }
            }
            .store(in: &cancellables)

        device.$batteryLevel
            .removeDuplicates()
            .sink { [weak self] level in
                guard let self else { return }
                self.batteryAlerts.levelChanged(level, keyboard: self.device.deviceName)
            }
            .store(in: &cancellables)

        if startBluetooth {
            device.start()
            let device = self.device
            batteryAlerts.start { device.refreshBattery() }
            UpdateChecker.shared.start()
        }
    }

    var isConnected: Bool { device.state.isConnected }
    var isBusy: Bool { busy != nil }

    // MARK: Status

    /// Asks the keyboard which lighting and layout are active (they can also be changed on the keyboard itself).
    func refreshStatus(force: Bool = false) async {
        guard isConnected, busy == nil else { return }
        guard force || Date().timeIntervalSince(lastStatusRefresh) > 3 else { return }
        lastStatusRefresh = Date()
        if let reply = try? await device.perform(.lightingMode, timeout: .seconds(2)), let value = reply.data.first {
            lightingMode = LightingMode(rawValue: value)
        }
        if let reply = try? await device.perform(.layoutMode, timeout: .seconds(2)), let value = reply.data.first {
            layoutMode = LayoutMode(rawValue: value)
        }
    }

    // MARK: Quick settings

    func setLightingMode(_ mode: LightingMode) {
        let previous = lightingMode
        lightingMode = mode
        perform(nil) {
            do {
                try await self.device.setLightingMode(mode)
            } catch {
                self.lightingMode = previous
                throw error
            }
        }
    }

    func sendBrightness() {
        let level = Int(brightness.rounded())
        perform(nil) { try await self.device.setBrightness(level) }
    }

    func setLayoutMode(_ mode: LayoutMode) {
        let previous = layoutMode
        layoutMode = mode
        perform(mode == .custom ? "Checking the custom layout…" : nil) {
            do {
                if mode == .custom {
                    try await self.device.switchToCustomLayoutSafely()
                } else {
                    try await self.device.setLayoutMode(mode)
                }
            } catch {
                self.layoutMode = previous
                throw error
            }
        }
    }

    // MARK: Lighting editor

    /// Call before a change to make it undoable (once per stroke, not per key).
    func checkpointLighting() {
        lightingHistory.append(lighting)
        if lightingHistory.count > 50 { lightingHistory.removeFirst() }
        canUndoLighting = true
    }

    func undoLighting() {
        guard let previous = lightingHistory.popLast() else { return }
        lighting = previous
        canUndoLighting = !lightingHistory.isEmpty
    }

    func paint(_ key: PhysicalKey) {
        guard lighting[key] != brush else { return }
        lighting[key] = brush
    }

    func fill(_ keys: [PhysicalKey], with color: RGB) {
        checkpointLighting()
        for key in keys { lighting[key] = color }
    }

    func applyPreset(_ profile: LightingProfile) {
        checkpointLighting()
        lighting = profile
    }

    func sendLighting() {
        let profile = lighting
        perform("Sending lighting…") {
            let result = try await self.device.writeLighting(profile)
            try await self.device.setLightingMode(.custom)
            self.lightingMode = .custom
            switch result {
            case .verified: self.say("Lighting saved on the keyboard.")
            case .unverified: self.say("Lighting sent. The keyboard didn't confirm it, so check it looks right.")
            }
        }
    }

    func readLighting() {
        perform("Reading lighting…") {
            let profile = try await self.device.readLighting()
            self.checkpointLighting()
            self.lighting = profile
            self.say("Loaded the lighting stored on the keyboard.")
        }
    }

    func importLighting() {
        guard let url = Self.openPanel(title: "Import Lighting") else { return }
        do {
            let profile = try LightingProfile(jsonData: Data(contentsOf: url))
            checkpointLighting()
            lighting = profile
            say("Imported \(url.lastPathComponent).")
        } catch {
            say(error.localizedDescription, isError: true)
        }
    }

    func exportLighting() {
        guard let url = Self.savePanel(title: "Export Lighting", name: "Anne Pro lighting.json") else { return }
        do {
            try lighting.jsonData().write(to: url)
            say("Exported \(url.lastPathComponent).")
        } catch {
            say(error.localizedDescription, isError: true)
        }
    }

    // MARK: Saved designs

    func saveCurrentDesign(named name: String) {
        let design = SavedDesign(name: name, profile: lighting)
        if let index = savedDesigns.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            savedDesigns[index] = SavedDesign(name: savedDesigns[index].name, profile: lighting)
        } else {
            savedDesigns.append(design)
            savedDesigns.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        say("Saved “\(name)”.")
    }

    func loadDesign(_ design: SavedDesign) {
        guard let profile = design.profile else { return }
        applyPreset(profile)
    }

    /// Loads a design and sends it to the keyboard in one go (used from the menu bar).
    func applyDesign(_ design: SavedDesign) {
        guard let profile = design.profile else { return }
        checkpointLighting()
        lighting = profile
        sendLighting()
    }

    func deleteDesign(_ design: SavedDesign) {
        savedDesigns.removeAll { $0.id == design.id }
    }

    // MARK: Layout editor

    func assign(_ code: UInt8, to key: PhysicalKey, on layer: KeyLayout.Layer) {
        layoutHistory.append(layout)
        canUndoLayout = true
        layout.assign(code, to: key, on: layer)
    }

    func applyLayoutPreset(_ preset: KeyLayout) {
        layoutHistory.append(layout)
        canUndoLayout = true
        layout = preset
    }

    func undoLayout() {
        guard let previous = layoutHistory.popLast() else { return }
        layout = previous
        canUndoLayout = !layoutHistory.isEmpty
    }

    func sendLayout() {
        let layout = self.layout
        if let issue = layout.issues.first {
            say(issue.description, isError: true)
            return
        }
        perform("Sending layout…") {
            let result = try await self.device.writeLayout(layout)
            try await self.device.setLayoutMode(.custom)
            self.layoutMode = .custom
            switch result {
            case .verified: self.say("Layout saved on the keyboard and switched to Custom.")
            case .unverified: self.say("Layout sent and switched to Custom. The keyboard didn't confirm it.")
            }
        }
    }

    func readLayout() {
        perform("Reading layout…") {
            let stored = try await self.device.readLayout()
            self.layoutHistory.append(self.layout)
            self.canUndoLayout = true
            self.layout = stored
            if stored.issues.isEmpty {
                self.say("Loaded the layout stored on the keyboard.")
            } else {
                self.say("Loaded the keyboard's custom layout, but it isn't usable yet: \(stored.issues[0].description)", isError: true)
            }
        }
    }

    func importLayout() {
        guard let url = Self.openPanel(title: "Import Layout") else { return }
        do {
            let imported = try KeyLayout(jsonData: Data(contentsOf: url))
            applyLayoutPreset(imported)
            say("Imported \(url.lastPathComponent).")
        } catch {
            say(error.localizedDescription, isError: true)
        }
    }

    func exportLayout() {
        guard let url = Self.savePanel(title: "Export Layout", name: "Anne Pro layout.json") else { return }
        do {
            try layout.jsonData().write(to: url)
            say("Exported \(url.lastPathComponent).")
        } catch {
            say(error.localizedDescription, isError: true)
        }
    }

    // MARK: Login item

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                say("Couldn't change the login item: \(error.localizedDescription)", isError: true)
            }
            objectWillChange.send()
        }
    }

    #if DEBUG
    /// Sample state for screenshots.
    func prepareForScreenshots() {
        lighting = .horizontalRainbow()
        layout = .windowsArrows
        brush = RGB(0, 160, 255)
        brightness = 8
        lightingMode = .custom
        layoutMode = .windowsArrows
        device.simulateConnection(name: "ANNE_KB_L0_XXXX", battery: 87)
        savedDesigns = [
            SavedDesign(name: "Ocean", profile: .gradient(from: RGB(0, 255, 160), to: RGB(0, 40, 255))),
            SavedDesign(name: "Rainbow", profile: .horizontalRainbow()),
            SavedDesign(name: "Sunset", profile: .gradient(from: RGB(255, 40, 0), to: RGB(120, 0, 255))),
        ]
    }
    #endif

    // MARK: Helpers

    func say(_ text: String, isError: Bool = false) {
        let notice = Notice(text: text, isError: isError)
        self.notice = notice
        Task {
            try? await Task.sleep(for: .seconds(isError ? 10 : 5))
            if self.notice == notice { self.notice = nil }
        }
    }

    private func perform(_ label: String?, _ work: @escaping @MainActor () async throws -> Void) {
        if label != nil {
            guard busy == nil else { return }
            busy = label
        }
        Task {
            defer { if label != nil { self.busy = nil } }
            do {
                try await work()
            } catch {
                self.say(error.localizedDescription, isError: true)
            }
        }
    }

    private func save(_ encode: () throws -> Data, key: String) {
        if let data = try? encode() { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func openPanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func savePanel(title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
