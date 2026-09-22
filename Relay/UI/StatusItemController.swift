import OSLog
import AppKit

/// The menu bar icon. Left click opens a plain, native NSMenu (the menu stays
/// attached to the status item, so AppKit handles it exactly like a system
/// menu). Right click or control-click is caught before AppKit sees it and
/// moves the speaker to the next device of the menu (each Mac, then "Aucun
/// Mac", and around again) without opening the menu.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let coordinator: SwitchCoordinator
    private let windows: WindowManager
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var menuIsOpen = false
    private var animationTimer: Timer?
    private var animationStart = Date()
    private var currentIcon: Icon?
    private var clickMonitor: Any?

    private enum Icon: Equatable {
        case symbol(String)
        case switching
        case error
    }

    /// Three dots hopping one after the other while a switch runs.
    private static let hopPeriod = 1.0
    private static let hopStagger = 0.14

    init(coordinator: SwitchCoordinator, windows: WindowManager) {
        self.coordinator = coordinator
        self.windows = windows
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false

        statusItem.button?.imagePosition = .imageOnly
        statusItem.behavior = []
        statusItem.menu = menu

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let button = self.statusItem.button, event.window === button.window else { return event }
            let isSecondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard isSecondary else { return event }
            self.cycle()
            return nil
        }

        observeChanges { [weak self] in
            self?.refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    // MARK: Clicks

    private func cycle() {
        guard coordinator.store.settings.onboardingCompleted else {
            windows.showOnboarding()
            return
        }
        // Brief native highlight so the click is felt even when nothing moves.
        statusItem.button?.highlight(true)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            statusItem.button?.highlight(false)
        }
        guard coordinator.switchingTo == nil else {
            Log.switching.info("Right click ignored: a switch is already running")
            return
        }
        guard let target = coordinator.nextCycleTarget() else {
            Log.switching.info("Right click: no other device to switch to")
            NSSound.beep()
            return
        }
        Log.switching.info("Right click: cycling to \(String(describing: target), privacy: .public)")
        Task { await coordinator.switchTo(target) }
    }

    // MARK: Refresh

    /// Reads the observable state (so it is tracked) and updates icon + open menu.
    private func refresh() {
        let icon = desiredIcon()
        let tooltip = tooltipText()
        if menuIsOpen { rebuildMenu() }
        apply(icon)
        statusItem.button?.toolTip = tooltip
        statusItem.button?.setAccessibilityLabel(tooltip)
    }

    private func desiredIcon() -> Icon {
        if coordinator.switchingTo != nil { return .switching }
        if coordinator.lastError != nil { return .error }
        if let holder = coordinator.holderID {
            return .symbol(DeviceSymbols.resolved(coordinator.identity(of: holder).symbol))
        }
        return .symbol(coordinator.isReleasedForPhone ? "iphone" : "speaker.slash")
    }

    private func tooltipText() -> String {
        guard let speaker = coordinator.store.speaker else { return "Relay — aucune enceinte choisie" }
        if coordinator.switchingTo != nil { return "Relay — bascule en cours…" }
        if let holder = coordinator.holderID {
            return "Relay — « \(speaker.name) » est sur \(coordinator.identity(of: holder).name)"
        }
        return coordinator.isReleasedForPhone
            ? "Relay — « \(speaker.name) » est libre pour l’iPhone"
            : "Relay — « \(speaker.name) » n’est connectée à aucun Mac"
    }

    private func apply(_ icon: Icon) {
        guard icon != currentIcon else { return }
        currentIcon = icon
        animationTimer?.invalidate()
        animationTimer = nil

        switch icon {
        case .symbol(let name):
            setImage(name)
        case .error:
            setImage("exclamationmark.triangle")
        case .switching:
            animationStart = Date()
            advanceAnimation()
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advanceAnimation() }
            }
            timer.tolerance = 1.0 / 120
            // Keep animating while the menu is open (event-tracking run loop mode).
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }
    }

    private func advanceAnimation() {
        let elapsed = Date().timeIntervalSince(animationStart)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let waves = (0..<3).map { Self.wave(elapsed - Double($0) * Self.hopStagger) }
        statusItem.button?.image = Self.dotsImage(waves: waves, hop: !reduceMotion)
    }

    /// 0 at rest, rises smoothly to 1 and back during the first half of each period.
    private static func wave(_ time: Double) -> Double {
        var phase = time.truncatingRemainder(dividingBy: hopPeriod) / hopPeriod
        if phase < 0 { phase += 1 }
        return phase < 0.5 ? sin(phase * 2 * .pi) : 0
    }

    /// Template image, so the dots follow the menu bar's colour like any system icon.
    /// With Reduce Motion the dots stay put and only pulse.
    private static func dotsImage(waves: [Double], hop: Bool) -> NSImage {
        let diameter: CGFloat = 3.6
        let spacing: CGFloat = 2.6
        let size = NSSize(width: 3 * diameter + 2 * spacing + 4, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, wave) in waves.enumerated() {
                let x = 2 + CGFloat(index) * (diameter + spacing)
                let y = 5 + (hop ? CGFloat(wave) * 4.5 : 0)
                NSColor.black.withAlphaComponent(0.45 + 0.55 * wave).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Bascule en cours"
        return image
    }

    private func setImage(_ name: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Relay")?
            .withSymbolConfiguration(configuration)
            ?? NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Relay")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func accessibilityChanged() {
        currentIcon = nil
        apply(desiredIcon())
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let store = coordinator.store
        let switching = coordinator.switchingTo != nil

        if !store.settings.onboardingCompleted {
            menu.addItem(actionItem("Terminer la configuration…", symbol: "sparkles", action: #selector(openOnboarding)))
            menu.addItem(.separator())
        }

        if let error = coordinator.lastError {
            menu.addItem(messageItem(title: "La bascule n’a pas abouti", message: error))
            menu.addItem(.separator())
        }

        if let speaker = store.speaker {
            menu.addItem(NSMenuItem.sectionHeader(title: speaker.name))

            for member in coordinator.orderedMembers {
                menu.addItem(macItem(member, disabled: switching))
            }

            menu.addItem(.separator())
            let none = actionItem("Aucun Mac (libérer pour l’iPhone)", symbol: "iphone", action: #selector(selectNone))
            none.state = coordinator.isReleasedForPhone ? .on : .off
            none.isEnabled = !switching
            if coordinator.switchingTo == SwitchTarget.none { setSubtitle(none, "Libération en cours…") }
            menu.addItem(none)
        } else {
            let missing = NSMenuItem(title: "Aucune enceinte choisie", action: nil, keyEquivalent: "")
            missing.image = symbolImage("speaker.slash")
            missing.isEnabled = false
            menu.addItem(missing)
            menu.addItem(actionItem("Choisir une enceinte…", symbol: "hifispeaker", action: #selector(openSpeakerSettings)))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Réglages…", symbol: "gearshape", action: #selector(openSettings), key: ","))
        menu.addItem(actionItem("Aide et prérequis", symbol: "questionmark.circle", action: #selector(openHelp), key: "?"))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quitter Relay", symbol: nil, action: #selector(quit), key: "q"))
    }

    private func macItem(_ member: DeviceIdentity, disabled: Bool) -> NSMenuItem {
        let isSelf = member.id == coordinator.selfID
        let identity = coordinator.identity(of: member.id)
        let online = isSelf || coordinator.peers.isOnline(member.id)
        let item = NSMenuItem(title: identity.name, action: #selector(selectMac(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = member.id
        item.image = symbolImage(DeviceSymbols.resolved(identity.symbol))
        item.state = coordinator.holderID == member.id ? .on : .off
        item.isEnabled = online && !disabled

        if coordinator.isBusy(member.id) {
            setSubtitle(item, "Connexion en cours…")
        } else if !online {
            setSubtitle(item, "Hors ligne")
        } else if isSelf {
            setSubtitle(item, "Ce Mac")
        }
        return item
    }

    private func actionItem(_ title: String, symbol: String?, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = symbolImage(symbol) }
        return item
    }

    /// A disabled, possibly multi-line explanation.
    private func messageItem(title: String, message: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = symbolImage("exclamationmark.triangle")
        item.isEnabled = false
        let wrapped = Self.wrap(message, width: 46)
        if #available(macOS 14.4, *) {
            item.subtitle = wrapped
        } else {
            let text = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: wrapped, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = text
        }
        return item
    }

    private func setSubtitle(_ item: NSMenuItem, _ text: String) {
        if #available(macOS 14.4, *) {
            item.subtitle = text
        } else {
            item.title += " — \(text.lowercased())"
        }
    }

    private func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Menu items do not wrap on their own.
    private static func wrap(_ text: String, width: Int) -> String {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.count + word.count + 1 > width, !current.isEmpty {
                lines.append(current)
                current = String(word)
            } else {
                current += current.isEmpty ? String(word) : " \(word)"
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    @objc private func selectMac(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        Task { await coordinator.switchTo(.mac(id)) }
    }

    @objc private func selectNone() {
        Task { await coordinator.switchTo(.none) }
    }

    @objc private func openSettings() { windows.showSettings() }
    @objc private func openSpeakerSettings() { windows.showSettings(page: .speaker) }
    @objc private func openHelp() { windows.showHelp() }
    @objc private func openOnboarding() { windows.showOnboarding() }
    @objc private func quit() { NSApp.terminate(nil) }
}
