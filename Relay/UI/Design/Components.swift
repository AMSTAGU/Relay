import SwiftUI

// MARK: - Switch

/// boardui switch (md, 42×24): accent gradient track when on, white thumb
/// with a small embossed chip in its centre.
struct RToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        RToggle(configuration: configuration)
    }
}

private struct RToggle: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let on = configuration.isOn
        HStack(spacing: 10) {
            configuration.label
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on
                          ? AnyShapeStyle(LinearGradient(colors: [Color(.accent500), Color(.accent600)], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color(.backgroundTertiary)))
                    .overlay {
                        if on {
                            Capsule().strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center),
                                lineWidth: 1
                            )
                        }
                    }
                    .frame(width: 42, height: 24)
                Circle()
                    .fill(LinearGradient(colors: [Color(.thumbTop), Color(.thumbBottom)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Circle()
                            .fill(on
                                  ? AnyShapeStyle(LinearGradient(colors: [Color(.accent500), Color(.accent600)], startPoint: .bottom, endPoint: .top))
                                  : AnyShapeStyle(LinearGradient(colors: [Color(.thumbTop), Color(.thumbBottom)], startPoint: .bottom, endPoint: .top)))
                            .overlay(Circle().strokeBorder(on ? Color(.accent600) : Color.black.opacity(0.06), lineWidth: 0.5))
                            .frame(width: 7.5, height: 7.5)
                    }
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.08), radius: 1.5, x: 0, y: 1)
                    .padding(3)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(reduceMotion ? nil : Motion.toggle, value: on)
            .onTapGesture { configuration.isOn.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "activé" : "désactivé")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

extension ToggleStyle where Self == RToggleStyle {
    static var rSwitch: RToggleStyle { RToggleStyle() }
}

// MARK: - Grouped settings

/// boardui settings card: secondary background, radius 16, rows inset 12 px left.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(DividedRows()) { content }
        }
        .padding(.leading, 12)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color(.backgroundSecondary)))
    }
}

/// Puts a hairline under every row except the last, stopping 12 px short of the card edge.
private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle().fill(Color(.hairline)).frame(height: 1)
            }
        }
    }
}

/// One label/control row, min height 52.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var description: String?
    var icon: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(.iconSecondary))
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.rBody)
                    .foregroundStyle(Color(.textPrimary))
                if let description {
                    Text(description)
                        .font(.rBody2)
                        .foregroundStyle(Color(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
        .frame(minHeight: 52)
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(title: String, description: String? = nil, icon: String? = nil) {
        self.init(title: title, description: description, icon: icon) { EmptyView() }
    }
}

/// Muted 13 px heading above a card.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.rBody2Medium)
            .foregroundStyle(Color(.textSecondary))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Status

/// 12 px halo with a 6 px dot.
struct StatusDot: View {
    enum Tone { case online, offline, busy }
    let tone: Tone

    var body: some View {
        Circle()
            .fill(halo)
            .frame(width: 12, height: 12)
            .overlay(Circle().fill(dot).frame(width: 6, height: 6))
            .accessibilityHidden(true)
    }

    private var halo: Color {
        switch tone {
        case .online: Color(.dotGreenHalo)
        case .offline: Color(.dotGrayHalo)
        case .busy: Color(.dotYellowHalo)
        }
    }

    private var dot: Color {
        switch tone {
        case .online: Color(.dotGreen)
        case .offline: Color(.dotGray)
        case .busy: Color(.dotYellow)
        }
    }
}

/// Small rounded label ("Ce Mac", "Suggéré", "Connectée").
struct Pill: View {
    enum Tone { case neutral, accent, success }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.rCaptionSemibold)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: Color(.textSecondary)
        case .accent: Color(.ghostForeground)
        case .success: Color(.successForeground)
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Color(.backgroundTertiary)
        case .accent: Color(.ghostBackground)
        case .success: Color(.successBackground)
        }
    }
}

// MARK: - Notice (boardui notification)

struct Notice<Actions: View>: View {
    enum Tone { case info, success, warning, error, neutral }
    let tone: Tone
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(background))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.rBodyMedium)
                    .foregroundStyle(Color(.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(.rBody2)
                        .foregroundStyle(Color(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) { actions }
                    .padding(.top, Actions.self == EmptyView.self ? 0 : 6)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Color(.backgroundPrimary)))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Color(.borderButton), lineWidth: 1))
        .shadowCard()
    }

    private var symbol: String {
        switch tone {
        case .info: "info"
        case .success: "checkmark"
        case .warning: "exclamationmark"
        case .error: "xmark"
        case .neutral: "ellipsis"
        }
    }

    private var foreground: Color {
        switch tone {
        case .info: Color(.infoForeground)
        case .success: Color(.successForeground)
        case .warning: Color(.warningForeground)
        case .error: Color(.errorForeground)
        case .neutral: Color(.iconSecondary)
        }
    }

    private var background: Color {
        switch tone {
        case .info: Color(.infoBackground)
        case .success: Color(.successBackground)
        case .warning: Color(.warningBackground)
        case .error: Color(.errorBackground)
        case .neutral: Color(.backgroundTertiary)
        }
    }
}

