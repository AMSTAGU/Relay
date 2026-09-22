import ServiceManagement
import SwiftUI

struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, bluetooth, speaker, thisMac, otherMacs, launch, test
    }

    @Environment(SwitchCoordinator.self) private var coordinator
    @Environment(Store.self) private var store
    @Environment(Permissions.self) private var permissions
    @Environment(PeerService.self) private var peers
    @Environment(WindowManager.self) private var windows
    @Environment(\.appActions) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Step
    @State private var speakerLater = false
    @State private var launchAtLogin = true

    init(initialStep: Step = .welcome) {
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(count: Step.allCases.count, current: step.rawValue)
                .padding(.top, 22)

            ZStack(alignment: .top) {
                content
                    .id(step)
                    .transition(.rise(reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 48)
            .padding(.top, 28)
            .clipped()

            footer
        }
        .frame(width: 640, height: 600)
        .background(Color(.backgroundFull))
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .bluetooth: BluetoothStep()
        case .speaker: SpeakerStep(speakerLater: $speakerLater)
        case .thisMac: ThisMacStep()
        case .otherMacs: OtherMacsStep()
        case .launch: LaunchStep(launchAtLogin: $launchAtLogin)
        case .test: TestStep()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if step != .welcome {
                Button("Retour") { go(-1) }
                    .buttonStyle(.rPlain)
            }
            Spacer()
            Button(primaryTitle) { advance() }
                .buttonStyle(.rPrimary)
                .disabled(!canContinue)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Color(.hairline)).frame(height: 1) }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Commencer"
        case .otherMacs: store.peers.isEmpty ? "Plus tard" : "Continuer"
        case .test: "Terminer"
        default: "Continuer"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .bluetooth: permissions.bluetooth == .allowed
        case .speaker: store.speaker != nil || speakerLater
        case .thisMac: !store.identity.name.trimmingCharacters(in: .whitespaces).isEmpty
        default: true
        }
    }

    private func advance() {
        switch step {
        case .launch:
            if launchAtLogin != permissions.launchAtLogin { permissions.setLaunchAtLogin(launchAtLogin) }
        case .test:
            actions.completeOnboarding()
            windows.closeOnboarding()
            return
        default:
            break
        }
        go(1)
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(Motion.panel(reduceMotion)) { step = next }
    }
}

// MARK: - Chrome

private struct StepIndicator: View {
    let count: Int
    let current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Color(.accent500) : Color(.backgroundTertiary))
                    .frame(width: index == current ? 20 : 6, height: 6)
            }
        }
        .animation(Motion.panel(reduceMotion), value: current)
        .accessibilityElement()
        .accessibilityLabel("Étape \(current + 1) sur \(count)")
    }
}

/// Icon tile, title and one-line explanation at the top of each step.
struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SymbolTile(symbol: symbol, size: 48)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.rTitle1)
                    .foregroundStyle(Color(.textPrimary))
                Text(subtitle)
                    .font(.rBody)
                    .foregroundStyle(Color(.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 1. Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer(minLength: 0)
            Schema()
            VStack(spacing: 10) {
                Text("Une enceinte, tous vos appareils")
                    .font(.rTitle1)
                    .foregroundStyle(Color(.textPrimary))
                Text("Votre enceinte Bluetooth ne se connecte qu’à un appareil à la fois. Relay la fait passer d’un Mac à l’autre — ou la libère pour votre iPhone — en un clic depuis la barre des menus.")
                    .font(.rBody)
                    .foregroundStyle(Color(.textSecondary))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 28)
    }
}

/// Mac ⇄ speaker ⇄ Mac, with the iPhone underneath.
private struct Schema: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                SymbolTile(symbol: DeviceSymbols.resolved("macbook"), size: 64)
                link
                SymbolTile(symbol: "hifispeaker.fill", size: 84, tint: Color(.accent500), background: Color(.selectionBackground))
                link
                SymbolTile(symbol: DeviceSymbols.resolved("macmini"), size: 64)
            }
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(.iconTertiary))
            SymbolTile(symbol: "iphone", size: 48)
        }
        .accessibilityElement()
        .accessibilityLabel("Une enceinte partagée entre un MacBook, un Mac mini et un iPhone")
    }

    private var link: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(.iconTertiary))
    }
}

// MARK: - 2. Bluetooth

private struct BluetoothStep: View {
    @Environment(Permissions.self) private var permissions
    @Environment(SwitchCoordinator.self) private var coordinator
    @Environment(SpeakerController.self) private var speaker

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(
                symbol: "dot.radiowaves.left.and.right",
                title: "Autoriser le Bluetooth",
                subtitle: "Relay en a besoin pour connecter et déconnecter votre enceinte. Il ne fait rien d’autre avec."
            )

