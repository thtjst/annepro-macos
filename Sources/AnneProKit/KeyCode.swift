/// Key codes the Anne Pro accepts in a custom layout. They are USB HID usage IDs
/// (keyboard page), plus two firmware-specific codes for the Fn and Anne keys.
public struct KeyCode: Hashable, Sendable, Identifiable {
    public enum Category: String, CaseIterable, Sendable {
        case none = "None"
        case letters = "Letters"
        case numbers = "Numbers"
        case punctuation = "Punctuation"
        case editing = "Editing"
        case modifiers = "Modifiers"
        case function = "Function keys"
        case navigation = "Navigation"
        case media = "Media"
        case special = "Anne Pro"
    }

    public let code: UInt8
    public let name: String
    /// Short legend for drawing on a keycap.
    public let legend: String
    public let category: Category

    public var id: UInt8 { code }

    public static let none: UInt8 = 0
    public static let fn: UInt8 = 254
    public static let anne: UInt8 = 250

    public static let all: [KeyCode] = {
        var list: [KeyCode] = [KeyCode(code: 0, name: "None", legend: "", category: .none)]
        func add(_ code: UInt8, _ name: String, _ legend: String? = nil, _ category: Category) {
            list.append(KeyCode(code: code, name: name, legend: legend ?? name, category: category))
        }
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            add(UInt8(4 + offset), String(letter), nil, .letters)
        }
        for (offset, digit) in "1234567890".enumerated() {
            add(UInt8(30 + offset), String(digit), nil, .numbers)
        }
        add(45, "- _", "-", .punctuation)
        add(46, "= +", "=", .punctuation)
        add(47, "[ {", "[", .punctuation)
        add(48, "] }", "]", .punctuation)
        add(49, "\\ |", "\\", .punctuation)
        add(51, "; :", ";", .punctuation)
        add(52, "' \"", "'", .punctuation)
        add(53, "` ~", "`", .punctuation)
        add(54, ", <", ",", .punctuation)
        add(55, ". >", ".", .punctuation)
        add(56, "/ ?", "/", .punctuation)

        add(41, "Escape", "Esc", .editing)
        add(43, "Tab", nil, .editing)
        add(57, "Caps Lock", "Caps", .editing)
        add(44, "Space", "Space", .editing)
        add(40, "Enter", nil, .editing)
        add(42, "Backspace", nil, .editing)
        add(76, "Delete", "Del", .editing)
        add(73, "Insert", "Ins", .editing)

        add(224, "Left Control", "Ctrl", .modifiers)
        add(225, "Left Shift", "Shift", .modifiers)
        add(226, "Left Alt / Option", "Alt", .modifiers)
        add(227, "Left Win / Command", "Win", .modifiers)
        add(228, "Right Control", "Ctrl", .modifiers)
        add(229, "Right Shift", "Shift", .modifiers)
        add(230, "Right Alt / Option", "Alt", .modifiers)
        add(231, "Right Win / Command", "Win", .modifiers)

        for number in 1...12 {
            add(UInt8(57 + number), "F\(number)", nil, .function)
        }

        add(80, "Left Arrow", "←", .navigation)
        add(82, "Up Arrow", "↑", .navigation)
        add(81, "Down Arrow", "↓", .navigation)
        add(79, "Right Arrow", "→", .navigation)
        add(74, "Home", nil, .navigation)
        add(77, "End", nil, .navigation)
        add(75, "Page Up", "PgUp", .navigation)
        add(78, "Page Down", "PgDn", .navigation)
        add(70, "Print Screen", "PrtSc", .navigation)
        add(71, "Scroll Lock", "ScrLk", .navigation)
        add(72, "Pause", nil, .navigation)

        add(127, "Mute", nil, .media)
        add(128, "Volume Up", "Vol+", .media)
        add(129, "Volume Down", "Vol−", .media)

        add(254, "Fn", nil, .special)
        add(250, "Anne", nil, .special)
        return list
    }()

    private static let byCode: [UInt8: KeyCode] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    /// Known codes by value. Unknown codes read from a keyboard are kept and shown as hex.
    public static func named(_ code: UInt8) -> KeyCode {
        byCode[code] ?? KeyCode(code: code, name: "Code \(code)", legend: "0x" + [code].hexString, category: .none)
    }

    public static func isKnown(_ code: UInt8) -> Bool { byCode[code] != nil }
}
