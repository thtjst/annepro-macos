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
    private static let latestVersionKey = "latestKnownVersion"
    private static let latestPageKey = "latestKnownReleasePage"
    private let latestRelease = URL(string: "https://api.github.com/repos/thtjst/annepro-macos/releases/latest")!
    private var loop: Task<Void, Never>?

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        // Show what we learned last time straight away, without asking GitHub again.
        let defaults = UserDefaults.standard
        if isEnabled, let version = defaults.string(forKey: Self.latestVersionKey),
           let page = defaults.url(forKey: Self.latestPageKey) {
            available = update(version: version, page: page)
        }
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
                    if Date().timeIntervalSince(last) > 24 * 3600 { await self.check() }
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func check() async {
        guard isEnabled, currentVersion != nil else { return }
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
              !release.draft, !release.prerelease,
              // Only ever open a GitHub page from this, whatever the response says.
              release.html_url.scheme == "https", release.html_url.host == "github.com"
        else { return }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: Self.lastCheckKey)
        defaults.set(version, forKey: Self.latestVersionKey)
        defaults.set(release.html_url, forKey: Self.latestPageKey)
        available = update(version: version, page: release.html_url)
    }

    private func update(version: String, page: URL) -> Update? {
        guard let current = currentVersion, VersionNumber.isNewer(version, than: current) else { return nil }
        return Update(version: version, page: page)
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

/// Undo and redo for an editor, one snapshot per user action.
struct EditHistory<Value> {
    private var undoStack: [Value] = []
    private var redoStack: [Value] = []
    private let limit = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Call with the current value just before changing it.
    mutating func record(_ current: Value) {
        undoStack.append(current)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    mutating func undo(from current: Value) -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(from current: Value) -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}

/// Averages colours from a picture, centre-cropped to the keyboard's 3:1 shape.
struct ImageSampler {
    private static let width = 150, height = 50
    private var pixels: [UInt8]

    init?(contentsOf url: URL) {
        guard let image = NSImage(contentsOf: url) else { return nil }
        self.init(image: image)
    }

    init?(image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let sourceWidth = Double(cgImage.width), sourceHeight = Double(cgImage.height)
        let aspect = Double(Self.width) / Double(Self.height)
        let crop = sourceWidth / sourceHeight > aspect
            ? CGRect(x: (sourceWidth - sourceHeight * aspect) / 2, y: 0, width: sourceHeight * aspect, height: sourceHeight)
            : CGRect(x: 0, y: (sourceHeight - sourceWidth / aspect) / 2, width: sourceWidth, height: sourceWidth / aspect)
        guard let cropped = cgImage.cropping(to: crop.integral) else { return nil }
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: Self.width, height: Self.height, bitsPerComponent: 8,
                bytesPerRow: Self.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
            return true
        }
        guard drawn else { return nil }
        self.pixels = pixels
    }

    /// Mean colour of a region given as fractions of the picture, origin top-left.
    func averageColor(x: Double, y: Double, width: Double, height: Double) -> RGB {
        let x0 = max(0, Int(x * Double(Self.width))), x1 = min(Self.width, max(x0 + 1, Int((x + width) * Double(Self.width))))
        let y0 = max(0, Int(y * Double(Self.height))), y1 = min(Self.height, max(y0 + 1, Int((y + height) * Double(Self.height))))
        var r = 0, g = 0, b = 0, count = 0
        for row in y0..<y1 {
            for column in x0..<x1 {
                // The bitmap's first row is the top of the picture.
                let index = (row * Self.width + column) * 4
                r += Int(pixels[index]); g += Int(pixels[index + 1]); b += Int(pixels[index + 2])
                count += 1
            }
        }
        guard count > 0 else { return .black }
        return RGB(UInt8(r / count), UInt8(g / count), UInt8(b / count))
    }
}
