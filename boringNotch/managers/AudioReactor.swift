//
//  AudioReactor.swift
//  boringNotch
//
//  Audio levels for the liquid visualiser.
//
//  Real mode (macOS 14.2+): a Core Audio process tap on the system output
//  (needs the "System Audio Recording" permission). Samples are windowed and
//  run through an FFT; energy is split into 4 bands (bass, low-mid, mid,
//  high), normalised adaptively, and beats are detected from spikes in bass
//  energy ("spectral flux").
//
//  Simulated mode: used until real audio arrives (permission not granted,
//  tap failed, setting off). A slow energy curve with skipped beats so it
//  never feels like a metronome.
//
//  Lifecycle: the tap starts when music plays and stops ~8 s after it stops.
//

import Accelerate
import AudioToolbox
import CoreAudio
import Defaults
import Foundation
import OSLog

final class AudioReactor {
    static let shared = AudioReactor()

    struct Levels {
        var bands: SIMD4<Float>
        var beat: Float
        var isReal: Bool
    }

    private let log = Logger(subsystem: "boringnotch.liquid", category: "audio")

    // Written on the audio queue, read on main.
    private let lock = NSLock()
    private var rawBands = SIMD4<Float>(repeating: 0)
    private var rawBeat: Float = 0
    private var lastRealUpdate: CFAbsoluteTime = 0

    // Main-thread smoothing state.
    private var smooth = SIMD4<Float>(repeating: 0)
    private var beatEnvelope: Float = 0
    private var lastSample: CFAbsoluteTime?
    private var lastPlaying: CFAbsoluteTime = 0
    private var nextStartAttempt: CFAbsoluteTime = 0
    /// When the visualiser last started drawing after a gap.
    private var sessionStart: CFAbsoluteTime = 0
    /// Stops the tap once nothing is drawing. Only the open visualiser calls
    /// sample(), so nothing else would ever notice the notch had closed.
    private var watchdog: DispatchSourceTimer?

    // Simulation state.
    private var simNextBeat: Double = 0
    private var simBeatCount = 0

    // Tap state.
    private(set) var isTapRunning = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let audioQueue = DispatchQueue(label: "boringnotch.audiotap", qos: .userInteractive)
    private var sampleRate: Double = 48_000
    private var channelCount = 2

    // Analysis state (audio queue only).
    private let fftSize = 1024
    private let log2n: vDSP_Length = 10
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var ring: [Float] = []
    private var newSamples = 0
    private var bandPeak = SIMD4<Float>(repeating: 1e-3)
    private var previousBass: Float = 0
    private var fluxAverage: Float = 0
    private var lastBeatTime: CFAbsoluteTime = 0

