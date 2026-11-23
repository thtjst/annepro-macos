import Foundation

/// A custom key layout: what each key sends normally, and while Fn is held.
public struct KeyLayout: Hashable, Sendable {
    public enum Layer: String, CaseIterable, Sendable, Identifiable {
        case base = "Base layer"
        case fn = "Fn layer"
        public var id: Self { self }
    }

    /// 4-byte header (two zero bytes, CRC high, CRC low) + 70 base slots + 70 Fn slots.
    public static let payloadSize = 4 + AnnePro.slotCount * 2

    /// Fn-layer keys the firmware keeps for itself (Fn + R/T/Y/U and Fn + B, which switches
    /// Bluetooth modes). msvisser's app locks these; so do we.
    public static let reservedFnKeyIDs: Set<Int> = [18, 19, 20, 21, 46]

    /// Key codes by matrix slot (70 each). Unused slots are kept as read so a round trip is exact.
    public private(set) var base: [UInt8]
    public private(set) var fn: [UInt8]

    public init(base: [UInt8], fn: [UInt8]) {
        precondition(base.count == AnnePro.slotCount && fn.count == AnnePro.slotCount)
        self.base = base
        self.fn = fn
    }

    public subscript(layer: Layer, key: PhysicalKey) -> UInt8 {
        get { layer == .base ? base[key.slot] : fn[key.slot] }
        set {
            switch layer {
            case .base: base[key.slot] = newValue
            case .fn: fn[key.slot] = newValue
            }
        }
    }

    public func isLocked(_ key: PhysicalKey, on layer: Layer) -> Bool {
        guard layer == .fn else { return false }
        if Self.reservedFnKeyIDs.contains(key.id) { return true }
        // Fn and Anne must sit on the same key in both layers, so the base layer decides.
        let code = base[key.slot]
        return code == KeyCode.fn || code == KeyCode.anne
    }

    /// Bytes sent to the keyboard.
    public var payload: [UInt8] {
        var bytes: [UInt8] = [0, 0, 0, 0] + base + fn
        let crc = CRC16.modbus(bytes[4...])
        bytes[2] = UInt8(crc >> 8)
        bytes[3] = UInt8(crc & 0xFF)
        return bytes
    }

    /// Reads what the keyboard sends back: either the full payload or just the 140 key bytes.
    public init(payload: [UInt8]) throws {
        let body: ArraySlice<UInt8>
        switch payload.count {
        case Self.payloadSize: body = payload[4...]
        case Self.payloadSize - 4: body = payload[...]
        default: throw AnneProDataError.wrongLength(expected: Self.payloadSize, got: payload.count)
        }
        let start = body.startIndex
        self.init(
            base: Array(body[start..<start + AnnePro.slotCount]),
            fn: Array(body[(start + AnnePro.slotCount)...])
        )
    }

    /// True when every real key matches (unused matrix slots are ignored).
    public func hasSameKeys(as other: KeyLayout) -> Bool {
        AnnePro.usedSlots.allSatisfy { base[$0] == other.base[$0] && fn[$0] == other.fn[$0] }
    }

    // MARK: Validation

    public enum Issue: Equatable, Sendable, CustomStringConvertible {
        case missing(code: UInt8, layer: Layer)
        case duplicate(code: UInt8, layer: Layer)
        case misaligned(code: UInt8)

        public var description: String {
            switch self {
            case let .missing(code, layer): "The \(layer.rawValue.lowercased()) has no \(KeyCode.named(code).name) key."
            case let .duplicate(code, layer): "The \(layer.rawValue.lowercased()) has more than one \(KeyCode.named(code).name) key."
            case let .misaligned(code): "\(KeyCode.named(code).name) must be on the same key in both layers."
            }
        }
    }

