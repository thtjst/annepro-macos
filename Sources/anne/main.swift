import AnneProBluetooth
import AnneProKit
import Foundation

let usage = """
anne — control an original Anne Pro keyboard over Bluetooth LE

USAGE: anne <command> [arguments] [-v]

  status                      Connect and show device info and battery
  modes                       List lighting modes
  mode <name|number>          Set the lighting mode, e.g. `anne mode rainbow`
  brightness <1-10>           Set backlight brightness
  layout <windows|arrows|mac|custom>
                              Switch the active layout
  fill <#RRGGBB>              Light every key in one colour (uses custom mode)
  rainbow                     Upload a rainbow as custom lighting
  read-lighting [file.json]   Download custom lighting (print or save)
  write-lighting <file.json>  Upload custom lighting and switch to it
  read-layout [file.json]     Download the custom layout (print or save)
  write-layout <file.json|windows|arrows|mac>
                              Upload a custom layout (or a factory preset) and switch to it
  raw <hex bytes…>            Send bytes as-is and print replies for 3 seconds

  -v, --verbose               Print every packet
  --attempts <n>              Upload attempts before giving up (default 3)
  --delay <ms>                Pause between upload packets (default 20)
  --confirmed                 Wait for Bluetooth write confirmations (slower)

The keyboard must be paired with this Mac and in BLE mode (it shows up as ANNE_KB_L0…).
"""

var arguments = Array(CommandLine.arguments.dropFirst())
let verbose = arguments.contains("-v") || arguments.contains("--verbose")
arguments.removeAll { $0 == "-v" || $0 == "--verbose" }

/// Removes `--name value` from the arguments and returns the value.
@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
let uploadAttempts = option("--attempts").flatMap(Int.init) ?? 3
let packetDelay = option("--delay").flatMap(Int.init)
let confirmed = arguments.contains("--confirmed")
arguments.removeAll { $0 == "--confirmed" }

struct UsageError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func say(_ text: String) {
    print(text)
    fflush(stdout)
}

@MainActor
func connect() async throws -> AnneProDevice {
    let device = AnneProDevice()
    device.verbose = verbose
    if let packetDelay { device.interPacketDelay = .milliseconds(packetDelay) }
    if confirmed { device.preferWriteWithoutResponse = false }
    device.logHandler = { if verbose { say("  · \($0)") } }
    device.unsolicitedHandler = { say("  ← unsolicited: \($0)") }
    say("Looking for the keyboard…")
    do {
        try await device.waitUntilConnected(timeout: .seconds(20))
    } catch {
        if device.state == .unauthorized {
            throw UsageError("""
            Bluetooth access was denied. Allow it for your terminal app in
            System Settings → Privacy & Security → Bluetooth, then try again.
            """)
        }
        throw error
    }
    say(device.state.summary)
    return device
}

func readJSON(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
}

func writeJSON(_ data: Data, to path: String) throws {
    try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    say("Saved \(path)")
}

func describe(_ result: UploadResult) -> String {
    switch result {
    case .verified: "Done — read back from the keyboard and verified."
    case .unverified: "Sent, but the keyboard didn't answer the read-back, so it couldn't be verified."
    }
}

@MainActor
func uploadLighting(_ profile: LightingProfile, on device: AnneProDevice) async throws {
    say("Uploading custom lighting…")
    let result = try await device.writeLighting(profile, attempts: uploadAttempts)
    try await device.setLightingMode(.custom)
    say(describe(result))
}

