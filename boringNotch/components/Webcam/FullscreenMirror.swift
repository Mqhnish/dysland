//
//  FullscreenMirror.swift
//  boringNotch
//
//  Double-click the notch mirror to pop it out into a floating window in the
//  middle of the screen. It grows out of the notch and shrinks back into it.
//  Close it by clicking anywhere else, double-clicking, pressing Esc, or the
//  X button. Drag to move.
//

import AppKit
@preconcurrency import AVFoundation
import Defaults
import SwiftUI

/// A floating panel that can take Esc without activating the whole app.
private final class MirrorPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class FullscreenMirrorController: ObservableObject {
    static let shared = FullscreenMirrorController()

    @Published private(set) var isShowing = false

    private var panel: MirrorPanel?
    /// Watches for clicks outside our app, so clicking away dismisses the mirror.
    private var outsideClickMonitor: Any?
    /// Separate from the notch's capture session, so the mirror keeps running
    /// after the notch closes underneath it.
    private var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "boringNotch.mirrorPopOut")

    /// Feels like a spring settling, without overshooting the window frame.
    private let openCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
    private let closeCurve = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.8, 0.3)

    private init() {}

    func toggle(on screen: NSScreen? = nil) {
        isShowing ? close() : show(on: screen)
    }

    func show(on screen: NSScreen? = nil) {
        guard !isShowing else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        self.session = session

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill

        let finalFrame = centeredFrame(on: screen)
        let startFrame = notchFrame(on: screen)

        let panel = MirrorPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Floats above normal app windows, but below the menu bar and the notch.
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.onEscape = { [weak self] in self?.close() }

        let hosting = NSHostingView(
            rootView: MirrorPopOutView(previewLayer: previewLayer) { [weak self] in
                self?.close()
            }
        )
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0

        self.panel = panel
        isShowing = true

        panel.orderFrontRegardless()
        panel.makeKey()

        sessionQueue.async { session.startRunning() }

        // Global monitors only see clicks in other apps, so dragging the mirror
        // or pressing its X doesn't count as clicking away.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.42 * animationSpeed
            ctx.timingFunction = openCurve
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard isShowing, let panel else { return }
        isShowing = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        let session = self.session
        self.session = nil

        let target = notchFrame(on: panel.screen ?? NSScreen.main ?? NSScreen.screens[0])

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28 * animationSpeed
            ctx.timingFunction = closeCurve
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                panel.orderOut(nil)
                panel.contentView = nil
                if self?.panel === panel { self?.panel = nil }
            }
        })

        sessionQueue.async { session?.stopRunning() }
    }

    // MARK: - Geometry

    private var animationSpeed: Double { min(max(Defaults[.notchAnimationSpeed], 0.5), 2.0) }

    /// Middle of the visible screen area (below the menu bar, above the Dock).
    private func centeredFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(max(Defaults[.mirrorPopOutSize], 280), visible.width * 0.9)
        let height = min(width * 3.0 / 4.0, visible.height * 0.9)
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        ).integral
    }

    /// A small rect tucked under the notch: where the window grows from and returns to.
    private func notchFrame(on screen: NSScreen) -> NSRect {
        let width: CGFloat = 120
        let height: CGFloat = 90
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, 24)
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: top - height,
            width: width,
            height: height
        )
    }
}

private struct MirrorPopOutView: View {
    let previewLayer: AVCaptureVideoPreviewLayer
    let onClose: () -> Void

    @State private var hovering = false

    private let corner: CGFloat = 22

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black

            CameraPreviewLayerView(previewLayer: previewLayer)
                .scaleEffect(x: -1, y: 1) // mirror, like the notch preview

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .opacity(hovering ? 1 : 0)
            .help("Close mirror (Esc)")
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onTapGesture(count: 2, perform: onClose)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.18)) { hovering = isHovering }
        }
    }
}