    /// The firmware needs exactly one Fn and one Anne key, on the same key in both layers.
    /// Without them you can't reach the keyboard's own settings, so uploads are refused.
    public var issues: [Issue] {
        var issues: [Issue] = []
        for code in [KeyCode.fn, KeyCode.anne] {
            let positions = (base: slots(of: code, in: base), fn: slots(of: code, in: fn))
            for (layer, found) in [(Layer.base, positions.base), (Layer.fn, positions.fn)] {
                if found.isEmpty { issues.append(.missing(code: code, layer: layer)) }
                if found.count > 1 { issues.append(.duplicate(code: code, layer: layer)) }
            }
            if positions.base.count == 1, positions.fn.count == 1, positions.base != positions.fn {
                issues.append(.misaligned(code: code))
            }
        }
        return issues
    }

    private func slots(of code: UInt8, in layer: [UInt8]) -> [Int] {
        AnnePro.usedSlots.filter { layer[$0] == code }
    }

    /// Assigns `code` to `key`, keeping Fn and Anne unique and mirrored into the Fn layer.
    public mutating func assign(_ code: UInt8, to key: PhysicalKey, on layer: Layer) {
        guard !isLocked(key, on: layer) else { return }
        let special = code == KeyCode.fn || code == KeyCode.anne
        if special && layer == .fn { return }

        let previous = base[key.slot]
        self[layer, key] = code

        if layer == .base {
            if special {
                // Only one of each: clear it from wherever it was.
                for slot in AnnePro.usedSlots where slot != key.slot {
                    if base[slot] == code { base[slot] = KeyCode.none }
                    if fn[slot] == code { fn[slot] = KeyCode.none }
                }
                fn[key.slot] = code
            } else if previous == KeyCode.fn || previous == KeyCode.anne {
                // The key stopped being Fn/Anne; free its Fn-layer slot too.
                fn[key.slot] = KeyCode.none
            }
        }
    }

    // MARK: Quick changes

    /// Common one-click remaps, applied to the base layer.
    public enum QuickChange: String, CaseIterable, Identifiable, Sendable {
        case capsLockToEscape = "Caps Lock → Escape"
        case capsLockToControl = "Caps Lock → Control"
        case swapLeftAltAndWin = "Swap left Alt and Win"
        case swapRightAltAndCtrl = "Swap right Alt and Ctrl"

        public var id: Self { self }

        public var detail: String {
            switch self {
            case .capsLockToEscape: "Popular with Vim users. Escape stays on its own key too."
            case .capsLockToControl: "An easier-to-reach Control key."
            case .swapLeftAltAndWin: "Puts Command next to the space bar, like a Mac keyboard."
            case .swapRightAltAndCtrl: "Swaps the two right-hand modifier keys."
            }
        }
    }

    private static func physicalKey(row: Int, label: String, last: Bool = false) -> PhysicalKey {
        let matches = AnnePro.keys.filter { $0.row == row && $0.label == label }
        return last ? matches.last! : matches.first!
    }

    public mutating func apply(_ change: QuickChange) {
        switch change {
        case .capsLockToEscape:
            assign(41, to: Self.physicalKey(row: 2, label: "Caps"), on: .base)
        case .capsLockToControl:
            assign(224, to: Self.physicalKey(row: 2, label: "Caps"), on: .base)
        case .swapLeftAltAndWin:
            swap(Self.physicalKey(row: 4, label: "Alt"), Self.physicalKey(row: 4, label: "Win"))
        case .swapRightAltAndCtrl:
            swap(Self.physicalKey(row: 4, label: "Alt", last: true), Self.physicalKey(row: 4, label: "Ctrl", last: true))
        }
    }

