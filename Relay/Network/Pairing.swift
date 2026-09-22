import OSLog
import CryptoKit
import Foundation
import Network
import Observation

/*
 Pairing, in short
 -----------------
 The host shows a 6-digit code; the joiner types it.

 1. Both sides exchange Curve25519 public keys (pairHello).
 2. For each digit of the code, a commit/reveal round:
        joiner → commit  HMAC(nonceB, "B" · round · digit · transcript)
        host   → commit  HMAC(nonceA, "A" · round · digit · transcript)
        joiner → reveal  nonceB        (host checks the joiner knew the digit)
        host   → reveal  nonceA        (joiner checks the host knew the digit)
    Each side commits before seeing the other's nonce, so a man in the middle
    has to guess each digit blind (1 in 10⁶ for the whole code), and a wrong
    guess aborts the session and burns the code.
 3. The session key is HKDF(ECDH secret, all nonces, transcript). The host
    sends the group key, members and speaker sealed with ChaChaPoly under it.
*/

private enum PairingCrypto {
    static let rounds = 6

    static func transcript(host: PairHello, joiner: PairHello) -> Data {
        var data = Data("relay.pair.v1".utf8)
        data.append(host.publicKey)
        data.append(joiner.publicKey)
        data.append(Data(host.identity.id.utf8))
        data.append(Data(joiner.identity.id.utf8))
        return Data(SHA256.hash(data: data))
    }

    static func commitment(role: String, round: Int, digit: Character, nonce: Data, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: input(role, round, digit, transcript), using: SymmetricKey(data: nonce)))
    }

    static func verify(_ commitment: Data, role: String, round: Int, digit: Character, nonce: Data, transcript: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(commitment, authenticating: input(role, round, digit, transcript), using: SymmetricKey(data: nonce))
    }

    private static func input(_ role: String, _ round: Int, _ digit: Character, _ transcript: Data) -> Data {
        var data = Data("\(role)|\(round)|\(digit)|".utf8)
        data.append(transcript)
        return data
    }

    static func sessionKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data, nonces: Data, transcript: Data) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonces, sharedInfo: transcript, outputByteCount: 32)
    }

    static func digit(_ code: String, round: Int) -> Character {
        Array(code)[round - 1]
    }
}

private struct PairWelcome: Codable {
    var groupKey: Data
    var group: GroupSnapshot
}

// MARK: - Host (shows the code)

@Observable
final class PairingHost: Identifiable {
    enum Phase: Equatable {
        case showingCode, verifying, succeeded, failed(String)
    }

    let id = UUID()
    let joiner: DeviceIdentity
    let code: String
    private(set) var phase: Phase = .showingCode

    @ObservationIgnored var makeWelcome: ((DeviceIdentity) -> (GroupSnapshot, SymmetricKey))?
    @ObservationIgnored var onFinish: ((PairingHost) -> Void)?

    @ObservationIgnored private let connection: FramedConnection
    @ObservationIgnored private let local: DeviceIdentity
    @ObservationIgnored private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    @ObservationIgnored private let joinerHello: PairHello
    @ObservationIgnored private var transcript = Data()
    @ObservationIgnored private var round = 1
    @ObservationIgnored private var joinerCommit: Data?
    @ObservationIgnored private var hostNonce: Data?
    @ObservationIgnored private var nonces = Data()
    @ObservationIgnored private var timeout: Task<Void, Never>?

    init(connection: FramedConnection, hello: PairHello, local: DeviceIdentity) {
        self.connection = connection
        self.joinerHello = hello
        self.joiner = hello.identity
        self.local = local
        var generator = SystemRandomNumberGenerator()
        self.code = (0..<PairingCrypto.rounds).map { _ in String(Int.random(in: 0...9, using: &generator)) }.joined()
    }

