//
//  NotchBackground.swift
//  boringNotch
//
//  Shared notch motion values, the notch background, and Liquid Glass helpers.
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

/// Black when closed (so it blends into the hardware notch). When open:
/// - Tiles mode: a faint veil, with the content split into glass tiles on top
///   (like Control Center). Each tile edge bends what's behind it.
/// - Panel mode: one glass panel behind everything.
/// - Glass off: solid black.
struct NotchBackground<S: Shape>: View {
    let shape: S
    let isOpen: Bool
    let useGlass: Bool

    @Default(.glassClear) private var glassClear
    @Default(.glassTint) private var glassTint
    @Default(.glassOpacity) private var glassOpacity
    @Default(.glassTiles) private var glassTiles
    @Default(.albumGlow) private var albumGlow
    @Default(.albumGlowIntensity) private var albumGlowIntensity

    @ObservedObject private var music = MusicManager.shared

    private var tint: Double { min(max(glassTint, 0), 0.8) }
    private var showAlbumGlow: Bool { albumGlow && !music.isPlayerIdle }
    private var tilesMode: Bool { useGlass && glassTiles && GlassSupport.available }

    var body: some View {
        ZStack(alignment: .top) {
            // Base
            if tilesMode {
                Rectangle().fill(.black.opacity(0.14 + tint))
            } else if useGlass {
                panelGlass
            } else {
                Rectangle().fill(.black)
            }

            // Album colours flowing like liquid. In tiles mode they sit behind
            // the glass tiles, so the tile edges refract them.
            if showAlbumGlow {
                AlbumGlowView(active: isOpen)
                    .opacity(isOpen ? min(max(albumGlowIntensity, 0), 1) : 0)
            }

            // Closed: solid black so it blends into the hardware notch.
            Rectangle()
                .fill(.black)
                .opacity(isOpen ? 0 : 1)
        }
        .overlay {
            // Hairline rim so the panel's outline reads over busy backgrounds.
            shape.stroke(.white.opacity(isOpen && tilesMode ? 0.12 : 0), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var panelGlass: some View {
        if #available(macOS 26.0, *) {
            // Extended above the panel so its rounded top corners get clipped
            // away by the notch shape.
            NativeGlassView(
                style: glassClear ? .clear : .regular,
                tint: tint > 0.001 ? NSColor.black.withAlphaComponent(tint) : nil,
                cornerRadius: 24
            )
            .opacity(min(max(glassOpacity, 0.3), 1))
            .padding(.top, -40)
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(tint + 0.15))
        }
    }
}

enum GlassSupport {
    static var available: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// Wraps content in its own Liquid Glass tile when tiles mode is on.
struct GlassTile: ViewModifier {
    var cornerRadius: CGFloat = 18
    var padding: CGFloat = 8

    @Default(.glassBackground) private var glassBackground
    @Default(.glassTiles) private var glassTiles
    @Default(.glassClear) private var glassClear

    func body(content: Content) -> some View {
        if glassBackground && glassTiles, #available(macOS 26.0, *) {
            content
                .padding(padding)
                .background {
                    NativeGlassView(
                        style: glassClear ? .clear : .regular,
                        tint: nil,
                        cornerRadius: cornerRadius,
                        interactive: true
                    )
                }
        } else {
            content
        }
    }
}

extension View {
    func glassTile(cornerRadius: CGFloat = 18, padding: CGFloat = 8) -> some View {
        modifier(GlassTile(cornerRadius: cornerRadius, padding: padding))
    }
}

/// Background for the round header buttons: a small glass bubble in tiles
/// mode, a faint circle on panel glass, black otherwise.
struct HeaderButtonBackground: View {
    @Default(.glassBackground) private var glassBackground
    @Default(.glassTiles) private var glassTiles

    var body: some View {
        if glassBackground && glassTiles, #available(macOS 26.0, *) {
            NativeGlassView(style: .regular, tint: nil, cornerRadius: 15, interactive: true)
                .frame(width: 30, height: 30)
        } else {
            Capsule()
                .fill(glassBackground ? Color.white.opacity(0.1) : Color.black)
                .frame(width: 30, height: 30)
        }
    }
}

@available(macOS 26.0, *)
struct NativeGlassView: NSViewRepresentable {
    var style: NSGlassEffectView.Style
    var tint: NSColor?
    var cornerRadius: CGFloat
    /// macOS 27+: the glass responds to the pointer (light follows it, presses squish).
    var interactive: Bool = false

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
        if #available(macOS 27.0, *) {
            if view.effectIsInteractive != interactive { view.effectIsInteractive = interactive }
        }
    }
}
