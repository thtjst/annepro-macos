import AppKit
import SwiftUI

@main
struct AnneProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Not observed here: the scene list must only rebuild when menu bar visibility changes.
    private let model = AppModel.shared
    @ObservedObject private var menuBar = MenuBarVisibility.shared

    init() {
        #if DEBUG
        PreviewRenderer.renderIfRequested()
        #endif
    }

    var body: some Scene {
        // Declared first so SwiftUI opens it on launch and when the app is opened again;
        // AppDelegate closes it at launch in menu bar mode.
        Window("Anne Pro", id: "main") {
            MenuBarView()
                .environmentObject(model)
                .background(WindowOpenerCapture(model: model))
        }
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: Binding(get: { menuBar.isShown }, set: { menuBar.set($0) })) {
            MenuBarView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Lighting", id: "lighting") {
            LightingEditorView()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 520)
        .windowResizability(.contentMinSize)

        Window("Custom Layout", id: "layout") {
            LayoutEditorView()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
    }
}

/// Two ways to run:
/// - Menu bar mode (default): no Dock icon, keeps running, controls live behind the menu bar icon.
/// - App mode (icon hidden): a normal app with a Dock icon that quits when its windows close.
/// Opening the app again always shows the main window, and so does the very first launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let launchedBeforeKey = "launchedBefore"

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(MenuBarVisibility.shared.isShown ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let directory = ScreenshotMaker.directory {
            Task { @MainActor in await ScreenshotMaker.run(into: directory) }
            return
        }
        #endif
        let firstLaunch = !UserDefaults.standard.bool(forKey: Self.launchedBeforeKey)
        UserDefaults.standard.set(true, forKey: Self.launchedBeforeKey)
        if firstLaunch || !MenuBarVisibility.shared.isShown {
            Task { @MainActor in await Self.showMainWindowWhenReady() }
        } else {
            // Started in the menu bar (e.g. at login): SwiftUI opens the first window
            // scene on launch, so put it away again.
            Self.closeMainWindow()
            DispatchQueue.main.async { Self.closeMainWindow() }
        }
    }

    @MainActor
    private static func closeMainWindow() {
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true || window.title == "Anne Pro" {
            window.close()
        }
    }

    /// The open-window action is captured once SwiftUI has built the menu bar item or a window.
    @MainActor
    static func showMainWindowWhenReady() async {
        for _ in 0..<50 {
            if AppModel.shared.openWindowAction != nil {
                AppModel.shared.showMainWindow()
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MenuBarVisibility.shared.isShown
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in await Self.showMainWindowWhenReady() }
        return false
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.isConnected ? "keyboard.fill" : "keyboard")
            .accessibilityLabel("Anne Pro")
            .background(WindowOpenerCapture(model: model))
    }
}

/// Hands SwiftUI's `openWindow` to the model so the app delegate can open windows.
private struct WindowOpenerCapture: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear { model.openWindowAction = openWindow }
    }
}

/// Whether the app runs from the menu bar (no Dock icon, keeps running) or as a regular app
/// (Dock icon, quits when its windows close). Kept apart from `AppModel` so that keyboard
/// updates don't rebuild the app's scenes, and it only publishes real changes.
@MainActor
final class MenuBarVisibility: ObservableObject {
    static let shared = MenuBarVisibility()
    private static let key = "showsMenuBarIcon"

    @Published private(set) var isShown: Bool

    private init() {
        isShown = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
    }

    func set(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        UserDefaults.standard.set(shown, forKey: Self.key)
        NSApp.setActivationPolicy(shown ? .accessory : .regular)
        if !shown, AppModel.shared.opensAtLogin { AppModel.shared.opensAtLogin = false }
    }
}
