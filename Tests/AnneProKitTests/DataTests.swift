import Foundation
import Testing
@testable import AnneProKit

@Suite struct KeyboardTests {
    @Test func sixtyOneKeysInFiveRowsOfFifteenUnits() {
        #expect(AnnePro.keys.count == 61)
        for row in 0..<AnnePro.rows {
            let width = AnnePro.keys.filter { $0.row == row }.reduce(0) { $0 + $1.width }
            #expect(width == AnnePro.width, "row \(row)")
        }
    }

    @Test func matrixSlotsMatchFactoryLayout() {
        func key(_ row: Int, _ label: String, last: Bool = false) -> PhysicalKey {
            let matches = AnnePro.keys.filter { $0.row == row && $0.label == label }
            return last ? matches.last! : matches.first!
        }
        let layout = KeyLayout.windows
        #expect(layout[.base, key(2, "Enter")] == 40)
        #expect(layout[.base, key(3, "Shift")] == 225)
        #expect(layout[.base, key(3, "Shift", last: true)] == 229)
        #expect(layout[.base, key(4, "")] == 44) // space
        #expect(layout[.base, key(4, "Fn")] == KeyCode.fn)
        #expect(layout[.base, key(4, "Anne")] == KeyCode.anne)
        #expect(layout[.base, key(4, "Ctrl", last: true)] == 228)
    }

    @Test func groupsCoverEveryKey() {
        let total = PhysicalKey.Group.allCases.map { AnnePro.keys(in: $0).count }.reduce(0, +)
        #expect(total == 61)
        #expect(AnnePro.keys(in: .number).count == 12)
    }
}

@Suite struct LightingTests {
    @Test func payloadLayout() {
        var profile = LightingProfile(repeating: .black)
        profile[0] = RGB(1, 2, 3) // Esc, slot 0
        profile[AnnePro.keys.count - 1] = RGB(4, 5, 6) // right Ctrl, slot 69
        let payload = profile.payload
        #expect(payload.count == 214)
        #expect(payload[0] == 0 && payload[1] == 0)
        #expect(Array(payload[4...6]) == [1, 2, 3])
        #expect(Array(payload[211...213]) == [4, 5, 6])
        let crc = CRC16.modbus(payload[4...])
        #expect(payload[2] == UInt8(crc >> 8) && payload[3] == UInt8(crc & 0xFF))
    }

    @Test func roundTrip() throws {
        let profile = LightingProfile.horizontalRainbow()
        #expect(try LightingProfile(payload: profile.payload) == profile)
        #expect(try LightingProfile(payload: Array(profile.payload.dropFirst(4))) == profile)
        #expect(throws: AnneProDataError.self) { try LightingProfile(payload: [1, 2, 3]) }
    }

    @Test func jsonRoundTrip() throws {
        let profile = LightingProfile.verticalRainbow()
        #expect(try LightingProfile(jsonData: profile.jsonData()) == profile)
    }

    @Test func importsMsvisserExport() throws {
        let profile = LightingProfile.accent(base: RGB(10, 20, 30), accent: RGB(200, 100, 0))
        let legacy = try JSONEncoder().encode(profile.payload)
        #expect(try LightingProfile(jsonData: legacy) == profile)
    }

    @Test func hex() {
        #expect(RGB(hex: "#FF8000") == RGB(255, 128, 0))
        #expect(RGB(255, 128, 0).hex == "#FF8000")
        #expect(RGB(hex: "nope") == nil)
    }

    @Test func hsb() {
        #expect(RGB(hue: 0) == RGB(255, 0, 0))
        #expect(RGB(hue: 1.0 / 3) == RGB(0, 255, 0))
        #expect(RGB(hue: 2.0 / 3) == RGB(0, 0, 255))
    }
}

@Suite struct LayoutTests {
    @Test func factoryLayoutsAreValid() {
        for preset in KeyLayout.presets {
            #expect(preset.layout.issues.isEmpty, "\(preset.name): \(preset.layout.issues)")
        }
    }

    @Test func factoryLayoutsOnlyUseKnownCodes() {
        for preset in KeyLayout.presets {
            for code in preset.layout.base + preset.layout.fn {
                #expect(KeyCode.isKnown(code), "\(preset.name) uses unknown code \(code)")
            }
        }
    }

