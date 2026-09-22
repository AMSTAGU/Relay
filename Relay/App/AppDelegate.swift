import AppKit
import Observation
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let permissions = Permissions()
    let speaker = SpeakerController()
    private(set) lazy var peers = PeerService(store: store)
    private(set) lazy var coordinator = SwitchCoordinator(store: store, speaker: speaker, peers: peers, permissions: permissions)
    private(set) lazy var windows = WindowManager(app: self)
    private var statusItem: StatusItemController?
    private var suggester: HandoffSuggester?
    private var handoffPanel: HandoffPanelController?
    private var shownPairingHost: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Relay \(SystemInfo.appVersion, privacy: .public) starting")
        installMainMenu()
        #if DEBUG
        if SelfTest.requested {
            Task {
                let ok = await SelfTest.run()
                print(ok ? "ALL PASSED" : "SOME FAILED")
                exit(ok ? 0 : 1)
            }
            return
        }
        #endif
        coordinator.start()
        #if DEBUG
        if Snapshots.requested {
            Snapshots.render(app: self)
            return
        }
        #endif
        let statusItem = StatusItemController(coordinator: coordinator, windows: windows)
        self.statusItem = statusItem

        // Offer to bring the speaker here when media starts playing on this Mac.
        let suggester = HandoffSuggester(coordinator: coordinator)
        self.suggester = suggester
        handoffPanel = HandoffPanelController(suggester: suggester) { [weak statusItem] in statusItem?.anchorFrame }
        suggester.start()

        if store.settings.onboardingCompleted {
            coordinator.startNetworking()
        } else {
            windows.showOnboarding()
        }

        // A Mac asking to pair with this one: show the code.
        observeChanges { [weak self] in
            guard let self, let host = self.peers.activeHost, host.id != self.shownPairingHost else { return }
            self.shownPairingHost = host.id
            Task { self.windows.showPairingCode(host) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching Relay again from the Finder opens the settings.
        if !flag { store.settings.onboardingCompleted ? windows.showSettings() : windows.showOnboarding() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        peers.stop()
    }

    func completeOnboarding() {
        store.update { $0.onboardingCompleted = true }
        coordinator.startNetworking()
    }

    func resetEverything() async {
        await coordinator.resetEverything()
        windows.closeAll()
        coordinator.startBluetoothIfAllowed()
        windows.showOnboarding()
    }

    /// Agent apps have no visible menu bar, but text fields still need the
    /// standard Edit shortcuts (copy, paste, undo…) to work.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quitter Relay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Fenêtre")
        window.addItem(withTitle: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
