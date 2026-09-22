import AppKit
import Observation
import OSLog

/// Offers to bring the speaker here when media starts playing on this Mac
/// while the speaker is on another one.
///
/// Declining ("Pas maintenant") mutes the offer for `snooze`. Any switch of
/// the speaker lifts that pause, and a playback that was already running never
/// triggers the offer: only a new one does.
@Observable
final class HandoffSuggester {
    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let appName: String?
        let appIcon: NSImage?
        let speakerName: String
        let holderName: String
    }

    private(set) var current: Suggestion?

    @ObservationIgnored private let coordinator: SwitchCoordinator
    @ObservationIgnored private let monitor: PlaybackMonitor
    @ObservationIgnored private var snoozedUntil: Date?
    @ObservationIgnored private var lastHolder: String??
    @ObservationIgnored private var expiry: Task<Void, Never>?

    static let snooze: TimeInterval = 30 * 60
    /// An offer left unanswered goes away and mutes itself for a while.
    static let unansweredSnooze: TimeInterval = 10 * 60
    static let visibleFor: Duration = .seconds(20)
    /// A discreet system sound when the offer shows up. Relay excludes its own
    /// process from playback detection, so this can never trigger an offer.
    static let sound = "Tink"

    init(coordinator: SwitchCoordinator, monitor: PlaybackMonitor = PlaybackMonitor()) {
        self.coordinator = coordinator
        self.monitor = monitor
    }

    func start() {
        monitor.onSustainedPlayback = { [weak self] source in
            self?.playbackStarted(source)
        }
        observeChanges { [weak self] in
            self?.stateChanged()
        }
    }

    // MARK: Decisions

    private func stateChanged() {
        let store = coordinator.store
        // Run the audio listeners only while the feature can actually fire.
        let enabled = store.settings.suggestHandoff && store.settings.onboardingCompleted && store.speaker != nil && !store.peers.isEmpty
        enabled ? monitor.start() : monitor.stop()

        let holder = coordinator.holderID
        if let lastHolder, lastHolder != holder {
            // The speaker moved: that's the "action" that lifts a pause, and
            // whatever is already playing is not a new playback.
            snoozedUntil = nil
            monitor.resetBaseline()
            if current != nil { dismiss(snoozeFor: nil) }
        }
        lastHolder = .some(holder)
        if !enabled, current != nil { dismiss(snoozeFor: nil) }
    }

    private func playbackStarted(_ source: PlaybackMonitor.Source) {
        let store = coordinator.store
        guard store.settings.suggestHandoff, current == nil, coordinator.switchingTo == nil,
              let speaker = store.speaker,
              let holder = coordinator.holderID, holder != coordinator.selfID,
              coordinator.peers.isOnline(holder) else { return }
        if let snoozedUntil, snoozedUntil > Date() {
            Log.switching.info("Handoff offer muted until \(snoozedUntil, privacy: .public)")
            return
        }
        guard !AudioOutput.isPrivateOutput else {
            Log.switching.info("Handoff offer skipped: this Mac plays on headphones")
            return
        }

        let app = Self.application(for: source)
        current = Suggestion(
            appName: app?.localizedName,
            appIcon: app?.icon,
            speakerName: speaker.name,
            holderName: coordinator.identity(of: holder).name
        )
        Log.switching.info("Offering handoff (\(app?.localizedName ?? "unknown app", privacy: .public))")
        if let chime = NSSound(named: Self.sound) {
            chime.volume = 0.6
            chime.play()
        }
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            self?.dismiss(snoozeFor: Self.unansweredSnooze)
        }
    }

    // MARK: Answers

    func accept() {
        dismiss(snoozeFor: nil)
        Task { await coordinator.switchTo(.mac(coordinator.selfID)) }
    }

    func decline() {
        dismiss(snoozeFor: Self.snooze)
    }

    private func dismiss(snoozeFor interval: TimeInterval?) {
        expiry?.cancel()
        expiry = nil
        current = nil
        if let interval { snoozedUntil = Date().addingTimeInterval(interval) }
    }

    // MARK: App lookup

    /// The visible app behind an audio process. Browser audio often comes from
    /// a helper ("com.google.Chrome.helper"), so shorter bundle prefixes are tried too.
    private static func application(for source: PlaybackMonitor.Source) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: source.pid), app.activationPolicy == .regular {
            return app
        }
        var parts = source.bundleID.split(separator: ".")
        while parts.count >= 2 {
            let candidate = parts.joined(separator: ".")
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first(where: { $0.activationPolicy == .regular }) {
                return app
            }
            parts.removeLast()
        }
        return nil
    }
}
