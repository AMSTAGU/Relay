import SwiftUI

/// Three dots hopping one after the other. With "Reduce motion" they stay in
/// place and only pulse in opacity.
struct DotsLoader: View {
    var color: Color = Color(.iconSecondary)
    var dotSize: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let period = 1.05
    private let stagger = 0.14

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: dotSize * 0.8) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = Self.wave(time: time - Double(index) * stagger, period: period)
                    Circle()
                        .fill(color)
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: reduceMotion ? 0 : -dotSize * 0.9 * wave)
                        .opacity(0.35 + 0.65 * wave)
                }
            }
            .frame(height: dotSize * 2.2, alignment: .bottom)
        }
        .accessibilityElement()
        .accessibilityLabel("Chargement")
    }

    /// 0 at rest, rises smoothly to 1 and back during the first half of each period.
    private static func wave(time: Double, period: Double) -> Double {
        let phase = time.truncatingRemainder(dividingBy: period) / period
        let t = phase < 0 ? phase + 1 : phase
        guard t < 0.5 else { return 0 }
        return sin(t * 2 * .pi)
    }
}
