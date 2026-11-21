/// Wire protocol of the original Anne Pro (2016–2018, micro-USB) over Bluetooth LE.
///
/// Every message has the shape `[type, dataLength + 1, operation, data…]`. Replies use the
/// same type with the high bit set on the operation (`op | 0x80`). Payloads that do not fit
/// in one 20-byte BLE packet are split into 14-byte chunks:
/// `[type, totalLength + 1, operation, chunkLength + 2, chunkCount, chunkIndex, chunk…]`.
///
/// See docs/PROTOCOL.md for the full table and where each fact came from.
public enum MessageType {
    public static let system: UInt8 = 2
    public static let ble: UInt8 = 6
    public static let keyboard: UInt8 = 7
    public static let led: UInt8 = 9
}

public enum Operation {
    public enum System {
        public static let getID: UInt8 = 1
    }

    public enum Keyboard {
        /// Host → keyboard: store a custom layout.
        public static let downloadUserLayout: UInt8 = 2
        public static let setLayoutID: UInt8 = 3
        public static let getLayoutID: UInt8 = 4
        /// Keyboard → host: send back the stored custom layout.
        public static let uploadUserLayout: UInt8 = 5
    }

    public enum LED {
        public static let themeMode: UInt8 = 1
        public static let themeSwitch: UInt8 = 2
        public static let userStaticTheme: UInt8 = 3
        public static let configCmd: UInt8 = 5
        public static let getUsedThemeID: UInt8 = 8
        public static let getUserStaticTheme: UInt8 = 9
        public static let getUserStaticCRCID: UInt8 = 10
    }

    /// The operation code the keyboard answers `op` with.
    public static func reply(to op: UInt8) -> UInt8 { op | 0x80 }
}

/// One complete message from the keyboard, reassembled from however many packets it took.
public struct Message: Equatable, Sendable, CustomStringConvertible {
    public let type: UInt8
    public let op: UInt8
    public let data: [UInt8]

    public init(type: UInt8, op: UInt8, data: [UInt8]) {
        self.type = type
        self.op = op
        self.data = data
    }

    public var description: String {
        "type \(type) op \(op) data [\(data.hexString)]"
    }
}

/// Identifies which message answers a request.
public struct ReplyKey: Hashable, Sendable {
    public let type: UInt8
    public let op: UInt8

    public init(type: UInt8, op: UInt8) {
        self.type = type
        self.op = op
    }

    public func matches(_ message: Message) -> Bool {
        message.type == type && message.op == op
    }
}

public enum Framing {
    /// Default ATT MTU (23) minus 3 bytes of ATT header.
    public static let packetSize = 20
    /// Bytes of payload per chunk once the 6-byte chunk header is in.
    public static let chunkSize = 14

    /// A message that fits in one packet. Sent unpadded, like the official app.
    public static func packet(type: UInt8, op: UInt8, data: [UInt8] = []) -> [UInt8] {
        precondition(data.count + 3 <= packetSize, "use chunked(…) for payloads this large")
        return [type, UInt8(data.count + 1), op] + data
    }

    /// A large payload split into 20-byte packets, zero padded.
    public static func chunked(type: UInt8, op: UInt8, payload: [UInt8]) -> [[UInt8]] {
        precondition(!payload.isEmpty && payload.count < 255)
        let count = (payload.count + chunkSize - 1) / chunkSize
        return (0..<count).map { index in
            let start = index * chunkSize
            let chunk = payload[start..<min(payload.count, start + chunkSize)]
            var packet: [UInt8] = [
                type, UInt8(payload.count + 1), op,
                UInt8(chunk.count + 2), UInt8(count), UInt8(index),
            ]
            packet += chunk
            packet += [UInt8](repeating: 0, count: packetSize - packet.count)
            return packet
        }
    }
}

/// Turns the stream of notification packets back into whole messages.
public struct MessageAssembler: Sendable {
    /// Replies that always arrive as numbered chunks.
    public static let chunkedReplies: Set<ReplyKey> = [
        ReplyKey(type: MessageType.system, op: Operation.reply(to: Operation.System.getID)),
        ReplyKey(type: MessageType.keyboard, op: Operation.reply(to: Operation.Keyboard.uploadUserLayout)),
        ReplyKey(type: MessageType.led, op: Operation.reply(to: Operation.LED.getUserStaticTheme)),
    ]

    private var key: ReplyKey?
    private var buffer: [UInt8] = []
    private var nextIndex = 0

    public init() {}

