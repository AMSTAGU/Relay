import SwiftUI

/// Name and icon of this Mac, as shown in every Mac's menu.
struct IdentityEditor: View {
    @Environment(SwitchCoordinator.self) private var coordinator
    @Environment(Store.self) private var store
    var onSaved: () -> Void = {}

    @State private var name = ""
    private let symbols = DeviceSymbols.available
    private let suggested = DeviceSymbols.suggested

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel("Nom")
                RTextField(placeholder: SystemInfo.computerName, text: $name, onCommit: save)
            }

            VStack(alignment: .leading, spacing: 8) {
                FieldLabel("Icône")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(symbols, id: \.self) { symbol in
                        SymbolChoice(
                            symbol: symbol,
                            selected: store.identity.symbol == symbol,
                            badge: symbol == suggested ? "Suggéré" : nil
                        ) {
                            guard store.identity.symbol != symbol else { return }
                            coordinator.setIdentity(symbol: symbol)
                            onSaved()
                        }
                    }
                }
            }
        }
        .onAppear { name = store.identity.name }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            name = store.identity.name
            return
        }
        guard trimmed != store.identity.name else { return }
        coordinator.setIdentity(name: trimmed)
        onSaved()
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.rBody2Medium)
            .foregroundStyle(Color(.textSecondary))
    }
}
