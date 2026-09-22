#if DEBUG
import CryptoKit
import Foundation
import Network

/// Debug aid: `Relay --selftest` checks message signing and runs two real
/// pairing handshakes over loopback TCP, prints the results and quits.
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }

    static func run() async -> Bool {
        var ok = true
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "PASS" : "FAIL", label)
            ok = ok && condition
        }

        // Wire: signature, tampering, replay, stale timestamp.
        let key = SymmetricKey(size: .bits256)
        let replay = ReplayGuard()
        let message = Message(sender: "A", body: .release(lock: true))
        let data = try! Wire.encode(message, key: key)
        check((try? Wire.decode(data, key: key, replay: replay)) != nil, "signed message accepted")
        check((try? Wire.decode(data, key: key, replay: replay)) == nil, "replayed message rejected")
        check((try? Wire.decode(Wire.encode(Message(sender: "A", body: .connect), key: key), key: SymmetricKey(size: .bits256), replay: replay)) == nil, "wrong key rejected")
        var old = Message(sender: "A", body: .connect)
        old.timestamp = Date().addingTimeInterval(-600)
        check((try? Wire.decode(Wire.encode(old, key: key), key: key, replay: replay)) == nil, "stale message rejected")
        check((try? Wire.decode(Wire.encode(Message(sender: "A", body: .connect), key: nil), key: key, replay: replay)) == nil, "unsigned command rejected")

        // Pairing: right code joins, wrong code aborts on both sides.
        let right = await pair(wrongCode: false)
        check(right.joined && right.keyMatches, "pairing with the right code shares the group key")
        let wrong = await pair(wrongCode: true)
        check(!wrong.joined && wrong.hostFailed, "pairing with a wrong code is refused")

        return ok
    }

    private static func pair(wrongCode: Bool) async -> (joined: Bool, keyMatches: Bool, hostFailed: Bool) {
        let groupKey = SymmetricKey(size: .bits256)
        let hostIdentity = DeviceIdentity(id: "host", name: "Host", symbol: "macmini")
        let joinerIdentity = DeviceIdentity(id: "joiner", name: "Joiner", symbol: "macbook")
        let listener = try! NWListener(using: .tcp, on: .any)
        let box = HostBox()

        listener.newConnectionHandler = { nwConnection in
            MainActor.assumeIsolated {
                let connection = FramedConnection(nwConnection)
                box.connection = connection
                connection.start { event in
                    guard case .frame(let data) = event,
                          let message = try? Wire.decode(data, key: groupKey, replay: ReplayGuard()) else { return }
                    if let host = box.host {
                        host.receive(message.body)
                    } else if case .pairHello(let hello) = message.body {
                        let session = PairingHost(connection: connection, hello: hello, local: hostIdentity)
                        session.makeWelcome = { joiner in
                            (GroupSnapshot(groupID: "g", revision: 1, members: [hostIdentity, joiner], speaker: nil), groupKey)
                        }
                        box.host = session
                        session.start()
                    }
                }
            }
        }
        listener.start(queue: .main)
        while (listener.port?.rawValue ?? 0) == 0 { try? await Task.sleep(for: .milliseconds(20)) }

        var receivedKey: SymmetricKey?
        let joiner = PairingJoiner(host: hostIdentity, endpoint: .hostPort(host: "::1", port: listener.port!), local: joinerIdentity)
        joiner.onWelcome = { _, key in receivedKey = key }
        joiner.start()

        for _ in 0..<300 where joiner.phase != .waitingForCode {
            try? await Task.sleep(for: .milliseconds(30))
        }
        print("  joiner after hello:", joiner.phase, "host:", box.host.map { "\($0.phase)" } ?? "none")
        if let code = box.host?.code {
            let typed = wrongCode ? String(code.prefix(5)) + String((Int(String(code.last!))! + 1) % 10) : code
            joiner.submit(typed)
        }
        for _ in 0..<100 {
            if joiner.phase == .succeeded { break }
            if case .failed = joiner.phase { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(100))
        print("  joiner end:", joiner.phase, "host:", box.host.map { "\($0.phase)" } ?? "none")

        let hostFailed: Bool = {
            if case .failed = box.host?.phase { return true }
            return false
        }()
        let matches = receivedKey.map { $0.withUnsafeBytes { Data($0) } == groupKey.withUnsafeBytes { Data($0) } } ?? false
        listener.cancel()
        box.connection?.cancel()
        return (joiner.phase == .succeeded, matches, hostFailed)
    }
}
private final class HostBox {
    var host: PairingHost?
    var connection: FramedConnection?
}
#endif
