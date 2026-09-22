import OSLog
import CryptoKit
import Foundation
import Network
import Observation

enum PeerError: LocalizedError {
    case offline, timeout, closed

    var errorDescription: String? {
        switch self {
        case .offline: "hors ligne"
        case .timeout: "pas de réponse"
        case .closed: "connexion interrompue"
        }
    }
}

/// A Relay instance seen on the local network.
struct DiscoveredPeer: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let groupID: String
    let endpoint: NWEndpoint
}

/// Bonjour advertising and browsing, TCP links to the other Macs of the group,
/// signed request/response, heartbeat, and the network side of pairing.
@Observable
final class PeerService {
    private(set) var discovered: [String: DiscoveredPeer] = [:]
    private(set) var online: Set<String> = []
    private(set) var localNetworkDenied = false
    private(set) var isRunning = false
    private(set) var activeHost: PairingHost?

    /// Handles a signed request from a group member; returns the reply.
    @ObservationIgnored var onRequest: ((Message) async -> Body)?
    /// A member answered a heartbeat or connected.
    @ObservationIgnored var onPeerState: ((PeerState) -> Void)?
    @ObservationIgnored var onPeerOffline: ((String) -> Void)?
    /// A joiner completed pairing with this Mac.
    @ObservationIgnored var onMemberJoined: ((DeviceIdentity) -> Void)?
    @ObservationIgnored var onUnknownMember: (() -> Void)?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var links: [String: PeerLink] = [:]
    @ObservationIgnored private var incoming: [UUID: FramedConnection] = [:]
    @ObservationIgnored private var hostSessions: [UUID: PairingHost] = [:]
    @ObservationIgnored private let replay = ReplayGuard()
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var advertised: [String: String] = [:]

