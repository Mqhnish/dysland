//
//  AlbumGlowView.swift
//  boringNotch
//
//  The album art's colours as liquid: blobs of the cover's main colours that
//  drift, merge and split apart (metaballs), with a glossy highlight on top.
//  While music plays they swell in a beat-like pulse.
//
//  How the liquid look works: each colour's blobs are drawn as plain circles,
//  blurred, then cut at 50% alpha. Where two blurred circles overlap, their
//  alpha adds up past the cut, so they join with a smooth, surface-tension-like
//  neck instead of just overlapping.
//
//  Performance: colours are picked once per track. The canvas renders at half
//  resolution and is scaled up (which also softens the cut edge).
//
//  Note: pulses follow play state and a simulated musical energy, not the audio.
//  Real audio reaction needs system-audio capture permission.
//

import AppKit
import CoreImage
import Defaults
import SwiftUI

struct AlbumGlowView: View {
    /// Only animate while the notch is open.
    let active: Bool

    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var calendar = CalendarManager.shared
    @Default(.albumGlowMotion) private var motion
    @Default(.albumGlowPulse) private var pulse
    @Default(.glowCalendarColors) private var useCalendarColors

    @State private var albumColors: [Color] = []
    @State private var sourceArt: NSImage?
    /// Physics state lives across frames (a class, so stepping it doesn't
    /// trigger extra SwiftUI updates).
    @State private var sim = LiquidSim()

    /// Colours of today's events' calendars (up to 2 distinct ones).
    private var eventColors: [Color] {
        guard useCalendarColors, calendar.calendarAuthorizationStatus == .fullAccess else { return [] }
        var seen = Set<String>()
        var result: [Color] = []
        for event in EventListView.filteredEvents(events: calendar.events) {
            let ns = event.calendar.color.usingColorSpace(.sRGB) ?? event.calendar.color
            let key = String(format: "%.2f-%.2f-%.2f", ns.redComponent, ns.greenComponent, ns.blueComponent)
            if seen.insert(key).inserted { result.append(Color(nsColor: ns)) }
            if result.count == 2 { break }
        }
        return result
    }

    /// Album colours while music is active, plus calendar colours flowing in.
    private var colors: [Color] {
        let album = music.isPlayerIdle ? [] : albumColors
        let combined = album + eventColors
        // A single colour still needs a partner so the liquid has depth.
        if combined.count == 1, let only = combined.first {
            return [only, only.opacity(0.7)]
        }
        return combined
    }

    var body: some View {
        GeometryReader { geo in
            if colors.count >= 2 {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || !motion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let playing = pulse && music.isPlaying
                    let half = CGSize(width: geo.size.width / 2, height: geo.size.height / 2)

                    Canvas { ctx, size in
                        if motion {
                            sim.step(to: t, size: size, beatsEnabled: playing)
                        } else {
                            sim.prepare(size: size)
                        }
                        LiquidBlobs.draw(in: &ctx, size: size, sim: sim, colors: colors)
                    }
                    .frame(width: half.width, height: half.height)
                    .scaleEffect(2, anchor: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 1.0), value: colors)
        .onAppear { refresh(music.albumArt) }
        .onChange(of: music.albumArt) { _, art in refresh(art) }
    }

    private func refresh(_ art: NSImage) {
        guard art !== sourceArt else { return }
        sourceArt = art
        Task.detached(priority: .utility) {
            let picked = AlbumGlowView.pickColors(from: art)
            await MainActor.run { if let picked { albumColors = picked } }
        }
    }

    /// Samples the cover on a 6×6 grid and keeps up to 4 vivid, distinct colours.
    nonisolated static func pickColors(from art: NSImage) -> [Color]? {
        guard let cg = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let extent = input.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let grid = 6
        let small = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(extent.width, extent.height) / 30)
            .cropped(to: extent)
            .transformed(by: .init(scaleX: CGFloat(grid) / extent.width,
                                   y: CGFloat(grid) / extent.height))

        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            small, toBitmap: &pixels, rowBytes: grid * 4,
            bounds: CGRect(x: 0, y: 0, width: grid, height: grid),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        struct Sample { var h: CGFloat; var s: CGFloat; var b: CGFloat }
        var samples: [Sample] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let c = NSColor(srgbRed: CGFloat(pixels[i]) / 255,
                            green: CGFloat(pixels[i + 1]) / 255,
                            blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            samples.append(Sample(h: h, s: s, b: b))
        }

        // Most vivid first, then keep colours whose hue differs enough.
        let sorted = samples.sorted { ($0.s * 0.7 + $0.b * 0.3) > ($1.s * 0.7 + $1.b * 0.3) }
        var picked: [Sample] = []
        for s in sorted where picked.count < 4 {
            let distinct = picked.allSatisfy { other in
                let d = abs(s.h - other.h)
                return min(d, 1 - d) > 0.07 || abs(s.b - other.b) > 0.35
            }
            if distinct { picked.append(s) }
        }
        while picked.count < 3, let s = sorted.dropFirst(picked.count).first { picked.append(s) }

        // Push saturation/brightness up so the liquid reads as colour, not grey.
        return picked.map { s in
            Color(hue: s.h,
                  saturation: min(1, s.s * 1.35 + 0.12),
                  brightness: min(1, max(0.55, s.b * 1.1)))
        }
    }
}


