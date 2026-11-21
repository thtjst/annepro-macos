/// Physical layout of the Anne Pro: a 60% ANSI board with 61 keys.
///
/// The firmware addresses keys through a 70-slot matrix. Nine slots have no key on the
/// ANSI board (ISO and split-shift positions); they are still sent, filled with zeros.
public struct PhysicalKey: Identifiable, Hashable, Sendable {
    public enum Group: String, Sendable, CaseIterable {
        case number, letter, modifier
    }

    /// Position in reading order, 0..<61.
    public let id: Int
    /// Matrix slot the firmware uses, 0..<70.
    public let slot: Int
    public let row: Int
    /// Left edge, in key units (1u = one letter key).
    public let x: Double
    public let width: Double
    /// Legend printed on the keycap.
    public let label: String
    public let group: Group
}

public enum AnnePro {
    public static let slotCount = 70
    public static let unusedSlots: Set<Int> = [40, 53, 54, 59, 60, 62, 63, 64, 65]
    public static let usedSlots: [Int] = (0..<slotCount).filter { !unusedSlots.contains($0) }

    /// Board size in key units.
    public static let width = 15.0
    public static let rows = 5

    public static let keys: [PhysicalKey] = {
        typealias Spec = (label: String, width: Double, group: PhysicalKey.Group)
        let n = PhysicalKey.Group.number, l = PhysicalKey.Group.letter, m = PhysicalKey.Group.modifier
        func row(_ labels: String, _ group: PhysicalKey.Group) -> [Spec] {
            labels.split(separator: " ").map { (String($0), 1, group) }
        }
        let rows: [[Spec]] = [
            [("Esc", 1, m)] + row("1 2 3 4 5 6 7 8 9 0 - =", n) + [("Backspace", 2, m)],
            [("Tab", 1.5, m)] + row("Q W E R T Y U I O P [ ]", l) + [("\\", 1.5, m)],
            [("Caps", 1.75, m)] + row("A S D F G H J K L ; '", l) + [("Enter", 2.25, m)],
            [("Shift", 2.25, m)] + row("Z X C V B N M , . /", l) + [("Shift", 2.75, m)],
            [("Ctrl", 1.25, m), ("Win", 1.25, m), ("Alt", 1.25, m), ("", 6.25, m),
             ("Alt", 1.25, m), ("Fn", 1.25, m), ("Anne", 1.25, m), ("Ctrl", 1.25, m)],
        ]
        var keys: [PhysicalKey] = []
        for (rowIndex, specs) in rows.enumerated() {
            var x = 0.0
            for spec in specs {
                let id = keys.count
                keys.append(PhysicalKey(
                    id: id, slot: usedSlots[id], row: rowIndex, x: x,
                    width: spec.width, label: spec.label, group: spec.group
                ))
                x += spec.width
            }
        }
        precondition(keys.count == usedSlots.count)
        return keys
    }()

    public static func keys(in group: PhysicalKey.Group) -> [PhysicalKey] {
        keys.filter { $0.group == group }
    }
}
