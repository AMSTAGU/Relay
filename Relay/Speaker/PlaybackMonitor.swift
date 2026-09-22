import AppKit
import CoreAudio
import Darwin
import OSLog

/// Notices when media starts playing on this Mac, as opposed to an alert,
/// a notification or a short interface sound.
///
/// Entirely event-driven: CoreAudio tells us when the default output device
/// starts and stops running. A run that lasts `sustain` seconds is reported
/// once, with the app behind it. Nothing runs while nothing plays.
///
/// The device-level signal is used rather than the per-process one because
/// CoreAudio reliably notifies the first but not the second.
final class PlaybackMonitor {
    struct Source: Equatable {
        let pid: pid_t
        let bundleID: String
    }

    /// Sound played for `sustain` without interruption.
    var onSustainedPlayback: ((Source) -> Void)?

    private let sustain: Duration
    private var started = false
    private var isRunning = false
    /// True while a run that was already going at the last baseline continues:
    /// it must not be reported as a new playback.
    private var suppressCurrentRun = false
    private var pending: Task<Void, Never>?
    private var deviceListener: (AudioObjectID, AudioObjectPropertyListenerBlock)?
    private var systemListener: AudioObjectPropertyListenerBlock?

    private static let ownPID = getpid()
    /// Processes whose sound is never "media".
    private static let excludedBundlePrefixes = [
        Bundle.main.bundleIdentifier ?? "com.Amaury.Relay",
        "com.apple.systemsoundserverd", "com.apple.notificationcenterui", "com.apple.UserNotificationCenter",
        "com.apple.usernoted", "com.apple.accessibility", "com.apple.siri", "com.apple.SiriNCService",
        "com.apple.CoreSpeech", "com.apple.loginwindow", "com.apple.coreaudiod",
    ]
    private static let excludedProcessNames: Set<String> = [
        "systemsoundserverd", "usernoted", "NotificationCenter", "coreaudiod", "loginwindow",
    ]

    init(sustain: Duration = .seconds(5)) {
        self.sustain = sustain
    }

    func start() {
        guard !started else { return }
        started = true
        Self.detachHALFromMainRunLoop()
        watchDefaultOutput()
        watchDefaultDeviceChanges()
        isRunning = currentlyRunning()
        suppressCurrentRun = isRunning
        Log.speaker.info("Playback monitor started")
    }

    func stop() {
        guard started else { return }
        started = false
        unwatchDefaultOutput()
        if let systemListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, systemListener)
        }
        systemListener = nil
        pending?.cancel()
        pending = nil
        isRunning = false
        suppressCurrentRun = false
    }

    /// What is playing right now stops counting as a new playback.
    func resetBaseline() {
        pending?.cancel()
        pending = nil
        isRunning = currentlyRunning()
        suppressCurrentRun = isRunning
    }

    #if DEBUG
    /// Test seams: replace the CoreAudio probes and drive changes by hand.
    var debugRunningProbe: (() -> Bool)?
    var debugSourceProbe: (() -> Source?)?
    func debugRunningChanged() { runningChanged() }

    /// Is anything playing on the default output right now (test harness).
    static var debugIsOutputRunning: Bool { Self.isDefaultOutputRunning() }

    var debugSummary: String {
        "running=\(isRunning) suppressed=\(suppressCurrentRun) pending=\(pending != nil)"
    }
    #endif

    private func currentlyRunning() -> Bool {
        #if DEBUG
        if let debugRunningProbe { return debugRunningProbe() }
        #endif
        return Self.isDefaultOutputRunning()
    }

    private func currentSource() -> Source? {
        #if DEBUG
        if let debugSourceProbe { return debugSourceProbe() }
        #endif
        return Self.currentSource()
    }

    // MARK: Runs

    private func runningChanged() {
        let running = currentlyRunning()
        guard running != isRunning else { return }
        isRunning = running

        guard running else {
            // Silence: the next run counts again.
            pending?.cancel()
            pending = nil
            suppressCurrentRun = false
            return
        }
        guard !suppressCurrentRun else { return }

        pending = Task { [weak self, sustain] in
            try? await Task.sleep(for: sustain)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            // Short sounds (alerts, notifications) are long gone by now.
            guard self.currentlyRunning() else { return }
            guard let source = self.currentSource() else { return }
            self.suppressCurrentRun = true
            Log.speaker.info("Sustained playback from \(source.bundleID.isEmpty ? "pid \(source.pid)" : source.bundleID, privacy: .public)")
            self.onSustainedPlayback?(source)
        }
    }

    /// The process behind the sound, when CoreAudio exposes process objects
    /// (macOS 14.2+). Returns nil when only excluded processes are playing.
    private static func currentSource() -> Source? {
        let objects = processObjects()
        guard !objects.isEmpty else { return Source(pid: 0, bundleID: "") }
        var fallback: Source?
        for object in objects where uint32(object, kAudioProcessPropertyIsRunningOutput) == 1 {
            let pid = pid_t(bitPattern: uint32(object, kAudioProcessPropertyPID) ?? 0)
            let bundleID = string(object, kAudioProcessPropertyBundleID) ?? ""
            guard !isExcluded(pid: pid, bundleID: bundleID) else { continue }
            let source = Source(pid: pid, bundleID: bundleID)
            // Prefer a process that belongs to a visible app.
            if NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular { return source }
            fallback = fallback ?? source
        }
        return fallback
    }

    private static func isExcluded(pid: pid_t, bundleID: String) -> Bool {
        if pid == ownPID { return true }
        if excludedBundlePrefixes.contains(where: { !$0.isEmpty && bundleID.hasPrefix($0) }) { return true }
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if excludedProcessNames.contains(name) { return true }
        }
        return false
    }

    // MARK: Listeners

    private func watchDefaultOutput() {
        guard let device = AudioOutput.defaultOutputID else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.runningChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
            deviceListener = (device, block)
        }
    }

    private func unwatchDefaultOutput() {
        guard let (device, block) = deviceListener else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        deviceListener = nil
    }

    private func watchDefaultDeviceChanges() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.unwatchDefaultOutput()
                self.watchDefaultOutput()
                // Apps restart their audio on the new device: not a new playback.
                self.resetBaseline()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            systemListener = block
        }
    }

    // MARK: CoreAudio helpers

    private static func isDefaultOutputRunning() -> Bool {
        guard let device = AudioOutput.defaultOutputID else { return false }
        return uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    /// By default the HAL delivers property notifications through the main run
    /// loop; setting its run loop to nil gives it a thread of its own, so
    /// listeners fire wherever the app runs from.
    private static func detachHALFromMainRunLoop() {
        var address = address(kAudioHardwarePropertyRunLoop)
        // A null CFRunLoopRef, passed as a raw pointer to keep ARC out of it.
        var runLoop: UnsafeRawPointer? = nil
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<UnsafeRawPointer?>.size), &runLoop
        )
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

extension AudioOutput {
    /// Headphones or a Bluetooth headset on this Mac: the user is listening
    /// privately, so never offer to move the speaker here.
    static var isPrivateOutput: Bool {
        guard let id = defaultOutputID else { return false }
        if outputDevices().first(where: { $0.id == id })?.isBluetooth == true { return true }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source) == noErr else { return false }
        return source == 0x6864_706E // 'hdpn': built-in headphone jack
    }
}
