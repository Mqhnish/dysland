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
    @Default(.albumGlowMotion) private var motion
    @Default(.albumGlowPulse) private var pulse

    @State private var colors: [Color] = []
    @State private var sourceArt: NSImage?
    /// Physics state lives across frames (a class, so stepping it doesn't
    /// trigger extra SwiftUI updates).
    @State private var sim = LiquidSim()

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
            await MainActor.run { if let picked { colors = picked } }
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


// MARK: - Liquid physics

/// A tiny physics world for the glow. World units: the panel's height is 1,
/// its width is `aspect`. Blobs:
/// - wander toward slow, drifting targets (so the liquid keeps moving),
/// - pull toward nearby blobs and resist moving apart (cohesion + viscosity),
///   which makes them cling, merge and stretch into necks before pinching off,
/// - push apart only when squashed deep into each other,
/// - have springy radii, so a pulse makes them wobble rather than just grow.
///
/// Pulses aren't on every beat: a slow "energy" curve rises and falls over
/// tens of seconds, beats are skipped at random (more often when energy is
/// low), and each beat only hits some blobs, as a ripple across the panel.
final class LiquidSim {
    struct Blob {
        var p: SIMD2<Double>
        var v: SIMD2<Double> = .zero
        var baseRadius: Double
        var r: Double
        var rv: Double = 0
        let colorIndex: Int
        let seed: Double
    }

    private(set) var blobs: [Blob] = []
    private(set) var aspect: Double = 3.4
    /// 0...1, recent pulse strength (used for the gloss).
    private(set) var glow: Double = 0

    private var lastT: Double?
    private var nextBeat: Double = 0
    private var beatCount = 0

    func prepare(size: CGSize) {
        guard size.height > 0 else { return }
        aspect = size.width / size.height
        if blobs.isEmpty { seed() }
    }

    private func seed() {
        blobs = (0..<10).map { i in
            let d = Double(i)
            let r = 0.30 + 0.12 * (0.5 + 0.5 * sin(d * 2.7))
            return Blob(
                p: SIMD2((d + 0.5) / 10 * aspect, 0.5 + 0.3 * sin(d * 2.1)),
                baseRadius: r,
                r: r,
                colorIndex: i,
                seed: d * 1.618
            )
        }
    }

    func step(to t: Double, size: CGSize, beatsEnabled: Bool) {
        prepare(size: size)
        let dt = min(max(t - (lastT ?? t), 0), 1.0 / 20.0)
        lastT = t
        guard dt > 0 else { return }

        if beatsEnabled { handleBeats(t: t) } else { nextBeat = t }
        glow *= exp(-dt * 3)

        let n = blobs.count
        var force = [SIMD2<Double>](repeating: .zero, count: n)

        for i in 0..<n {
            let b = blobs[i]
            // Wander: each blob chases its own slow figure-of-eight target.
            let s = 0.6 + 0.4 * sin(b.seed)
            let target = SIMD2(
                (0.5 + 0.44 * sin(t * 0.07 * s + b.seed)) * aspect,
                0.5 + 0.36 * cos(t * 0.11 * s + b.seed * 1.3)
            )
            force[i] += (target - b.p) * 0.22

            // Soft walls keep the liquid on the panel.
            let m = b.r * 0.2
            if b.p.x < m { force[i].x += (m - b.p.x) * 3 }
            if b.p.x > aspect - m { force[i].x -= (b.p.x - (aspect - m)) * 3 }
            if b.p.y < m { force[i].y += (m - b.p.y) * 3 }
            if b.p.y > 1 - m { force[i].y -= (b.p.y - (1 - m)) * 3 }
        }

        // Cohesion, viscosity and overlap pressure between pairs.
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = blobs[i], b = blobs[j]
                let delta = b.p - a.p
                let dist = max(sqrt((delta * delta).sum()), 0.0001)
                let reach = (a.r + b.r) * 2.0
                guard dist < reach else { continue }
                let dir = delta / dist
                let rest = (a.r + b.r) * 0.62          // like to overlap → merge
                let closeness = 1 - dist / reach         // 0 at edge of reach, 1 touching
                var f = dir * (dist - rest) * 0.9 * closeness
                if dist < rest * 0.55 {                  // squashed: push back
                    f -= dir * (rest * 0.55 - dist) * 4
                }
                // Viscosity: neighbours drag each other along, so they move as one.
                f += (b.v - a.v) * 1.1 * closeness
                force[i] += f
                force[j] -= f
            }
        }

        for i in 0..<n {
            var b = blobs[i]
            b.v += force[i] * dt
            b.v *= exp(-dt * 1.4)                        // thick liquid, not water
            b.p += b.v * dt

            // Springy radius: breathes slowly, wobbles after a pulse.
            let rest = b.baseRadius * (1 + 0.08 * sin(t * 0.45 + b.seed))
            let accel = (rest - b.r) * 22 - b.rv * 4.5
            b.rv += accel * dt
            b.r = max(b.baseRadius * 0.6, b.r + b.rv * dt)
            blobs[i] = b
        }
    }

    private func handleBeats(t: Double) {
        guard t >= nextBeat else { return }

        let beatInterval = 60.0 / 112.0
        // Slow musical "energy": calm verses and busier choruses.
        let energy = 0.25 + 0.75
            * (0.5 + 0.5 * sin(t * 0.045))
            * (0.55 + 0.45 * sin(t * 0.13 + 1.7))

        beatCount += 1
        // Sometimes hold for two beats; more often when energy is low.
        let skip = Double.random(in: 0...1) < 0.35 * (1 - energy) + 0.08
        nextBeat = t + beatInterval * (skip ? 2 : 1)

        // Fire only some beats, more of them when energy is high.
        guard Double.random(in: 0...1) < 0.25 + 0.6 * energy else { return }

        let accent = beatCount % 8 == 0 ? 1.6 : 1.0
        let strength = energy * Double.random(in: 0.55...1.0) * accent
        glow = max(glow, min(1, strength))

        // A ripple: blobs near a random point react most, far ones barely.
        let center = Double.random(in: 0...aspect)
        let centroid = blobs.reduce(SIMD2<Double>.zero) { $0 + $1.p } / Double(max(blobs.count, 1))
        for i in blobs.indices {
            let falloff = max(0, 1 - abs(blobs[i].p.x - center) / (aspect * 0.6))
            guard Double.random(in: 0...1) < 0.35 + 0.6 * falloff else { continue }
            blobs[i].rv += strength * falloff * 1.6 * blobs[i].baseRadius
            // A small outward push; cohesion then pulls the liquid back together.
            let away = blobs[i].p - centroid
            let len = max(sqrt((away * away).sum()), 0.0001)
            blobs[i].v += away / len * strength * falloff * 0.22
        }
    }
}

enum LiquidBlobs {
    static func draw(in ctx: inout GraphicsContext, size: CGSize, sim: LiquidSim, colors: [Color]) {
        let h = size.height
        let blur = h * 0.2

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
