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

    /// SwiftUI's half of the motion: what moves inside the outline.
    static var open: Animation {
        .spring(duration: 0.36 * speed, bounce: min(max(Defaults[.notchOpenBounce], 0), 0.4))
    }
    static var close: Animation { .spring(duration: 0.24 * speed, bounce: 0) }
    /// SwiftUI takes about 100 ms to build the content, which already gives the
    /// outline its head start, so nothing here waits any longer.
    static var contentIn: Animation { .easeOut(duration: 0.2 * speed) }
    /// Content leaves fast so the shrinking shape never squeezes it.
    static var contentOut: Animation { .easeOut(duration: 0.12 * speed) }
    /// Glass stays hidden behind black until the island has nearly arrived.
    static var glassReveal: Animation { .easeOut(duration: 0.14 * speed).delay(0.03 * speed) }

    fileprivate static var outlineSpeed: Double { speed }
}

/// The outline's springs. Width and height move separately, which is most of
/// what makes the island feel elastic.
enum IslandMotion {
    /// The farthest a side may swing past its target.
    static let overshootLimit: CGFloat = 8

    static func spring(from: CGFloat, to: CGFloat, isWidth: Bool) -> IslandSpring {
        let speed = NotchMotion.outlineSpeed
        let bounce = min(max(Defaults[.notchOpenBounce], 0), 0.4)
        let base: IslandSpring
        if to > from {
            base = isWidth ? IslandSpring(duration: 0.36 * speed, bounce: bounce)
                : IslandSpring(duration: 0.32 * speed, bounce: bounce * 0.88)
        } else {
            base = IslandSpring(duration: (isWidth ? 0.24 : 0.22) * speed, bounce: 0)
        }
        return base.limited(travel: abs(to - from), limit: overshootLimit)
    }
}

/// Content coming in: slightly small and soft, then sharp.
struct IslandArrival: ViewModifier, Animatable {
    var progress: Double
    var blurs: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let shown = min(progress / 0.6, 1)
        content
            .opacity(shown)
            .scaleEffect(0.95 + 0.05 * progress, anchor: .top)
            .blur(radius: blurs ? 6 * (1 - progress) : 0)
    }
}

/// Black over the glass while the island opens, so empty glass never moves.
private struct GlassShutter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened = false

    var body: some View {
        Rectangle()
            .fill(.black)
            .opacity(opened ? 0 : 1)
            .onAppear {
                withAnimation(reduceMotion ? nil : NotchMotion.glassReveal) { opened = true }
            }
    }
}

/// Nothing when closed: the island's black is drawn by IslandSurfaceView. When open:
/// - Tiles mode: a faint veil, with the content split into glass tiles on top
///   (like Control Center). Each tile edge bends what's behind it.
/// - Panel mode: one glass panel behind everything.
/// - Glass off: solid black.
struct NotchBackground: View {
    let isOpen: Bool
    let useGlass: Bool
    /// Where the glass tiles are (in the "notchPanel" coordinate space),
    /// used by the refraction shader.
    var tileFrames: [GlassTileFrame] = []

    @ObservedObject private var backdrop = ScreenBackdrop.shared
    @Default(.realRefraction) private var realRefraction
    @Default(.refractionStrength) private var refractionStrength
    @Default(.glassFrost) private var glassFrost

    @Default(.glassClear) private var glassClear
    @Default(.glassTint) private var glassTint
    @Default(.glassOpacity) private var glassOpacity
    @Default(.glassTiles) private var glassTiles
    @Default(.albumGlow) private var albumGlow
    @Default(.albumGlowIntensity) private var albumGlowIntensity

    @Default(.glowCalendarColors) private var glowCalendarColors

    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var calendar = CalendarManager.shared

    private var tint: Double { min(max(glassTint, 0), 0.8) }
    /// Glow while music is active, or when today's events can lend their colours.
    private var showAlbumGlow: Bool {
        guard albumGlow else { return false }
        let hasEvents = glowCalendarColors
            && calendar.calendarAuthorizationStatus == .fullAccess
            && !EventListView.filteredEvents(events: calendar.events).isEmpty
        return !music.isPlayerIdle || music.albumArt !== defaultImage || hasEvents
    }
    private var tilesMode: Bool { useGlass && glassTiles && GlassSupport.available }

    /// Our own liquid glass: the captured backdrop, refracted at tile edges.
    private var customRefraction: Bool {
        tilesMode && realRefraction && backdrop.hasFrame && isOpen
    }

