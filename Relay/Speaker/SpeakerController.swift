import OSLog
import Foundation
import IOBluetooth
import Observation

enum SpeakerError: LocalizedError, Equatable {
    case bluetoothOff
    case notPaired(String)
    case connectFailed(String)
    case disconnectFailed(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothOff:
            "Le Bluetooth est désactivé sur ce Mac."
        case .notPaired(let name):
            "« \(name) » n’est pas appairée avec ce Mac."
        case .connectFailed(let name):
            "Impossible de se connecter à « \(name) ». Vérifiez qu’elle est allumée, à portée, et qu’aucun autre appareil ne l’utilise."
        case .disconnectFailed(let name):
            "« \(name) » ne s’est pas déconnectée."
        }
    }
}

/// Everything that touches IOBluetooth and CoreAudio.
@Observable
final class SpeakerController {
    struct Device: Identifiable, Hashable {
        let address: String
        let name: String
        let isConnected: Bool
        let isAudio: Bool
        var id: String { address }
    }

    /// Called on the main thread when any Bluetooth device connects or disconnects.
    @ObservationIgnored var onConnectionChange: ((_ address: String, _ connected: Bool) -> Void)?

    @ObservationIgnored private let observer = BluetoothObserver()
    @ObservationIgnored private var connectNotification: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    init() {
        observer.owner = self
    }

    // MARK: Queries

    var isPoweredOn: Bool {
        IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
    }

    /// Paired devices; audio-class devices only unless `includeAll`.
    func pairedDevices(includeAll: Bool = false) -> [Device] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices
            .map { device in
                Device(
                    address: SpeakerInfo.normalize(device.addressString ?? ""),
                    name: device.nameOrAddress ?? "Appareil Bluetooth",
                    isConnected: device.isConnected(),
                    isAudio: Self.isAudio(device)
                )
            }
            .filter { includeAll || $0.isAudio }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isPaired(_ address: String) -> Bool {
        device(address)?.isPaired() ?? false
    }

    func isConnected(_ address: String) -> Bool {
        device(address)?.isConnected() ?? false
    }

    private func device(_ address: String) -> IOBluetoothDevice? {
        IOBluetoothDevice(addressString: address)
    }

    private static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        let major = device.deviceClassMajor
        // Some speakers advertise another major class but set the "Audio" service bit.
        let audioServiceBit: UInt32 = 1 << 21
        return major == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
            || (device.classOfDevice & audioServiceBit) != 0
    }

    // MARK: Monitoring

    func startMonitoring(_ address: String?) {
        if connectNotification == nil {
            connectNotification = IOBluetoothDevice.register(
                forConnectNotifications: observer,
                selector: #selector(BluetoothObserver.deviceConnected(_:device:))
            )
        }
        if let address, let device = device(address), device.isConnected() {
            watchDisconnect(device)
        }
    }

    fileprivate func handleConnected(_ device: IOBluetoothDevice) {
        let address = SpeakerInfo.normalize(device.addressString ?? "")
        watchDisconnect(device)
        onConnectionChange?(address, true)
    }

    fileprivate func handleDisconnected(_ device: IOBluetoothDevice, notification: IOBluetoothUserNotification) {
        let address = SpeakerInfo.normalize(device.addressString ?? "")
        notification.unregister()
        disconnectNotifications[address] = nil
        onConnectionChange?(address, false)
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        let address = SpeakerInfo.normalize(device.addressString ?? "")
        guard disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(
            forDisconnectNotification: observer,
            selector: #selector(BluetoothObserver.deviceDisconnected(_:device:))
        )
    }

    // MARK: Actions

    /// Opens the baseband connection (3 attempts, 1 s apart), then makes sure
    /// the speaker is the default audio output.
    func connect(_ speaker: SpeakerInfo) async throws {
        guard isPoweredOn else { throw SpeakerError.bluetoothOff }
        guard let device = device(speaker.address), device.isPaired() else { throw SpeakerError.notPaired(speaker.name) }

        if !device.isConnected() {
            var connected = false
            for attempt in 1...3 {
                Log.speaker.info("Connect attempt \(attempt) to \(speaker.address, privacy: .public)")
                let status = await openConnection(device)
                if status == kIOReturnSuccess, await waitFor({ device.isConnected() }, timeout: .seconds(3)) {
                    connected = true
                    break
                }
                Log.speaker.error("Connect attempt \(attempt) failed: \(status)")
                if attempt < 3 { try? await Task.sleep(for: .seconds(1)) }
            }
            guard connected else { throw SpeakerError.connectFailed(speaker.name) }
        }
        watchDisconnect(device)
        await routeAudio(to: speaker)
        guard device.isConnected() else { throw SpeakerError.connectFailed(speaker.name) }
    }

    /// Closes the connection and checks it actually went away.
    func disconnect(_ speaker: SpeakerInfo) async throws {
        guard let device = device(speaker.address), device.isConnected() else { return }
        for attempt in 1...2 {
            let status = device.closeConnection()
            Log.speaker.info("Disconnect attempt \(attempt): \(status)")
            if await waitFor({ !device.isConnected() }, timeout: .seconds(4)) { return }
        }
        throw SpeakerError.disconnectFailed(speaker.name)
    }

    /// Synchronous, for when there is no time to wait (going to sleep).
    func disconnectNow(_ speaker: SpeakerInfo) {
        guard let device = device(speaker.address), device.isConnected() else { return }
        device.closeConnection()
    }

    /// Waits for macOS to publish the audio device, then forces it as default output if needed.
    private func routeAudio(to speaker: SpeakerInfo) async {
        var output: AudioOutput.Device?
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            output = AudioOutput.device(forSpeaker: speaker)
            if output != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let output else {
            Log.speaker.error("Audio device for \(speaker.name, privacy: .public) never appeared")
            return
        }
        // Give macOS a moment to switch on its own before overriding.
        try? await Task.sleep(for: .milliseconds(400))
        if AudioOutput.defaultOutputID != output.id {
            let ok = AudioOutput.setDefaultOutput(output.id)
            Log.speaker.info("Forced default output to \(output.name, privacy: .public): \(ok)")
        }
    }

    private func openConnection(_ device: IOBluetoothDevice) async -> IOReturn {
        await withCheckedContinuation { continuation in
            let request = ConnectRequest(continuation: continuation)
            // Page timeout in 0.625 ms slots: 0x2000 ≈ 5 s.
            let status = device.openConnection(request, withPageTimeout: 0x2000, authenticationRequired: false)
            if status != kIOReturnSuccess {
                request.finish(status)
            } else {
                request.armTimeout(seconds: 8)
            }
        }
    }

    private func waitFor(_ condition: () -> Bool, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }
}

/// Target for IOBluetooth's asynchronous `openConnection:` callback.
private final class ConnectRequest: NSObject {
    private var continuation: CheckedContinuation<IOReturn, Never>?
    private var retainSelf: ConnectRequest?

    init(continuation: CheckedContinuation<IOReturn, Never>) {
        self.continuation = continuation
        super.init()
        retainSelf = self
    }

    func finish(_ status: IOReturn) {
        continuation?.resume(returning: status)
        continuation = nil
        retainSelf = nil
    }

    func armTimeout(seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.finish(kIOReturnTimeout)
        }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        finish(status)
    }
}

/// Receives IOBluetooth notifications (delivered on the main run loop).
private final class BluetoothObserver: NSObject {
    weak var owner: SpeakerController?

    @objc func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        owner?.handleConnected(device)
    }

    @objc func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        owner?.handleDisconnected(device, notification: notification)
    }
}
