import AppKit
import ServiceManagement
import SwiftUI

/// boardui settings layout: a secondary-surface rail on the left, the page on the right.
struct SettingsView: View {
    @Environment(WindowManager.self) private var windows
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toast: String?
    @State private var scrolled = false

    /// The rail header and the page header sit on one line, below the traffic lights.
    private static let headerTop: CGFloat = 44
    private static let headerHeight: CGFloat = 40

    var body: some View {
        @Bindable var windows = windows
        HStack(spacing: 0) {
            rail
            VStack(spacing: 0) {
                HStack {
                    Text(title(windows.settingsPage))
                        .font(.rTitle3)
                        .foregroundStyle(Color(.textPrimary))
                    Spacer()
                    CloseButton { NSApp.keyWindow?.close() }
                }
                // Same line as the icon + "Relay" block of the rail.
                .frame(height: Self.headerHeight)
                .padding(.horizontal, 32)
                .padding(.top, Self.headerTop)
                .padding(.bottom, 14)

                ScrollView {
                    page(windows.settingsPage)
                        .id(windows.settingsPage)
                        .transition(.opacity)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: ScrollOffsetKey.self, value: proxy.frame(in: .named("scroll")).minY)
                        })
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(ScrollOffsetKey.self) { offset in
                    let isScrolled = offset < -1
                    if isScrolled != scrolled { scrolled = isScrolled }
                }
                .overlay(alignment: .top) {
                    // Rows dissolve under the title instead of cutting sharply.
                    LinearGradient(colors: [Color(.backgroundFull), Color(.backgroundFull).opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                        .opacity(scrolled ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: scrolled)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 820, height: 580)
        .background(Color(.backgroundFull))
        .toast($toast)
        .animation(Motion.quick, value: windows.settingsPage)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AppIconImage(size: Self.headerHeight)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Relay")
                        .font(.rHeadline)
                        .foregroundStyle(Color(.textPrimary))
                    Text("Réglages")
                        .font(.rBody2)
                        .foregroundStyle(Color(.textSecondary))
                }
            }
            .frame(height: Self.headerHeight)
            .padding(.leading, 2)
            .padding(.bottom, 12)
            VStack(spacing: 2) {
                ForEach(WindowManager.SettingsPage.allCases) { page in
                    RailItem(title: title(page), symbol: symbol(page), selected: windows.settingsPage == page) {
                        windows.settingsPage = page
                    }
                }
            }
            Spacer()
            RailItem(title: "Aide et prérequis", symbol: "questionmark.circle", selected: false) {
                windows.showHelp()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, Self.headerTop)
        .padding(.bottom, 12)
        .frame(width: 230)
        .frame(maxHeight: .infinity)
        .background(Color(.backgroundSecondary))
        .overlay(alignment: .trailing) { Rectangle().fill(Color(.hairline)).frame(width: 1) }
    }

    @ViewBuilder private func page(_ page: WindowManager.SettingsPage) -> some View {
        switch page {
        case .general: GeneralPage()
        case .thisMac: IdentityEditor { toast = "Enregistré" }
        case .group: PairingPanel(allowsRemoval: true)
        case .speaker: SpeakerPage()
        case .advanced: AdvancedPage()
        }
    }

    private func title(_ page: WindowManager.SettingsPage) -> String {
        switch page {
        case .general: "Général"
        case .thisMac: "Ce Mac"
        case .group: "Mac du groupe"
        case .speaker: "Enceinte"
        case .advanced: "Avancé"
        }
    }