@MainActor
func run() async throws {
    guard let command = arguments.first else {
        say(usage)
        return
    }
    let rest = Array(arguments.dropFirst())

    switch command {
    case "help", "-h", "--help":
        say(usage)

    case "modes":
        for mode in LightingMode.allCases {
            say(String(format: "%5d  %-16@ %@", mode.rawValue, mode.slug as NSString, mode.detail as NSString))
        }

    case "status":
        let device = try await connect()
        let info = try await device.refreshInfo()
        say("Model:    \(info.modelName)")
        say("Serial:   \(info.serialString)")
        try await Task.sleep(for: .milliseconds(300))
        if let battery = device.batteryLevel { say("Battery:  \(battery)%") }
        if let layout = try? await device.perform(.layoutMode, timeout: .seconds(2)), let value = layout.data.first {
            say("Layout:   \(LayoutMode(rawValue: value)?.name ?? "unknown (\(value))")")
        }
        if let lighting = try? await device.perform(.lightingMode, timeout: .seconds(2)), let value = lighting.data.first {
            say("Lighting: \(LightingMode(rawValue: value)?.name ?? "unknown (\(value))")")
        }

    case "mode":
        guard let name = rest.first, let mode = LightingMode(slug: name) else {
            throw UsageError("Usage: anne mode <name|number>. See `anne modes`.")
        }
        let device = try await connect()
        try await device.setLightingMode(mode)
        say("Lighting: \(mode.name)")

    case "brightness":
        guard let text = rest.first, let level = Int(text), (1...10).contains(level) else {
            throw UsageError("Usage: anne brightness <1-10>")
        }
        let device = try await connect()
        try await device.setBrightness(level)
        say("Brightness: \(level)")

    case "layout":
        guard let name = rest.first, let mode = LayoutMode(slug: name) else {
            throw UsageError("Usage: anne layout <windows|arrows|mac|custom>")
        }
        let device = try await connect()
        if mode == .custom {
            try await device.switchToCustomLayoutSafely()
        } else {
            try await device.setLayoutMode(mode)
        }
        say("Layout: \(mode.name)")

    case "fill":
        guard let hex = rest.first, let color = RGB(hex: hex) else {
            throw UsageError("Usage: anne fill <#RRGGBB>")
        }
        let device = try await connect()
        try await uploadLighting(LightingProfile(repeating: color), on: device)

    case "rainbow":
        let device = try await connect()
        try await uploadLighting(.horizontalRainbow(), on: device)

    case "read-lighting":
        let device = try await connect()
        let profile = try await device.readLighting()
        if let path = rest.first {
            try writeJSON(profile.jsonData(), to: path)
        } else {
            for row in 0..<AnnePro.rows {
                let keys = AnnePro.keys.filter { $0.row == row }
                say(keys.map { "\($0.label.isEmpty ? "Space" : $0.label)=\(profile[$0].hex)" }.joined(separator: " "))
            }
        }

    case "write-lighting":
        guard let path = rest.first else { throw UsageError("Usage: anne write-lighting <file.json>") }
        let profile = try LightingProfile(jsonData: readJSON(path))
        let device = try await connect()
        try await uploadLighting(profile, on: device)

    case "read-layout":
        let device = try await connect()
        let layout = try await device.readLayout()
        if let path = rest.first {
            try writeJSON(layout.jsonData(), to: path)
        } else {
            for layer in KeyLayout.Layer.allCases {
                say("\(layer.rawValue):")
                for row in 0..<AnnePro.rows {
                    let keys = AnnePro.keys.filter { $0.row == row }
                    say("  " + keys.map { KeyCode.named(layout[layer, $0]).legend.padding(toLength: 5, withPad: " ", startingAt: 0) }.joined(separator: " "))
                }
            }
            if !layout.issues.isEmpty { say("Problems: " + layout.issues.map(\.description).joined(separator: " ")) }
        }

    case "write-layout":
        guard let source = rest.first else { throw UsageError("Usage: anne write-layout <file.json|windows|arrows|mac>") }
        let presets: [String: KeyLayout] = ["windows": .windows, "arrows": .windowsArrows, "mac": .mac]
        let layout = try presets[source.lowercased()] ?? KeyLayout(jsonData: readJSON(source))
        if let issue = layout.issues.first { throw UsageError(issue.description) }
        let device = try await connect()
        say("Uploading custom layout…")
        let result = try await device.writeLayout(layout, attempts: uploadAttempts)
        try await device.setLayoutMode(.custom)
        say(describe(result))

    case "raw":
        let bytes = try rest.map { text -> UInt8 in
            let digits = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
            guard let byte = UInt8(digits, radix: 16) else { throw UsageError("Not a hex byte: \(text)") }
            return byte
        }
        guard !bytes.isEmpty, bytes.count <= Framing.packetSize else {
            throw UsageError("Usage: anne raw <1–20 hex bytes>, e.g. `anne raw 09 01 08`")
        }
        let device = try await connect()
        device.unsolicitedHandler = { say("← \($0)") }
        try await device.perform(.raw(bytes))
        say("→ \(bytes.hexString)")
        try await Task.sleep(for: .seconds(3))

    default:
        throw UsageError("Unknown command `\(command)`.\n\n\(usage)")
    }
}

Task { @MainActor in
    do {
        try await run()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
RunLoop.main.run()