    /// Feeds one packet. Returns a message once one is complete.
    public mutating func feed(_ packet: [UInt8]) -> Message? {
        guard packet.count >= 3 else { return nil }
        let key = ReplyKey(type: packet[0], op: packet[2])

        if Self.chunkedReplies.contains(key), packet.count >= 6 {
            let length = max(0, Int(packet[3]) - 2)
            let total = Int(packet[4])
            let index = Int(packet[5])
            guard total > 0, index < total else { return nil }

            if index == 0 {
                self.key = key
                buffer = []
                nextIndex = 0
            }
            guard self.key == key, index == nextIndex else {
                // A chunk went missing or arrived out of order: drop the whole message.
                reset()
                return nil
            }
            // Packets are reused buffers, so anything past `length` is stale and ignored.
            buffer += packet[6..<min(packet.count, 6 + length)]
            nextIndex += 1
            guard nextIndex == total else { return nil }
            defer { reset() }
            return Message(type: key.type, op: key.op, data: buffer)
        }

        let end = min(packet.count, 2 + max(1, Int(packet[1])))
        return Message(type: key.type, op: key.op, data: Array(packet[3..<end]))
    }

    private mutating func reset() {
        key = nil
        buffer = []
        nextIndex = 0
    }
}

/// A request to the keyboard: the packets to send and, if the keyboard answers, what to wait for.
public struct Request: Sendable {
    public let name: String
    public let packets: [[UInt8]]
    /// The answer that carries the data asked for.
    public let reply: ReplyKey?
    /// A confirmation some setters get. Not guaranteed, so its absence is not an error.
    public let acknowledgement: ReplyKey?

    public init(name: String, packets: [[UInt8]], reply: ReplyKey? = nil, acknowledgement: ReplyKey? = nil) {
        self.name = name
        self.packets = packets
        self.reply = reply
        self.acknowledgement = acknowledgement
    }

    private static func get(_ name: String, type: UInt8, op: UInt8) -> Request {
        Request(
            name: name,
            packets: [Framing.packet(type: type, op: op)],
            reply: ReplyKey(type: type, op: Operation.reply(to: op))
        )
    }

    public static let deviceInfo = get("device info", type: MessageType.system, op: Operation.System.getID)

    public static func setLightingMode(_ mode: LightingMode) -> Request {
        Request(
            name: "lighting mode \(mode.name)",
            packets: [Framing.packet(type: MessageType.led, op: Operation.LED.themeMode, data: [mode.rawValue])],
            acknowledgement: ReplyKey(type: MessageType.led, op: Operation.reply(to: Operation.LED.themeMode))
        )
    }

    public static let lightingMode = get("lighting mode", type: MessageType.led, op: Operation.LED.getUsedThemeID)

    /// Brightness from 1 (dim) to 10 (full).
    public static func setBrightness(_ level: Int) -> Request {
        let level = UInt8(min(max(level, 1), 10))
        return Request(
            name: "brightness \(level)",
            packets: [Framing.packet(type: MessageType.led, op: Operation.LED.themeSwitch, data: [1, level, 0])],
            acknowledgement: ReplyKey(type: MessageType.led, op: Operation.reply(to: Operation.LED.themeSwitch))
        )
    }

    public static let customLighting = get("custom lighting", type: MessageType.led, op: Operation.LED.getUserStaticTheme)
    public static let customLightingID = get("custom lighting id", type: MessageType.led, op: Operation.LED.getUserStaticCRCID)

    public static func uploadLighting(_ profile: LightingProfile) -> Request {
        Request(
            name: "upload lighting",
            packets: Framing.chunked(type: MessageType.led, op: Operation.LED.userStaticTheme, payload: profile.payload),
            reply: ReplyKey(type: MessageType.led, op: Operation.reply(to: Operation.LED.userStaticTheme))
        )
    }

    public static func setLayoutMode(_ mode: LayoutMode) -> Request {
        Request(name: "layout \(mode.name)", packets: [
            Framing.packet(type: MessageType.keyboard, op: Operation.Keyboard.setLayoutID, data: [mode.rawValue]),
        ])
    }

    public static let layoutMode = get("layout mode", type: MessageType.keyboard, op: Operation.Keyboard.getLayoutID)
    public static let customLayout = get("custom layout", type: MessageType.keyboard, op: Operation.Keyboard.uploadUserLayout)

    public static func uploadLayout(_ layout: KeyLayout) -> Request {
        Request(
            name: "upload layout",
            packets: Framing.chunked(type: MessageType.keyboard, op: Operation.Keyboard.downloadUserLayout, payload: layout.payload),
            reply: ReplyKey(type: MessageType.keyboard, op: Operation.reply(to: Operation.Keyboard.downloadUserLayout))
        )
    }

    /// Anything else, for experiments (`anne raw …`).
    public static func raw(_ bytes: [UInt8]) -> Request {
        Request(name: "raw", packets: [bytes])
    }
}

