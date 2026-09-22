import OSLog
import AppKit
import CoreBluetooth
import Observation
import ServiceManagement

/// Live view of the permissions and system switches Relay depends on.
@Observable
final class Permissions: NSObject {
    enum BluetoothAccess: Equatable {
        case notDetermined, allowed, denied
    }

    private(set) var bluetooth: BluetoothAccess = Permissions.currentBluetoothAccess()
    /// nil while unknown (before permission is granted).
    private(set) var bluetoothPoweredOn: Bool?
    private(set) var loginItem: SMAppService.Status = SMAppService.mainApp.status

    @ObservationIgnored private var central: CBCentralManager?

    override init() {
        super.init()
        if bluetooth == .allowed { startCentral() }
    }

    func refresh() {
        let access = Self.currentBluetoothAccess()
        if access != bluetooth { bluetooth = access }
        if access == .allowed, central == nil { startCentral() }
        let status = SMAppService.mainApp.status
        if status != loginItem { loginItem = status }
    }

    /// Creating a central manager is what makes macOS show the Bluetooth prompt.
    func requestBluetooth() {
        startCentral()
    }

    private func startCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    private static func currentBluetoothAccess() -> BluetoothAccess {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    fileprivate func centralStateChanged(_ state: CBManagerState) {
        bluetooth = Self.currentBluetoothAccess()
        switch state {
        case .poweredOn: bluetoothPoweredOn = true
        case .poweredOff: bluetoothPoweredOn = false
        default: bluetoothPoweredOn = nil
        }
    }

    // MARK: Login item

    var launchAtLogin: Bool {
        loginItem == .enabled || loginItem == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Login item change failed: \(error.localizedDescription)")
        }
        loginItem = SMAppService.mainApp.status
    }
}

extension Permissions: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.centralStateChanged(state) }
        }
    }
}

/// Deep links into System Settings. Nothing in Relay ever asks for the Terminal.
enum SystemSettingsLink {
    case bluetoothPrivacy, bluetooth, localNetworkPrivacy, loginItems, sound

    var url: URL {
        let string = switch self {
        case .bluetoothPrivacy: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        case .bluetooth: "x-apple.systempreferences:com.apple.BluetoothSettings"
        case .localNetworkPrivacy: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        case .loginItems: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        case .sound: "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        }
        return URL(string: string)!
    }

    func open() {
        if self == .loginItems {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        NSWorkspace.shared.open(url)
    }
}