            switch permissions.bluetooth {
            case .notDetermined:
                Button("Autoriser le Bluetooth") { permissions.requestBluetooth() }
                    .buttonStyle(.rPrimary)
            case .allowed:
                if permissions.bluetoothPoweredOn == false {
                    Notice(tone: .warning, title: "Le Bluetooth est désactivé", message: "Activez-le pour que Relay puisse piloter l’enceinte.") {
                        Button("Ouvrir les réglages Bluetooth") { SystemSettingsLink.bluetooth.open() }
                            .buttonStyle(.r(.secondary, .small))
                    }
                } else {
                    Notice(tone: .success, title: "Accès au Bluetooth autorisé", message: "Tout est en ordre, vous pouvez continuer.")
                }
            case .denied:
                Notice(
                    tone: .error,
                    title: "L’accès au Bluetooth a été refusé",
                    message: "Activez Relay dans Réglages Système › Confidentialité et sécurité › Bluetooth, puis revenez ici."
                ) {
                    Button("Ouvrir les réglages") { SystemSettingsLink.bluetoothPrivacy.open() }
                        .buttonStyle(.r(.secondary, .small))
                }
            }
        }
        .task {
            while !Task.isCancelled {
                coordinator.startBluetoothIfAllowed()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: - 3. Speaker

private struct SpeakerStep: View {
    @Binding var speakerLater: Bool
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(
                symbol: "hifispeaker",
                title: "Choisissez votre enceinte",
                subtitle: "Voici les enceintes et casques appairés avec ce Mac. L’enceinte doit être appairée une fois avec chacun de vos Mac."
            )
            SpeakerPicker(maxListHeight: 200)

            if store.speaker == nil {
                Button {
                    speakerLater = true
                } label: {
                    Label(
                        speakerLater
                            ? "D’accord : l’enceinte sera récupérée en rejoignant votre groupe."
                            : "Relay tourne déjà sur un autre Mac ? Rejoignez son groupe à l’étape suivante.",
                        systemImage: speakerLater ? "checkmark" : "arrow.turn.down.right"
                    )
                    .font(.rBody2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(speakerLater ? Color(.successForeground) : Color(.ghostForeground))
                .disabled(speakerLater)
            }
        }
    }
}

// MARK: - 4. This Mac

private struct ThisMacStep: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(
                symbol: DeviceSymbols.resolved(store.identity.symbol),
                title: "Ce Mac",
                subtitle: "Donnez-lui un nom et une icône : c’est ainsi qu’il apparaîtra dans le menu de vos autres Mac."
            )
            IdentityEditor()
        }
    }
}

// MARK: - 5. Other Macs

private struct OtherMacsStep: View {
    @Environment(SwitchCoordinator.self) private var coordinator
    @Environment(Store.self) private var store
    @Environment(SpeakerController.self) private var speaker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StepHeader(
                    symbol: "network",
                    title: "Vos autres Mac",
                    subtitle: "Ouvrez Relay sur vos autres Mac, sur le même réseau, puis appairez-les avec un code à 6 chiffres. Vous pourrez aussi le faire plus tard dans les réglages."
                )

                if let current = store.speaker, !speaker.isPaired(current.address) {
                    Notice(
                        tone: .warning,
                        title: "« \(current.name) » n’est pas appairée avec ce Mac",
                        message: "C’est l’enceinte de votre groupe. Mettez-la en mode appairage et connectez-la une fois depuis Réglages Système › Bluetooth."
                    ) {
                        Button("Ouvrir les réglages Bluetooth") { SystemSettingsLink.bluetooth.open() }
                            .buttonStyle(.r(.secondary, .small))
                    }
                }

                PairingPanel()
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .onAppear { coordinator.startNetworking() }
    }
}

// MARK: - 6. Launch at login

private struct LaunchStep: View {
    @Binding var launchAtLogin: Bool
    @Environment(Permissions.self) private var permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(
                symbol: "power",
                title: "Lancement au démarrage",
                subtitle: "Pour que vos autres Mac puissent toujours lui passer ou lui reprendre l’enceinte, Relay doit tourner en permanence."
            )
            SettingsCard {
                SettingsRow(title: "Ouvrir Relay à l’ouverture de session", description: "Recommandé. Relay reste discret dans la barre des menus.") {
                    Toggle("", isOn: $launchAtLogin).toggleStyle(.rSwitch).labelsHidden()
                }
            }
            if permissions.loginItem == .requiresApproval {
                Notice(tone: .warning, title: "macOS demande votre accord", message: "Autorisez Relay dans Réglages Système › Général › Ouverture.") {
                    Button("Ouvrir les réglages") { SystemSettingsLink.loginItems.open() }
                        .buttonStyle(.r(.secondary, .small))
                }
            }
        }
    }
}

// MARK: - 7. Test

private struct TestStep: View {
    @Environment(SwitchCoordinator.self) private var coordinator
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var running = false
    @State private var result: (ok: Bool, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(
                symbol: "checkmark.seal",
                title: "Tout est prêt",
                subtitle: store.speaker.map { "Faites un essai : Relay va amener « \($0.name) » sur ce Mac et y envoyer le son." }
                    ?? "Choisissez une enceinte dans les réglages ou rejoignez un groupe pour pouvoir tester."
            )

            Button {
                Task {
                    running = true
                    result = nil
                    let outcome = await coordinator.runTest()
                    withAnimation(Motion.panel(reduceMotion)) { result = outcome }
                    running = false
                }
            } label: {
                HStack(spacing: 8) {
                    if running { ProgressView().controlSize(.small).tint(.white) }
                    Text(running ? "Bascule en cours…" : "Tester la bascule")
                }
            }
            .buttonStyle(.rPrimary)
            .disabled(running || store.speaker == nil)

            if let result {
                Notice(
                    tone: result.ok ? .success : .error,
                    title: result.ok ? "Ça marche !" : "La bascule n’a pas abouti",
                    message: result.message
                )
                .transition(.rise(reduceMotion))
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Au quotidien")
                SettingsCard {
                    SettingsRow(title: "Clic sur l’icône", description: "Choisissez le Mac qui doit avoir l’enceinte, ou « Aucun Mac » pour l’iPhone.", icon: "cursorarrow.click")
                    SettingsRow(title: "Clic droit sur l’icône", description: "Passe l’enceinte à l’appareil suivant : chaque Mac à tour de rôle, puis l’iPhone, et on recommence.", icon: "cursorarrow.click.2")
                }
            }
        }
    }
}
