//
//  AppAudioMixer.swift
//  boringNotch
//
//  Per-app volume with no audio driver. An app below 100% gets a Core Audio
//  process tap that mutes its normal output and plays the captured audio back
//  at the chosen level. An app at 100% isn't touched at all.
//
//  The process-tap approach and the handling of output buffer layouts are
//  adapted from Vorssaint (https://github.com/vorssaint/vorssaint-utils),
//  Copyright (C) 2026 Vorssaint, licensed GPL-3.0-or-later.
//

import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Defaults
import OSLog

// MARK: - Engine

/// One app's tap, aggregate device and render callback.
@available(macOS 14.2, *)
final class AppAudioEngine: @unchecked Sendable {
    let objects: Set<AudioObjectID>
    let outputUID: String

    // Shared with the realtime thread, which may not lock or allocate. A
    // 32-bit aligned float is read and written whole.
    private let target = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let applied = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?

    init?(objects: [AudioObjectID], outputUID: String, gain: Float) {
        self.objects = Set(objects)
        self.outputUID = outputUID
        target.initialize(to: gain)
        applied.initialize(to: 1)

        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else {
            tap = kAudioObjectUnknown
            return nil
        }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, format.mChannelsPerFrame > 0 else {
            stop()
            return nil
        }
        let channels = Int(format.mChannelsPerFrame)

        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dysland Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate) == noErr,
              aggregate != kAudioObjectUnknown else {
            aggregate = kAudioObjectUnknown
            stop()
            return nil
        }

        let target = self.target
        let applied = self.applied
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil, { _, input, _, output, _ in
            Self.render(input: input, output: output, tapChannels: channels, target: target.pointee, applied: applied)
        }) == noErr, ioProc != nil, AudioDeviceStart(aggregate, ioProc) == noErr else {
            stop()
            return nil
        }
    }

    deinit {
        stop()
        target.deallocate()
        applied.deallocate()
    }

    func setGain(_ gain: Float) { target.pointee = gain }

    /// Blocks until the render callback has finished. Never call on the main thread.
    func stop() {
        if aggregate != kAudioObjectUnknown, let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = kAudioObjectUnknown
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = kAudioObjectUnknown
    }

    /// Realtime thread: no allocation, locks or logging.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                               tapChannels: Int, target: Float, applied: UnsafeMutablePointer<Float>) {
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }

        // The tap comes after any input the output device has of its own.
        var found: AudioBuffer?
        for index in stride(from: sources.count - 1, through: 0, by: -1)
        where Int(sources[index].mNumberChannels) == tapChannels {
            found = sources[index]
            break
        }
        guard let source = found, let data = source.mData else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let frames = Int(source.mDataByteSize) / (MemoryLayout<Float>.size * tapChannels)
        guard frames > 0 else { return }

        // Ramped across the buffer so a slider move never clicks.
        let start = applied.pointee
        let step = (target - start) / Float(frames)
        applied.pointee = target

        // Channels are numbered across buffers, so one stereo stream and two
        // mono streams both get left and right.
        let totalChannels = outputs.reduce(0) { $0 + Int($1.mNumberChannels) }
        var channel = 0
        for buffer in outputs {
            let width = Int(buffer.mNumberChannels)
            defer { channel += width }
            guard width > 0, let raw = buffer.mData else { continue }
            let out = raw.assumingMemoryBound(to: Float.self)
            let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * width))
            for c in 0..<width where channel + c < 2 {
                let lane = channel + c
                for frame in 0..<count {
                    let gain = start + step * Float(frame)
                    var sample: Float
                    if totalChannels == 1 {
                        sample = 0
                        for s in 0..<tapChannels { sample += samples[frame * tapChannels + s] }
                        sample /= Float(tapChannels)
                    } else {
                        sample = samples[frame * tapChannels + lane % tapChannels]
                    }
                    out[frame * width + c] = max(-1, min(1, sample * gain))
                }
            }
        }
    }
}

// MARK: - Mixer

@MainActor
final class AppAudioMixer: ObservableObject {
    static let shared = AppAudioMixer()

    struct App: Identifiable, Equatable {
        let id: String
        let name: String
        let icon: NSImage?
        var objects: [AudioObjectID]
        var isPlaying: Bool
        var volume: Double
        var isMuted: Bool
        /// Tapping a call app can break its echo cancellation, so it's left alone.
        var isAdjustable: Bool
    }

    @Published private(set) var apps: [App] = []
    @Published private(set) var isSupported = false

    private let log = Logger(subsystem: "boringnotch.mixer", category: "mixer")
    private let engineQueue = DispatchQueue(label: "boringnotch.mixer.engines", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "boringnotch.mixer.scan", qos: .utility)

    private var engines: [String: AnyObject] = [:]
    private var building: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    private var lastPlaying: [String: Date] = [:]
    private var timer: Timer?
    private var panelVisible = false
    private var started = false
    private var scanPending = false
    private var reconcileTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    private var volumes: [String: Double] = Defaults[.appVolumes]
    private var mutes: [String: Bool] = Defaults[.appMutes]

