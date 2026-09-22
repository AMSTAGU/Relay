#if DEBUG
import Foundation

/// Debug aid: two isolated Relay instances in one process talking over real
/// Bonjour/TCP — discovery, pairing, heartbeat, rename sync, a remote order
/// and removal. Uses a fake speaker address, so no real device is touched.
enum GroupTest {
    static func run() async -> Bool {
        var ok = true
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "PASS" : "FAIL", label)
            ok = ok && condition
        }
        func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return condition()
        }

        let a = Instance(profile: "test-a", name: "Alpha")
        let b = Instance(profile: "test-b", name: "Bravo")
        defer {
            a.peers.stop(); b.peers.stop()
            a.store.purge(); b.store.purge()
        }

        check(await wait(10) { b.peers.discovered[a.store.deviceID] != nil }, "Bravo discovers Alpha over Bonjour")

        let joiner = b.peers.beginPairing(with: b.peers.discovered[a.store.deviceID]!)
        joiner.onWelcome = { snapshot, key in Task { await b.coordinator.joinGroup(snapshot, key: key) } }
        joiner.start()
        _ = await wait(5) { joiner.phase == .waitingForCode && a.peers.activeHost != nil }
        if let code = a.peers.activeHost?.code { joiner.submit(code) }
        check(await wait(10) { joiner.phase == .succeeded }, "pairing succeeds")
        check(await wait(5) { b.store.group.groupID == a.store.group.groupID }, "Bravo adopts Alpha's group")
        check(a.store.member(b.store.deviceID) != nil, "Alpha lists Bravo as a member")
        check(await wait(25) { a.peers.isOnline(b.store.deviceID) && b.peers.isOnline(a.store.deviceID) }, "both see each other online")

        a.coordinator.setIdentity(name: "Alpha 2")
        check(await wait(10) { b.coordinator.identity(of: a.store.deviceID).name == "Alpha 2" }, "rename reaches Bravo")

        a.coordinator.setSpeaker(SpeakerInfo(address: "00-00-00-00-00-01", name: "Fausse enceinte"))
        check(await wait(10) { b.store.speaker?.address == "00-00-00-00-00-01" }, "speaker choice reaches Bravo")

        let order = b.coordinator.orderedMembers.map(\.id)
        check(order == [b.store.deviceID, a.store.deviceID], "menu order: this Mac first, then the others")
        check(b.coordinator.nextCycleTarget() == .mac(b.store.deviceID), "right click from « Aucun Mac » goes to the first Mac")

        await b.coordinator.switchTo(.mac(a.store.deviceID))
        let error = b.coordinator.lastError ?? ""
        check(error.contains("Alpha 2"), "remote connect order runs on Alpha and its failure is reported: \(error)")
        check(b.store.isLocked, "Bravo locked itself while handing over")

        await b.coordinator.switchTo(.none)
        check(await wait(5) { a.store.isLocked }, "« Aucun Mac » locks Alpha too")

        await a.coordinator.removeMember(b.store.deviceID)
        check(await wait(10) { b.store.group.groupID != a.store.group.groupID && b.store.peers.isEmpty }, "removed Mac leaves the group")

        return ok
    }

    private final class Instance {
        let store: Store
        let permissions = Permissions()
        let speaker = SpeakerController()
        let peers: PeerService
        let coordinator: SwitchCoordinator

        init(profile: String, name: String) {
            store = Store(profile: profile)
            store.purge()
            store.resetAll()
            store.setIdentity(name: name)
            peers = PeerService(store: store)
            coordinator = SwitchCoordinator(store: store, speaker: speaker, peers: peers, permissions: permissions)
            coordinator.start()
            coordinator.startNetworking()
        }
    }
}
#endif