    private init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring.reserveCapacity(fftSize * 2)
    }

    // MARK: - Public

    /// Called every frame from the visualiser (main thread).
    func sample(time t: Double, playing: Bool, songPosition: Double? = nil) -> Levels {
        let now = CFAbsoluteTimeGetCurrent()
        if now - (lastSample ?? 0) > 1 { sessionStart = now }
        manageTap(now: now, playing: playing)

        let dt = Float(min(max(now - (lastSample ?? now), 0), 0.1))
        lastSample = now

        var target = SIMD4<Float>(repeating: 0)
        var hit: Float = 0
        lock.lock()
        let isReal = isTapRunning && now - lastRealUpdate < 0.6
        if isReal {
            target = rawBands
            hit = rawBeat
            rawBeat = 0
        }
        lock.unlock()

        if !isReal && playing {
            if let songPosition, let song = SongFollower.shared.levels(at: songPosition) {
                (target, hit) = (song.bands, song.hit)
            } else {
                (target, hit) = simulate(t: t)
            }
        }
        if !playing && !isReal { target = .zero }

        // Fast attack, slower release (frame-rate independent).
        let attack = 1 - exp(-dt * 28)
        let release = 1 - exp(-dt * 6)
        for i in 0..<4 {
            let k = target[i] > smooth[i] ? attack : release
            smooth[i] += (target[i] - smooth[i]) * k
        }
        beatEnvelope = max(beatEnvelope * exp(-dt * 6), hit)
        return Levels(bands: smooth, beat: beatEnvelope, isReal: isReal)
    }

    // MARK: - Simulation

    private func simulate(t: Double) -> (SIMD4<Float>, Float) {
        let energy = 0.4 + 0.6 * (0.5 + 0.5 * sin(t * 0.05)) * (0.6 + 0.4 * sin(t * 0.14 + 1.7))
        var hit: Float = 0
        if t >= simNextBeat {
            simBeatCount += 1
            let interval = 60.0 / 112.0
            let skip = Double.random(in: 0...1) < 0.3 * (1 - energy) + 0.06
            simNextBeat = t + interval * (skip ? 2 : 1)
            if Double.random(in: 0...1) < 0.35 + 0.6 * energy {
                let accent = simBeatCount % 8 == 0 ? 1.0 : 0.7
                hit = Float(min(1, energy * Double.random(in: 0.6...1.0) * accent))
            }
        }
        let wobble = { (f: Double, p: Double) -> Float in Float(0.5 + 0.5 * sin(t * f + p)) }
        let bands = SIMD4<Float>(
            Float(energy) * (0.55 + 0.45 * wobble(1.1, 0)),
            Float(energy) * (0.4 + 0.4 * wobble(1.7, 1)),
            Float(energy) * (0.35 + 0.4 * wobble(2.3, 2)),
            Float(energy) * (0.25 + 0.5 * wobble(3.1, 3))
        )
        return (bands, hit)
    }

    // MARK: - Tap lifecycle

    private func manageTap(now: CFAbsoluteTime, playing: Bool) {
        if playing { lastPlaying = now }
        let wanted = Defaults[.realAudioReaction] && (playing || now - lastPlaying < 8)
        // Creating the tap blocks briefly, so let the opening animation finish.
        if wanted && !isTapRunning && now >= nextStartAttempt && now - sessionStart > 0.8 {
            nextStartAttempt = now + 30 // don't hammer on failure
            if #available(macOS 14.2, *) { startTap() }
        } else if !wanted && isTapRunning {
            stopTap()
        }
    }

    @available(macOS 14.2, *)
    private func startTap() {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr, tap != kAudioObjectUnknown else {
            log.error("Process tap creation failed: \(err, privacy: .public)")
            return
        }
        tapID = tap

        // Tap format
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        if err == noErr {
            sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
            channelCount = max(Int(asbd.mChannelsPerFrame), 1)
        }

        // Default output device UID (the aggregate's clock source).
        var outputID = AudioObjectID(kAudioObjectUnknown)
        address.mSelector = kAudioHardwarePropertyDefaultSystemOutputDevice
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &outputID)

        var uidRef: Unmanaged<CFString>?
        address.mSelector = kAudioDevicePropertyDeviceUID
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(outputID, &address, 0, nil, &size, &uidRef)
        let outputUID = (uidRef?.takeRetainedValue() as String?) ?? ""

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dysland Liquid Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]

        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard err == noErr else {
            log.error("Aggregate device creation failed: \(err, privacy: .public)")
            cleanup()
            return
        }
        aggregateID = aggregateDevice

        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateDevice, audioQueue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard err == noErr, let proc else {
            log.error("IOProc creation failed: \(err, privacy: .public)")
            cleanup()
            return
        }
        procID = proc

        err = AudioDeviceStart(aggregateDevice, proc)
        guard err == noErr else {
            log.error("AudioDeviceStart failed: \(err, privacy: .public)")
            cleanup()
            return
        }
        isTapRunning = true
        startWatchdog()
        log.info("Audio tap running at \(self.sampleRate, privacy: .public) Hz, \(self.channelCount, privacy: .public) ch")
    }

    private func startWatchdog() {
        // A dispatch timer, because the visualiser can call in from a thread
        // with no run loop, where a plain Timer would silently never fire.
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isTapRunning,
                  CFAbsoluteTimeGetCurrent() - (self.lastSample ?? 0) > 2 else { return }
            self.stopTap()
            self.nextStartAttempt = 0 // reopening should reconnect straight away
        }
        timer.resume()
        watchdog = timer
    }

    private func stopTap() {
        watchdog?.cancel()
        watchdog = nil
        cleanup()
        log.info("Audio tap stopped")
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isTapRunning = false
    }

    // MARK: - Analysis (audio queue)

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)

        for f in 0..<frames {
            var v = samples[f * channels]
            if channels > 1 { v = (v + samples[f * channels + 1]) * 0.5 }
            ring.append(v)
        }
        newSamples += frames
        if ring.count > fftSize { ring.removeFirst(ring.count - fftSize) }
        guard ring.count == fftSize, newSamples >= fftSize / 2 else { return }
        newSamples = 0
        analyze()
    }

    private func analyze() {
        guard let fftSetup else { return }
        let half = fftSize / 2

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var rms: Float = 0
        vDSP_rmsqv(ring, 1, &rms, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { wPtr in
                    wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        let binHz = Float(sampleRate) / Float(fftSize)
        func energy(_ lo: Float, _ hi: Float) -> Float {
            let a = max(1, Int(lo / binHz)), b = min(half - 1, max(a + 1, Int(hi / binHz)))
            var sum: Float = 0
            vDSP_sve(Array(magnitudes[a...b]), 1, &sum, vDSP_Length(b - a + 1))
            return sqrt(sum / Float(b - a + 1))
        }
        var e = SIMD4<Float>(energy(30, 160), energy(160, 600), energy(600, 2500), energy(2500, 10000))

        // Silence gate.
        if rms < 0.0008 { e = .zero }

        // Adaptive normalisation: each band relative to its recent peak.
        bandPeak = pointwiseMax(bandPeak * Float(0.997), e)
        bandPeak = pointwiseMax(bandPeak, SIMD4<Float>(repeating: 1e-3))
        var normalized = e / bandPeak
        normalized = normalized.clamped(lowerBound: .zero, upperBound: SIMD4<Float>(repeating: 1))
        // A little curve so quiet parts still move and loud parts pop.
        normalized = SIMD4(pow(normalized.x, 1.3), pow(normalized.y, 1.2), pow(normalized.z, 1.2), pow(normalized.w, 1.1))

        // Beat: bass energy jumping well above its recent average.
        let now = CFAbsoluteTimeGetCurrent()
        let flux = max(0, e.x - previousBass)
        previousBass = e.x
        fluxAverage = fluxAverage * 0.93 + flux * 0.07
        var beat: Float = 0
        if flux > fluxAverage * 2.0, normalized.x > 0.35, now - lastBeatTime > 0.2 {
            lastBeatTime = now
            beat = min(1, 0.45 + flux / max(fluxAverage * 5, 1e-4))
        }

        lock.lock()
        rawBands = normalized
        if beat > 0 { rawBeat = max(rawBeat, beat) }
        lastRealUpdate = now
        lock.unlock()
    }
}
