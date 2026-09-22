import AppKit
import ServiceManagement
import SwiftUI

struct HelpView: View {
    @Environment(SwitchCoordinator.self) private var coordinator
    @Environment(Store.self) private var store
    @Environment(Permissions.self) private var permissions
    @Environment(SpeakerController.self) private var speaker
    @Environment(PeerService.self) private var peers
    @Environment(WindowManager.self) private var windows

    /// IOBluetooth state is not observable; tick to re-read it.
    @State private var tick = 0
    @State private var expanded: String?
    @State private var toast: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Aide et prérequis")
                            .font(.rTitle1)
                            .foregroundStyle(Color(.textPrimary))
                        Text("Tout ce dont Relay a besoin, vérifié en direct.")
                            .font(.rBody)
                            .foregroundStyle(Color(.textSecondary))
                    }
                    Spacer()
                    CloseButton { NSApp.keyWindow?.close() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Prérequis")
                    SettingsCard { checklist }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Dépannage")
                    SettingsCard { troubleshooting }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Diagnostic")
                    SettingsCard {
                        SettingsRow(
                            title: "Journal de Relay",
                            description: "Copie les événements de la dernière heure, à joindre à un signalement de problème.",
                            icon: "doc.on.clipboard"
                        ) {
                            Button("Copier les logs") { copyLogs() }
                                .buttonStyle(.r(.secondary, .small))
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 32)
        }
        .frame(width: 700, height: 660)
        .background(Color(.backgroundFull))
        .toast($toast)
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                tick &+= 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Checklist

    @ViewBuilder private var checklist: some View {
        let _ = tick

        // Bluetooth permission
        switch permissions.bluetooth {
        case .allowed:
            CheckRow(status: .ok, title: "Accès au Bluetooth", detail: "Autorisé.")
        case .notDetermined:
            CheckRow(status: .failed, title: "Accès au Bluetooth", detail: "Relay n’a pas encore demandé l’accès.") {
                Button("Autoriser") {
                    permissions.requestBluetooth()
                    coordinator.startBluetoothIfAllowed()
                }
                .buttonStyle(.r(.secondary, .small))
            }
        case .denied:
            CheckRow(status: .failed, title: "Accès au Bluetooth", detail: "Refusé. Activez Relay dans Confidentialité et sécurité › Bluetooth.") {
                Button("Ouvrir les réglages") { SystemSettingsLink.bluetoothPrivacy.open() }
                    .buttonStyle(.r(.secondary, .small))
            }
        }

        // Bluetooth power
        if permissions.bluetooth == .allowed {
            if speaker.isPoweredOn {
                CheckRow(status: .ok, title: "Bluetooth activé", detail: "Le Bluetooth de ce Mac est allumé.")
            } else {
                CheckRow(status: .failed, title: "Bluetooth activé", detail: "Le Bluetooth de ce Mac est éteint.") {
                    Button("Ouvrir les réglages") { SystemSettingsLink.bluetooth.open() }
                        .buttonStyle(.r(.secondary, .small))
                }
            }
        }

        // Speaker paired here
        if let current = store.speaker {
            if permissions.bluetooth == .allowed, speaker.isPaired(current.address) {
                CheckRow(status: .ok, title: "Enceinte appairée avec ce Mac", detail: "« \(current.name) »")
            } else {
                CheckRow(
                    status: .failed,
                    title: "Enceinte appairée avec ce Mac",
                    detail: "« \(current.name) » doit être appairée une fois avec ce Mac : mode appairage sur l’enceinte, puis « Se connecter » dans Réglages Système › Bluetooth."
                ) {
                    Button("Réglages Bluetooth") { SystemSettingsLink.bluetooth.open() }
                        .buttonStyle(.r(.secondary, .small))
                }
            }
        } else {
            CheckRow(status: .failed, title: "Enceinte choisie", detail: "Aucune enceinte n’est encore choisie.") {
                Button("Choisir…") { windows.showSettings(page: .speaker) }
                    .buttonStyle(.r(.secondary, .small))
            }
        }

        // Local network
        if !peers.isRunning {
            CheckRow(status: .warning, title: "Réseau local", detail: "La recherche des autres Mac n’est pas encore lancée.") {
                Button("Lancer") { coordinator.startNetworking() }
                    .buttonStyle(.r(.secondary, .small))
            }
        } else if peers.localNetworkDenied {
            CheckRow(status: .failed, title: "Réseau local", detail: "Refusé. Activez Relay dans Confidentialité et sécurité › Réseau local.") {
                Button("Ouvrir les réglages") { SystemSettingsLink.localNetworkPrivacy.open() }
                    .buttonStyle(.r(.secondary, .small))
            }
        } else {
            CheckRow(status: .ok, title: "Réseau local", detail: "Relay peut communiquer avec vos autres Mac.")
        }

        // Peers
        let members = store.peers
        let onlineCount = members.filter { peers.isOnline($0.id) }.count
        if members.isEmpty {
            CheckRow(status: .warning, title: "Autres Mac", detail: "Aucun autre Mac dans le groupe pour l’instant.") {
                Button("Ajouter un Mac…") { windows.showSettings(page: .group) }
                    .buttonStyle(.r(.secondary, .small))
            }
        } else if onlineCount == members.count {
            CheckRow(status: .ok, title: "Autres Mac trouvés et joignables", detail: "\(onlineCount) sur \(members.count), tous en ligne.")
        } else {
            let offline = members.filter { !peers.isOnline($0.id) }.map { "« \($0.name) »" }.joined(separator: ", ")
            CheckRow(
                status: .warning,
                title: "Autres Mac trouvés et joignables",
                detail: "\(onlineCount) sur \(members.count) en ligne. Hors ligne : \(offline). Vérifiez qu’ils sont allumés, que Relay y tourne, et qu’aucun VPN ne bloque le réseau local."
            ) {
                Button("Relancer la détection") { peers.restart() }
                    .buttonStyle(.r(.secondary, .small))
            }
        }

        // Launch at login
        switch permissions.loginItem {
        case .enabled:
            CheckRow(status: .ok, title: "Lancement au démarrage", detail: "Relay s’ouvre avec votre session.")
        case .requiresApproval:
            CheckRow(status: .warning, title: "Lancement au démarrage", detail: "En attente de votre accord dans Réglages Système › Général › Ouverture.") {
                Button("Ouvrir les réglages") { SystemSettingsLink.loginItems.open() }
                    .buttonStyle(.r(.secondary, .small))
            }
        default:
            CheckRow(status: .failed, title: "Lancement au démarrage", detail: "Désactivé : après un redémarrage, ce Mac ne répondra plus aux autres.") {
                Button("Activer") { permissions.setLaunchAtLogin(true) }
                    .buttonStyle(.r(.secondary, .small))
            }
        }
    }

    // MARK: Troubleshooting

    @ViewBuilder private var troubleshooting: some View {
        TroubleRow(
            id: "vpn",
            expanded: $expanded,
            icon: "network.slash",
            title: "Mes autres Mac sont introuvables ou « hors ligne »",
            text: "Symptôme : les autres Mac restent hors ligne alors qu’ils sont allumés. La cause la plus fréquente est un VPN d’entreprise, un pare-feu ou un réseau « invité » (hôtel, Wi-Fi isolé) qui empêche les appareils de se voir. Déconnectez le VPN (ou demandez à votre service informatique d’autoriser l’accès au réseau local), et vérifiez que tous les Mac sont sur le même réseau. Enfin, vérifiez que Relay est autorisé dans Réglages Système › Confidentialité et sécurité › Réseau local."
        ) {
            Button("Réglages Réseau local") { SystemSettingsLink.localNetworkPrivacy.open() }
                .buttonStyle(.r(.secondary, .small))
        }
        TroubleRow(
            id: "pairing",
            expanded: $expanded,
            icon: "hifispeaker",
            title: "L’enceinte doit être appairée avec chaque Mac",
            text: "Relay ne remplace pas l’appairage Bluetooth. Faites-le une seule fois sur chaque Mac : mettez l’enceinte en mode appairage, puis cliquez sur « Se connecter » dans Réglages Système › Bluetooth. Ensuite, c’est Relay qui gère les connexions."
        ) {
            Button("Réglages Bluetooth") { SystemSettingsLink.bluetooth.open() }
                .buttonStyle(.r(.secondary, .small))
        }
        TroubleRow(
            id: "iphone",
            expanded: $expanded,
            icon: "iphone",
            title: "Utiliser l’enceinte avec l’iPhone",
            text: "Dans le menu de Relay, choisissez « Aucun Mac (libérer pour l’iPhone) » : tous les Mac lâchent l’enceinte et arrêtent de s’y reconnecter. Sur l’iPhone, ouvrez le Centre de contrôle (ou Réglages › Bluetooth) et touchez l’enceinte. Pour la récupérer, choisissez un Mac dans le menu. Astuce : un clic droit sur l’icône fait défiler les appareils (chaque Mac, puis l’iPhone)."
        ) { EmptyView() }
        TroubleRow(
            id: "sticky",
            expanded: $expanded,
            icon: "arrow.triangle.2.circlepath",
            title: "L’enceinte se reconnecte toute seule au mauvais Mac",
            text: "macOS reconnecte automatiquement les appareils audio qu’il connaît. Relay l’en empêche : un Mac qui a lâché l’enceinte se verrouille et la déconnecte aussitôt s’il la reprend de lui-même. Si cela arrive quand même, vérifiez que Relay tourne sur ce Mac (icône dans la barre des menus) et qu’il se lance au démarrage. Choisir ce Mac dans le menu lève le verrou."
        ) {
            Button("Lancement au démarrage") { windows.showSettings(page: .general) }
                .buttonStyle(.r(.secondary, .small))
        }
    }

    private func copyLogs() {
        let group = store.peers.map { "\($0.name) (\(peers.isOnline($0.id) ? "en ligne" : "hors ligne"))" }.joined(separator: ", ")
        let summary = """
        Relay \(SystemInfo.appVersion) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString) — \(SystemInfo.hardwareModel)
        Ce Mac : \(store.identity.name) · verrouillé : \(store.isLocked ? "oui" : "non") · enceinte connectée ici : \(coordinator.localConnected ? "oui" : "non")
        Enceinte : \(store.speaker.map { "\($0.name) \($0.address)" } ?? "aucune")
        Groupe (rév. \(store.group.revision)) : \(group.isEmpty ? "seul" : group)
        Bluetooth : \(permissions.bluetooth) · réseau local refusé : \(peers.localNetworkDenied ? "oui" : "non")
        """
        let text = Log.export(summary: summary)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast = "Logs copiés"
    }
}

