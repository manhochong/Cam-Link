import SwiftUI

/// Shared native theme. State is always described in words as well as colour.
enum CamLinkTheme {
    static let canvas = Color(hex: 0xF4F7FA)
    static let surface = Color.white
    static let navy = Color(hex: 0x17253D)
    static let ink = Color(hex: 0x24344B)
    static let accent = Color(hex: 0x007A86)
    static let accentSoft = Color(hex: 0xE5F3F3)
    static let soft = Color(hex: 0xEDF1F6)
    static let border = Color(hex: 0xDDE5EE)
    static let gold = Color(hex: 0xE7B978)
    static let error = Color(hex: 0xA53232)
    static let muted = Color(hex: 0x64748B)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}

struct CamLinkCard: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(CamLinkTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(CamLinkTheme.border.opacity(0.75), lineWidth: 1))
            .shadow(color: CamLinkTheme.navy.opacity(0.035), radius: 12, y: 4)
    }
}

extension View {
    func camLinkCard(padding: CGFloat = 18) -> some View {
        modifier(CamLinkCard(padding: padding))
    }
}

struct CamLinkPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    var accent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 20)
            .padding(.vertical, controlSize == .large ? 15 : 11)
            .frame(minHeight: 44)
            .background((accent ? CamLinkTheme.accent : CamLinkTheme.navy)
                .opacity(isEnabled ? (configuration.isPressed ? 0.84 : 1) : 0.55),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct CamLinkStatusBadge: View {
    let text: String
    let symbol: String
    var success = false
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(success ? CamLinkTheme.accent : CamLinkTheme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(success ? CamLinkTheme.accentSoft : CamLinkTheme.soft,
                        in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
