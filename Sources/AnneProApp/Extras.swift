import AnneProKit
import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Checks GitHub once a day for a newer release. One anonymous request, no data sent.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Update: Equatable {
        let version: String
        let page: URL
    }

    @Published private(set) var available: Update?
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { Task { await check() } } else { available = nil }
        }
    }

    private static let enabledKey = "checksForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private let latestRelease = URL(string: "https://api.github.com/repos/thtjst/annepro-macos/releases/latest")!
    private var loop: Task<Void, Never>?

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.isEnabled {
                    let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
                    if Date().timeIntervalSince(last) > 24 * 3600 || self.available == nil { await self.check() }
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func check() async {
        guard isEnabled, let current = currentVersion else { return }
        struct Release: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
        }
        var request = URLRequest(url: latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease
        else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        available = VersionNumber.isNewer(version, than: current) ? Update(version: version, page: release.html_url) : nil
    }
}

/// Posts a notification when the keyboard's battery runs low, once per threshold.
@MainActor
final class BatteryAlerts {
    private static let thresholds = [5, 15]
    private var lastAlerted: Int?
    private var refresher: Task<Void, Never>?

    /// Battery reports aren't always pushed, so re-read the level every 15 minutes.
    func start(refresh: @escaping @MainActor () -> Void) {
        refresher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                refresh()
            }
        }
    }

    func levelChanged(_ level: Int?, keyboard: String?) {
        guard let level else { return }
        if level > 20 {
            lastAlerted = nil // charged again
            return
        }
        guard let threshold = Self.thresholds.first(where: { level <= $0 }), threshold < (lastAlerted ?? .max) else { return }
        lastAlerted = threshold
        notify(level: level, keyboard: keyboard)
    }

    private func notify(level: Int, keyboard: String?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Anne Pro battery low"
            content.body = "\(level)% left on \(keyboard ?? "your keyboard"). Plug in the micro-USB cable soon."
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "battery-\(level)", content: content, trigger: nil))
        }
    }
}

/// A named custom lighting design kept on this Mac.
struct SavedDesign: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// One `#RRGGBB` per key, in `AnnePro.keys` order.
    var keys: [String]

    init(name: String, profile: LightingProfile) {
        self.name = name
        keys = profile.colors.map(\.hex)
    }

    var profile: LightingProfile? {
        let colors = keys.compactMap(RGB.init(hex:))
        return colors.count == AnnePro.keys.count ? LightingProfile(colors: colors) : nil
    }
}

/// Asks for a design name in a small dialog.
@MainActor
func promptForDesignName(suggested: String) -> String? {
    let alert = NSAlert()
    alert.messageText = "Save Lighting Design"
    alert.informativeText = "Saved designs can be loaded in the editor or applied from the menu bar."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = suggested
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}