/// One checklist line: live status, explanation, and the fix when needed.
private struct CheckRow<Action: View>: View {
    let status: CheckStatusIcon.Status
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CheckStatusIcon(status: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rBody).foregroundStyle(Color(.textPrimary))
                Text(detail)
                    .font(.rBody2)
                    .foregroundStyle(Color(.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
        .frame(minHeight: 52)
        .animation(Motion.quick, value: status)
    }
}

extension CheckRow where Action == EmptyView {
    init(status: CheckStatusIcon.Status, title: String, detail: String) {
        self.init(status: status, title: title, detail: detail) { EmptyView() }
    }
}

/// Expandable troubleshooting entry.
private struct TroubleRow<Action: View>: View {
    let id: String
    @Binding var expanded: String?
    let icon: String
    let title: String
    let text: String
    @ViewBuilder var action: Action
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { expanded == id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.panel(reduceMotion)) { expanded = isOpen ? nil : id }
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(.iconSecondary))
                        .frame(width: 20)
                    Text(title).font(.rBody).foregroundStyle(Color(.textPrimary))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(.iconTertiary))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .frame(minHeight: 52)
                .padding(.trailing, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    Text(text)
                        .font(.rBody2)
                        .foregroundStyle(Color(.textSecondary))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    action
                }
                .padding(.leading, 36)
                .padding(.trailing, 12)
                .padding(.bottom, 14)
                .transition(.rise(reduceMotion))
            }
        }
    }
}
