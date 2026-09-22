import CryptoKit
import Foundation
import Observation

/// Settings in UserDefaults (Codable), group secret in the Keychain.
@Observable
final class Store {
    private(set) var settings: AppSettings
    private(set) var groupKey: SymmetricKey

    @ObservationIgnored private let defaultsKey: String
    @ObservationIgnored private let keychainAccount: String
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// `profile` isolates settings and secret (used by the debug harness only).
    init(profile: String = "") {
        defaultsKey = profile.isEmpty ? "settings.v1" : "settings.v1.\(profile)"
        keychainAccount = profile.isEmpty ? Keychain.defaultAccount : "\(Keychain.defaultAccount)-\(profile)"
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .fresh()
        }
        if let key = Keychain.loadGroupKey(account: keychainAccount) {
            groupKey = key
        } else {
            // A missing key means the group can no longer talk: start a fresh solo group.
            groupKey = SymmetricKey(size: .bits256)
            Keychain.saveGroupKey(groupKey, account: keychainAccount)
            settings.group = .solo(settings.identity)
        }
        save()
    }

    // MARK: Accessors

    var identity: DeviceIdentity { settings.identity }
    var deviceID: String { settings.deviceID }
    var group: GroupSnapshot { settings.group }
    var speaker: SpeakerInfo? { settings.group.speaker }
    var isLocked: Bool { settings.locked }

    /// Other members of the group (never includes this Mac).
    var peers: [DeviceIdentity] {
        settings.group.members.filter { $0.id != settings.deviceID }
    }

    func member(_ id: String) -> DeviceIdentity? {
        settings.group.members.first { $0.id == id }
    }

    func displayName(_ id: String) -> String {
        member(id)?.name ?? "un Mac"
    }

    // MARK: Mutations

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        save()
    }

    func setLocked(_ locked: Bool) {
        guard settings.locked != locked else { return }
        update { $0.locked = locked }
    }

    /// Renames this Mac or changes its icon, and records it in the group.
    func setIdentity(name: String? = nil, symbol: String? = nil) {
        update { s in
            if let name { s.name = name }
            if let symbol { s.symbol = symbol }
            let me = s.identity
            if let index = s.group.members.firstIndex(where: { $0.id == me.id }) {
                s.group.members[index] = me
            } else {
                s.group.members.append(me)
            }
            s.group.revision += 1
        }
    }

    func setSpeaker(_ speaker: SpeakerInfo?) {
        update { s in
            s.group.speaker = speaker
            s.group.revision += 1
        }
    }

    func addMember(_ identity: DeviceIdentity) {
        update { s in
            s.group.members.removeAll { $0.id == identity.id }
            s.group.members.append(identity)
            s.group.revision += 1
        }
    }

    func removeMember(_ id: String) {
        update { s in
            s.group.members.removeAll { $0.id == id }
            s.group.revision += 1
        }
    }

    /// Applies a snapshot received from a peer. Returns false when this Mac is no longer part of it.
    @discardableResult
    func merge(_ snapshot: GroupSnapshot) -> Bool {
        guard snapshot.groupID == settings.group.groupID, snapshot.revision > settings.group.revision else { return true }
        guard snapshot.members.contains(where: { $0.id == settings.deviceID }) else {
            leaveGroup()
            return false
        }
        update { s in
            var merged = snapshot
            // This Mac is the authority on its own name and icon.
            if let index = merged.members.firstIndex(where: { $0.id == s.deviceID }) {
                merged.members[index] = s.identity
            }
            s.group = merged
        }
        return true
    }

    /// Joins another group after pairing.
    func adoptGroup(_ snapshot: GroupSnapshot, key: SymmetricKey) {
        let previousSpeaker = settings.group.speaker
        groupKey = key
        Keychain.saveGroupKey(key, account: keychainAccount)
        update { s in
            var adopted = snapshot
            if !adopted.members.contains(where: { $0.id == s.deviceID }) {
                adopted.members.append(s.identity)
            }
            if adopted.speaker == nil, let previousSpeaker {
                adopted.speaker = previousSpeaker
                adopted.revision += 1
            }
            s.group = adopted
        }
    }

    /// Leaves the group but keeps this Mac's name, icon and speaker.
    func leaveGroup() {
        let speaker = settings.group.speaker
        groupKey = SymmetricKey(size: .bits256)
        Keychain.saveGroupKey(groupKey, account: keychainAccount)
        update { s in
            s.group = .solo(s.identity)
            s.group.speaker = speaker
            s.locked = false
        }
    }

    func resetAll() {
        defaults.removeObject(forKey: defaultsKey)
        Keychain.deleteGroupKey(account: keychainAccount)
        settings = .fresh()
        groupKey = SymmetricKey(size: .bits256)
        Keychain.saveGroupKey(groupKey, account: keychainAccount)
        save()
    }

    #if DEBUG
    /// Removes everything this store wrote (debug harness cleanup).
    func purge() {
        defaults.removeObject(forKey: defaultsKey)
        Keychain.deleteGroupKey(account: keychainAccount)
    }
    #endif

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