    /// How long an app that went quiet keeps its tap, so gaps between tracks
    /// don't rebuild it.
    private static let idleGrace: TimeInterval = 15
    private static let callApps: Set<String> = [
        "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.cisco.webexmeetingsapp", "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
    ]

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        guard #available(macOS 14.2, *) else { return }
        isSupported = true
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated { AppAudioMixer.shared.scan() }
            }
        }
        updateTimer()
        scan()
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        updateTimer()
        if visible { scan() }
    }

    func setVolume(_ volume: Double, for id: String) {
        let clamped = min(max(volume, 0), 1)
        volumes[id] = clamped
        if let index = apps.firstIndex(where: { $0.id == id }) { apps[index].volume = clamped }
        changed(id)
    }

    func toggleMute(_ id: String) {
        let muted = !(mutes[id] ?? false)
        mutes[id] = muted
        if let index = apps.firstIndex(where: { $0.id == id }) { apps[index].isMuted = muted }
        changed(id)
    }

    private func changed(_ id: String) {
        if #available(macOS 14.2, *), let engine = engines[id] as? AppAudioEngine { engine.setGain(gain(for: id)) }
        saveLater()
        updateTimer()
        reconcileLater()
    }

    private func saveLater() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            Defaults[.appVolumes] = self.volumes.filter { $0.value < 0.995 }
            Defaults[.appMutes] = self.mutes.filter { $0.value }
        }
    }

    /// The slider reads evenly because hearing is roughly logarithmic.
    private func gain(for id: String) -> Float {
        if mutes[id] == true { return 0 }
        let volume = Float(volumes[id] ?? 1)
        return volume * volume
    }

    private func needsEngine(_ id: String) -> Bool {
        mutes[id] == true || (volumes[id] ?? 1) < 0.995
    }

    /// Polls only when something depends on it; Core Audio has no single
    /// notification for "an app started playing".
    private func updateTimer() {
        let wanted = panelVisible || volumes.contains { $0.value < 0.995 } || mutes.contains { $0.value }
        if wanted, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { AppAudioMixer.shared.scan() }
            }
        } else if !wanted {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Scanning

    private struct Scanned: Sendable {
        let owner: pid_t
        var objects: [AudioObjectID]
        var isPlaying: Bool
    }

    private func scan() {
        guard isSupported, !scanPending else { return }
        scanPending = true
        scanQueue.async { [weak self] in
            let result = Self.scanProcesses()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanPending = false
                    self.apply(result)
                }
            }
        }
    }

    private nonisolated static func scanProcesses() -> [Scanned] {
        let own = getpid()
        var groups: [pid_t: Scanned] = [:]
        for object in objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            var pid: pid_t = -1
            guard read(object, kAudioProcessPropertyPID, &pid), pid > 0, pid != own else { continue }
            let owner = responsiblePID(of: pid)
            guard owner != own else { continue }
            var running: UInt32 = 0
            _ = read(object, kAudioProcessPropertyIsRunningOutput, &running)
            groups[owner, default: Scanned(owner: owner, objects: [], isPlaying: false)].objects.append(object)
            if running != 0 { groups[owner]?.isPlaying = true }
        }
        return Array(groups.values)
    }

    private func apply(_ scanned: [Scanned]) {
        var next: [App] = []
        let now = Date()
        for item in scanned {
            guard let running = NSRunningApplication(processIdentifier: item.owner),
                  running.activationPolicy != .prohibited,
                  let id = running.bundleIdentifier else { continue }
            if item.isPlaying { lastPlaying[id] = now }
            next.append(App(id: id, name: running.localizedName ?? id, icon: running.icon,
                            objects: item.objects.sorted(), isPlaying: item.isPlaying,
                            volume: volumes[id] ?? 1, isMuted: mutes[id] ?? false,
                            isAdjustable: !Self.callApps.contains(id)))
        }
        next.sort {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if next != apps { apps = next }
        reconcile()
    }

    // MARK: Engines

    private func reconcileLater() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    private func reconcile() {
        guard #available(macOS 14.2, *), let outputUID = Self.defaultOutputUID() else { return }
        let now = Date()
        var wanted: [String: App] = [:]
        for app in apps where app.isAdjustable && needsEngine(app.id) {
            let recent = lastPlaying[app.id].map { now.timeIntervalSince($0) < Self.idleGrace } ?? false
            if app.isPlaying || recent { wanted[app.id] = app }
        }

        for (id, object) in engines {
            guard let engine = object as? AppAudioEngine else { continue }
            if let app = wanted[id], engine.objects == Set(app.objects), engine.outputUID == outputUID { continue }
            engines[id] = nil
            engineQueue.async { engine.stop() }
        }

        for (id, app) in wanted where engines[id] == nil && !building.contains(id) {
            if let retry = retryAfter[id], retry > now { continue }
            building.insert(id)
            let objects = app.objects
            let gain = gain(for: id)
            engineQueue.async { [weak self] in
                let engine = AppAudioEngine(objects: objects, outputUID: outputUID, gain: gain)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.building.remove(id)
                        if let engine {
                            self.engines[id] = engine
                            engine.setGain(self.gain(for: id))
                            self.retryAfter[id] = nil
                            self.log.info("Mixer engaged for \(id, privacy: .public)")
                        } else {
                            self.retryAfter[id] = Date().addingTimeInterval(10)
                            self.log.error("Mixer could not tap \(id, privacy: .public)")
                        }
                        self.reconcile()
                    }
                }
            }
        }
    }

    // MARK: Core Audio helpers

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private nonisolated static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    private nonisolated static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device),
              device != kAudioObjectUnknown else { return nil }
        var uid: Unmanaged<CFString>?
        var address = address(kAudioDevicePropertyDeviceUID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard withUnsafeMutablePointer(to: &uid, {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// Browsers play from helper processes; the app they belong to is what
    /// the user knows. The symbol isn't in a public header, so it's optional.
    private nonisolated static func responsiblePID(of pid: pid_t) -> pid_t {
        typealias Function = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return pid
        }
        let owner = unsafeBitCast(symbol, to: Function.self)(pid)
        return owner > 0 ? owner : pid
    }
}
