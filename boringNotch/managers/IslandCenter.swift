//
//  IslandCenter.swift
//  boringNotch
//
//  Dynamic Island–style live activities for the closed notch, modelled on the
//  new MacBook Pro's island:
//  - Short pop-ups that drop out of the notch and tuck back in: AirPods
//    connected (with battery), audio switching device, Focus on/off, low
//    battery, timer finished.
//  - A countdown timer / stopwatch that stays live in the closed notch, and
//    splits off into its own little pill when music is also playing.
//

import AppKit
import Combine
import CoreAudio
import Defaults
import Intents
import IOBluetooth
import OSLog
import SwiftUI

struct IslandAlert: Identifiable, Equatable {
    enum Trailing: Equatable {
        case none
        case text(String)
        case ring(Double)            // 0...1
    }

    let id = UUID()
    var icon: String
    var tint: Color
    var title: String
    var subtitle: String? = nil
    var trailing: Trailing = .none
    var duration: TimeInterval = 3.2
}

struct IslandTimer: Equatable {
    enum Kind: Equatable { case countdown, stopwatch }

    var kind: Kind
    var duration: TimeInterval            // countdown length (0 for stopwatch)
    var startedAt: Date?                  // nil while paused
    var accumulated: TimeInterval = 0     // time run before the last pause

