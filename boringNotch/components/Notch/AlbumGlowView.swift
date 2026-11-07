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
//  Note: the pulse is driven by play state and time, not the actual audio.
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

    var body: some View {
        GeometryReader { geo in
            if colors.count >= 2 {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || !motion)) { context in
                    let t = motion ? context.date.timeIntervalSinceReferenceDate : 0
                    let beat = (pulse && music.isPlaying) ? LiquidBlobs.beat(at: t) : 0
                    let half = CGSize(width: geo.size.width / 2, height: geo.size.height / 2)

                    Canvas { ctx, size in
                        LiquidBlobs.draw(in: &ctx, size: size, time: t, beat: beat, colors: colors)
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

enum LiquidBlobs {
    private struct Blob {
        let colorIndex: Int
        let baseX: Double, baseY: Double   // 0...1
        let ampX: Double, ampY: Double
        let speed: Double, phase: Double
        let radius: Double                 // fraction of height
    }

    /// Fixed "choreography" so the motion is smooth and never jumps.
    private static let blobs: [Blob] = (0..<10).map { i in
        let d = Double(i)
        return Blob(
            colorIndex: i,
            baseX: (d + 0.5) / 10,
            baseY: 0.35 + 0.35 * sin(d * 2.1),
            ampX: 0.10 + 0.05 * sin(d * 1.3),
            ampY: 0.22 + 0.08 * cos(d * 0.7),
            speed: 0.16 + 0.05 * sin(d * 1.9),
            phase: d * 1.618,
            radius: 0.30 + 0.12 * (0.5 + 0.5 * sin(d * 2.7))
        )
    }

    /// Beat-like pulse, 0...1: a sharp rise and slower fall at ~112 BPM,
    /// with an accent every 4th beat.
    static func beat(at t: TimeInterval) -> Double {
        let bps = 112.0 / 60.0
        let x = (t * bps).truncatingRemainder(dividingBy: 1)
        let accent = Int(t * bps) % 4 == 0 ? 1.0 : 0.6
        return pow(1 - x, 3) * accent
    }

    static func draw(in ctx: inout GraphicsContext, size: CGSize, time t: Double, beat: Double, colors: [Color]) {
        let w = size.width, h = size.height
        let blur = h * 0.22

        func circles(scale: Double, dx: Double, dy: Double, only colorIndex: Int?) -> Path {
            var path = Path()
            for (i, b) in blobs.enumerated() {
                if let colorIndex, b.colorIndex % colors.count != colorIndex { continue }
                let x = (b.baseX + b.ampX * sin(t * b.speed + b.phase)) * w
                let y = (b.baseY + b.ampY * cos(t * b.speed * 0.8 + b.phase * 1.3)) * h
                // Each blob breathes on its own, and swells with the beat.
                let breathe = 1 + 0.12 * sin(t * 0.6 + Double(i))
                let swell = 1 + 0.18 * beat * (0.6 + 0.4 * sin(Double(i) * 1.7))
                let r = b.radius * h * breathe * swell * scale
                path.addEllipse(in: CGRect(x: x - r + dx * r, y: y - r + dy * r, width: r * 2, height: r * 2))
            }
            return path
        }

        // Liquid body: one metaball layer per colour.
        for ci in 0..<colors.count {
            ctx.drawLayer { layer in
                layer.addFilter(.alphaThreshold(min: 0.5, color: colors[ci]))
                layer.addFilter(.blur(radius: blur))
                layer.fill(circles(scale: 1, dx: 0, dy: 0, only: ci), with: .color(.white))
            }
        }

        // Gloss: a smaller, offset metaball layer in soft white, like light
        // catching the top of a liquid surface.
        ctx.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.addFilter(.alphaThreshold(min: 0.55, color: .white.opacity(0.16 + 0.1 * beat)))
            layer.addFilter(.blur(radius: blur * 0.7))
            layer.fill(circles(scale: 0.55, dx: -0.3, dy: -0.45, only: nil), with: .color(.white))
        }
    }
}
