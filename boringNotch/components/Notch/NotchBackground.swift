//
//  NotchBackground.swift
//  boringNotch
//
//  Shared notch motion values and the (optionally glass) notch background.
//

import SwiftUI

/// Every open/close animation goes through these, so nothing fights over timing.
enum NotchMotion {
    /// Opening: quick, with a small settle at the end.
    static let open = Animation.spring(duration: 0.42, bounce: 0.14)
    /// Closing: a bit faster and with no bounce, so it tucks away cleanly.
    static let close = Animation.spring(duration: 0.34, bounce: 0)
    /// Content appears just after the shape starts growing.
    static let contentIn = Animation.spring(duration: 0.36, bounce: 0).delay(0.06)
    /// Content leaves fast so the shrinking shape never squeezes it.
    static let contentOut = Animation.easeOut(duration: 0.12)
}

/// Black when closed (so it blends into the hardware notch).
/// When open, either stays black or becomes tinted Liquid Glass.
struct NotchBackground<S: Shape>: View {
    let shape: S
    let isOpen: Bool
    let useGlass: Bool
    /// Height of the physical notch. Kept dark when open so the camera housing doesn't
    /// look like a hole cut into the glass.
    let topBandHeight: CGFloat

    private var showGlass: Bool { useGlass && isOpen }

    var body: some View {
        ZStack(alignment: .top) {
            if useGlass {
                glassLayer
                LinearGradient(
                    colors: [.black, .black, .black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: max(topBandHeight, 24) + 18)
                .allowsHitTesting(false)
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
                .glassEffect(.regular.tint(.black.opacity(0.38)), in: shape)
        } else {
            // Older macOS: frosted material with a dark tint.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.45))
        }
    }
}
