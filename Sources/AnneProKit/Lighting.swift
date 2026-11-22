import Foundation

public struct RGB: Hashable, Sendable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = RGB(0, 0, 0)
    public static let white = RGB(255, 255, 255)

    /// Parses `#RRGGBB` or `RRGGBB`.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
    }

    public var hex: String { "#" + [r, g, b].hexString.replacingOccurrences(of: " ", with: "") }

    /// Builds a colour from hue, saturation and brightness in 0...1.
    public init(hue: Double, saturation: Double = 1, brightness: Double = 1) {
        let h = (hue - hue.rounded(.down)) * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        func byte(_ v: Double) -> UInt8 { UInt8((min(max(v + m, 0), 1) * 255).rounded()) }
        self.init(byte(r), byte(g), byte(b))
    }

    /// The keyboard's LED power budget: a key whose channels add up to more than this is
    /// stored and shown at 60% (rounded down). Measured on real hardware.
    public static let powerBudget = 450

    /// This colour as the keyboard actually stores and displays it.
    public var asStoredByKeyboard: RGB {
        guard Int(r) + Int(g) + Int(b) > Self.powerBudget else { return self }
        func dim(_ c: UInt8) -> UInt8 { UInt8(Int(c) * 3 / 5) }
        return RGB(dim(r), dim(g), dim(b))
    }

    public var exceedsPowerBudget: Bool { asStoredByKeyboard != self }

    /// This colour scaled down just enough to stay within the power budget, keeping its hue.
    /// Looks smoother than letting the keyboard cut it to 60%.
    public var fittingPowerBudget: RGB {
        let sum = Int(r) + Int(g) + Int(b)
        guard sum > Self.powerBudget else { return self }
        let scale = Double(Self.powerBudget) / Double(sum)
        func fit(_ c: UInt8) -> UInt8 { UInt8((Double(c) * scale).rounded(.down)) }
        return RGB(fit(r), fit(g), fit(b))
    }

    public func mixed(with other: RGB, amount t: Double) -> RGB {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        return RGB(mix(r, other.r), mix(g, other.g), mix(b, other.b))
    }
}

/// Per-key colours for the "Custom" lighting mode.
public struct LightingProfile: Hashable, Sendable {
    /// 4-byte header (two zero bytes, CRC high, CRC low) + 70 slots × RGB.
    public static let payloadSize = 4 + AnnePro.slotCount * 3

    /// One colour per physical key, in `AnnePro.keys` order.
    public private(set) var colors: [RGB]

    public init(colors: [RGB]) {
        precondition(colors.count == AnnePro.keys.count, "expected \(AnnePro.keys.count) colours")
        self.colors = colors
    }

    public init(repeating color: RGB) {
        self.init(colors: Array(repeating: color, count: AnnePro.keys.count))
    }

    public subscript(key: PhysicalKey) -> RGB {
        get { colors[key.id] }
        set { colors[key.id] = newValue }
    }

    public subscript(keyID: Int) -> RGB {
        get { colors[keyID] }
        set { colors[keyID] = newValue }
    }

    /// These colours as the keyboard will store them (very bright keys are dimmed).
    public var asStoredByKeyboard: LightingProfile {
        LightingProfile(colors: colors.map(\.asStoredByKeyboard))
    }

    /// Bytes sent to the keyboard.
    public var payload: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.payloadSize)
        for key in AnnePro.keys {
            let offset = 4 + key.slot * 3
            let color = colors[key.id]
            bytes[offset] = color.r
            bytes[offset + 1] = color.g
            bytes[offset + 2] = color.b
        }
        let crc = CRC16.modbus(bytes[4...])
        bytes[2] = UInt8(crc >> 8)
        bytes[3] = UInt8(crc & 0xFF)
        return bytes
    }

    /// Reads what the keyboard sends back: either the full payload or just the 210 colour bytes.
    public init(payload: [UInt8]) throws {
        let body: ArraySlice<UInt8>
        switch payload.count {
        case Self.payloadSize: body = payload[4...]
        case Self.payloadSize - 4: body = payload[...]
        default: throw AnneProDataError.wrongLength(expected: Self.payloadSize, got: payload.count)
        }
        let start = body.startIndex
        self.init(colors: AnnePro.keys.map { key in
            let offset = start + key.slot * 3
            return RGB(body[offset], body[offset + 1], body[offset + 2])
        })
    }
}

public enum AnneProDataError: LocalizedError, Equatable {
    case wrongLength(expected: Int, got: Int)
    case unrecognizedFile(String)

    public var errorDescription: String? {
        switch self {
        case let .wrongLength(expected, got): "Expected \(expected) bytes from the keyboard, got \(got)."
        case let .unrecognizedFile(reason): "This file isn't an Anne Pro profile: \(reason)"
        }
    }
}

// MARK: - Files

extension LightingProfile {
    private struct File: Codable {
        var format = "annepro-lighting"
        var version = 1
        /// One `#RRGGBB` per key, left to right, top to bottom.
        var keys: [String]
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(keys: colors.map(\.hex)))
    }

    /// Reads this app's format, or the 214-number arrays exported by msvisser's AnnePro-mac.
    public init(jsonData data: Data) throws {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(File.self, from: data) {
            guard file.format == "annepro-lighting" else { throw AnneProDataError.unrecognizedFile("format is \(file.format)") }
            let colors = file.keys.compactMap(RGB.init(hex:))
            guard colors.count == AnnePro.keys.count else {
                throw AnneProDataError.unrecognizedFile("expected \(AnnePro.keys.count) colours, found \(colors.count)")
            }
            self.init(colors: colors)
        } else if let bytes = try? decoder.decode([UInt8].self, from: data) {
            try self.init(payload: bytes)
        } else {
            throw AnneProDataError.unrecognizedFile("not a lighting profile")
        }
    }
}

// MARK: - Presets

extension LightingProfile {
    /// Hue sweeps left to right.
    public static func horizontalRainbow() -> LightingProfile {
        LightingProfile(colors: AnnePro.keys.map { key in
            RGB(hue: (key.x + key.width / 2) / AnnePro.width * 0.85).fittingPowerBudget
        })
    }

    /// One hue per row.
    public static func verticalRainbow() -> LightingProfile {
        LightingProfile(colors: AnnePro.keys.map { key in
            RGB(hue: Double(key.row) / Double(AnnePro.rows)).fittingPowerBudget
        })
    }

    /// Diagonal blend between two colours.
    public static func gradient(from start: RGB, to end: RGB) -> LightingProfile {
        let span = AnnePro.width + Double(AnnePro.rows)
        return LightingProfile(colors: AnnePro.keys.map { key in
            start.mixed(with: end, amount: (key.x + key.width / 2 + Double(key.row)) / span).fittingPowerBudget
        })
    }

    /// Letters in one colour, numbers and modifiers in another.
    public static func accent(base: RGB, accent: RGB) -> LightingProfile {
        LightingProfile(colors: AnnePro.keys.map { $0.group == .letter ? base : accent })
    }
}