    func start() {
        let hello = PairHello(identity: local, publicKey: privateKey.publicKey.rawRepresentation)
        transcript = PairingCrypto.transcript(host: hello, joiner: joinerHello)
        send(.pairHello(hello))
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.fail("Le délai est dépassé.", notify: true)
        }
        Log.pairing.info("Hosting pairing for \(self.joiner.name, privacy: .public)")
    }

    func receive(_ body: Body) {
        guard phase == .showingCode || phase == .verifying else { return }
        switch body {
        case .pairCommit(let round, let commitment) where round == self.round && joinerCommit == nil:
            phase = .verifying
            joinerCommit = commitment
            let nonce = Data.random(count: 32)
            hostNonce = nonce
            let digit = PairingCrypto.digit(code, round: round)
            send(.pairCommit(round: round, commitment: PairingCrypto.commitment(role: "A", round: round, digit: digit, nonce: nonce, transcript: transcript)))

        case .pairReveal(let round, let joinerNonce) where round == self.round:
            guard let joinerCommit, let hostNonce else { return fail("Échange inattendu.", notify: true) }
            let digit = PairingCrypto.digit(code, round: round)
            guard PairingCrypto.verify(joinerCommit, role: "B", round: round, digit: digit, nonce: joinerNonce, transcript: transcript) else {
                Log.pairing.error("Wrong code digit at round \(round)")
                return fail("Le code saisi sur « \(joiner.name) » est incorrect.", notify: true)
            }
            nonces.append(joinerNonce)
            nonces.append(hostNonce)
            send(.pairReveal(round: round, nonce: hostNonce))
            self.joinerCommit = nil
            self.hostNonce = nil
            self.round += 1
            if self.round > PairingCrypto.rounds { finish() }

        case .pairAbort(let reason):
            fail(reason, notify: false)

        default:
            fail("Échange inattendu.", notify: true)
        }
    }

    func connectionClosed() {
        if phase == .showingCode || phase == .verifying {
            fail("La connexion avec « \(joiner.name) » a été interrompue.", notify: false)
        }
    }

    func cancel() {
        fail("Appairage annulé.", notify: true)
    }

    private func finish() {
        do {
            let key = try PairingCrypto.sessionKey(privateKey: privateKey, peerKey: joinerHello.publicKey, nonces: nonces, transcript: transcript)
            guard let (group, groupKey) = makeWelcome?(joiner) else { throw WireError.malformed }
            let payload = try JSONEncoder().encode(PairWelcome(groupKey: groupKey.withUnsafeBytes { Data($0) }, group: group))
            let sealed = try ChaChaPoly.seal(payload, using: key).combined
            send(.pairWelcome(sealed: sealed))
            phase = .succeeded
            timeout?.cancel()
            Log.pairing.info("Paired with \(self.joiner.name, privacy: .public)")
            onFinish?(self)
        } catch {
            fail("Impossible de finaliser l’appairage.", notify: true)
        }
    }

    private func fail(_ reason: String, notify: Bool) {
        guard phase != .succeeded else { return }
        if case .failed = phase { return }
        if notify { send(.pairAbort(reason: reason)) }
        phase = .failed(reason)
        timeout?.cancel()
        Log.pairing.error("Pairing (host) failed: \(reason, privacy: .public)")
        // Let the abort message leave before closing.
        Task { [connection] in
            try? await Task.sleep(for: .milliseconds(300))
            connection.cancel()
        }
        onFinish?(self)
    }

    private func send(_ body: Body) {
        guard let data = try? Wire.encode(Message(sender: local.id, body: body), key: nil) else { return }
        connection.send(data)
    }
}

// MARK: - Joiner (types the code)

@Observable
final class PairingJoiner {
    enum Phase: Equatable {
        case connecting, waitingForCode, verifying, succeeded, failed(String)
    }

    let host: DeviceIdentity
    private(set) var phase: Phase = .connecting

    @ObservationIgnored var onWelcome: ((GroupSnapshot, SymmetricKey) -> Void)?

    @ObservationIgnored private let endpoint: NWEndpoint
    @ObservationIgnored private let local: DeviceIdentity
    @ObservationIgnored private var connection: FramedConnection?
    @ObservationIgnored private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    @ObservationIgnored private var hostHello: PairHello?
    @ObservationIgnored private var transcript = Data()
    @ObservationIgnored private var code = ""
    @ObservationIgnored private var round = 1
    @ObservationIgnored private var joinerNonce: Data?
    @ObservationIgnored private var hostCommit: Data?
    @ObservationIgnored private var nonces = Data()

