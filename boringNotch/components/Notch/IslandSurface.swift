//
//  IslandSurface.swift
//  boringNotch
//
//  Draws the island's outline as a Core Animation mask, so opening and closing
//  run in the render server and a busy main thread can't stutter them. SwiftUI
//  jumps straight to the new layout; only this mask moves.
//
//  The approach and spring timings are adapted from Vorssaint
//  (https://github.com/vorssaint/vorssaint-utils), Copyright (C) 2026 Vorssaint,
//  licensed GPL-3.0-or-later.
//

import AppKit
import Defaults
import QuartzCore
import SwiftUI

/// A damped spring, described the way SwiftUI's `spring(duration:bounce:)` is.
struct IslandSpring: Equatable {
    var duration: Double
    var bounce: Double

    var natural: Double { 2 * .pi / max(duration, 0.01) }
    var damping: Double { 1 - min(max(bounce, 0), 0.95) }

    /// This spring with only as much bounce as keeps its swing within `limit`.
    func limited(travel: CGFloat, limit: CGFloat) -> IslandSpring {
        guard bounce > 0, travel > limit, limit > 0 else { return self }
        let swing = exp(-.pi * damping / (1 - damping * damping).squareRoot())
        guard Double(travel) * swing > Double(limit) else { return self }
        let share = log(Double(limit / travel))
        return IslandSpring(duration: duration, bounce: 1 + share / (Double.pi * .pi + share * share).squareRoot())
    }
}

/// One side of the island in motion. Solved exactly at any moment, so a new
/// target carries on from the position and speed actually on screen.
struct IslandAxis: Equatable {
    var target: CGFloat
    var start: CGFloat
    var velocity: CGFloat
    var begin: CFTimeInterval
    var spring: IslandSpring

    func state(at time: CFTimeInterval) -> (value: CGFloat, velocity: CGFloat) {
        let t = max(0, time - begin)
        let x0 = Double(start - target)
        let v0 = Double(velocity)
        let w = spring.natural
        let z = spring.damping
        let x: Double
        let v: Double
        if z >= 1 {
            let b = v0 + w * x0
            let decay = exp(-w * t)
            x = decay * (x0 + b * t)
            v = decay * (b - w * (x0 + b * t))
        } else {
            let wd = w * (1 - z * z).squareRoot()
            let b = (v0 + z * w * x0) / wd
            let decay = exp(-z * w * t)
            let c = cos(wd * t)
            let s = sin(wd * t)
            x = decay * (x0 * c + b * s)
            v = decay * ((wd * b - z * w * x0) * c - (wd * x0 + z * w * b) * s)
        }
        return (target + CGFloat(x), CGFloat(v))
    }
}

/// The island's silhouette: hanging from the top edge, with true circular
/// corners that grow with its height.
enum IslandOutline {
    private static let tangent: CGFloat = 0.55228475

    static func radii(height: CGFloat, closedHeight: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let closed = cornerRadiusInsets.closed
        guard Defaults[.cornerRadiusScaling] else { return closed }
        let opened = cornerRadiusInsets.opened
        let t = min(max((height - closedHeight) / max(openNotchSize.height - closedHeight, 1), 0), 1)
        return (closed.top + (opened.top - closed.top) * t, closed.bottom + (opened.bottom - closed.bottom) * t)
    }

    static func add(to path: CGMutablePath, in rect: CGRect, top topRadius: CGFloat, bottom bottomRadius: CGFloat) {
        let top = min(topRadius, rect.width / 2, rect.height)
        let bottom = max(0, min(bottomRadius, rect.height - top, (rect.width - top * 2) / 2))
        let k = tangent
        let (l, r, t, b) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        path.move(to: CGPoint(x: l, y: t))
        path.addLine(to: CGPoint(x: r, y: t))
        path.addCurve(to: CGPoint(x: r - top, y: t + top),
                      control1: CGPoint(x: r - top * k, y: t),
                      control2: CGPoint(x: r - top, y: t + top * (1 - k)))
        path.addLine(to: CGPoint(x: r - top, y: b - bottom))
        path.addCurve(to: CGPoint(x: r - top - bottom, y: b),
                      control1: CGPoint(x: r - top, y: b - bottom * (1 - k)),
                      control2: CGPoint(x: r - top - bottom * (1 - k), y: b))
        path.addLine(to: CGPoint(x: l + top + bottom, y: b))
        path.addCurve(to: CGPoint(x: l + top, y: b - bottom),
                      control1: CGPoint(x: l + top + bottom * (1 - k), y: b),
                      control2: CGPoint(x: l + top, y: b - bottom * (1 - k)))
        path.addLine(to: CGPoint(x: l + top, y: t + top))
        path.addCurve(to: CGPoint(x: l, y: t),
                      control1: CGPoint(x: l + top, y: t + top * (1 - k)),
                      control2: CGPoint(x: l + top * k, y: t))
        path.closeSubpath()
    }
}