// MARK: - Liquid physics (ferrofluid-style)

/// A small physics world for the glow, tuned to feel like ferrofluid.
/// World units: panel height is 1, width is `aspect`.
///
/// - Three invisible "magnets" roam the whole panel. Each blob is drawn to one
///   magnet and swirls around it, so the liquid gathers in moving clusters.
/// - Every few seconds a blob switches magnets: it stretches out of its
///   cluster into a strand toward the other one, then pinches off.
/// - Nearby blobs stick (cohesion + viscosity) and push back only when squashed.
/// - On a beat, the liquid fires spikes: small droplets shoot out of the
///   surface on a stretchy tether and snap back in. Their parent blobs swell
///   hard and wobble on springy radii.
/// - Beats vary: a slow energy curve sets how often and how hard they hit,
///   some beats are skipped, and each hits one region of the panel.
final class LiquidSim {
    struct Blob {
        var p: SIMD2<Double>
        var v: SIMD2<Double> = .zero
        var baseRadius: Double
        var r: Double
        var rv: Double = 0
        let colorIndex: Int
        let seed: Double
        var magnet: Int = 0
        // Droplets (spikes)
        var isDroplet = false
        var parent = 0
        var age: Double = 0
    }

    private(set) var blobs: [Blob] = []
    private(set) var aspect: Double = 3.4
    /// 0...1, recent pulse strength (used for the gloss).
    private(set) var glow: Double = 0

    private let mainCount = 10
    private let magnetCount = 3
    private var lastT: Double?
    private var nextBeat: Double = 0
    private var nextSwitch: Double = 0
    private var beatCount = 0

    func prepare(size: CGSize) {
        guard size.height > 0 else { return }
        aspect = size.width / size.height
        if blobs.isEmpty { seed() }
    }

    private func seed() {
        blobs = (0..<mainCount).map { i in
            let d = Double(i)
            let r = 0.22 + 0.1 * (0.5 + 0.5 * sin(d * 2.7))
            return Blob(
                p: SIMD2((d + 0.5) / Double(mainCount) * aspect, 0.5 + 0.3 * sin(d * 2.1)),
                baseRadius: r, r: r, colorIndex: i, seed: d * 1.618,
                magnet: i % magnetCount
            )
        }
    }

    private func magnetPosition(_ k: Int, _ t: Double) -> SIMD2<Double> {
        let d = Double(k)
        let x = 0.5 + 0.40 * sin(t * (0.10 + 0.035 * d) + d * 2.4)
                    + 0.06 * sin(t * 0.47 + d)
        let y = 0.5 + 0.26 * sin(t * (0.17 + 0.05 * d) + d * 1.3)
        return SIMD2(min(max(x, 0.08), 0.92) * aspect, y)
    }