    var isRunning: Bool { startedAt != nil }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        accumulated + (startedAt.map { date.timeIntervalSince($0) } ?? 0)
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        max(duration - elapsed(at: date), 0)
    }

    /// What the island shows: time left for a countdown, time so far for a stopwatch.
    func display(at date: Date = Date()) -> TimeInterval {
        kind == .countdown ? remaining(at: date) : elapsed(at: date)
    }

    func progress(at date: Date = Date()) -> Double {
        guard kind == .countdown, duration > 0 else { return 0 }
        return min(elapsed(at: date) / duration, 1)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

@MainActor
final class IslandCenter: ObservableObject {
    static let shared = IslandCenter()

    @Published private(set) var alert: IslandAlert?
    @Published private(set) var timer: IslandTimer?

    private var queue: [IslandAlert] = []
    private var dismissTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private let log = Logger(subsystem: "boringnotch.island", category: "island")

    private let audio = AudioDeviceWatcher()
    private let focus = FocusWatcher()
    private var cancellables: Set<AnyCancellable> = []
    private var lastLowBatteryWarning: Int = 101

    private init() {}

    /// Start watching the system for things worth popping up.
    func start() {
        audio.onChange = { [weak self] device in self?.audioDeviceChanged(device) }
        audio.start()
        focus.onChange = { [weak self] on in self?.focusChanged(on) }
        focus.start()
        watchBattery()
    }

    // MARK: - Alerts

    func show(_ alert: IslandAlert) {
        guard Defaults[.islandAlerts] else { return }
        if self.alert == nil {
            present(alert)
        } else {
            // Replace a queued alert of the same kind instead of stacking them.
            queue.removeAll { $0.icon == alert.icon }
            queue.append(alert)
        }
    }

    func dismissAlert() {
        dismissTask?.cancel()
        withAnimation(.spring(duration: 0.38, bounce: 0)) { alert = nil }
        presentNextSoon()
    }

    private func present(_ next: IslandAlert) {
        withAnimation(.spring(duration: 0.5, bounce: 0.32)) { alert = next }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.duration))
            guard !Task.isCancelled else { return }
            self?.dismissAlert()
        }
    }

    private func presentNextSoon() {
        guard !queue.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.alert == nil, !self.queue.isEmpty else { return }
            self.present(self.queue.removeFirst())
        }
    }

    // MARK: - Timer

    func startCountdown(minutes: Double) {
        let seconds = max(minutes * 60, 1)
        setTimer(IslandTimer(kind: .countdown, duration: seconds, startedAt: Date()))
    }

    func startStopwatch() {
        setTimer(IslandTimer(kind: .stopwatch, duration: 0, startedAt: Date()))
    }

    func pauseOrResume() {
        guard var t = timer else { return }
        if let started = t.startedAt {
            t.accumulated += Date().timeIntervalSince(started)
            t.startedAt = nil
        } else {
            t.startedAt = Date()
        }
        setTimer(t)
    }

    /// Add time to a running countdown (the "+1 min" button).
    func extend(by minutes: Double) {
        guard var t = timer, t.kind == .countdown else { return }
        t.duration += minutes * 60
        setTimer(t)
    }

    func cancelTimer() {
        finishTask?.cancel()
        withAnimation(.spring(duration: 0.45, bounce: 0.2)) { timer = nil }
    }

    private func setTimer(_ t: IslandTimer) {
        withAnimation(.spring(duration: 0.45, bounce: 0.25)) { timer = t }
        finishTask?.cancel()
        guard t.kind == .countdown, t.isRunning else { return }
        let left = t.remaining()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled else { return }
            self?.timerFinished()
        }
    }

    private func timerFinished() {
        guard let t = timer else { return }
        cancelTimer()
        NSSound(named: "Glass")?.play()
        show(IslandAlert(
            icon: "timer", tint: .orange,
            title: "Timer done",
            subtitle: IslandTimer.format(t.duration) + " timer",
            trailing: .text("00:00"),
            duration: 6
        ))
    }

    // MARK: - Sources

    private func audioDeviceChanged(_ device: AudioDeviceWatcher.Device) {
        let name = device.name
        let lower = name.lowercased()
        if lower.contains("airpods") || lower.contains("beats") {
            let icon: String
            if lower.contains("max") { icon = "airpodsmax" }
            else if lower.contains("pro") { icon = "airpods.pro" }
            else if lower.contains("beats") { icon = "beats.headphones" }
            else { icon = "airpods" }

            let battery = BluetoothBattery.levels(forName: name)
            var subtitle = "Connected"
            var trailing: IslandAlert.Trailing = .none
            if let b = battery {
                subtitle = b.summary
                if let main = b.headline { trailing = .ring(Double(main) / 100) }
            }
            show(IslandAlert(icon: icon, tint: .white, title: name, subtitle: subtitle, trailing: trailing))
        } else if Defaults[.islandAudioSwitchAlerts] {
            let icon = device.isBluetooth ? "headphones" : (lower.contains("display") || lower.contains("hdmi") ? "tv" : "speaker.wave.2.fill")
            show(IslandAlert(icon: icon, tint: .white, title: name, subtitle: "Now playing audio", duration: 2.6))
        }
    }

    private func focusChanged(_ on: Bool) {
        show(IslandAlert(
            icon: on ? "moon.fill" : "moon",
            tint: on ? Color(red: 0.55, green: 0.5, blue: 1) : .gray,
            title: on ? "Focus On" : "Focus Off",
            subtitle: on ? "Notifications silenced" : nil,
            duration: 2.6
        ))
    }

    private func watchBattery() {
        let battery = BatteryStatusViewModel.shared
        battery.$levelBattery
            .combineLatest(battery.$isPluggedIn)
            .receive(on: RunLoop.main)
            .sink { [weak self] level, plugged in
                guard let self else { return }
                let pct = Int(level.rounded())
                if plugged || pct > 21 { self.lastLowBatteryWarning = 101; return }
                // Warn once at 20% and once at 10%.
                for threshold in [10, 20] where pct <= threshold && self.lastLowBatteryWarning > threshold {
                    self.lastLowBatteryWarning = threshold
                    self.show(IslandAlert(
                        icon: "battery.25percent", tint: .red,
                        title: "Low Battery",
                        subtitle: "\(pct)% remaining",
                        trailing: .ring(Double(pct) / 100),
                        duration: 4
                    ))
                    break
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Default output device

/// Calls back when the default audio output device changes (AirPods
/// connecting, plugging in headphones, picking a display's speakers...).
final class AudioDeviceWatcher {
    struct Device {
        let id: AudioDeviceID
        let name: String
        let isBluetooth: Bool
    }

    var onChange: ((Device) -> Void)?
    private var lastID: AudioDeviceID = 0
    private var started = false
    private var debounce: DispatchWorkItem?

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        guard !started else { return }
        started = true
        lastID = Self.defaultOutput() ?? 0
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            self?.scheduleCheck()
        }
    }

    private func scheduleCheck() {
        // Devices often flap while connecting; wait for it to settle.
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func check() {
        guard let id = Self.defaultOutput(), id != lastID else { return }
        lastID = id
        let device = Device(id: id, name: Self.name(of: id) ?? "Audio device", isBluetooth: Self.isBluetooth(id))
        onChange?(device)
    }

    static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func name(of id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        guard status == noErr, let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

// MARK: - AirPods battery

/// Reads AirPods / Beats battery levels from IOBluetooth. These properties
/// aren't public API, so every one is checked before use and anything
/// missing just means no battery is shown.
enum BluetoothBattery {
    struct Levels {
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        var single: Int?

        var headline: Int? {
            if let single { return single }
            switch (left, right) {
            case let (l?, r?): return min(l, r)
            case let (l?, nil): return l
            case let (nil, r?): return r
            default: return nil
            }
        }

        var summary: String {
            if let single { return "\(single)% battery" }
            var parts: [String] = []
            if let left { parts.append("L \(left)%") }
            if let right { parts.append("R \(right)%") }
            if let caseLevel { parts.append("Case \(caseLevel)%") }
            return parts.isEmpty ? "Connected" : parts.joined(separator: "  ·  ")
        }
    }

    static func levels(forName name: String) -> Levels? {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        guard let device = devices.first(where: { $0.isConnected() && ($0.name ?? "") == name })
                ?? devices.first(where: { $0.isConnected() && name.contains($0.name ?? "\u{0}") })
        else { return nil }

        func read(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let n = device.value(forKey: key) as? NSNumber else { return nil }
            let v = n.intValue
            return (1...100).contains(v) ? v : nil
        }
        let levels = Levels(
            left: read("batteryPercentLeft"),
            right: read("batteryPercentRight"),
            caseLevel: read("batteryPercentCase"),
            single: read("batteryPercentSingle")
        )
        return levels.headline == nil && levels.caseLevel == nil ? nil : levels
    }
}

// MARK: - Focus

/// Watches whether a Focus mode is on. macOS only reports this to apps the
/// user has allowed (and that carry Apple's Focus entitlement), so if it
/// isn't available the Focus pop-up simply never appears.
final class FocusWatcher {
    var onChange: ((Bool) -> Void)?
    private var last: Bool?
    private var timer: Timer?
    private let log = Logger(subsystem: "boringnotch.island", category: "focus")

    func start() {
        guard Defaults[.islandFocusAlerts] else { return }
        INFocusStatusCenter.default.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log.info("Focus authorization: \(status.rawValue, privacy: .public)")
                guard status == .authorized else { return }
                self.last = INFocusStatusCenter.default.focusStatus.isFocused
                self.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.poll()
                }
            }
        }
    }

    private func poll() {
        guard let now = INFocusStatusCenter.default.focusStatus.isFocused else { return }
        if let last, last != now { onChange?(now) }
        last = now
    }
}