/// What the island should look like now, as SwiftUI laid it out.
struct IslandRequest: Equatable {
    var size: CGSize
    var closedHeight: CGFloat
    /// Height of the strip kept visible beside the closed island for a split pill.
    var wingHeight: CGFloat = 0
    /// Invisible hover area under the closed island, where the menu bar is taller.
    var chin: CGSize = .zero
    var isOpen = false
    var usesGlass = false
    var hairline = false
    var shadow = false
    /// A trackpad drag is moving the island: follow it exactly, with no spring.
    var tracksPointer = false
}

class IslandFlippedView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
}

/// The notch window's content: the SwiftUI host, inside a container masked to
/// the outline. The window never resizes.
final class IslandSurfaceView: IslandFlippedView {
    fileprivate let clip = IslandFlippedView()
    fileprivate let silhouette = CAShapeLayer()
    /// The island's black. It lives here, under the SwiftUI content, because it
    /// has to follow the outline exactly on every frame.
    fileprivate let fill = CAShapeLayer()
    fileprivate let edge = CAShapeLayer()
    fileprivate let dropShadow = CAShapeLayer()

    init(content: NSView, size: CGSize) {
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.masksToBounds = false

        clip.frame = bounds
        clip.autoresizingMask = [.width, .height]
        clip.wantsLayer = true
        addSubview(clip)

        content.frame = clip.bounds
        content.autoresizingMask = [.width, .height]
        clip.addSubview(content)

        silhouette.fillColor = NSColor.black.cgColor
        silhouette.frame = clip.bounds
        clip.layer?.mask = silhouette

        fill.fillColor = NSColor.black.cgColor
        fill.frame = clip.bounds
        fill.zPosition = -1
        clip.layer?.addSublayer(fill)

        edge.fillColor = nil
        edge.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        edge.lineWidth = 1
        edge.frame = clip.bounds
        edge.zPosition = 2
        edge.opacity = 0
        clip.layer?.addSublayer(edge)

        dropShadow.fillColor = NSColor.black.cgColor
        dropShadow.shadowColor = NSColor.black.cgColor
        dropShadow.shadowOpacity = 0.7
        dropShadow.shadowRadius = 6
        dropShadow.shadowOffset = .zero
        dropShadow.frame = bounds
        dropShadow.zPosition = -1
        dropShadow.opacity = 0
        layer?.addSublayer(dropShadow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [silhouette, fill, edge] { sublayer.frame = clip.bounds }
        dropShadow.frame = bounds
        CATransaction.commit()
    }
}

/// Runs the outline. Held by the view model so SwiftUI can reach it.
@MainActor
final class IslandSurfaceController {
    private weak var view: IslandSurfaceView?
    private var request: IslandRequest?
    private var width: IslandAxis?
    private var height: IslandAxis?

    private static let motionKey = "island.motion"
    private static let fillKey = "island.fill"
    private static let settledDistance: CGFloat = 0.25
    private static let settledSpeed: CGFloat = 4
    private static let longest: CFTimeInterval = 2.5
    private static let step: CFTimeInterval = 1.0 / 120

    /// The open island's size, as last laid out.
    private(set) var expectedOpenSize = openNotchSize

    nonisolated init() {}

    /// Starts the outline before SwiftUI builds the open content, which can
    /// hold the main thread for 100 ms. Core Animation keeps running meanwhile.
    func anticipateOpen() {
        guard var next = request, !next.isOpen else { return }
        next.size = expectedOpenSize
        present(next)
        CATransaction.flush()
    }

    func makeView(content: NSView, size: CGSize) -> IslandSurfaceView {
        let view = IslandSurfaceView(content: content, size: size)
        self.view = view
        width = nil
        height = nil
        if let request { apply(request) }
        return view
    }

    func present(_ next: IslandRequest) {
        guard next != request else { return }
        request = next
        if next.isOpen, !next.tracksPointer, next.size.height > next.closedHeight + 1 { expectedOpenSize = next.size }
        apply(next)
    }

