import SwiftUI

/// The group: members with their status, Macs nearby, and the joiner's code entry.
struct PairingPanel: View {
    @Environment(PeerService.self) private var peers
    @Environment(SwitchCoordinator.self) private var coordinator
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var allowsRemoval = false
    @State private var joiner: PairingJoiner?
    @State private var pendingRemoval: DeviceIdentity?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if peers.localNetworkDenied {
                Notice(
                    tone: .error,
                    title: "Relay n’a pas accès au réseau local",
                    message: "Sans cette autorisation, vos Mac ne peuvent pas se trouver. Activez Relay dans Réglages Système › Confidentialité et sécurité › Réseau local."
                ) {
                    Button("Ouvrir les réglages") { SystemSettingsLink.localNetworkPrivacy.open() }
                        .buttonStyle(.r(.secondary, .small))
                }
            }

            ZStack(alignment: .top) {
                if let joiner {
                    JoinFlow(joiner: joiner) { self.joiner = nil } retry: { startJoin(with: joiner.host.id) }
                        .transition(.rise(reduceMotion))
                } else {
                    lists.transition(.rise(reduceMotion))
                }
            }
            .animation(Motion.panel(reduceMotion), value: joiner == nil)
        }
        .confirmationDialog(
            "Retirer « \(pendingRemoval?.name ?? "") » du groupe ?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Retirer", role: .destructive) {
                if let member = pendingRemoval { Task { await coordinator.removeMember(member.id) } }
                pendingRemoval = nil
            }
            Button("Annuler", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Ce Mac ne pourra plus piloter l’enceinte. Vous pourrez l’appairer de nouveau plus tard.")
        }
    }

    private var lists: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Mac du groupe")
                SettingsCard {
                    memberRow(store.identity, isSelf: true)
                    ForEach(store.peers.sorted { $0.name < $1.name }) { member in
                        memberRow(member, isSelf: false)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Mac à proximité")
                if peers.strangers.isEmpty {
                    SettingsCard {
                        HStack(spacing: 10) {
                            DotsLoader()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recherche des Mac qui ont Relay…")
                                    .font(.rBody)
                                    .foregroundStyle(Color(.textPrimary))
                                Text("Ouvrez Relay sur vos autres Mac, connectés au même réseau.")
                                    .font(.rBody2)
                                    .foregroundStyle(Color(.textSecondary))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .padding(.trailing, 12)
                    }
                } else {
                    SettingsCard {
                        ForEach(peers.strangers) { peer in
                            SettingsRow(title: peer.name, description: "Pas encore dans votre groupe", icon: peer.symbol) {
                                Button("Appairer") { startJoin(with: peer.id) }
                                    .buttonStyle(.r(.ghost, .small))
                            }
                        }
                    }
                }
            }
        }
    }

    private func memberRow(_ member: DeviceIdentity, isSelf: Bool) -> some View {
        let identity = coordinator.identity(of: member.id)
        let online = isSelf || peers.isOnline(member.id)
        return SettingsRow(
            title: identity.name,
            description: isSelf ? "Ce Mac" : (online ? "En ligne" : "Hors ligne"),
            icon: DeviceSymbols.resolved(identity.symbol)
        ) {
            HStack(spacing: 12) {
                if coordinator.holderID == member.id { Pill(text: "A l’enceinte", tone: .accent) }
                StatusDot(tone: online ? .online : .offline)
                if allowsRemoval && !isSelf {
                    Button("Retirer") { pendingRemoval = identity }
                        .buttonStyle(.r(.secondary, .small))
                }
            }
        }
    }

    private func startJoin(with id: String) {
        joiner?.cancel()
        guard let peer = peers.discovered[id] else { return }
        let session = peers.beginPairing(with: peer)
        session.onWelcome = { snapshot, key in
            Task { await coordinator.joinGroup(snapshot, key: key) }
        }
        session.start()
        joiner = session
    }
}

/// Joiner side: type the code shown on the other Mac.
private struct JoinFlow: View {
    let joiner: PairingJoiner
    let close: () -> Void
    let retry: () -> Void
    @State private var code = ""

