import SwiftUI

/// Paired audio devices as selectable cards, with help when the speaker is missing.
struct SpeakerPicker: View {
    @Environment(SpeakerController.self) private var speaker
    @Environment(SwitchCoordinator.self) private var coordinator
    @Environment(Store.self) private var store
    @Environment(Permissions.self) private var permissions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var maxListHeight: CGFloat = 240
    @State private var devices: [SpeakerController.Device] = []
    @State private var showAll = false
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if permissions.bluetooth != .allowed {
                Notice(tone: .warning, title: "Autorisez d’abord le Bluetooth", message: "Sans cet accès, Relay ne peut pas voir vos appareils.") {
                    Button("Ouvrir les réglages") { SystemSettingsLink.bluetoothPrivacy.open() }
                        .buttonStyle(.r(.secondary, .small))
                }
            } else if let current = store.speaker, !speaker.isPaired(current.address) {
                Notice(
                    tone: .warning,
                    title: "« \(current.name) » n’est pas encore appairée avec ce Mac",
                    message: "Votre groupe utilise cette enceinte. Mettez-la en mode appairage, puis connectez-la une fois depuis Réglages Système › Bluetooth. Elle apparaîtra ensuite ici."
                ) {
                    Button("Ouvrir les réglages Bluetooth") { SystemSettingsLink.bluetooth.open() }
                        .buttonStyle(.r(.secondary, .small))
                }
            }

            if devices.isEmpty {
                Notice(
                    tone: .neutral,
                    title: showAll ? "Aucun appareil appairé avec ce Mac" : "Aucune enceinte ni casque appairé avec ce Mac",
                    message: "Appairez votre enceinte dans Réglages Système › Bluetooth, puis revenez ici."
                )
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(devices) { device in
                            deviceCard(device)
                        }
                    }
                    .padding(2)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: maxListHeight)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    reload()
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.r(.secondary, .small))

                Button("Réglages Bluetooth") { SystemSettingsLink.bluetooth.open() }
                    .buttonStyle(.r(.secondary, .small))

                Spacer()

                Button(showAll ? "Audio uniquement" : "Tous les appareils") {
                    showAll.toggle()
                    reload()
                }
                .buttonStyle(.rPlain)
            }

            DisclosureRow(title: "Mon enceinte n’apparaît pas", isExpanded: $showHelp) {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Allumez l’enceinte et mettez-la en mode appairage (souvent en maintenant son bouton Bluetooth).")
                    step(2, "Ouvrez Réglages Système › Bluetooth et cliquez sur « Se connecter » à côté de l’enceinte.")
                    step(3, "Revenez ici et cliquez sur « Actualiser ». À faire une seule fois par Mac.")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func deviceCard(_ device: SpeakerController.Device) -> some View {
        let selected = store.speaker?.address == device.address
        return ChoiceCard(
            title: device.name,
            subtitle: device.address.uppercased(),
            selected: selected,
            action: { coordinator.setSpeaker(SpeakerInfo(address: device.address, name: device.name)) }
        ) {
            Image(systemName: device.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color(.iconSecondary))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Color(.backgroundTertiary)))
        } trailing: {
            if device.isConnected { Pill(text: "Connectée", tone: .success) }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.rCaptionSemibold)
                .foregroundStyle(Color(.textSecondary))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(.backgroundTertiary)))
            Text(text)
                .font(.rBody2)
                .foregroundStyle(Color(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reload() {
        guard permissions.bluetooth == .allowed else {
            devices = []
            return
        }
        let fresh = speaker.pairedDevices(includeAll: showAll)
        if fresh != devices {
            withAnimation(reduceMotion ? nil : Motion.quick) { devices = fresh }
        }
    }
}

/// A title that expands to reveal content, with a rotating chevron.
struct DisclosureRow<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(Motion.panel(reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title).font(.rBody2Medium)
                }
                .foregroundStyle(Color(.textSecondary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .padding(.leading, 16)
                    .transition(.rise(reduceMotion))
            }
        }
    }
}
