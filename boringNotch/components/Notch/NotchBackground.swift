//
//  NotchBackground.swift
//  boringNotch
//
//  Shared notch motion values and the (optionally glass) notch background.
//

import Defaults
import SwiftUI

/// Every open/close animation goes through these, so nothing fights over timing.
/// Speed and bounce come from Settings > Appearance.
enum NotchMotion {
    private static var speed: Double { min(max(Defaults[.notchAnimationSpeed], 0.5), 2.0) }

    /// Opening: quick, with a small settle at the end.
    static var open: Animation {
        .spring(duration: 0.42 * speed, bounce: min(max(Defaults[.notchOpenBounce], 0), 0.4))
    }
    /// Closing: a bit faster and with no bounce, so it tucks away cleanly.
    static var close: Animation { .spring(duration: 0.34 * speed, bounce: 0) }
    /// Content appears just after the shape starts growing.
    static var contentIn: Animation { .spring(duration: 0.36 * speed, bounce: 0).delay(0.06 * speed) }
    /// Content leaves fast so the shrinking shape never squeezes it.
    static var contentOut: Animation { .easeOut(duration: 0.12 * speed) }
}

/// Black when closed (so it blends into the hardware notch).
/// When open, either stays black or becomes tinted Liquid Glass.
struct NotchBackground<S: Shape>: View {
    let shape: S
    let isOpen: Bool
    let useGlass: Bool

    @Default(.glassClear) private var glassClear
    @Default(.glassTint) private var glassTint
    @Default(.albumGlow) private var albumGlow
    @Default(.albumGlowIntensity) private var albumGlowIntensity

    @ObservedObject private var music = MusicManager.shared

    private var tint: Double { min(max(glassTint, 0), 0.8) }
    private var showAlbumGlow: Bool { albumGlow && !music.isPlayerIdle }

    var body: some View {
        ZStack(alignment: .top) {
            // Base: glass, or solid black when glass is off.
            if useGlass {
                glassLayer
            } else {
                Rectangle().fill(.black)
            }

            // Album colours seeping into the background.
            if showAlbumGlow {
                AlbumGlowView(active: isOpen)
                    .opacity(isOpen ? min(max(albumGlowIntensity, 0), 1) : 0)
                    .saturation(1.2)
            }

            // Closed: solid black so it blends into the hardware notch.
            Rectangle()
                .fill(.black)
                .opacity(isOpen ? 0 : 1)
        }
    }

    @ViewBuilder
    private var glassLayer: some View {
        if #available(macOS 26.0, *) {
            // AppKit's own Liquid Glass view: samples what's behind the window and
            // draws Apple's edge highlight. It's extended above the panel so its
            // rounded top corners get clipped away by the notch shape.
            NativeGlassView(
                style: glassClear ? .clear : .regular,
                tint: NSColor.black.withAlphaComponent(tint),
                cornerRadius: 24
            )
            .padding(.top, -40)
        } else {
            // Older macOS: frosted material with a dark tint.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(tint + 0.15))
        }
    }
}

@available(macOS 26.0, *)
struct NativeGlassView: NSViewRepresentable {
    var style: NSGlassEffectView.Style
    var tint: NSColor?
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSGlassEffectView) {
        if view.style != style { view.style = style }
        if view.tintColor != tint { view.tintColor = tint }
        if view.cornerRadius != cornerRadius { view.cornerRadius = cornerRadius }
    }
}
