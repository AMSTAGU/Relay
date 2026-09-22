import AppKit
import Observation
import SwiftUI

/// Opens the SwiftUI windows (onboarding, settings, help, pairing code) in
/// plain NSWindows, since Relay is a menu bar agent with no scenes.
@Observable
final class WindowManager {
    enum SettingsPage: String, CaseIterable, Identifiable {
        case general, thisMac, group, speaker, advanced
        var id: String { rawValue }
    }

    var settingsPage: SettingsPage = .general

    @ObservationIgnored private unowned let app: AppDelegate
    @ObservationIgnored private var windows: [String: NSWindow] = [:]
    @ObservationIgnored private var closeObservers: [String: NSObjectProtocol] = [:]
    @ObservationIgnored private var pairingHostID: UUID?

    init(app: AppDelegate) {
        self.app = app
    }

    func showOnboarding() {
        show("onboarding", size: NSSize(width: 640, height: 600)) {
            OnboardingView()
        }
    }

    func closeOnboarding() {
        windows["onboarding"]?.close()
    }

    func showSettings(page: SettingsPage? = nil) {
        if let page { settingsPage = page }
        show("settings", size: NSSize(width: 820, height: 580)) {
            SettingsView()
        }
    }

    func showHelp() {
        show("help", size: NSSize(width: 700, height: 660)) {
            HelpView()
        }
    }

    func showPairingCode(_ host: PairingHost) {
        windows["pairing"]?.close()
        pairingHostID = host.id
        let window = show("pairing", size: NSSize(width: 420, height: 380), floating: true) {
            PairingCodeView(host: host)
        }
        window.level = .floating
    }

    func closePairingCode() {
        windows["pairing"]?.close()
    }

    func closeAll() {
        windows.values.forEach { $0.close() }
    }

    @discardableResult
    private func show<Content: View>(_ key: String, size: NSSize, floating: Bool = false, @ViewBuilder content: () -> Content) -> NSWindow {
        if let window = windows[key], key != "pairing" {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return window
        }

        let root = content()
            .environment(app.coordinator)
            .environment(app.store)
            .environment(app.permissions)
            .environment(app.speaker)
            .environment(app.peers)
            .environment(self)
            .environment(\.appActions, AppActions(app: app))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(resource: .backgroundFull)
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.title = switch key {
        case "onboarding": "Bienvenue dans Relay"
        case "settings": "Réglages de Relay"
        case "help": "Aide et prérequis"
        default: "Appairage"
        }
        window.center()

        windows[key] = window
        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowClosed(key) }
        }

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func windowClosed(_ key: String) {
        if let observer = closeObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows[key] = nil
        if key == "pairing", let id = pairingHostID {
            pairingHostID = nil
            app.peers.dismissHostSession(id)
        }
    }
}

/// App-level actions reachable from any SwiftUI view.
struct AppActions {
    fileprivate weak var app: AppDelegate?

    func completeOnboarding() { app?.completeOnboarding() }
    func resetEverything() async { await app?.resetEverything() }
}

private struct AppActionsKey: EnvironmentKey {
    static let defaultValue = AppActions(app: nil)
}

extension EnvironmentValues {
    var appActions: AppActions {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}
