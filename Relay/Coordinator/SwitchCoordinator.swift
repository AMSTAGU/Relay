import OSLog
import AppKit
import CryptoKit
import Foundation
import Observation

/// The switch state machine: who has the speaker, moving it between Macs,
/// the lock that stops macOS from grabbing it back, and group bookkeeping.
@Observable
final class SwitchCoordinator {
    private(set) var switchingTo: SwitchTarget?
    private(set) var lastError: String?
    private(set) var localConnected = false
    private(set) var localActivity: Activity = .idle
    private(set) var peerStates: [String: PeerState] = [:]

    @ObservationIgnored let store: Store
    @ObservationIgnored let speaker: SpeakerController
    @ObservationIgnored let peers: PeerService
    @ObservationIgnored let permissions: Permissions

    @ObservationIgnored private var explicitConnect = false
    @ObservationIgnored private var bluetoothStarted = false
    @ObservationIgnored private var errorExpiry: Task<Void, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?

    init(store: Store, speaker: SpeakerController, peers: PeerService, permissions: Permissions) {
        self.store = store
        self.speaker = speaker
        self.peers = peers
        self.permissions = permissions
    }

    // MARK: Startup

    func start() {
        speaker.onConnectionChange = { [weak self] address, connected in
            self?.connectionChanged(address, connected)
        }
        peers.onRequest = { [weak self] message in
            await self?.handle(message) ?? .ack
        }
        peers.onPeerState = { [weak self] state in
            self?.received(state, from: state.identity.id)
        }
        peers.onMemberJoined = { [weak self] identity in
            self?.memberJoined(identity)
        }
        peers.onUnknownMember = { [weak self] in
            self?.syncGroup()
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                self?.refreshLocal()
            }
        }
        startBluetoothIfAllowed()
    }

    /// IOBluetooth is only touched once the user granted access, so the
    /// permission prompt shows up in onboarding and not at first launch.
    func startBluetoothIfAllowed() {
        permissions.refresh()
        guard permissions.bluetooth == .allowed, !bluetoothStarted else { return }
        bluetoothStarted = true
        speaker.startMonitoring(store.speaker?.address)
        refreshLocal()
    }

    func startNetworking() {
        peers.start()
        peers.syncMembers()
    }

    // MARK: Derived state

    var selfID: String { store.deviceID }

    /// The Mac currently holding the speaker, as far as anyone reports.
    var holderID: String? {
        if localConnected { return selfID }
        return store.peers.first { peers.isOnline($0.id) && peerStates[$0.id]?.speakerConnected == true }?.id
    }

    /// "Aucun Mac": nobody holds the speaker and this Mac is holding back on purpose.
    var isReleasedForPhone: Bool {
        holderID == nil && store.isLocked && store.speaker != nil
    }

    var localState: PeerState {
        PeerState(
            identity: store.identity,
            speakerConnected: localConnected,
            locked: store.isLocked,
            activity: localActivity,
            groupRevision: store.group.revision
        )
    }

    func identity(of id: String) -> DeviceIdentity {
        if id == selfID { return store.identity }
        return peerStates[id]?.identity ?? store.member(id) ?? DeviceIdentity(id: id, name: "Mac", symbol: DeviceSymbols.fallback)
    }

    func isBusy(_ id: String) -> Bool {
        if switchingTo == .mac(id) { return true }
        if id == selfID { return localActivity == .connecting }
        return peers.isOnline(id) && peerStates[id]?.activity == .connecting
    }

    // MARK: Switching

    func switchTo(_ target: SwitchTarget) async {
        guard switchingTo == nil else { return }
        guard store.speaker != nil else {
            return setError("Choisissez d’abord une enceinte dans les réglages.")
        }
        if case .mac(let id) = target, id != selfID, !peers.isOnline(id) {
            return setError("« \(identity(of: id).name) » est hors ligne.")
        }
        if target == .mac(selfID), permissions.bluetooth != .allowed {
            return setError("Relay n’a pas accès au Bluetooth. Ouvrez « Aide et prérequis ».")
        }

        Log.switching.info("Switch to \(String(describing: target), privacy: .public)")
        switchingTo = target
        clearError()
        defer {
            switchingTo = nil
            broadcastState()
        }

        // 1. Everyone except the target lets go (and locks), in parallel.
        let others = store.peers.map(\.id).filter { peers.isOnline($0) && target != .mac($0) }
        async let remoteFailures = releaseRemotes(others)
        var localFailure: String?
        if target != .mac(selfID) {
            do { try await releaseLocal(lock: true) } catch { localFailure = error.localizedDescription }
        }
        let failures = await remoteFailures
        let silent = failures.map { "« \(identity(of: $0).name) »" }

        // 2. The target connects.
        switch target {
        case .none:
            if let localFailure { setError(localFailure) }
            else if !silent.isEmpty { setError("\(silent.joined(separator: ", ")) n’a pas libéré l’enceinte à temps.") }

        case .mac(let id) where id == selfID:
            do {
                try await connectLocal()
            } catch {
                var message = error.localizedDescription
                if !silent.isEmpty { message += " \(silent.joined(separator: ", ")) n’a pas répondu et la garde peut-être encore." }
                setError(message)
            }

        case .mac(let id):
            let name = identity(of: id).name
            do {
                let reply = try await peers.request(.connect, to: id, timeout: .seconds(35))
                if case .result(false, let error) = reply {
                    setError(error ?? "« \(name) » n’a pas pu se connecter à l’enceinte.")
                }
            } catch {
                setError("« \(name) » n’a pas répondu. Vérifiez qu’il est allumé et sur le même réseau.")
            }
        }
    }

    /// Asks each Mac to release; returns the ones that failed or stayed silent.
    private func releaseRemotes(_ ids: [String]) async -> [String] {
        let tasks = ids.map { id in
            Task { () -> String? in
                do {
                    let reply = try await peers.request(.release(lock: true), to: id, timeout: .seconds(5))
                    if case .result(true, _) = reply { return nil }
                    return id
                } catch {
                    return id
                }
            }
        }
        var failed: [String] = []
        for task in tasks {
            if let id = await task.value { failed.append(id) }
        }
        return failed
    }

    func releaseLocal(lock: Bool) async throws {
        store.setLocked(lock)
        guard let info = store.speaker, permissions.bluetooth == .allowed else { return }
        guard speaker.isConnected(info.address) else {
            refreshLocal()
            return
        }
        localActivity = .releasing
        broadcastState()
        defer {
            localActivity = .idle
            refreshLocal(force: true)
        }
        try await speaker.disconnect(info)
        Log.switching.info("Released speaker (lock: \(lock))")
    }

    func connectLocal() async throws {
        guard let info = store.speaker else { throw SpeakerError.connectFailed("l’enceinte") }
        store.setLocked(false)
        explicitConnect = true
        localActivity = .connecting
        broadcastState()
        defer {
            explicitConnect = false
            localActivity = .idle
            refreshLocal(force: true)
        }
        try await speaker.connect(info)
        Log.switching.info("Connected speaker locally")
    }

    /// Onboarding check: moves the speaker here and reports in plain words.
    func runTest() async -> (ok: Bool, message: String) {
        guard let info = store.speaker else { return (false, "Aucune enceinte n’est choisie.") }
        if store.peers.contains(where: { peers.isOnline($0.id) }) {
            await switchTo(.mac(selfID))
        } else {
            clearError()
            do {
                if speaker.isConnected(info.address) {
                    try await releaseLocal(lock: false)
                    try? await Task.sleep(for: .seconds(1))
                }
                try await connectLocal()
            } catch {
                setError(error.localizedDescription)
            }
        }
        if let lastError { return (false, lastError) }
        return (true, "« \(info.name) » est connectée à ce Mac et le son sort dessus.")
    }

    // MARK: Lock

    private func connectionChanged(_ address: String, _ connected: Bool) {
        guard let info = store.speaker, address == info.address else { return }
        localConnected = connected
        if connected, store.isLocked, !explicitConnect {
            Log.switching.info("macOS reconnected the speaker on its own while locked: disconnecting")
            Task { try? await speaker.disconnect(info) }
        }
        broadcastState()
    }

    func refreshLocal(force: Bool = false) {
        guard bluetoothStarted, let info = store.speaker else {
            if localConnected { localConnected = false }
            return
        }
        let connected = speaker.isConnected(info.address)
        let changed = connected != localConnected
        if changed { localConnected = connected }
        if connected, store.isLocked, !explicitConnect, localActivity == .idle {
            Log.switching.info("Speaker connected while locked: disconnecting")
            Task { try? await speaker.disconnect(info) }
        }
        if changed || force { broadcastState() }
    }

    private func willSleep() {
        guard store.settings.releaseOnSleep, let info = store.speaker, localConnected else { return }
        Log.switching.info("Going to sleep: releasing speaker")
        store.setLocked(true)
        speaker.disconnectNow(info)
        localConnected = false
        broadcastState()
    }

    // MARK: Errors

    private func setError(_ message: String) {
        Log.switching.error("\(message, privacy: .public)")
        lastError = message
        errorExpiry?.cancel()
        errorExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    func clearError() {
        errorExpiry?.cancel()
        lastError = nil
    }

    // MARK: Messages from peers

    private func handle(_ message: Message) async -> Body {
        switch message.body {
        case .status:
            return .state(localState)
        case .state(let state):
            received(state, from: message.sender)
            return .ack
        case .release(let lock):
            do {
                try await releaseLocal(lock: lock)
                return .result(ok: true, error: nil)
            } catch {
                return .result(ok: false, error: error.localizedDescription)
            }
        case .connect:
            do {
                try await connectLocal()
                return .result(ok: true, error: nil)
            } catch {
                return .result(ok: false, error: "« \(store.identity.name) » : \(error.localizedDescription)")
            }
        case .groupUpdate(let snapshot):
            apply(snapshot)
            return .ack
        case .groupSyncRequest:
            return .groupUpdate(store.group)
        case .removed:
            Log.app.info("Removed from the group by \(self.store.displayName(message.sender), privacy: .public)")
            store.leaveGroup()
            groupChanged()
            return .ack
        case .leave:
            store.removeMember(message.sender)
            peerStates[message.sender] = nil
            groupChanged()
            return .ack
        default:
            return .ack
        }
    }

    private func received(_ state: PeerState, from id: String) {
        guard state.identity.id == id, store.member(id) != nil else { return }
        if peerStates[id] != state { peerStates[id] = state }
        if state.groupRevision > store.group.revision { syncGroup(from: id) }
    }

    private func broadcastState() {
        peers.broadcast(.state(localState))
    }

    // MARK: Group

    func syncGroup(from id: String? = nil) {
        let sources = id.map { [$0] } ?? store.peers.map(\.id).filter { peers.isOnline($0) }
        for source in sources {
            Task {
                if case .groupUpdate(let snapshot) = try? await peers.request(.groupSyncRequest, to: source) {
                    apply(snapshot)
                }
            }
        }
    }

    private func apply(_ snapshot: GroupSnapshot) {
        let before = store.group
        let stillMember = store.merge(snapshot)
        if !stillMember { Log.app.info("No longer part of the group") }
        if store.group != before { groupChanged() }
    }

    private func groupChanged() {
        peers.syncMembers()
        peers.refreshAdvertisement()
        if bluetoothStarted { speaker.startMonitoring(store.speaker?.address) }
        refreshLocal(force: true)
    }

    /// Host side of pairing: the new Mac is already in the store.
    private func memberJoined(_ identity: DeviceIdentity) {
        Log.app.info("\(identity.name, privacy: .public) joined the group")
        peers.broadcast(.groupUpdate(store.group))
        groupChanged()
    }

    /// Joiner side of pairing.
    func joinGroup(_ snapshot: GroupSnapshot, key: SymmetricKey) async {
        let formerPeers = store.peers.map(\.id).filter { peers.isOnline($0) }
        for id in formerPeers { _ = try? await peers.request(.leave, to: id, timeout: .seconds(2)) }
        store.adoptGroup(snapshot, key: key)
        peerStates.removeAll()
        peers.restart()
        groupChanged()
        // Let links come up, then tell everyone (new speaker, this Mac's name).
        try? await Task.sleep(for: .seconds(2))
        peers.broadcast(.groupUpdate(store.group))
    }

    func removeMember(_ id: String) {
        let wasOnline = peers.isOnline(id)
        let name = identity(of: id).name
        if wasOnline {
            Task { _ = try? await peers.request(.removed, to: id, timeout: .seconds(2)) }
        }
        store.removeMember(id)
        peerStates[id] = nil
        peers.broadcast(.groupUpdate(store.group))
        groupChanged()
        Log.app.info("Removed \(name, privacy: .public) from the group")
    }

    func setSpeaker(_ info: SpeakerInfo) {
        let previous = store.speaker
        if let previous, previous.address != info.address, localConnected {
            speaker.disconnectNow(previous)
        }
        store.setSpeaker(info)
        localConnected = false
        peers.broadcast(.groupUpdate(store.group))
        groupChanged()
    }

    func setIdentity(name: String? = nil, symbol: String? = nil) {
        store.setIdentity(name: name, symbol: symbol)
        peers.broadcast(.groupUpdate(store.group))
        peers.refreshAdvertisement()
        broadcastState()
    }

    func setReleaseOnSleep(_ enabled: Bool) {
        store.update { $0.releaseOnSleep = enabled }
    }

    /// Leaves the group and forgets everything.
    func resetEverything() async {
        for id in store.peers.map(\.id) where peers.isOnline(id) {
            _ = try? await peers.request(.leave, to: id, timeout: .seconds(2))
        }
        peers.stop()
        store.resetAll()
        peerStates.removeAll()
        localConnected = false
        clearError()
        bluetoothStarted = false
    }
}
