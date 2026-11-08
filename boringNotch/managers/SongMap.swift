//
//  SongMap.swift
//  boringNotch
//
//  Lets the visualiser follow an Apple Music song without recording system
//  audio (which turns on the purple indicator). Apple Music doesn't tell apps
//  anything about a song's rhythm, so this works it out:
//
//  - The song's real motion comes from its public 30-second preview, run
//    through the same analysis used for live audio: the rise and fall of each
//    frequency band and every real bass hit. The audio is deleted straight
//    after; only those numbers are kept, then replayed in time with the song.
//  - Where the beats fall comes from the synced lyrics: line starts tend to
//    land on the beat, so they pin the beat grid to the song's timeline.
//  - Song structure also comes from the lyrics: repeated lines are the chorus,
//    long gaps are instrumental breaks, and before the first line is the intro.
//

import Accelerate
import AVFoundation
import Foundation
import OSLog

// MARK: - Analysis

struct SongProfile: Sendable {
    var bpm: Double
    /// The preview's band levels (bass, low-mid, mid, high) over time.
    var frames: [SIMD4<Float>]
    /// Strength of a bass hit at each frame, 0 for none.
    var hits: [Float]
    var framesPerSecond: Double
    /// Seconds into the preview of its first strong beat.
    var firstBeat: Double
    /// How many beats of the preview to loop: always whole bars.
    var loopBeats: Double
}

struct BeatGrid: Sendable {
    var bpm: Double
    /// Time of a beat, in seconds into the song.
    var offset: Double
    /// How well the lyrics agreed with the grid (0...1).
    var confidence: Double
}