    init(store: Store) {
        self.store = store
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startListener()
        startBrowser()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                await self?.beat()
            }
        }
    }

    func stop() {
        isRunning = false
        heartbeat?.cancel()
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        links.values.forEach { $0.close() }
        links.removeAll()
        incoming.values.forEach { $0.cancel() }
        incoming.removeAll()
        online.removeAll()
        discovered.removeAll()
    }

    func restart() {
        stop()
        start()
    }

    /// Re-advertises when this Mac's name, icon or group changed.
    func refreshAdvertisement() {
        guard isRunning, advertised != txtValues else { return }
        listener?.cancel()
        startListener()
    }

    /// Opens links to new members, drops removed ones.
    func syncMembers() {
        let members = Set(store.peers.map(\.id))
        for id in links.keys where !members.contains(id) {
            links[id]?.close()
            links[id] = nil
            online.remove(id)
        }
        for id in members { ensureLink(id) }
    }

    func isOnline(_ id: String) -> Bool { online.contains(id) }

    // MARK: Requests

    func request(_ body: Body, to id: String, timeout: Duration = .seconds(5)) async throws -> Body {
        ensureLink(id)
        guard let link = links[id] else { throw PeerError.offline }
        try await link.waitUntilReady(timeout: .seconds(3))
        let message = Message(sender: store.deviceID, body: body)
        let reply = try await link.send(message, key: store.groupKey, timeout: timeout)
        return reply.body
    }

    /// Fire-and-forget to every online member.
    func broadcast(_ body: Body) {
        for id in online {
            Task { _ = try? await self.request(body, to: id, timeout: .seconds(3)) }
        }
    }

    // MARK: Pairing

    func beginPairing(with peer: DiscoveredPeer) -> PairingJoiner {
        let host = DeviceIdentity(id: peer.id, name: peer.name, symbol: peer.symbol)
        return PairingJoiner(host: host, endpoint: peer.endpoint, local: store.identity)
    }

    /// Macs on the network that run Relay but are not in this Mac's group.
    var strangers: [DiscoveredPeer] {
        let members = Set(store.peers.map(\.id))
        return discovered.values
            .filter { !members.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Listener

    private var txtValues: [String: String] {
        let identity = store.identity
        return ["n": identity.name, "s": identity.symbol, "g": store.group.groupID, "v": RelayService.protocolVersion]
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: .tcp)
            let values = txtValues
            advertised = values
            listener.service = NWListener.Service(name: store.deviceID, type: RelayService.type, domain: nil, txtRecord: NWTXTRecord(values))
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerStateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Log.network.error("Listener failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            Log.network.info("Advertising \(RelayService.type, privacy: .public)")
        case .failed(let error), .waiting(let error):
            Log.network.error("Listener: \(error.localizedDescription, privacy: .public)")
            if Self.isPolicyDenied(error) { localNetworkDenied = true }
            if case .failed = state {
                listener?.cancel()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.isRunning else { return }
                    self.startListener()
                }
            }
        default:
            break
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = FramedConnection(nwConnection)
        incoming[connection.id] = connection
        connection.start { [weak self, weak connection] event in
            guard let self, let connection else { return }
            switch event {
            case .ready:
                break
            case .frame(let data):
                self.handleIncoming(data, on: connection)
            case .closed:
                self.incoming[connection.id] = nil
                if let host = self.hostSessions.removeValue(forKey: connection.id) { host.connectionClosed() }
            }
        }
    }

    private func handleIncoming(_ data: Data, on connection: FramedConnection) {
        let message: Message
        do {
            message = try Wire.decode(data, key: store.groupKey, replay: replay)
        } catch {
            Log.network.error("Rejected frame: \(String(describing: error), privacy: .public)")
            return
        }

        if message.body.isPairing {
            handlePairing(message, on: connection)
            return
        }

        // Only members of the group may give orders. A former member gets told.
        guard store.member(message.sender) != nil, message.sender != store.deviceID else {
            Log.network.error("Command from non-member \(message.sender, privacy: .public)")
            reply(.removed, to: message, on: connection)
            // It may have just joined through another Mac: catch up on membership.
            onUnknownMember?()
            return
        }

        online.insert(message.sender)
        Task {
            let body = await self.onRequest?(message) ?? .ack
            self.reply(body, to: message, on: connection)
        }
    }

    private func reply(_ body: Body, to request: Message, on connection: FramedConnection) {
        let response = Message(sender: store.deviceID, replyTo: request.id, body: body)
        guard let data = try? Wire.encode(response, key: store.groupKey) else { return }
        connection.send(data)
    }

    private func handlePairing(_ message: Message, on connection: FramedConnection) {
        if let host = hostSessions[connection.id] {
            host.receive(message.body)
            return
        }
        guard case .pairHello(let hello) = message.body else { return }

        if let active = activeHost, active.phase == .showingCode || active.phase == .verifying {
            let busy = Message(sender: store.deviceID, body: .pairAbort(reason: "« \(store.identity.name) » est déjà en train d’appairer un autre Mac."))
            if let data = try? Wire.encode(busy, key: nil) { connection.send(data) }
            return
        }

        let host = PairingHost(connection: connection, hello: hello, local: store.identity)
        host.makeWelcome = { [weak self] joiner in
            guard let self else { return (GroupSnapshot.solo(joiner), SymmetricKey(size: .bits256)) }
            self.store.addMember(joiner)
            return (self.store.group, self.store.groupKey)
        }
        host.onFinish = { [weak self] host in
            guard let self else { return }
            self.hostSessions = self.hostSessions.filter { $0.value !== host }
            if host.phase == .succeeded { self.onMemberJoined?(host.joiner) }
        }
        hostSessions[connection.id] = host
        activeHost = host
        host.start()
    }

    /// The code window was closed: cancel that session if it is still running.
    func dismissHostSession(_ id: UUID) {
        guard let host = activeHost, host.id == id else { return }
        if host.phase == .showingCode || host.phase == .verifying { host.cancel() }
        activeHost = nil
    }

    // MARK: Browser

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RelayService.type, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.browserStateChanged(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.resultsChanged(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            if localNetworkDenied { localNetworkDenied = false }
        case .failed(let error), .waiting(let error):
            Log.network.error("Browser: \(error.localizedDescription, privacy: .public)")
            if Self.isPolicyDenied(error) { localNetworkDenied = true }
            if case .failed = state {
                browser?.cancel()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.isRunning else { return }
                    self.startBrowser()
                }
            }
        default:
            break
        }
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
        var found: [String: DiscoveredPeer] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint, name != store.deviceID else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            // Several interfaces can announce the same Mac; the first one is enough.
            if found[name] != nil { continue }
            found[name] = DiscoveredPeer(
                id: name,
                name: txt["n"] ?? "Mac",
                symbol: DeviceSymbols.resolved(txt["s"] ?? DeviceSymbols.fallback),
                groupID: txt["g"] ?? "",
                endpoint: result.endpoint
            )
        }
        let appeared = Set(found.keys).subtracting(discovered.keys)
        let vanished = Set(discovered.keys).subtracting(found.keys)
        discovered = found

        for id in vanished where links[id] != nil {
            links[id]?.close()
            links[id] = nil
            markOffline(id)
        }
        let members = Set(store.peers.map(\.id))
        for id in appeared where members.contains(id) {
            Log.network.info("Member reappeared: \(found[id]?.name ?? id, privacy: .public)")
            ensureLink(id)
            Task { await self.poll(id) }
        }
    }

    // MARK: Links and heartbeat

    private func ensureLink(_ id: String) {
        if let link = links[id], !link.isClosed { return }
        guard let peer = discovered[id], store.member(id) != nil else { return }
        let link = PeerLink(peerID: id, endpoint: peer.endpoint, store: store, replay: replay)
        link.onClose = { [weak self, weak link] in
            guard let self, let link, self.links[id] === link else { return }
            self.links[id] = nil
            self.markOffline(id)
        }
        links[id] = link
        link.open()
    }

    private func beat() async {
        for member in store.peers {
            if discovered[member.id] == nil {
                markOffline(member.id)
                continue
            }
            await poll(member.id)
        }
    }

    private func poll(_ id: String) async {
        do {
            let body = try await request(.status, to: id, timeout: .seconds(4))
            if case .state(let state) = body {
                online.insert(id)
                onPeerState?(state)
            } else if case .removed = body {
                markOffline(id)
            }
        } catch {
            markOffline(id)
        }
    }

    private func markOffline(_ id: String) {
        guard online.contains(id) else { return }
        online.remove(id)
        Log.network.info("Member offline: \(self.store.displayName(id), privacy: .public)")
        onPeerOffline?(id)
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { return true }
        return false
    }
}

