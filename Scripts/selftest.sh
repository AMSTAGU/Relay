#!/bin/zsh
# Runs the protocol self-tests outside the app sandbox:
#   - message signing, replay and freshness checks
#   - pairing over loopback TCP (right and wrong code)
#   - with --group: two isolated instances over real Bonjour (pairing,
#     heartbeat, rename/speaker sync, remote connect, lock, removal).
#     Uses a fake speaker address; no real Bluetooth device is touched.
#   - with --playback: PlaybackMonitor against a real, nearly silent sound
#     (a sustained one is reported, a short one is not).
#   - with --idle [seconds]: two paired instances left idle; prints CPU time
#     and wakeups, to keep an eye on background cost.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=build/selftest
mkdir -p build
cat > build/selftest-main.swift <<'SWIFT'
import Foundation
@main enum Harness {
    static func main() async {
        if CommandLine.arguments.contains("--playback") {
            exit(await PlaybackTest.run() ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--idle") {
            let seconds = CommandLine.arguments.dropFirst(index + 1).first.flatMap(Int.init) ?? 60
            await GroupTest.idle(seconds: seconds)
            exit(0)
        }
        var ok = await SelfTest.run()
        if CommandLine.arguments.contains("--group") { ok = await GroupTest.run() && ok }
        print(ok ? "ALL PASSED" : "SOME FAILED")
        exit(ok ? 0 : 1)
    }
}
SWIFT
swiftc -swift-version 6 -default-isolation MainActor -D DEBUG -parse-as-library -o "$BIN" \
  $(find Relay/Core Relay/Network Relay/Speaker Relay/Coordinator -name '*.swift') \
  Relay/App/SelfTest.swift Relay/App/GroupTest.swift Relay/App/PlaybackTest.swift build/selftest-main.swift
# Never share the installed app's Keychain item or settings.
export RELAY_PROFILE=${RELAY_PROFILE:-harness}
"$BIN" "$@"
