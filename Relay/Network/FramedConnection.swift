import Foundation
import Network

/// A TCP connection carrying length-prefixed frames (4-byte big-endian length).
/// All callbacks run on the main queue.
final class FramedConnection {
    enum Event {
        case ready
        case frame(Data)
        case closed(NWError?)
    }

    let id = UUID()
    private let connection: NWConnection
    private var handler: ((Event) -> Void)?
    private var closed = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    convenience init(endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 5
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 30
        }
        self.init(NWConnection(to: endpoint, using: parameters))
    }

    var endpoint: NWEndpoint { connection.endpoint }

    func start(_ handler: @escaping (Event) -> Void) {
        self.handler = handler
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                self?.stateChanged(state)
            }
        }
        connection.start(queue: .main)
    }

    func send(_ payload: Data) {
        guard !closed else { return }
        connection.send(content: Wire.frame(payload), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.close(error)
            }
        })
    }

    func cancel() {
        close(nil)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            handler?(.ready)
            receiveLength()
        case .failed(let error):
            close(error)
        case .waiting(let error):
            // Unreachable for now; a peer that is really there answers quickly.
            close(error)
        case .cancelled:
            close(nil)
        default:
            break
        }
    }

    private func receiveLength() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error { return self.close(error) }
                guard let data, data.count == 4 else {
                    if isComplete { self.close(nil) }
                    return
                }
                let length = data.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
                guard length > 0, length <= Wire.maxFrame else { return self.close(nil) }
                self.receiveBody(length)
            }
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error { return self.close(error) }
                guard let data, data.count == length else {
                    if isComplete { self.close(nil) }
                    return
                }
                self.handler?(.frame(data))
                if !self.closed { self.receiveLength() }
            }
        }
    }

    private func close(_ error: NWError?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let handler = handler
        self.handler = nil
        handler?(.closed(error))
    }
}
