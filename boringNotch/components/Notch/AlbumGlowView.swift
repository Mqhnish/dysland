//
//  AlbumGlowView.swift
//  boringNotch
//
//  The liquid visualiser behind the notch content: glossy ferrofluid in the
//  album art's colours (plus today's calendar colours), drawn by a GPU shader
//  (LiquidShaders.metal → ferrofluid). Bass swells the blobs, highs grow
//  spikes, beats kick them. Levels come from AudioReactor: the real system
//  audio when permitted, otherwise a varied simulated pulse.
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
    @Default(.visualizerSpikiness) private var spikiness

    @State private var albumColors: [Color] = []
    @State private var sourceArt: NSImage?

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
        return album + eventColors
    }

    /// Flattened RGBA floats for the shader (at least 1 colour).
    private var colorFloats: [Float] {
        let list = colors.isEmpty ? [Color.gray] : colors
        return list.prefix(6).flatMap { color -> [Float] in
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
            return [Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent), 1]
        }
    }

    var body: some View {
        GeometryReader { geo in
            if !colors.isEmpty {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active || !motion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let levels = AudioReactor.shared.sample(time: t, playing: pulse && music.isPlaying)
                    Rectangle().fill(
                        ShaderLibrary.ferrofluid(
                            .float2(geo.size),
                            .float(Float(motion ? t.truncatingRemainder(dividingBy: 10_000) : 0)),
                            .float4(levels.bands.x, levels.bands.y, levels.bands.z, levels.bands.w),
                            .float(levels.beat),
                            .float(Float(spikiness)),
                            .floatArray(colorFloats)
                        )
                    )
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