extension Notice where Actions == EmptyView {
    init(tone: Tone, title: String, message: String? = nil) {
        self.init(tone: tone, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Choice card (boardui radio card)

struct ChoiceCard<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.rBodyMedium)
                        .foregroundStyle(Color(.textPrimary))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.rBody2)
                            .foregroundStyle(Color(.textSecondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
                RadioDot(selected: selected)
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(selected ? Color(.selectionBackground) : (hovering ? Color(.backgroundPrimaryHover) : Color(.backgroundPrimary)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(selected ? Color(.accent500) : Color(.borderButton), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RadioDot: View {
    let selected: Bool

    var body: some View {
        ZStack {
            if selected {
                Circle()
                    .fill(LinearGradient(colors: [Color(.accent500), Color(.accent600)], startPoint: .top, endPoint: .bottom))
                Circle().fill(.white).frame(width: 7, height: 7)
            } else {
                Circle().fill(Color(.backgroundPrimary))
                Circle().strokeBorder(Color(.borderButtonHover), lineWidth: 1)
            }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Icon tiles

/// Large rounded tile holding an SF Symbol (onboarding headers, schema).
struct SymbolTile: View {
    let symbol: String
    var size: CGFloat = 56
    var tint: Color = Color(.iconPrimary)
    var background: Color = Color(.backgroundSecondary)

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color(.borderButton), lineWidth: 1))
    }
}

/// Selectable tile in the device icon grid.
struct SymbolChoice: View {
    let symbol: String
    let selected: Bool
    var badge: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(selected ? Color(.ghostForeground) : Color(.iconPrimary))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .fill(selected ? Color(.selectionBackground) : (hovering ? Color(.backgroundPrimaryHover) : Color(.backgroundPrimary)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .strokeBorder(selected ? Color(.accent500) : Color(.borderButton), lineWidth: selected ? 1.5 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(.ghostForeground))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(.ghostBackground)))
                            .offset(x: -4, y: 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Text input

/// boardui input: 36 px, radius 10, 1 px border, accent ring when focused.
struct RTextField: View {
    let placeholder: String
    @Binding var text: String
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.rBody)
            .foregroundStyle(Color(.textPrimary))
            .focused($focused)
            .onSubmit(onCommit)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color(.backgroundPrimary)))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(focused ? Color(.accent500) : Color(.borderButton), lineWidth: focused ? 1.5 : 1)
            )
            .shadowXS()
            .animation(Motion.quick, value: focused)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onCommit() }
            }
    }
}

// MARK: - Checklist status

struct CheckStatusIcon: View {
    enum Status { case ok, failed, warning, pending }
    let status: Status

    var body: some View {
        Group {
            switch status {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(.successForeground))
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color(.errorForeground))
            case .warning:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color(.warningForeground))
            case .pending:
                ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 17))
        .frame(width: 20, height: 20)
        .contentTransition(.symbolEffect(.replace))
    }
}

// MARK: - Toast

/// "Enregistré" / "Copié" pill that rises in and drifts away.
struct Toast: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(.successForeground))
            Text(text)
                .font(.rBody2Medium)
                .foregroundStyle(Color(.textPrimary))
        }
        .padding(.leading, 7)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color(.backgroundPrimary)))
        .overlay(Capsule().strokeBorder(Color(.borderButton), lineWidth: 1))
        .shadowCard()
    }
}

/// Shows a toast for 2 s. Usage: `.toast(text: $toast)`.
extension View {
    func toast(_ text: Binding<String?>) -> some View {
        modifier(ToastModifier(text: text))
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var text: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            ZStack {
                if let text {
                    Toast(text: text)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 12)).combined(with: .scale(scale: 0.9)),
                            removal: .opacity.combined(with: .offset(y: -10)).combined(with: .scale(scale: 0.9))
                        ))
                }
            }
            .padding(.bottom, 20)
            .animation(.easeOut(duration: 0.2), value: text)
            .allowsHitTesting(false)
        }
        .onChange(of: text) { _, newValue in
            guard newValue != nil else { return }
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                text = nil
            }
        }
    }
}
