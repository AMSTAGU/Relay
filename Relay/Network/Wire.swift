import CryptoKit
import Foundation

/// Bonjour service type shared by every Relay instance.
enum RelayService {
    static let type = "_speakerswitch._tcp"
    static let protocolVersion = "1"
}

struct PairHello: Codable, Sendable {
    var identity: DeviceIdentity
    var publicKey: Data
}

/// Everything two Relay instances can say to each other.
/// The group commands are HMAC-signed with the group key; pairing messages are
/// not (there is no shared key yet) and are protected by the pairing protocol itself.
enum Body: Codable, Sendable {
    // Group (signed)
    case status
    case state(PeerState)
    case release(lock: Bool)
    case connect
    case result(ok: Bool, error: String?)
    case groupUpdate(GroupSnapshot)
    case groupSyncRequest
    case removed
    case leave
    case ack

    // Pairing (unsigned)
    case pairHello(PairHello)
    case pairCommit(round: Int, commitment: Data)
    case pairReveal(round: Int, nonce: Data)
    case pairWelcome(sealed: Data)
    case pairAbort(reason: String)

    var isPairing: Bool {
        switch self {
        case .pairHello, .pairCommit, .pairReveal, .pairWelcome, .pairAbort: true
        default: false
        }
    }
}

struct Message: Codable, Sendable {
    var id = UUID()
    var sender: String
    var timestamp = Date()
    var nonce = Data.random(count: 16)
    var replyTo: UUID?
    var body: Body
}

/// What goes on the wire: the encoded message plus its HMAC.
private struct Envelope: Codable {
    var message: Data
    var mac: Data?
}

enum WireError: Error {
    case malformed, badSignature, stale, replayed, unsignedCommand
}

enum Wire {
    static let maxFrame = 1 << 20
    static let clockTolerance: TimeInterval = 90

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// Encodes a message; signs it unless it is a pairing message.
    static func encode(_ message: Message, key: SymmetricKey?) throws -> Data {
        let payload = try encoder.encode(message)
        var mac: Data?
        if !message.body.isPairing, let key {
            mac = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        }
        return try encoder.encode(Envelope(message: payload, mac: mac))
    }

    /// Decodes a frame. Group commands must carry a valid signature, a fresh
    /// timestamp and a nonce never seen before.
    static func decode(_ frame: Data, key: SymmetricKey, replay: ReplayGuard) throws -> Message {
        guard let envelope = try? decoder.decode(Envelope.self, from: frame),
              let message = try? decoder.decode(Message.self, from: envelope.message) else {
            throw WireError.malformed
        }
        if message.body.isPairing { return message }

        guard let mac = envelope.mac else { throw WireError.unsignedCommand }
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: envelope.message, using: key) else {
            throw WireError.badSignature
        }
        guard abs(message.timestamp.timeIntervalSinceNow) < clockTolerance else { throw WireError.stale }
        guard replay.accept(message.nonce) else { throw WireError.replayed }
        return message
    }

    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }
}

/// Remembers recent nonces for longer than the clock tolerance.
final class ReplayGuard {
    private var seen: [Data: Date] = [:]

    func accept(_ nonce: Data) -> Bool {
        let now = Date()
        if seen.count > 512 {
            seen = seen.filter { now.timeIntervalSince($0.value) < Wire.clockTolerance * 2 }
        }
        guard seen[nonce] == nil else { return false }
        seen[nonce] = now
        return true
    }
}

extension Data {
    static func random(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