/// What the keyboard says about itself in reply to `Request.deviceInfo`.
public struct DeviceInfo: Equatable, Sendable {
    public let deviceType: UInt8
    public let model: UInt8
    public let serial: [UInt8]

    public init?(_ message: Message) {
        guard message.type == MessageType.system, message.data.count >= 2 else { return nil }
        deviceType = message.data[0]
        model = message.data[1]
        serial = Array(message.data.dropFirst(2))
    }

    public var modelName: String {
        switch (deviceType, model) {
        case (1, 2): "Anne Pro"
        default: "Unknown device (type \(deviceType), model \(model))"
        }
    }

    public var serialString: String { serial.hexString }
}

public enum LightingMode: UInt8, CaseIterable, Identifiable, Sendable {
    case off = 0
    case red = 1, yellow, green, cyan, blue, purple, pink, orange, white
    case france = 10, italy, argentina
    case breathing = 13
    case rainbow = 14
    case reactiveFade = 15
    case reactiveCycle = 16
    case ripple = 17
    case colorCycle = 18
    case custom = 128

    public var id: UInt8 { rawValue }

    public var name: String {
        switch self {
        case .off: "Off"
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .cyan: "Cyan"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .orange: "Orange"
        case .white: "White"
        case .france: "France flag"
        case .italy: "Italy flag"
        case .argentina: "Argentina flag"
        case .breathing: "Breathing"
        case .rainbow: "Rainbow"
        case .reactiveFade: "Reactive"
        case .reactiveCycle: "Reactive cycle"
        case .ripple: "Ripple"
        case .colorCycle: "Color cycle"
        case .custom: "Custom"
        }
    }

    /// Short name used on the command line.
    public var slug: String {
        name.lowercased().replacingOccurrences(of: " flag", with: "").replacingOccurrences(of: " ", with: "-")
    }

    public var detail: String {
        switch self {
        case .breathing: "All keys fade through red, yellow, green, cyan, blue and purple"
        case .rainbow: "Colours roll across the keyboard"
        case .reactiveFade: "Pressed keys light up and fade out"
        case .reactiveCycle: "Pressed keys light up in a new colour each press"
        case .ripple: "The row and column of a pressed key light up"
        case .colorCycle: "All keys cycle through colours together"
        case .custom: "Your own per-key colours"
        default: name
        }
    }

    public static let solidColors: [LightingMode] = [.red, .yellow, .green, .cyan, .blue, .purple, .pink, .orange, .white]
    public static let effects: [LightingMode] = [.breathing, .rainbow, .reactiveFade, .reactiveCycle, .ripple, .colorCycle]
    public static let flags: [LightingMode] = [.france, .italy, .argentina]

    /// Approximate colour of solid modes, for swatches.
    public var swatch: RGB? {
        switch self {
        case .off: RGB(0, 0, 0)
        case .red: RGB(255, 0, 0)
        case .yellow: RGB(255, 220, 0)
        case .green: RGB(0, 255, 0)
        case .cyan: RGB(0, 255, 255)
        case .blue: RGB(0, 0, 255)
        case .purple: RGB(150, 0, 255)
        case .pink: RGB(255, 80, 180)
        case .orange: RGB(255, 120, 0)
        case .white: RGB(255, 255, 255)
        default: nil
        }
    }

    public init?(slug: String) {
        let wanted = slug.lowercased()
        if let match = Self.allCases.first(where: { $0.slug == wanted }) {
            self = match
        } else if let number = UInt8(wanted), let match = LightingMode(rawValue: number) {
            self = match
        } else {
            return nil
        }
    }
}

public enum LayoutMode: UInt8, CaseIterable, Identifiable, Sendable {
    case windows = 1
    case windowsArrows = 2
    case mac = 3
    case custom = 128

    public var id: UInt8 { rawValue }

    public var name: String {
        switch self {
        case .windows: "Windows"
        case .windowsArrows: "Arrows"
        case .mac: "Mac"
        case .custom: "Custom"
        }
    }

    public var detail: String {
        switch self {
        case .windows: "Standard 60% layout"
        case .windowsArrows: "/ and the bottom-right keys become arrow keys"
        case .mac: "Alt and Win swapped so Cmd sits next to the space bar"
        case .custom: "Your own layout"
        }
    }

    public var slug: String {
        switch self {
        case .windows: "windows"
        case .windowsArrows: "arrows"
        case .mac: "mac"
        case .custom: "custom"
        }
    }

    public init?(slug: String) {
        guard let match = Self.allCases.first(where: { $0.slug == slug.lowercased() }) else { return nil }
        self = match
    }
}

extension Sequence where Element == UInt8 {
    public var hexString: String {
        map { byte in
            let digits = String(byte, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }.joined(separator: " ")
    }
}
