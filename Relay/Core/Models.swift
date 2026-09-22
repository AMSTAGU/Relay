import Foundation

/// A Mac taking part in a group: stable ID plus the name and SF Symbol the user picked.
struct DeviceIdentity: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var symbol: String
}

/// The shared speaker. The address is normalized (`aa-bb-cc-dd-ee-ff`).
struct SpeakerInfo: Codable, Hashable, Sendable {
    var address: String
    var name: String

    nonisolated static func normalize(_ address: String) -> String {
        let hex = address.lowercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return address.lowercased() }
        var parts: [String] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index..<next]))
            index = next
        }
        return parts.joined(separator: "-")
    }
}

/// Group membership, replicated on every Mac. The highest `revision` wins.
struct GroupSnapshot: Codable, Hashable, Sendable {
    var groupID: String
    var revision: Int
    var members: [DeviceIdentity]
    var speaker: SpeakerInfo?

    static func solo(_ identity: DeviceIdentity) -> GroupSnapshot {
        GroupSnapshot(groupID: UUID().uuidString, revision: 0, members: [identity], speaker: nil)
    }
}

enum Activity: String, Codable, Sendable {
    case idle, connecting, releasing
}

/// What each Mac reports about itself. Every Mac tells the truth about its own
/// Bluetooth link; "who has the speaker" is derived from these reports.
struct PeerState: Codable, Hashable, Sendable {
    var identity: DeviceIdentity
    var speakerConnected: Bool
    var locked: Bool
    var activity: Activity
    var groupRevision: Int
}

/// Where the speaker should go.
enum SwitchTarget: Hashable, Sendable {
    case mac(String)
    case none
}

struct AppSettings: Codable, Sendable {
    var deviceID: String
    var name: String
    var symbol: String
    var onboardingCompleted = false
    var releaseOnSleep = false
    /// Locked Macs disconnect the speaker as soon as macOS reconnects it on its own.
    var locked = false
    /// Offer to bring the speaker here when media starts playing on this Mac.
    var suggestHandoff = true
    var group: GroupSnapshot

    var identity: DeviceIdentity {
        DeviceIdentity(id: deviceID, name: name, symbol: symbol)
    }

    static func fresh() -> AppSettings {
        let id = UUID().uuidString
        let identity = DeviceIdentity(id: id, name: SystemInfo.computerName, symbol: DeviceSymbols.suggested)
        return AppSettings(deviceID: id, name: identity.name, symbol: identity.symbol, group: .solo(identity))
    }
}

extension AppSettings {
    /// Tolerant decoding: settings saved by an older version lack the newer
    /// keys, and must not be thrown away (that would drop the group).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decode(String.self, forKey: .symbol)
        group = try c.decode(GroupSnapshot.self, forKey: .group)
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        releaseOnSleep = try c.decodeIfPresent(Bool.self, forKey: .releaseOnSleep) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        suggestHandoff = try c.decodeIfPresent(Bool.self, forKey: .suggestHandoff) ?? true
    }
}
