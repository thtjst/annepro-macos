import AnneProKit
import AppKit
import SwiftUI

extension RGB {
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self.init(byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
    }

    /// Relative luminance, for picking a readable legend colour.
    var luminance: Double {
        0.2126 * Double(r) / 255 + 0.7152 * Double(g) / 255 + 0.0722 * Double(b) / 255
    }
}

/// Lays out the 61 keys of the Anne Pro at their real proportions inside a keyboard case.
struct KeyboardCanvas<Key: View>: View {
    var gap: CGFloat = 0.08
    @ViewBuilder var key: (PhysicalKey, CGSize) -> Key

    static func unit(for size: CGSize) -> CGFloat {
        min(size.width / AnnePro.width, size.height / Double(AnnePro.rows))
    }

    static func key(at point: CGPoint, in size: CGSize) -> PhysicalKey? {
        let unit = unit(for: size)
        guard unit > 0 else { return nil }
        let row = Int(point.y / unit)
        let x = point.x / unit
        return AnnePro.keys.first { $0.row == row && x >= $0.x && x < $0.x + $0.width }
    }

    var body: some View {
        GeometryReader { geometry in
            let unit = Self.unit(for: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(AnnePro.keys) { physical in
                    let size = CGSize(width: physical.width * unit - gap * unit, height: unit - gap * unit)
                    key(physical, size)
                        .frame(width: size.width, height: size.height)
                        .position(x: (physical.x + physical.width / 2) * unit, y: (Double(physical.row) + 0.5) * unit)
                }
            }
        }
        .aspectRatio(AnnePro.width / Double(AnnePro.rows), contentMode: .fit)
    }
}

/// The dark aluminium-and-plastic look of the keyboard around the keys.
struct KeyboardCase<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
    }
}

/// One keycap lit by an LED of the given colour.
struct LitKeycap: View {
    let label: String
    let color: RGB
    var isHighlighted = false

    var body: some View {
        let lit = color.luminance > 0.02
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(white: 0.13))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.color.opacity(lit ? 0.85 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isHighlighted ? Color.accentColor : Color.white.opacity(0.10), lineWidth: isHighlighted ? 2 : 1)
            )
            .overlay(
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(lit && color.luminance > 0.55 ? Color.black.opacity(0.75) : Color.white.opacity(0.9))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
            )
            .shadow(color: lit ? color.color.opacity(0.55) : .clear, radius: 5)
    }
}

/// A keycap showing which key code it sends.
struct LayoutKeycap: View {
    let code: UInt8
    let isLocked: Bool
    let isSelected: Bool
    let isChanged: Bool

    var body: some View {
        let keyCode = KeyCode.named(code)
        let special = code == KeyCode.fn || code == KeyCode.anne
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(special ? Color.accentColor.opacity(0.75) : Color(white: isLocked ? 0.10 : 0.2))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 7)).foregroundStyle(.white.opacity(0.35)).padding(4)
                } else if isChanged {
                    Circle().fill(Color.orange).frame(width: 5, height: 5).padding(4)
                }
            }
            .overlay(
                Text(code == 0 ? "—" : keyCode.legend)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(code == 0 || isLocked ? 0.35 : 0.92))
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
            )
    }
}

/// View-local state. Used instead of `@State`, which recent SDKs implement as a compiler
/// macro whose plugin ships only with Xcode; this keeps the app buildable with just the
/// Command Line Tools.
@MainActor
final class LocalState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
