//
//  ScreenBackdrop.swift
//  boringNotch
//
//  Grabs what's on screen *below* the notch window so the custom liquid glass
//  can refract it. Needs the Screen Recording permission.
//
//  Uses repeated one-shot grabs instead of a ScreenCaptureKit stream: a stream
//  puts the purple recording indicator in the menu bar. A grab is also quick
//  enough to have the first image ready before the notch starts opening.
//

import AppKit
import Defaults
import OSLog

/// The live frames. Kept apart from ScreenBackdrop so that only the one view
/// showing the picture redraws on each new frame, not every glass tile.
@MainActor
final class BackdropFrame: ObservableObject {
    /// Latest image of the area behind the notch window, in window coordinates.
    @Published fileprivate(set) var image: CGImage?
    /// The window-sized rect the image covers (top-left origin, points).
    @Published fileprivate(set) var windowSize: CGSize = .zero
}

/// CGWindowListCreateImage is hidden from Swift by the current SDK, so it's
/// looked up at runtime. If a future macOS removes it, this returns nil and the
/// notch simply keeps Apple's glass.
private enum BelowWindowGrab {
    private typealias Function = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let function: Function? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static var isAvailable: Bool { function != nil }

    /// `rect` is in global top-left coordinates.
    static func image(rect: CGRect, below window: CGWindowID) -> CGImage? {
        function?(
            rect,
            CGWindowListOption.optionOnScreenBelowWindow.rawValue,
            window,
            CGWindowImageOption.bestResolution.rawValue
        )?.takeRetainedValue()
    }
}

@MainActor
final class ScreenBackdrop: NSObject, ObservableObject {
    static let shared = ScreenBackdrop()

    let frame = BackdropFrame()
    /// Whether an image is available. Only changes when grabbing starts or stops.
    @Published private(set) var hasFrame = false

    private let log = Logger(subsystem: "boringnotch.liquid", category: "backdrop")
    private var grabTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var askedForPermission = false

    /// How long to wait between grabs while the notch is open.
    private static let interval: Duration = .milliseconds(80)

    private var enabled: Bool {
        Defaults[.realRefraction] && Defaults[.glassBackground] && BelowWindowGrab.isAvailable
    }

    /// Call when the pointer reaches the closed notch, so the image is ready
    /// before it opens. Lets go again by itself if the notch doesn't open.
    func prepare(for window: NSWindow?) {
        guard enabled, let window, CGPreflightScreenCaptureAccess() else { return }
        beginGrabbing(window)
        stop()
    }

    /// Call when the notch opens.
    func start(for window: NSWindow?) {
        stopTask?.cancel()
        guard enabled, let window else { return }
        guard CGPreflightScreenCaptureAccess() else {
            if !askedForPermission {
                askedForPermission = true
                log.info("Requesting Screen Recording permission")
                CGRequestScreenCaptureAccess()
            }
            return
        }
        beginGrabbing(window)
    }

    /// Call when the notch closes. Keeps going briefly in case it reopens.
    func stop() {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.endGrabbing()
        }
    }

    private func beginGrabbing(_ window: NSWindow) {
        guard grabTask == nil, let primary = NSScreen.screens.first else { return }
        let f = window.frame
        let rect = CGRect(x: f.minX, y: primary.frame.height - f.maxY, width: f.width, height: f.height)
        let windowID = CGWindowID(window.windowNumber)
        frame.windowSize = f.size

        let began = CFAbsoluteTimeGetCurrent()
        let log = self.log
        grabTask = Task.detached(priority: .userInitiated) { [weak self] in
            var first = true
            while !Task.isCancelled {
                if let image = BelowWindowGrab.image(rect: rect, below: windowID) {
                    if first {
                        first = false
                        log.info("First grab after \(Int((CFAbsoluteTimeGetCurrent() - began) * 1000), privacy: .public) ms: \(image.width, privacy: .public)x\(image.height, privacy: .public)")
                    }
                    await self?.publish(image)
                }
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func publish(_ image: CGImage) {
        guard grabTask != nil else { return }
        frame.image = image
        if !hasFrame { hasFrame = true }
    }

    private func endGrabbing() {
        grabTask?.cancel()
        grabTask = nil
        frame.image = nil
        hasFrame = false
    }
}