/// Outbound connection to one member; matches replies to requests.
private final class PeerLink {
    let peerID: String
    var onClose: (() -> Void)?
    private(set) var isReady = false
    private(set) var isClosed = false

    private let connection: FramedConnection
    private let store: Store
    private let replay: ReplayGuard
    private var pending: [UUID: CheckedContinuation<Message, Error>] = [:]

    init(peerID: String, endpoint: NWEndpoint, store: Store, replay: ReplayGuard) {
        self.peerID = peerID
        self.connection = FramedConnection(endpoint: endpoint)
        self.store = store
        self.replay = replay
    }

    func open() {
        connection.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready:
                self.isReady = true
            case .frame(let data):
                guard let message = try? Wire.decode(data, key: self.store.groupKey, replay: self.replay),
                      let replyTo = message.replyTo,
                      message.sender == self.peerID,
                      let continuation = self.pending.removeValue(forKey: replyTo) else { return }
                continuation.resume(returning: message)
            case .closed:
                self.finishClosed()
            }
        }
    }

    func waitUntilReady(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while !isReady {
            if isClosed || ContinuousClock.now >= deadline { throw PeerError.offline }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    func send(_ message: Message, key: SymmetricKey, timeout: Duration) async throws -> Message {
        guard !isClosed else { throw PeerError.closed }
        let data = try Wire.encode(message, key: key)
        return try await withCheckedThrowingContinuation { continuation in
            pending[message.id] = continuation
            connection.send(data)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.pending.removeValue(forKey: message.id)?.resume(throwing: PeerError.timeout)
            }
        }
    }

    func close() {
        connection.cancel()
    }

    private func finishClosed() {
        guard !isClosed else { return }
        isClosed = true
        isReady = false
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: PeerError.closed) }
        onClose?()
    }
}
