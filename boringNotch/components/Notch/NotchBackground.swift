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

    private var showGlass: Bool { useGlass && isOpen }
    private var tint: Double { min(max(glassTint, 0), 0.8) }

    var body: some View {
        ZStack(alignment: .top) {
            if useGlass {
                glassLayer
            }

            // Solid black on top, faded out when the glass should show through.
            Rectangle()
                .fill(.black)
                .opacity(showGlass ? 0 : 1)
        }
    }

    @ViewBuilder
    private var glassLayer: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(
                    (glassClear ? Glass.clear : Glass.regular).tint(.black.opacity(tint)),
                    in: shape
                )
        } else {
            // Older macOS: frosted material with a dark tint.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(tint + 0.15))
        }
    }
}