    @Test func payloadChecksumCoversKeyBytes() throws {
        let payload = KeyLayout.mac.payload
        #expect(payload.count == 144)
        let crc = CRC16.modbus(payload[4...])
        #expect(payload[2] == UInt8(crc >> 8) && payload[3] == UInt8(crc & 0xFF))
        #expect(try KeyLayout(payload: payload) == .mac)
    }

    @Test func jsonRoundTrip() throws {
        #expect(try KeyLayout(jsonData: KeyLayout.windowsArrows.jsonData()) == .windowsArrows)
    }

    @Test func movingFnKeepsLayersAligned() {
        var layout = KeyLayout.windows
        let caps = AnnePro.keys.first { $0.label == "Caps" }!
        layout.assign(KeyCode.fn, to: caps, on: .base)
        #expect(layout.issues.isEmpty)
        #expect(layout[.fn, caps] == KeyCode.fn)
        #expect(AnnePro.keys.filter { layout[.base, $0] == KeyCode.fn } == [caps])
        #expect(layout.isLocked(caps, on: .fn))
    }

    @Test func replacingAnneIsReported() {
        var layout = KeyLayout.windows
        let anne = AnnePro.keys.first { $0.label == "Anne" }!
        layout.assign(4, to: anne, on: .base)
        #expect(layout.issues.contains(.missing(code: KeyCode.anne, layer: .base)))
        #expect(layout.issues.contains(.missing(code: KeyCode.anne, layer: .fn)))
    }

    @Test func reservedKeysCannotBeChanged() {
        var layout = KeyLayout.windows
        let b = AnnePro.keys.first { $0.label == "B" }!
        layout.assign(4, to: b, on: .fn)
        #expect(layout[.fn, b] == KeyLayout.windows[.fn, b])
        layout.assign(4, to: b, on: .base)
        #expect(layout[.base, b] == 4)
    }

    @Test func comparisonIgnoresUnusedSlots() throws {
        var payload = KeyLayout.windows.payload
        payload[4 + 40] = 99 // slot 40 has no key
        let changed = try KeyLayout(payload: payload)
        #expect(changed != .windows)
        #expect(changed.hasSameKeys(as: .windows))
    }
}

@Suite struct PowerBudgetTests {
    // Measured on an Anne Pro: sums up to 450 are stored as-is, above that at 60% rounded down.
    @Test func dimsOnlyAboveBudget() {
        #expect(RGB(255, 195, 0).asStoredByKeyboard == RGB(255, 195, 0)) // 450
        #expect(RGB(255, 196, 0).asStoredByKeyboard == RGB(0x99, 0x75, 0)) // 451
        #expect(RGB(255, 198, 0).asStoredByKeyboard == RGB(0x99, 0x76, 0))
        #expect(RGB(255, 217, 0).asStoredByKeyboard == RGB(0x99, 0x82, 0))
        #expect(RGB(0, 255, 227).asStoredByKeyboard == RGB(0, 0x99, 0x88))
        #expect(RGB.white.asStoredByKeyboard == RGB(153, 153, 153))
    }

    @Test func presetsStayWithinBudget() {
        let presets: [LightingProfile] = [
            .horizontalRainbow(), .verticalRainbow(),
            .gradient(from: RGB(255, 255, 0), to: RGB(0, 255, 255)),
        ]
        for preset in presets {
            #expect(preset.colors.allSatisfy { !$0.exceedsPowerBudget })
        }
        #expect(RGB(255, 255, 0).fittingPowerBudget == RGB(225, 225, 0))
    }
}

@Suite struct VersionTests {
    @Test func comparesVersions() {
        #expect(VersionNumber.isNewer("v1.1.0", than: "1.0.1"))
        #expect(VersionNumber.isNewer("1.0.10", than: "1.0.9"))
        #expect(VersionNumber.isNewer("2.0", than: "1.9.9"))
        #expect(!VersionNumber.isNewer("1.0.1", than: "1.0.1"))
        #expect(!VersionNumber.isNewer("v1.0.0", than: "1.0.1"))
        #expect(!VersionNumber.isNewer("1.0", than: "1.0.0"))
    }
}