enum SongAnalysis {
    /// Finds the song's preview through Apple's public search API.
    static func previewURL(title: String, artist: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty
        else { return nil }

        func simple(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wantedTitle = simple(title), wantedArtist = simple(artist)
        let match = results.first { result in
            let t = simple(result["trackName"] as? String ?? "")
            let a = simple(result["artistName"] as? String ?? "")
            return (t.contains(wantedTitle) || wantedTitle.contains(t)) && (a.contains(wantedArtist) || wantedArtist.contains(a))
        }
        guard let match, let preview = match["previewUrl"] as? String else { return nil }
        return URL(string: preview)
    }

    /// Downloads the preview, analyses it and deletes it.
    static func profile(title: String, artist: String) async -> SongProfile? {
        guard let url = await previewURL(title: title, artist: artist),
              let (file, _) = try? await URLSession.shared.download(from: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        let audio = file.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.moveItem(at: file, to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        return analyze(audioAt: audio)
    }

    static func analyze(audioAt url: URL) -> SongProfile? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData, buffer.frameLength > 44_100
        else { return nil }

        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channelCount {
            vDSP_vadd(mono, 1, channels[c], 1, &mono, 1, vDSP_Length(count))
        }
        var divisor = Float(channelCount)
        vDSP_vsdiv(mono, 1, &divisor, &mono, 1, vDSP_Length(count))

        let sampleRate = buffer.format.sampleRate
        let log2n: vDSP_Length = 10
        let size = 1 << Int(log2n), hop = 512, bins = size / 2
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))

        let edges: [Double] = [30, 160, 600, 2500, 10000]
        let edgeBins = edges.map { max(min(Int($0 * Double(size) / sampleRate), bins - 1), 1) }

        var onset: [Float] = []
        var raw: [SIMD4<Float>] = []
        var previous = [Float](repeating: 0, count: bins)
        var frame = [Float](repeating: 0, count: size)
        var real = [Float](repeating: 0, count: bins)
        var imag = [Float](repeating: 0, count: bins)
        var mags = [Float](repeating: 0, count: bins)

        var position = 0
        while position + size <= count {
            mono.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + position, 1, window, 1, &frame, 1, vDSP_Length(size))
            }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBytes {
                        vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(bins))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                }
            }
            var flux: Float = 0
            for b in 1..<bins {
                let compressed = log1p(mags[b])
                flux += max(0, compressed - previous[b])
                previous[b] = compressed
            }
            onset.append(flux)
            var energies = SIMD4<Float>(repeating: 0)
            for band in 0..<4 {
                let upper = max(edgeBins[band + 1], edgeBins[band] + 1)
                var sum: Float = 0
                for b in edgeBins[band]..<upper { sum += mags[b] * mags[b] }
                energies[band] = sqrt(sum / Float(upper - edgeBins[band]))
            }
            raw.append(energies)
            position += hop
        }
        guard onset.count > 200 else { return nil }

        let framesPerSecond = sampleRate / Double(hop)
        guard let bpm = tempo(onset: onset, framesPerSecond: framesPerSecond) else { return nil }

        // The same steps as live audio in AudioReactor, so it moves the same way.
        var peak = raw.reduce(SIMD4<Float>(repeating: 1e-3)) { pointwiseMax($0, $1) } * Float(0.7)
        var frames: [SIMD4<Float>] = []
        var hits: [Float] = []
        frames.reserveCapacity(raw.count)
        hits.reserveCapacity(raw.count)
        var previousBass: Float = 0, fluxAverage: Float = 0
        var lastHit = -1_000_000
        let minimumGap = Int(0.2 * framesPerSecond)
        for (i, e) in raw.enumerated() {
            peak = pointwiseMax(peak * Float(0.9985), e)
            var n = (e / peak).clamped(lowerBound: .zero, upperBound: SIMD4<Float>(repeating: 1))
            n = SIMD4(pow(n.x, 1.3), pow(n.y, 1.2), pow(n.z, 1.2), pow(n.w, 1.1))
            frames.append(n)

            let flux = max(0, e.x - previousBass)
            previousBass = e.x
            fluxAverage = fluxAverage * 0.965 + flux * 0.035
            var hit: Float = 0
            if flux > fluxAverage * 2, n.x > 0.35, i - lastHit > minimumGap {
                lastHit = i
                hit = min(1, 0.45 + flux / max(fluxAverage * 5, 1e-4))
            }
            hits.append(hit)
        }

        // Find where the preview's beats fall, then loop whole bars of it.
        let beatFrames = framesPerSecond * 60 / bpm
        let slots = 16
        var folded = [Float](repeating: 0, count: slots)
        for (i, value) in onset.enumerated() {
            let position = Double(i).truncatingRemainder(dividingBy: beatFrames) / beatFrames
            folded[min(Int(position * Double(slots)), slots - 1)] += value
        }
        let bestSlot = folded.indices.max { folded[$0] < folded[$1] } ?? 0
        let firstBeat = Double(bestSlot) / Double(slots) * 60 / bpm
        let duration = Double(frames.count) / framesPerSecond
        let bars = floor((duration - firstBeat) / (60 / bpm) / 4)
        guard bars >= 1 else { return nil }
        return SongProfile(
            bpm: bpm, frames: frames, hits: hits, framesPerSecond: framesPerSecond,
            firstBeat: firstBeat, loopBeats: bars * 4
        )
    }

    /// Autocorrelation of the onset strength, favouring common tempos so a
    /// song isn't read at half or double speed.
    static func tempo(onset: [Float], framesPerSecond fps: Double) -> Double? {
        var e = onset
        var mean: Float = 0
        vDSP_meanv(e, 1, &mean, vDSP_Length(e.count))
        var negative = -mean
        vDSP_vsadd(e, 1, &negative, &e, 1, vDSP_Length(e.count))

        let minLag = Int(60 / 190 * fps), maxLag = Int(60 / 62 * fps)
        guard e.count > maxLag * 3 else { return nil }
        func ac(_ lag: Int) -> Float {
            guard lag < e.count else { return 0 }
            var result: Float = 0
            vDSP_dotpr(e, 1, Array(e[lag...]), 1, &result, vDSP_Length(e.count - lag))
            return result / Float(e.count - lag)
        }
        var values = [Float](repeating: 0, count: maxLag * 4 + 2)
        for lag in minLag..<values.count { values[lag] = ac(lag) }

        var best = 0, bestScore: Float = -.infinity
        for lag in minLag...maxLag {
            let bpm = 60 * fps / Double(lag)
            let octaves = log2(bpm / 118)
            let preference = Float(exp(-0.5 * pow(octaves / 0.75, 2)))
            // A true beat also lines up at 2x and 4x its period.
            let comb = values[lag] + 0.6 * values[lag * 2] + 0.4 * values[lag * 4]
            let score = comb * preference
            if score > bestScore { bestScore = score; best = lag }
        }
        guard best > minLag, best < maxLag else { return best > 0 ? 60 * fps / Double(best) : nil }
        let a = values[best - 1], b = values[best], c = values[best + 1]
        let denominator = a - 2 * b + c
        let shift = abs(denominator) > 1e-9 ? 0.5 * (a - c) / denominator : 0
        return 60 * fps / (Double(best) + Double(shift))
    }

    /// Fits the beat grid to the lyric line starts across the whole song,
    /// nudging the tempo slightly so it doesn't drift over several minutes.
    static func grid(bpm: Double, lineTimes: [Double]) -> BeatGrid {
        guard lineTimes.count >= 6 else { return BeatGrid(bpm: bpm, offset: 0, confidence: 0) }
        var bestBPM = bpm, bestOffset = 0.0, bestR = -1.0
        for step in -40...40 {
            let candidate = bpm * (1 + Double(step) * 0.0005)
            let period = 60 / candidate
            var x = 0.0, y = 0.0
            for t in lineTimes {
                let angle = 2 * Double.pi * t / period
                x += cos(angle); y += sin(angle)
            }
            let r = sqrt(x * x + y * y) / Double(lineTimes.count)
            if r > bestR {
                bestR = r
                bestBPM = candidate
                var phase = atan2(y, x)
                if phase < 0 { phase += 2 * .pi }
                bestOffset = phase / (2 * .pi) * period
            }
        }
        return BeatGrid(bpm: bestBPM, offset: bestOffset, confidence: bestR)
    }
}

