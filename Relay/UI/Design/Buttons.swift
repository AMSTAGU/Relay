import SwiftUI

/// boardui buttons. Primary and danger carry a top-to-bottom gradient with a
/// soft inner highlight; secondary is a bordered surface; ghost is a tinted
/// accent. Press scales to 0.98, not when motion is reduced.
struct RButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost, danger, plain }
    enum Size { case medium, small }

    var variant: Variant = .primary
    var size: Size = .medium
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        RButton(configuration: configuration, variant: variant, size: size, fullWidth: fullWidth)
    }
}

private struct RButton: View {
    let configuration: ButtonStyleConfiguration
    let variant: RButtonStyle.Variant
    let size: RButtonStyle.Size
    let fullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var pressed: Bool { configuration.isPressed && isEnabled }
    private var radius: CGFloat { size == .medium ? Radius.control : Radius.small }
    private var height: CGFloat { size == .medium ? 36 : 30 }

    var body: some View {
        configuration.label
            .font(size == .medium ? .rBodyMedium : .rBody2Medium)
            .lineLimit(1)
            .padding(.horizontal, variant == .plain ? 6 : (size == .medium ? 14 : 10))
            .frame(height: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(foreground)
            .background(background)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .modifier(ShadowIf(enabled: isEnabled && (variant == .primary || variant == .secondary || variant == .danger)))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .animation(pressed ? .easeOut(duration: 0.15) : .timingCurve(0.4, 0, 0.2, 1, duration: 0.42), value: pressed)
            .animation(Motion.quick, value: hovering)
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        guard isEnabled else { return Color(.textTertiary) }
        switch variant {
        case .primary, .danger: return .white
        case .secondary: return Color(.textPrimary)
        case .ghost: return Color(.ghostForeground)
        case .plain: return hovering ? Color(.textPrimary) : Color(.textSecondary)
        }
    }

    @ViewBuilder private var background: some View {
        if !isEnabled {
            variant == .plain ? Color.clear : Color(.backgroundTertiary)
        } else {
            switch variant {
            case .primary:
                LinearGradient(colors: primaryStops, startPoint: .top, endPoint: .bottom)
            case .danger:
                LinearGradient(colors: [Color(.dangerTop), Color(.dangerBottom)], startPoint: .top, endPoint: .bottom)
                    .brightness(pressed ? -0.05 : (hovering ? 0.04 : 0))
            case .secondary:
                pressed ? Color(.backgroundPrimaryActive) : (hovering ? Color(.backgroundPrimaryHover) : Color(.backgroundPrimary))
            case .ghost:
                hovering || pressed ? Color(.ghostBackgroundHover) : Color(.ghostBackground)
            case .plain:
                hovering ? Color(.backgroundSecondaryHover).opacity(0.6) : Color.clear
            }
        }
    }

    private var primaryStops: [Color] {
        if pressed { return [Color(.accent600), Color(.accent700)] }
        if hovering { return [Color(.accent400), Color(.accent500)] }
        return [Color(.accent500), Color(.accent600)]
    }

    @ViewBuilder private var border: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch variant {
        case .primary where isEnabled, .danger where isEnabled:
            // Inner top highlight + 1 px inner edge, as in boardui.
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        case .secondary:
            shape.strokeBorder(hovering && isEnabled ? Color(.borderButtonHover) : Color(.borderButton), lineWidth: 1)
        default:
            EmptyView()
        }
    }
}

private struct ShadowIf: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.shadowXS() } else { content }
    }
}

extension ButtonStyle where Self == RButtonStyle {
    static var rPrimary: RButtonStyle { RButtonStyle(variant: .primary) }
    static var rSecondary: RButtonStyle { RButtonStyle(variant: .secondary) }
    static var rGhost: RButtonStyle { RButtonStyle(variant: .ghost) }
    static var rDanger: RButtonStyle { RButtonStyle(variant: .danger) }
    static var rPlain: RButtonStyle { RButtonStyle(variant: .plain, size: .small) }
    static func r(_ variant: RButtonStyle.Variant, _ size: RButtonStyle.Size = .medium, fullWidth: Bool = false) -> RButtonStyle {
        RButtonStyle(variant: variant, size: size, fullWidth: fullWidth)
    }
}

/// Round 24 px close button (boardui settings modal).
struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color(.iconSecondary))
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? Color(.backgroundTertiaryHover) : Color(.backgroundTertiary)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel("Fermer")
        .keyboardShortcut(.cancelAction)
    }
}