    private var notchWindow: NSWindow? {
        NSApp.windows.first { $0 is BoringNotchSkyLightWindow && $0.isVisible }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if isOpen {
                ZStack(alignment: .top) {
                    if customRefraction {
                        refractedBackdrop
                    } else {
                        standardLayers
                    }
                    if useGlass { GlassShutter() }
                }
                .transition(.identity)
            }
        }
        .onAppear { updateCapture(open: isOpen) }
        .onChange(of: isOpen) { _, open in updateCapture(open: open) }
        .onChange(of: realRefraction) { _, _ in updateCapture(open: isOpen) }
    }

    private func updateCapture(open: Bool) {
        if open && tilesMode && realRefraction {
            backdrop.start(for: notchWindow)
        } else {
            backdrop.stop()
        }
    }

    private var rectFloats: [Float] {
        tileFrames.flatMap { f -> [Float] in
            // Tiles are measured from the panel; this view starts at the stage's edge.
            [Float(f.rect.minX + islandStageBleed), Float(f.rect.minY), Float(f.rect.width), Float(f.rect.height), Float(f.radius)]
        }
    }

    private var refractedBackdrop: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                BackdropPicture(origin: origin)
                Rectangle().fill(.black.opacity(0.06 + tint))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .modifier(FormingGlass(
                size: geo.size,
                strength: Float(min(max(refractionStrength, 0), 1)),
                frost: Float(min(max(glassFrost, 0), 1)),
                rects: rectFloats
            ))
            // Above the frosted layer: fine strings would blur away under it.
            .overlay(alignment: .top) {
                if showAlbumGlow {
                    AlbumGlowView(active: isOpen)
                        .opacity(min(max(albumGlowIntensity, 0), 1))
                        .frame(width: openNotchSize.width, height: openNotchSize.height)
                }
            }
        }
    }

    @ViewBuilder
    private var standardLayers: some View {
        ZStack(alignment: .top) {
            // Base
            if tilesMode {
                Rectangle().fill(.black.opacity(0.14 + tint))
            } else if useGlass {
                panelGlass
            } else {
                Rectangle().fill(.black)
            }

            // The ribbon. In tiles mode this shows in the gaps; each tile draws
            // its own sharp slice above its glass (see TileRibbon).
            if showAlbumGlow {
                AlbumGlowView(active: isOpen)
                    .opacity(isOpen ? min(max(albumGlowIntensity, 0), 1) : 0)
                    .frame(width: openNotchSize.width, height: openNotchSize.height)
            }
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

/// Applies the refraction, growing from flat glass to full strength as the
/// notch opens, so the glass visibly forms instead of popping in.
private struct FormingGlass: ViewModifier {
    let size: CGSize
    let strength: Float
    let frost: Float
    let rects: [Float]
    @State private var formed = false

    func body(content: Content) -> some View {
        content
            .modifier(GlassEffectAmount(amount: formed ? 1 : 0, size: size, strength: strength, frost: frost, rects: rects))
            .onAppear {
                withAnimation(.spring(duration: 0.6, bounce: 0.25)) { formed = true }
            }
    }
}

private struct GlassEffectAmount: ViewModifier, Animatable {
    var amount: Double
    let size: CGSize
    let strength: Float
    let frost: Float
    let rects: [Float]

    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content.layerEffect(
            ShaderLibrary.liquidGlass(
                .float2(size),
                .float(strength * Float(amount)),
                .float(frost * Float(min(max(amount, 0), 1))),
                .floatArray(rects)
            ),
            maxSampleOffset: CGSize(width: 40, height: 40)
        )
    }
}

/// Just the captured picture, so a new frame only redraws this view.
private struct BackdropPicture: View {
    let origin: CGPoint
    @ObservedObject private var frame = ScreenBackdrop.shared.frame

    var body: some View {
        if let image = frame.image {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: frame.windowSize.width, height: frame.windowSize.height)
                .offset(x: -origin.x, y: -origin.y)
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
struct GlassTileFrame: Equatable {
    var rect: CGRect
    var radius: CGFloat
}

struct GlassTileFramesKey: PreferenceKey {
    static let defaultValue: [GlassTileFrame] = []
    static func reduce(value: inout [GlassTileFrame], nextValue: () -> [GlassTileFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// Reports a tile's frame in the notch panel's coordinate space.
private struct TileFrameReporter: View {
    let radius: CGFloat
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(
                key: GlassTileFramesKey.self,
                value: [GlassTileFrame(rect: g.frame(in: .named("notchPanel")), radius: radius)]
            )
        }
    }
}

/// The tile's slice of the visualiser ribbon, drawn above Apple's glass (which
/// would blur fine strings away) and below the tile's content.
private struct TileRibbon: View {
    let cornerRadius: CGFloat
    @Default(.albumGlow) private var albumGlow
    @Default(.albumGlowIntensity) private var intensity

    var body: some View {
        if albumGlow {
            GeometryReader { g in
                AlbumGlowView(
                    active: true,
                    origin: g.frame(in: .named("notchPanel")).origin,
                    panelSize: openNotchSize
                )
                .opacity(min(max(intensity, 0), 1))
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
    }
}

struct GlassTile: ViewModifier {
    var cornerRadius: CGFloat = 18
    var padding: CGFloat = 8

    @Default(.glassBackground) private var glassBackground
    @Default(.glassTiles) private var glassTiles
    @Default(.glassClear) private var glassClear
    @Default(.realRefraction) private var realRefraction
    @ObservedObject private var backdrop = ScreenBackdrop.shared

    func body(content: Content) -> some View {
        if glassBackground && glassTiles, #available(macOS 26.0, *) {
            content
                .padding(padding)
                .background {
                    ZStack {
                        // While our refraction shader runs it draws the glass,
                        // so Apple's would only blur it away.
                        if !(realRefraction && backdrop.hasFrame) {
                            NativeGlassView(
                                style: glassClear ? .clear : .regular,
                                tint: nil,
                                cornerRadius: cornerRadius,
                                interactive: true
                            )
                            TileRibbon(cornerRadius: cornerRadius)
                        }
                        TileFrameReporter(radius: cornerRadius)
                    }
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
    @Default(.realRefraction) private var realRefraction
    @ObservedObject private var backdrop = ScreenBackdrop.shared

    var body: some View {
        if glassBackground && glassTiles, #available(macOS 26.0, *) {
            ZStack {
                if !(realRefraction && backdrop.hasFrame) {
                    NativeGlassView(style: .regular, tint: nil, cornerRadius: 15, interactive: true)
                } else {
                    Color.white.opacity(0.001) // keep the button clickable
                }
                TileFrameReporter(radius: 15)
            }
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
