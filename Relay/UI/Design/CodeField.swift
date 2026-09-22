import SwiftUI

/// Six digit boxes (3 + 3) backed by one hidden field, so typing, Backspace
/// and pasting a whole code all just work. Digits are monospaced so the boxes
/// stay optically even.
struct CodeField: View {
    @Binding var code: String
    var isInvalid = false
    var isDisabled = false
    var onComplete: (String) -> Void = { _ in }

    static let length = 6
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .textFieldStyle(.plain)
                .focused($focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .disabled(isDisabled)
                .accessibilityLabel("Code d’appairage")
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(Self.length))
                    if digits != newValue { code = digits }
                    if digits.count == Self.length { onComplete(digits) }
                }

            HStack(spacing: 8) {
                ForEach(0..<Self.length, id: \.self) { index in
                    box(index)
                    if index == 2 {
                        Rectangle()
                            .fill(Color(.borderButtonHover))
                            .frame(width: 8, height: 2)
                            .padding(.horizontal, 2)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .onAppear { focused = true }
    }

    private func box(_ index: Int) -> some View {
        let characters = Array(code)
        let digit = index < characters.count ? String(characters[index]) : ""
        let isCurrent = focused && !isDisabled && index == min(code.count, Self.length - 1)
        let border: Color = isInvalid ? Color(.errorForeground) : (isCurrent ? Color(.accent500) : Color(.borderButton))

        return Text(digit)
            .font(.rCode)
            .foregroundStyle(isDisabled ? Color(.textTertiary) : Color(.textPrimary))
            .frame(width: 44, height: 54)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color(.backgroundPrimary)))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(border, lineWidth: isCurrent || isInvalid ? 1.5 : 1)
            )
            .shadowXS()
            .animation(Motion.quick, value: isCurrent)
    }
}

/// The code as the host shows it: large digits, 3 + 3.
struct CodeDisplay: View {
    let code: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(.rCode)
                    .foregroundStyle(Color(.textPrimary))
                    .frame(width: 44, height: 54)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color(.backgroundSecondary)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color(.borderButton), lineWidth: 1))
                if index == 2 {
                    Rectangle().fill(Color(.borderButtonHover)).frame(width: 8, height: 2).padding(.horizontal, 2)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Code : \(code.map(String.init).joined(separator: " "))")
    }
}
