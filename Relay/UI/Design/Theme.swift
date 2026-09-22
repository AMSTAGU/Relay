import SwiftUI

/// boardui's type scale, set in SF Pro.
extension Font {
    static let rTitle1 = Font.system(size: 24, weight: .medium)
    static let rTitle2 = Font.system(size: 20, weight: .medium)
    static let rTitle3 = Font.system(size: 18, weight: .medium)
    static let rHeadline = Font.system(size: 16, weight: .medium)
    static let rBody = Font.system(size: 14)
    static let rBodyMedium = Font.system(size: 14, weight: .medium)
    static let rBody2 = Font.system(size: 13)
    static let rBody2Medium = Font.system(size: 13, weight: .medium)
    static let rCaption = Font.system(size: 12)
    static let rCaptionSemibold = Font.system(size: 12, weight: .semibold)
    static let rCode = Font.system(size: 26, weight: .medium, design: .monospaced)
}

/// boardui radii: panels 24, cards 16, controls 10, small controls 8.
enum Radius {
    static let panel: CGFloat = 24
    static let card: CGFloat = 16
    static let tile: CGFloat = 12
    static let control: CGFloat = 10
    static let small: CGFloat = 8
}

/// boardui motion, with "Reduce motion" honoured everywhere.
enum Motion {
    /// Panels and step changes: cubic-bezier(0.32, 0.72, 0, 1), 300 ms.
    static let panel = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.3)
    /// Colors and hover: 150 ms ease.
    static let quick = Animation.easeInOut(duration: 0.15)
    static let toggle = Animation.easeInOut(duration: 0.2)

    static func panel(_ reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.15) : panel }
}

extension AnyTransition {
    /// Content rises 12 px while fading in; a plain fade when motion is reduced.
    static func rise(_ reduce: Bool) -> AnyTransition {
        reduce ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 12)),
            removal: .opacity.combined(with: .offset(y: -6))
        )
    }
}

/// boardui's soft layered shadows.
extension View {
    func shadowXS() -> some View {
        shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
    }

    func shadowCard() -> some View {
        self
            .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 4)
    }

    /// boardui focus ring: 2 px accent.
    func focusRing(_ visible: Bool, radius: CGFloat) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                .strokeBorder(Color(.accent500), lineWidth: 2)
                .padding(-3)
                .opacity(visible ? 1 : 0)
        }
    }
}
