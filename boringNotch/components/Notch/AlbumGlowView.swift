//
//  AlbumGlowView.swift
//  boringNotch
//
//  Lets the current album art's colours seep into the notch background as a
//  slow, drifting glow.
//
//  Performance: the artwork is blurred and saturated ONCE per track into a small
//  image. Per frame we only rotate/scale that image (cheap GPU transforms), so
//  there's no per-frame blur.
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

    @State private var wash: NSImage?
    @State private var sourceArt: NSImage?

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * 1.6
            if let wash {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || !motion)) { context in
                    let t = motion ? context.date.timeIntervalSinceReferenceDate : 0
                    ZStack {
                        washLayer(wash, side: side)
                            .rotationEffect(.degrees(t * 7))
                            .offset(x: sin(t * 0.21) * geo.size.width * 0.12,
                                    y: cos(t * 0.17) * geo.size.height * 0.15)
                        washLayer(wash, side: side * 0.85)
                            .scaleEffect(x: -1, y: 1)
                            .rotationEffect(.degrees(-t * 5 + 90))
                            .offset(x: cos(t * 0.13) * geo.size.width * 0.18,
                                    y: sin(t * 0.19) * geo.size.height * 0.1)
                            .opacity(0.75)
                            .blendMode(.screen)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .transition(.opacity)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.8), value: wash)
        .onAppear { refresh(music.albumArt) }
        .onChange(of: music.albumArt) { _, art in refresh(art) }
    }

    private func washLayer(_ image: NSImage, side: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
    }

    private func refresh(_ art: NSImage) {
        guard art !== sourceArt else { return }
        sourceArt = art
        Task.detached(priority: .utility) {
            let result = AlbumGlowView.makeWash(from: art)
            await MainActor.run { wash = result }
        }
    }

    /// Downscale, blur and saturate the artwork into a small, smooth colour field.
    nonisolated static func makeWash(from art: NSImage) -> NSImage? {
        guard let cg = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let size: CGFloat = 96
        let scale = size / max(input.extent.width, input.extent.height)

        let small = input
            .transformed(by: .init(scaleX: scale, y: scale))
            .clampedToExtent()
        let blurred = small
            .applyingGaussianBlur(sigma: 10)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.8,
                kCIInputBrightnessKey: 0.02,
                kCIInputContrastKey: 1.05,
            ])
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))

        let context = CIContext(options: [.cacheIntermediates: false])
        guard let out = context.createCGImage(blurred, from: blurred.extent) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: size, height: size))
    }
}
