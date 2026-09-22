#!/bin/zsh
# Runs the protocol self-tests outside the app sandbox:
#   - message signing, replay and freshness checks
#   - pairing over loopback TCP (right and wrong code)
#   - with --group: two isolated instances over real Bonjour (pairing,
#     heartbeat, rename/speaker sync, remote connect, lock, removal).
#     Uses a fake speaker address; no real Bluetooth device is touched.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=build/selftest
mkdir -p build
cat > build/selftest-main.swift <<'SWIFT'
import Foundation
@main enum Harness {
    static func main() async {
        var ok = await SelfTest.run()
        if CommandLine.arguments.contains("--group") { ok = await GroupTest.run() && ok }
        print(ok ? "ALL PASSED" : "SOME FAILED")
        exit(ok ? 0 : 1)
    }
}
SWIFT
swiftc -swift-version 6 -default-isolation MainActor -D DEBUG -parse-as-library -o "$BIN" \
  $(find Relay/Core Relay/Network Relay/Speaker Relay/Coordinator -name '*.swift') \
  Relay/App/SelfTest.swift Relay/App/GroupTest.swift build/selftest-main.swift
"$BIN" "$@"