    func step(to t: Double, size: CGSize, beatsEnabled: Bool) {
        prepare(size: size)
        let dt = min(max(t - (lastT ?? t), 0), 1.0 / 20.0)
        lastT = t
        guard dt > 0 else { return }

        if beatsEnabled { handleBeats(t: t) } else { nextBeat = t }
        if t >= nextSwitch { switchMagnet(t: t) }
        glow *= exp(-dt * 2.5)

        let n = blobs.count
        var force = [SIMD2<Double>](repeating: .zero, count: n)
        let magnets = (0..<magnetCount).map { magnetPosition($0, t) }

        for i in 0..<n {
            let b = blobs[i]
            if b.isDroplet {
                // Stretchy tether back to the blob it came from.
                let parent = blobs[b.parent]
                force[i] += (parent.p - b.p) * 14
                continue
            }
            // Pull toward its magnet, plus a swirl around it.
            let toMagnet = magnets[b.magnet] - b.p
            force[i] += toMagnet * 1.3
            force[i] += SIMD2(-toMagnet.y, toMagnet.x) * (0.55 + 0.2 * sin(b.seed))

            // Soft walls.
            let m = b.r * 0.25
            if b.p.x < m { force[i].x += (m - b.p.x) * 5 }
            if b.p.x > aspect - m { force[i].x -= (b.p.x - (aspect - m)) * 5 }
            if b.p.y < m { force[i].y += (m - b.p.y) * 5 }
            if b.p.y > 1 - m { force[i].y -= (b.p.y - (1 - m)) * 5 }
        }

        // Cohesion, viscosity and pressure between main blobs.
        for i in 0..<mainCount {
            for j in (i + 1)..<mainCount {
                let a = blobs[i], b = blobs[j]
                let delta = b.p - a.p
                let dist = max(sqrt((delta * delta).sum()), 0.0001)
                let reach = (a.r + b.r) * 1.35
                guard dist < reach else { continue }
                let dir = delta / dist
                let rest = (a.r + b.r) * 0.6
                let closeness = 1 - dist / reach
                var f = dir * (dist - rest) * 1.2 * closeness
                if dist < rest * 0.6 { f -= dir * (rest * 0.6 - dist) * 6 }
                f += (b.v - a.v) * 0.7 * closeness
                force[i] += f
                force[j] -= f
            }
        }

        for i in 0..<n {
            var b = blobs[i]
            b.v += force[i] * dt
            b.v *= exp(-dt * (b.isDroplet ? 3.2 : 1.8))
            b.p += b.v * dt
            if b.isDroplet {
                b.age += dt
                b.r = b.baseRadius * max(0.35, 1 - b.age * 0.6)
            } else {
                let rest = b.baseRadius * (1 + 0.1 * sin(t * 0.5 + b.seed))
                let accel = (rest - b.r) * 26 - b.rv * 3.2   // springy, wobbly
                b.rv += accel * dt
                b.r = max(b.baseRadius * 0.55, b.r + b.rv * dt)
            }
            blobs[i] = b
        }

        // Absorb droplets that have snapped back (or lived long enough).
        // Read parents from a copy: looking into `blobs` while `removeAll`
        // is modifying it is an exclusivity violation and crashes the app.
        let parents = Array(blobs.prefix(mainCount))
        blobs.removeAll { d in
            guard d.isDroplet, d.parent < parents.count else { return false }
            let parent = parents[d.parent]
            let delta = parent.p - d.p
            let dist = sqrt((delta * delta).sum())
            return (d.age > 0.5 && dist < parent.r * 0.5) || d.age > 1.8
        }
    }

    private func switchMagnet(t: Double) {
        nextSwitch = t + Double.random(in: 4...9)
        let i = Int.random(in: 0..<mainCount)
        blobs[i].magnet = (blobs[i].magnet + Int.random(in: 1..<magnetCount)) % magnetCount
    }