    /// Swaps what two keys send on the base layer, moving Fn/Anne correctly if either is one.
    private mutating func swap(_ a: PhysicalKey, _ b: PhysicalKey) {
        let codeA = base[a.slot], codeB = base[b.slot]
        let special: Set<UInt8> = [KeyCode.fn, KeyCode.anne]
        if special.contains(codeA) || special.contains(codeB) {
            // Assigning a special code clears it elsewhere, so place the special one last.
            if special.contains(codeA) {
                assign(codeB, to: a, on: .base)
                assign(codeA, to: b, on: .base)
            } else {
                assign(codeA, to: b, on: .base)
                assign(codeB, to: a, on: .base)
            }
        } else {
            base[a.slot] = codeB
            base[b.slot] = codeA
        }
    }

    // MARK: Files

    private struct File: Codable {
        var format = "annepro-layout"
        var version = 1
        /// 70 key codes per layer, by matrix slot.
        var base: [UInt8]
        var fn: [UInt8]
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(base: base, fn: fn))
    }

    public init(jsonData data: Data) throws {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(File.self, from: data) {
            guard file.format == "annepro-layout" else { throw AnneProDataError.unrecognizedFile("format is \(file.format)") }
            guard file.base.count == AnnePro.slotCount, file.fn.count == AnnePro.slotCount else {
                throw AnneProDataError.unrecognizedFile("each layer needs \(AnnePro.slotCount) entries")
            }
            self.init(base: file.base, fn: file.fn)
        } else if let bytes = try? decoder.decode([UInt8].self, from: data) {
            try self.init(payload: bytes)
        } else {
            throw AnneProDataError.unrecognizedFile("not a layout")
        }
    }
}

// MARK: - Built-in layouts

extension KeyLayout {
    // From msvisser/AnnePro-mac (MIT), matching the keyboard's three factory layouts.
    public static let windows = try! KeyLayout(payload: [
        41, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 42, 43, 20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 47, 48, 49, 57, 4, 22, 7, 9, 10, 11, 13, 14, 15, 51, 52, 0, 40, 225, 29, 27, 6, 25, 5, 17, 16, 54, 55, 56, 0, 0, 229, 224, 227, 226, 0, 0, 44, 0, 0, 0, 0, 230, 254, 250, 228,
        53, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 0, 0, 0, 82, 0, 0, 0, 0, 0, 82, 71, 72, 74, 77, 70, 0, 80, 81, 79, 0, 0, 0, 80, 81, 79, 75, 78, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 73, 76, 0, 0, 0, 0, 227, 0, 0, 0, 0, 0, 0, 0, 0, 0, 254, 250, 0,
    ])

    public static let windowsArrows = try! KeyLayout(payload: [
        41, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 42, 43, 20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 47, 48, 49, 57, 4, 22, 7, 9, 10, 11, 13, 14, 15, 51, 52, 0, 40, 225, 29, 27, 6, 25, 5, 17, 16, 54, 55, 82, 0, 0, 229, 224, 250, 226, 0, 0, 44, 0, 0, 0, 0, 80, 81, 79, 254,
        53, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 0, 0, 0, 82, 0, 0, 0, 0, 0, 82, 71, 72, 74, 77, 70, 0, 80, 81, 79, 0, 0, 0, 80, 81, 79, 75, 78, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 73, 56, 0, 0, 0, 0, 250, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 254,
    ])

    public static let mac = try! KeyLayout(payload: [
        41, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 42, 43, 20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 47, 48, 49, 57, 4, 22, 7, 9, 10, 11, 13, 14, 15, 51, 52, 0, 40, 225, 29, 27, 6, 25, 5, 17, 16, 54, 55, 56, 0, 0, 229, 224, 226, 227, 0, 0, 44, 0, 0, 0, 0, 230, 254, 250, 228,
        53, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 0, 0, 0, 82, 0, 0, 0, 0, 0, 82, 71, 72, 74, 77, 70, 0, 80, 81, 79, 0, 0, 0, 80, 81, 79, 75, 78, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 73, 76, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 254, 250, 0,
    ])

    public static let presets: [(name: String, layout: KeyLayout)] = [
        ("Windows", .windows), ("Windows + arrows", .windowsArrows), ("Mac", .mac),
    ]
}