    var body: some View {
        VStack(spacing: 18) {
            SymbolTile(symbol: DeviceSymbols.resolved(joiner.host.symbol), size: 48)

            switch joiner.phase {
            case .connecting:
                title("Connexion à « \(joiner.host.name) »…")
                DotsLoader()
                cancelButton

            case .waitingForCode, .verifying:
                title("Saisissez le code affiché sur « \(joiner.host.name) »")
                CodeField(code: $code, isDisabled: joiner.phase == .verifying) { joiner.submit($0) }
                if joiner.phase == .verifying {
                    HStack(spacing: 8) {
                        DotsLoader()
                        Text("Vérification…").font(.rBody2).foregroundStyle(Color(.textSecondary))
                    }
                } else {
                    Text("Le code vient d’apparaître sur l’écran de l’autre Mac.")
                        .font(.rBody2)
                        .foregroundStyle(Color(.textSecondary))
                }
                cancelButton

            case .succeeded:
                Notice(tone: .success, title: "Appairage réussi", message: "Ce Mac fait maintenant partie du groupe de « \(joiner.host.name) ».")
                Button("OK", action: close).buttonStyle(.rPrimary)

            case .failed(let reason):
                Notice(tone: .error, title: "L’appairage n’a pas abouti", message: reason)
                HStack(spacing: 8) {
                    Button("Annuler", action: close).buttonStyle(.rSecondary)
                    Button("Réessayer") {
                        code = ""
                        retry()
                    }
                    .buttonStyle(.rPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color(.backgroundSecondary)))
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.rHeadline)
            .foregroundStyle(Color(.textPrimary))
            .multilineTextAlignment(.center)
    }

    private var cancelButton: some View {
        Button("Annuler") {
            joiner.cancel()
            close()
        }
        .buttonStyle(.rPlain)
    }
}

/// Host side window: shows the code the other Mac must type.
struct PairingCodeView: View {
    let host: PairingHost
    @Environment(WindowManager.self) private var windows
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            SymbolTile(symbol: DeviceSymbols.resolved(host.joiner.symbol), size: 52)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text("« \(host.joiner.name) » veut rejoindre votre groupe")
                    .font(.rTitle3)
                    .foregroundStyle(Color(.textPrimary))
                    .multilineTextAlignment(.center)
                Text("Saisissez ce code sur « \(host.joiner.name) » :")
                    .font(.rBody)
                    .foregroundStyle(Color(.textSecondary))
            }

            ZStack {
                switch host.phase {
                case .showingCode, .verifying:
                    VStack(spacing: 14) {
                        CodeDisplay(code: host.code)
                        if host.phase == .verifying {
                            HStack(spacing: 8) {
                                DotsLoader()
                                Text("Vérification…").font(.rBody2).foregroundStyle(Color(.textSecondary))
                            }
                        } else {
                            Text("Ce code n’est valable qu’une fois, pendant 3 minutes.")
                                .font(.rBody2)
                                .foregroundStyle(Color(.textTertiary))
                        }
                    }
                    .transition(.rise(reduceMotion))
                case .succeeded:
                    Notice(tone: .success, title: "« \(host.joiner.name) » a rejoint le groupe", message: "Il apparaît maintenant dans le menu de Relay.")
                        .transition(.rise(reduceMotion))
                case .failed(let reason):
                    Notice(tone: .error, title: "L’appairage n’a pas abouti", message: reason)
                        .transition(.rise(reduceMotion))
                }
            }
            .animation(Motion.panel(reduceMotion), value: host.phase)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if host.phase == .showingCode || host.phase == .verifying {
                    Button("Refuser") {
                        host.cancel()
                        windows.closePairingCode()
                    }
                    .buttonStyle(.rSecondary)
                } else {
                    Button("Fermer") { windows.closePairingCode() }
                        .buttonStyle(.rPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(width: 420, height: 380)
        .background(Color(.backgroundFull))
        .task(id: host.phase) {
            if host.phase == .succeeded {
                try? await Task.sleep(for: .seconds(3))
                windows.closePairingCode()
            }
        }
    }
}
