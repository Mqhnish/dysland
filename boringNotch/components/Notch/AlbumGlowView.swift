//
//  AlbumGlowView.swift
//  boringNotch
//
//  Lets the current album art's colours flow through the notch background like
//  liquid: a 4×4 mesh gradient coloured from the artwork, whose grid points
//  slowly warp so the colour bands bend and roll into each other.
//
//  Performance: colours are sampled ONCE per track. Per frame only the 16 mesh
//  points move; the GPU draws the mesh. No per-frame blur.
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

    @State private var palette: [Color] = []
    @State private var sourceArt: NSImage?

    var body: some View {
        Group {
            if palette.count == 16 {
                if #available(macOS 15.0, *) {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active || !motion)) { context in
                        let t = motion ? context.date.timeIntervalSinceReferenceDate : 0
                        MeshGradient(
                            width: 4,
                            height: 4,
                            points: LiquidMesh.points(at: t),
                            colors: palette,
                            background: .clear,
                            smoothsColors: true
                        )
                    }
                } else {
                    // macOS 14: no mesh gradients, use a soft linear blend instead.
                    LinearGradient(colors: [palette[5], palette[6], palette[10], palette[9]],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 1.0), value: palette)
        .onAppear { refresh(music.albumArt) }
        .onChange(of: music.albumArt) { _, art in refresh(art) }
    }

    private func refresh(_ art: NSImage) {
        guard art !== sourceArt else { return }
        sourceArt = art
        Task.detached(priority: .utility) {
            let colors = AlbumGlowView.samplePalette(from: art)
            await MainActor.run { if let colors { palette = colors } }
        }
    }

    /// Shrinks the artwork to 4×4 pixels (each one the average of that region),
    /// then boosts saturation, so the mesh keeps the cover's colour layout.
    nonisolated static func samplePalette(from art: NSImage) -> [Color]? {
        guard let cg = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let extent = input.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let grid = 4
        let small = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(extent.width, extent.height) / 24)
            .cropped(to: extent)
            .transformed(by: .init(scaleX: CGFloat(grid) / extent.width,
                                   y: CGFloat(grid) / extent.height))
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.9,
                kCIInputContrastKey: 1.1,
            ])

        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        context.render(
            small,
            toBitmap: &pixels,
            rowBytes: grid * 4,
            bounds: CGRect(x: 0, y: 0, width: grid, height: grid),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        // CoreImage rows go bottom-up; the mesh expects top-down.
        var colors: [Color] = []
        for row in (0..<grid).reversed() {
            for col in 0..<grid {
                let i = (row * grid + col) * 4
                colors.append(Color(
                    .sRGB,
                    red: Double(pixels[i]) / 255,
                    green: Double(pixels[i + 1]) / 255,
                    blue: Double(pixels[i + 2]) / 255,
                    opacity: 1
                ))
            }
        }
        return colors
    }
}

/// Grid point motion for the liquid look. Edge points only slide along their
/// edge (so the mesh always fills the panel); inner points swirl on their own
/// slow, out-of-phase orbits so the colour bands fold into each other.
enum LiquidMesh {
    static func points(at t: TimeInterval) -> [SIMD2<Float>] {
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(16)
        for row in 0..<4 {
            for col in 0..<4 {
                let baseX = Float(col) / 3
                let baseY = Float(row) / 3
                let seed = Double(row * 4 + col)
                let speed = 0.35 + 0.08 * sin(seed)
                let phase = seed * 1.7

                let isEdgeX = col == 0 || col == 3
                let isEdgeY = row == 0 || row == 3

                let dx: Float = isEdgeX ? 0 : Float(sin(t * speed + phase) * 0.13 + sin(t * speed * 0.53 + phase * 2) * 0.05)
                let dy: Float = isEdgeY ? 0 : Float(cos(t * speed * 0.87 + phase) * 0.13 + cos(t * speed * 0.41 + phase * 3) * 0.05)

                // Edge points still slide along their edge for a rolling feel.
                let slideX: Float = (isEdgeY && !isEdgeX) ? Float(sin(t * 0.3 + phase) * 0.08) : 0
                let slideY: Float = (isEdgeX && !isEdgeY) ? Float(cos(t * 0.27 + phase) * 0.08) : 0

                result.append(SIMD2(baseX + dx + slideX, baseY + dy + slideY))
            }
        }
        return result
    }
}
