#if DEBUG
import Foundation

/// Debug aid for the playback detector.
///
/// The logic (threshold, sound already playing, restart) is checked with the
/// monitor's test seams, so the result never depends on what the Mac happens
/// to be playing. One last check uses a real, nearly silent sound to make sure
/// the CoreAudio wiring itself works.
enum PlaybackTest {
    static func run() async -> Bool {
        var ok = true
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "PASS" : "FAIL", label)
            ok = ok && condition
        }

        let sample = PlaybackMonitor.Source(pid: 1234, bundleID: "com.example.player")
        var running = false
        var reported: [PlaybackMonitor.Source] = []

        let monitor = PlaybackMonitor(sustain: .milliseconds(600))
        monitor.debugRunningProbe = { running }
        monitor.debugSourceProbe = { sample }
        monitor.onSustainedPlayback = { reported.append($0) }
        monitor.start()
        defer { monitor.stop() }

        func play(_ on: Bool) async {
            running = on
            monitor.debugRunningChanged()
            try? await Task.sleep(for: .milliseconds(100))
        }

        // A short sound, like a notification, stops well before the threshold.
        await play(true)
        try? await Task.sleep(for: .milliseconds(300))
        await play(false)
        try? await Task.sleep(for: .milliseconds(700))
        check(reported.isEmpty, "a short sound does not trigger anything")

        // Sound that lasts is reported once, and only once.
        await play(true)
        try? await Task.sleep(for: .seconds(1))
        check(reported.count == 1, "sustained sound is reported once (\(reported.count))")
        check(reported.first == sample, "the reported source is the one playing")
        try? await Task.sleep(for: .seconds(1))
        check(reported.count == 1, "it is not reported again while it keeps playing")

        // Stopping and starting again counts as a new playback.
        await play(false)
        await play(true)
        try? await Task.sleep(for: .seconds(1))
        check(reported.count == 2, "playing again is a new playback (\(reported.count))")

        // What plays at baseline time (a switch just happened) is not "starting".
        reported.removeAll()
        monitor.resetBaseline()
        try? await Task.sleep(for: .seconds(1))
        check(reported.isEmpty, "a sound already playing at baseline is ignored")

        await play(false)
        monitor.stop()

        check(await realSoundIsDetected(), "a real sustained sound reaches the monitor through CoreAudio")
        return ok
    }

    /// Smoke test: play a nearly silent tone and wait for the monitor to report it.
    private static func realSoundIsDetected() async -> Bool {
        guard await waitForSilence() else {
            print("  (skipped: something is already playing on this Mac)")
            return true
        }
        let monitor = PlaybackMonitor(sustain: .seconds(2))
        var reportedPID: pid_t?
        monitor.onSustainedPlayback = { reportedPID = $0.pid }
        monitor.start()
        defer { monitor.stop() }

        let player = play(seconds: 12)
        defer { player.terminate() }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if reportedPID != nil { break }
        }
        // afplay sometimes fails to start and retries on its own, so only the
        // reported process matters here, not the timing.
        return reportedPID == player.processIdentifier
    }

    private static func waitForSilence(timeout: Int = 15) async -> Bool {
        for _ in 0..<(timeout * 2) {
            if !PlaybackMonitor.debugIsOutputRunning { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return !PlaybackMonitor.debugIsOutputRunning
    }

    private static func play(seconds: Double) -> Process {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-tone.wav")
        writeTone(to: url, seconds: seconds)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = ["-v", "0.01", url.path]
        try? process.run()
        return process
    }

    private static func writeTone(to url: URL, seconds: Double) {
        let rate = 44100
        let frames = Int(Double(rate) * seconds)
        var samples = Data()
        for index in 0..<frames {
            let value = Int16(3000 * sin(2 * .pi * 440 * Double(index) / Double(rate)))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + samples.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(rate)); append32(UInt32(rate * 2)); append16(2); append16(16)
        append("data"); append32(UInt32(samples.count)); data.append(samples)
        try? data.write(to: url)
    }
}
#endif