    init(host: DeviceIdentity, endpoint: NWEndpoint, local: DeviceIdentity) {
        self.host = host
        self.endpoint = endpoint
        self.local = local
    }

    func start() {
        phase = .connecting
        let connection = FramedConnection(endpoint: endpoint)
        self.connection = connection
        connection.start { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready:
                self.send(.pairHello(PairHello(identity: self.local, publicKey: self.privateKey.publicKey.rawRepresentation)))
            case .frame(let data):
                guard let message = try? Wire.decode(data, key: SymmetricKey(size: .bits256), replay: ReplayGuard()), message.body.isPairing else { return }
                self.receive(message.body)
            case .closed:
                if self.phase != .succeeded, !self.isFailed {
                    self.phase = .failed("Impossible de joindre « \(self.host.name) ». Vérifiez que les deux Mac sont sur le même réseau.")
                }
            }
        }
    }

    /// Called when the user has typed the 6 digits shown on the host.
    func submit(_ code: String) {
        guard phase == .waitingForCode, code.count == PairingCrypto.rounds, code.allSatisfy(\.isNumber) else { return }
        self.code = code
        phase = .verifying
        sendCommit()
    }

    func cancel() {
        if phase != .succeeded { send(.pairAbort(reason: "Appairage annulé sur « \(local.name) ».")) }
        connection?.cancel()
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func receive(_ body: Body) {
        switch body {
        case .pairHello(let hello):
            hostHello = hello
            transcript = PairingCrypto.transcript(host: hello, joiner: PairHello(identity: local, publicKey: privateKey.publicKey.rawRepresentation))
            phase = .waitingForCode

        case .pairCommit(let round, let commitment) where round == self.round:
            hostCommit = commitment
            if let joinerNonce { send(.pairReveal(round: round, nonce: joinerNonce)) }

        case .pairReveal(let round, let hostNonce) where round == self.round:
            guard let hostCommit, let joinerNonce else { return fail("Échange inattendu.") }
            let digit = PairingCrypto.digit(code, round: round)
            guard PairingCrypto.verify(hostCommit, role: "A", round: round, digit: digit, nonce: hostNonce, transcript: transcript) else {
                return fail("« \(host.name) » n’a pas confirmé ce code.")
            }
            nonces.append(joinerNonce)
            nonces.append(hostNonce)
            self.hostCommit = nil
            self.joinerNonce = nil
            self.round += 1
            if self.round <= PairingCrypto.rounds { sendCommit() }

        case .pairWelcome(let sealed):
            guard round > PairingCrypto.rounds, let hostHello else { return fail("Échange inattendu.") }
            do {
                let key = try PairingCrypto.sessionKey(privateKey: privateKey, peerKey: hostHello.publicKey, nonces: nonces, transcript: transcript)
                let payload = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
                let welcome = try JSONDecoder().decode(PairWelcome.self, from: payload)
                phase = .succeeded
                Log.pairing.info("Joined group of \(self.host.name, privacy: .public)")
                onWelcome?(welcome.group, SymmetricKey(data: welcome.groupKey))
                connection?.cancel()
            } catch {
                fail("Impossible de lire la réponse de « \(host.name) ».")
            }

        case .pairAbort(let reason):
            phase = .failed(reason)
            connection?.cancel()

        default:
            break
        }
    }

    private func sendCommit() {
        let nonce = Data.random(count: 32)
        joinerNonce = nonce
        let digit = PairingCrypto.digit(code, round: round)
        send(.pairCommit(round: round, commitment: PairingCrypto.commitment(role: "B", round: round, digit: digit, nonce: nonce, transcript: transcript)))
    }

    private func fail(_ reason: String) {
        send(.pairAbort(reason: reason))
        phase = .failed(reason)
        Log.pairing.error("Pairing (joiner) failed: \(reason, privacy: .public)")
        Task { [connection] in
            try? await Task.sleep(for: .milliseconds(300))
            connection?.cancel()
        }
    }

    private func send(_ body: Body) {
        guard let data = try? Wire.encode(Message(sender: local.id, body: body), key: nil) else { return }
        connection?.send(data)
    }
}