    private func symbol(_ page: WindowManager.SettingsPage) -> String {
        switch page {
        case .general: "gearshape"
        case .thisMac: DeviceSymbols.resolved("laptopcomputer")
        case .group: "person.2"
        case .speaker: "hifispeaker"
        case .advanced: "slider.horizontal.3"
        }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct RailItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(.iconSecondary))
                    .frame(width: 20)
                Text(title)
                    .font(.rBodyMedium)
                    .foregroundStyle(selected ? Color(.textPrimary) : Color(.textSecondary))
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(selected ? Color(.backgroundSecondaryHover) : (hovering ? Color(.backgroundSecondaryHover).opacity(0.6) : .clear))
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

// MARK: - Pages

private struct GeneralPage: View {
    @Environment(SwitchCoordinator.self) private var coordinator
    @Environment(Store.self) private var store
    @Environment(Permissions.self) private var permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Démarrage et veille")
                SettingsCard {
                    SettingsRow(title: "Ouvrir Relay à l’ouverture de session", description: "Pour que vos autres Mac puissent toujours joindre celui-ci.") {
                        Toggle("", isOn: Binding(
                            get: { permissions.launchAtLogin },
                            set: { permissions.setLaunchAtLogin($0) }
                        ))
                        .toggleStyle(.rSwitch)
                        .labelsHidden()
                    }
                    SettingsRow(title: "Libérer l’enceinte quand ce Mac se met en veille", description: "Elle reste alors disponible pour vos autres appareils.") {
                        Toggle("", isOn: Binding(
                            get: { store.settings.releaseOnSleep },
                            set: { coordinator.setReleaseOnSleep($0) }
                        ))
                        .toggleStyle(.rSwitch)
                        .labelsHidden()
                    }
                    SettingsRow(
                        title: "Proposer l’enceinte quand ce Mac joue du son",
                        description: "Si une vidéo ou de la musique démarre ici alors que l’enceinte est sur un autre Mac. « Pas maintenant » met la question en pause 30 minutes."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { store.settings.suggestHandoff },
                            set: { enabled in coordinator.store.update { $0.suggestHandoff = enabled } }
                        ))
                        .toggleStyle(.rSwitch)
                        .labelsHidden()
                    }
                }
                if permissions.loginItem == .requiresApproval {
                    Notice(tone: .warning, title: "macOS demande votre accord", message: "Autorisez Relay dans Réglages Système › Général › Ouverture.") {
                        Button("Ouvrir les réglages") { SystemSettingsLink.loginItems.open() }
                            .buttonStyle(.r(.secondary, .small))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("En ce moment")
                SettingsCard {
                    SettingsRow(title: "Enceinte", icon: "hifispeaker") {
                        ValueText(store.speaker?.name ?? "Aucune")
                    }
                    SettingsRow(title: "Connectée à", icon: "dot.radiowaves.left.and.right") {
                        ValueText(holderText)
                    }
                    SettingsRow(title: "Ce Mac est verrouillé", description: "Un Mac verrouillé refuse que macOS lui reconnecte l’enceinte tout seul.", icon: "lock") {
                        ValueText(store.isLocked ? "Oui" : "Non")
                    }
                }
            }
        }
        .onAppear { permissions.refresh() }
    }

    private var holderText: String {
        if let holder = coordinator.holderID { return coordinator.identity(of: holder).name }
        return coordinator.isReleasedForPhone ? "Aucun Mac (iPhone)" : "Aucun Mac"
    }
}

private struct ValueText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.rBody)
            .foregroundStyle(Color(.textSecondary))
            .lineLimit(1)
    }
}

private struct SpeakerPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("L’enceinte est partagée par tout le groupe : la changer ici la change sur tous vos Mac.")
                .font(.rBody2)
                .foregroundStyle(Color(.textSecondary))
            SpeakerPicker(maxListHeight: 300)
        }
    }
}

private struct AdvancedPage: View {
    @Environment(\.appActions) private var actions
    @State private var confirmReset = false
    @State private var resetting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Réinitialisation")
            SettingsCard {
                SettingsRow(
                    title: "Réinitialiser Relay",
                    description: "Ce Mac quitte le groupe, oublie l’enceinte et ses réglages, puis l’assistant se relance.",
                    icon: "arrow.counterclockwise"
                ) {
                    Button(resetting ? "Réinitialisation…" : "Réinitialiser") { confirmReset = true }
                        .buttonStyle(.r(.danger, .small))
                        .disabled(resetting)
                }
            }
        }
        .confirmationDialog("Réinitialiser Relay sur ce Mac ?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Réinitialiser", role: .destructive) {
                resetting = true
                Task {
                    await actions.resetEverything()
                    resetting = false
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Vos autres Mac seront prévenus. L’appairage Bluetooth de l’enceinte n’est pas touché.")
        }
    }
}