/// How intense each part of the song is, read from the shape of its lyrics.
struct SongStructure: Sendable {
    private let times: [Double]
    private let levels: [Float]
    /// Where the big moments are: a chorus starting, or vocals back after a break.
    let entries: [Double]

    init(lines: [(time: Double, text: String)]) {
        times = lines.map(\.time)
        let keys = lines.map { $0.text.lowercased().filter { $0.isLetter || $0.isNumber } }
        var counts: [String: Int] = [:]
        for key in keys { counts[key, default: 0] += 1 }
        let repeated = keys.map { (counts[$0] ?? 0) >= 2 ? Float(1) : Float(0) }
        // Average with the neighbours: a chorus is a run of lines, not one.
        levels = repeated.indices.map { i in
            let range = max(i - 1, 0)...min(i + 1, repeated.count - 1)
            let score = range.map { repeated[$0] }.reduce(0, +) / Float(range.count)
            return 0.6 + 0.38 * score
        }

        var found: [Double] = []
        for i in lines.indices.dropFirst() {
            let chorusStarts = repeated[i] == 1 && repeated[i - 1] == 0
                && i + 1 < lines.count && repeated[i + 1] == 1
            let backFromBreak = lines[i].time - lines[i - 1].time > 9
            guard chorusStarts || backFromBreak else { continue }
            if let last = found.last, lines[i].time - last < 12 { continue }
            found.append(lines[i].time)
        }
        entries = found
    }

    /// Extra lift just after a big moment, fading over a couple of seconds.
    func surge(at t: Double) -> Float {
        guard let entry = entries.last(where: { $0 <= t }), t - entry < 3 else { return 0 }
        return Float(exp(-(t - entry) / 1.1)) * 0.35
    }

    /// Whether a big moment falls on the beat at time `t`.
    func isEntry(near t: Double, within window: Double) -> Bool {
        entries.contains { abs($0 - t) <= window }
    }

    /// 0...1 intensity at a point in the song.
    func energy(at t: Double) -> Float {
        guard let first = times.first, let last = times.last else { return 0.7 }
        if t < first { return 0.42 + 0.2 * Float(min(max(1 - (first - t) / 12, 0), 1)) }
        if t > last + 6 { return 0.4 }
        var low = 0, high = times.count - 1, index = 0
        while low <= high {
            let mid = (low + high) / 2
            if times[mid] <= t { index = mid; low = mid + 1 } else { high = mid - 1 }
        }
        // A long gap between lines is an instrumental break.
        if index + 1 < times.count, times[index + 1] - times[index] > 9, t - times[index] > 4 { return 0.55 }
        return levels[index]
    }
}

// MARK: - Live

/// Keeps a map of the current Apple Music song and turns playback position
/// into levels for the visualiser.
final class SongFollower: @unchecked Sendable {
    static let shared = SongFollower()

    private struct Map {
        var profile: SongProfile
        var grid: BeatGrid
        var structure: SongStructure?
    }