    private func handleBeats(t: Double) {
        guard t >= nextBeat else { return }

        let beatInterval = 60.0 / 112.0
        let energy = 0.45 + 0.55
            * (0.5 + 0.5 * sin(t * 0.05))
            * (0.6 + 0.4 * sin(t * 0.14 + 1.7))

        beatCount += 1
        let skip = Double.random(in: 0...1) < 0.3 * (1 - energy) + 0.06
        nextBeat = t + beatInterval * (skip ? 2 : 1)
        guard Double.random(in: 0...1) < 0.4 + 0.55 * energy else { return }

        let accent = beatCount % 8 == 0 ? 1.7 : 1.0
        let strength = min(1.6, energy * Double.random(in: 0.65...1.0) * accent)
        glow = max(glow, min(1, strength))

        // Hit one region of the panel.
        let center = Double.random(in: 0.1...0.9) * aspect
        var spikesLeft = Int(3 + 7 * strength)
        let liveDroplets = blobs.filter(\.isDroplet).count

        for i in 0..<mainCount {
            let falloff = max(0, 1 - abs(blobs[i].p.x - center) / (aspect * 0.45))
            guard falloff > 0.05 else { continue }

            // Swell hard; the spring makes it wobble back.
            blobs[i].rv += strength * falloff * 4.2 * blobs[i].baseRadius

            // Ferrofluid spikes shooting out of the surface.
            let spikes = min(spikesLeft, Int((Double.random(in: 0.5...2.5) * falloff * strength).rounded()))
            guard spikes > 0, liveDroplets + (Int(3 + 7 * strength) - spikesLeft) < 36 else { continue }
            for _ in 0..<spikes {
                let angle = Double.random(in: 0..<(2 * .pi))
                let dir = SIMD2(cos(angle), sin(angle))
                let parent = blobs[i]
                blobs.append(Blob(
                    p: parent.p + dir * parent.r * 0.7,
                    v: parent.v + dir * Double.random(in: 2.2...3.6) * strength,
                    baseRadius: Double.random(in: 0.06...0.11),
                    r: 0.1,
                    colorIndex: parent.colorIndex,
                    seed: Double.random(in: 0...10),
                    isDroplet: true,
                    parent: i
                ))
            }
            spikesLeft -= spikes
        }
    }
}

enum LiquidBlobs {
    static func draw(in ctx: inout GraphicsContext, size: CGSize, sim: LiquidSim, colors: [Color]) {
        let h = size.height
        // Small enough that the spike droplets survive the threshold, big
        // enough that touching blobs fuse with smooth necks.
        let blur = h * 0.11

        func circles(scale: Double, dx: Double, dy: Double, only colorIndex: Int?) -> Path {
            var path = Path()
            for b in sim.blobs {
                if let colorIndex, b.colorIndex % colors.count != colorIndex { continue }
                let r = b.r * h * scale
                let x = b.p.x * h + dx * r
                let y = b.p.y * h + dy * r
                path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            return path
        }

        // Liquid body: one metaball layer per colour. Same-coloured blobs fuse;
        // different colours flow over each other.
        for ci in 0..<colors.count {
            ctx.drawLayer { layer in
                layer.addFilter(.alphaThreshold(min: 0.5, color: colors[ci]))
                layer.addFilter(.blur(radius: blur))
                layer.fill(circles(scale: 1, dx: 0, dy: 0, only: ci), with: .color(.white))
            }
        }

        // Gloss: light catching the top of the liquid, brighter after a pulse.
        ctx.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.addFilter(.alphaThreshold(min: 0.55, color: .white.opacity(0.14 + 0.12 * sim.glow)))
            layer.addFilter(.blur(radius: blur * 0.7))
            layer.fill(circles(scale: 0.55, dx: -0.3, dy: -0.45, only: nil), with: .color(.white))
        }
    }
}