    private func apply(_ request: IslandRequest) {
        guard let view else { return }
        let now = CACurrentMediaTime()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animates = !reduceMotion && !request.tracksPointer && width != nil && height != nil

        if animates {
            width = retarget(width, to: request.size.width, at: now, isWidth: true)
            height = retarget(height, to: request.size.height, at: now, isWidth: false)
        } else {
            width = IslandAxis(target: request.size.width, start: request.size.width, velocity: 0, begin: now,
                               spring: IslandMotion.spring(from: 0, to: 0, isWidth: true))
            height = IslandAxis(target: request.size.height, start: request.size.height, velocity: 0, begin: now,
                                spring: IslandMotion.spring(from: 0, to: 0, isWidth: false))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        install(view, request, from: now)
        applyFill(view, request, at: now)
        CATransaction.commit()

        applyChrome(view, request, animated: !reduceMotion)
    }

    private func retarget(_ axis: IslandAxis?, to target: CGFloat, at now: CFTimeInterval, isWidth: Bool) -> IslandAxis? {
        guard let axis else { return nil }
        if abs(axis.target - target) < Self.settledDistance { return axis }
        let state = axis.state(at: now)
        return IslandAxis(target: target, start: state.value, velocity: state.velocity, begin: now,
                          spring: IslandMotion.spring(from: state.value, to: target, isWidth: isWidth))
    }

    private func size(at time: CFTimeInterval, in view: IslandSurfaceView) -> CGSize {
        guard let width, let height else { return .zero }
        return CGSize(width: min(max(width.state(at: time).value, 0), view.bounds.width),
                      height: min(max(height.state(at: time).value, 0), view.bounds.height))
    }

    private func isSettled(at time: CFTimeInterval) -> Bool {
        [width, height].allSatisfy { axis in
            guard let axis else { return true }
            let state = axis.state(at: time)
            return abs(state.value - axis.target) < Self.settledDistance && abs(state.velocity) < Self.settledSpeed
        }
    }

    private func install(_ view: IslandSurfaceView, _ request: IslandRequest, from now: CFTimeInterval) {
        let target = request.size
        var sizes: [CGSize] = []
        var elapsed: CFTimeInterval = 0
        while elapsed < Self.longest, !isSettled(at: now + elapsed) {
            sizes.append(size(at: now + elapsed, in: view))
            elapsed += Self.step
        }
        sizes.append(target)

        let layers: [(CAShapeLayer, Bool)] = [(view.fill, false), (view.edge, false), (view.dropShadow, false), (view.silhouette, true)]
        for (layer, full) in layers {
            layer.removeAnimation(forKey: Self.motionKey)
            layer.path = path(for: target, request, in: view, full: full)
            guard sizes.count > 1 else { continue }
            if layer === view.edge && !request.hairline { continue }
            if layer === view.dropShadow && !request.shadow { continue }
            let animation = CAKeyframeAnimation(keyPath: "path")
            animation.values = sizes.map { path(for: $0, request, in: view, full: full) }
            animation.calculationMode = .linear
            animation.duration = Self.step * Double(sizes.count - 1)
            animation.beginTime = now
            animation.fillMode = .backwards
            layer.add(animation, forKey: Self.motionKey)
        }
    }

    /// `full` adds the areas outside the island that must stay visible.
    private func path(for size: CGSize, _ request: IslandRequest, in view: IslandSurfaceView, full: Bool) -> CGPath {
        let stage = view.bounds.width
        let x = (stage - size.width) / 2
        let radii = IslandOutline.radii(height: size.height, closedHeight: request.closedHeight)
        let path = CGMutablePath()
        IslandOutline.add(to: path, in: CGRect(x: x, y: 0, width: size.width, height: size.height),
                          top: radii.top, bottom: radii.bottom)
        if full {
            if request.wingHeight > 0 {
                path.addRect(CGRect(x: x + size.width - 1, y: 0, width: max(0, stage - x - size.width + 1), height: request.wingHeight))
            }
            if request.chin.height > 0 {
                path.addRect(CGRect(x: (stage - request.chin.width) / 2, y: size.height - 1,
                                    width: request.chin.width, height: request.chin.height + 1))
            }
        }
        return path
    }

    /// Under glass the black must go, or the glass would show black instead of
    /// the desktop. SwiftUI's shutter covers the glass by then.
    private func applyFill(_ view: IslandSurfaceView, _ request: IslandRequest, at now: CFTimeInterval) {
        let hidden = request.isOpen && request.usesGlass
        let target: Float = hidden ? 0 : 1
        guard view.fill.opacity != target else { return }
        view.fill.removeAnimation(forKey: Self.fillKey)
        view.fill.opacity = target
        guard hidden else { return }
        // Held for a moment so the shutter is on screen before the black leaves.
        let hold = CAKeyframeAnimation(keyPath: "opacity")
        hold.values = [1, 1, 0]
        hold.keyTimes = [0, 0.99, 1]
        hold.duration = 0.1
        hold.beginTime = now
        hold.fillMode = .backwards
        view.fill.add(hold, forKey: Self.fillKey)
    }

    private func applyChrome(_ view: IslandSurfaceView, _ request: IslandRequest, animated: Bool) {
        // The hairline's path has already jumped to the new shape, so it goes at once.
        if !request.hairline {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.edge.opacity = 0
            CATransaction.commit()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        if request.hairline { view.edge.opacity = 1 }
        view.dropShadow.opacity = request.shadow ? 1 : 0
        CATransaction.commit()
    }
}