    private let lock = NSLock()
    private var map: Map?
    private var lastBeat = Int.min
    private var lastFrame = -1
    private var cache: [String: SongProfile] = [:]
    private var currentKey = ""
    private var lines: [(time: Double, text: String)] = []

    /// Very fast readings pulse on every other beat: still in time, and slow
    /// songs that get read at double speed don't look frantic.
    private static func pulseTempo(_ bpm: Double) -> Double {
        bpm > 150 ? bpm / 2 : bpm
    }

    /// Call when the song changes. Pass nil when it isn't an Apple Music song.
    func songChanged(title: String?, artist: String) {
        guard let title, !title.isEmpty else {
            lock.withLock { map = nil; currentKey = "" }
            return
        }
        let key = artist + "|" + title
        let cached: SongProfile? = lock.withLock {
            guard key != currentKey else { return nil }
            currentKey = key
            map = nil
            return cache[key]
        }
        if let cached { install(cached, key: key); return }
        Task.detached(priority: .utility) { [weak self] in
            guard let profile = await SongAnalysis.profile(title: title, artist: artist) else { return }
            self?.install(profile, key: key)
        }
    }

    /// Call when the synced lyrics for the current song arrive or change.
    func lyricsChanged(_ newLines: [(time: Double, text: String)]) {
        lock.withLock {
            lines = newLines
            guard var current = map else { return }
            current.grid = SongAnalysis.grid(bpm: Self.pulseTempo(current.profile.bpm), lineTimes: newLines.map(\.time))
            current.structure = newLines.isEmpty ? nil : SongStructure(lines: newLines)
            map = current
        }
    }

    private func install(_ profile: SongProfile, key: String) {
        lock.withLock {
            cache[key] = profile
            guard key == currentKey else { return }
            defer {
                if let grid = map?.grid {
                    Logger(subsystem: "boringnotch.liquid", category: "song").info("Song map: \(grid.bpm, privacy: .public) BPM, lyric fit \(grid.confidence, privacy: .public), \(self.lines.count, privacy: .public) lines")
                }
            }
            map = Map(
                profile: profile,
                grid: SongAnalysis.grid(bpm: Self.pulseTempo(profile.bpm), lineTimes: lines.map(\.time)),
                structure: lines.isEmpty ? nil : SongStructure(lines: lines)
            )
        }
    }

    /// Levels for this moment of the song, or nil if there's no map for it.
    func levels(at position: Double) -> (bands: SIMD4<Float>, hit: Float)? {
        lock.lock(); defer { lock.unlock() }
        guard let map else { return nil }
        let profile = map.profile

        // Which moment of the preview matches this beat of the song.
        let tempoRatio = profile.bpm > 150 ? 2.0 : 1.0
        let songBeats = (position - map.grid.offset) * map.grid.bpm * tempoRatio / 60
        var loopBeat = songBeats.truncatingRemainder(dividingBy: profile.loopBeats)
        if loopBeat < 0 { loopBeat += profile.loopBeats }
        let previewTime = profile.firstBeat + loopBeat * 60 / profile.bpm
        let frame = min(Int(previewTime * profile.framesPerSecond), profile.frames.count - 1)

        // Any bass hit passed since the last look, even between screen frames.
        var hit: Float = 0
        if frame > lastFrame, frame - lastFrame < 40, lastFrame >= 0 {
            for i in (lastFrame + 1)...frame { hit = max(hit, profile.hits[i]) }
        } else {
            hit = profile.hits[frame]
        }
        lastFrame = frame

        // The lyrics decide how big this part of the song is.
        let surge = map.structure?.surge(at: position) ?? 0
        let energy = (map.structure?.energy(at: position) ?? 0.78) + surge
        let scale = min(max(energy / 0.78, 0.55), 1.3)
        let cap = SIMD4<Float>(repeating: 1)
        let bands = (profile.frames[frame] * scale).clamped(lowerBound: .zero, upperBound: cap)
        hit = min(hit * min(scale, 1), 1)

        // Big moments still land as a full hit.
        let period = 60 / map.grid.bpm
        let beat = Int(floor((position - map.grid.offset) / period))
        if beat != lastBeat {
            lastBeat = beat
            let beatTime = map.grid.offset + Double(beat) * period
            if map.structure?.isEntry(near: beatTime, within: period * 0.6) == true { hit = 1 }
        }
        return (bands, hit)
    }
}
