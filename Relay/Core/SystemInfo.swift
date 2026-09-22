import AppKit
import CoreGraphics
import IOKit.ps
import SystemConfiguration

enum SystemInfo {
    static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }

    /// e.g. "MacBookPro18,3", "Macmini9,1", "Mac14,13".
    static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    static var hasBuiltInDisplay: Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.contains { CGDisplayIsBuiltin($0) != 0 }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// The SF Symbols offered for a Mac, filtered to what this macOS actually ships.
enum DeviceSymbols {
    static let candidates = [
        "macbook", "laptopcomputer", "macmini", "macstudio",
        "desktopcomputer", "display", "macpro.gen3", "macpro.gen2",
    ]

    static let fallback = "desktopcomputer"

    static var available: [String] {
        candidates.filter(exists)
    }

    static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// Returns `name` when it exists on this macOS, otherwise a safe fallback.
    static func resolved(_ name: String) -> String {
        if exists(name) { return name }
        if name.hasPrefix("mac") && exists("laptopcomputer") && name.contains("book") { return "laptopcomputer" }
        return exists(fallback) ? fallback : "display"
    }

    /// Guess from hw.model, then from the hardware itself for the "MacXX,Y" identifiers.
    static var suggested: String {
        let model = SystemInfo.hardwareModel
        let guess: String
        if model.hasPrefix("MacBook") {
            guess = "macbook"
        } else if model.hasPrefix("Macmini") {
            guess = "macmini"
        } else if model.hasPrefix("MacPro") {
            guess = "macpro.gen3"
        } else if model.hasPrefix("iMac") {
            guess = "desktopcomputer"
        } else if SystemInfo.hasInternalBattery {
            guess = "macbook"
        } else if SystemInfo.hasBuiltInDisplay {
            guess = "desktopcomputer"
        } else {
            guess = "macmini"
        }
        return resolved(guess)
    }
}
