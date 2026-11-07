//
//  FullscreenMirror.swift
//  boringNotch
//
//  Double-click the notch mirror to blow it up to full screen.
//  Double-click again, press Esc, or click the close button to exit.
//

import AppKit
@preconcurrency import AVFoundation
import SwiftUI

/// Borderless windows can't become key by default, which we need for Esc.
private final class MirrorWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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

    private var window: MirrorWindow?
    /// Separate from the notch's capture session, so the mirror keeps running
    /// after the notch closes underneath it.
    private var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "boringNotch.fullscreenMirror")

    private init() {}

    func toggle(on screen: NSScreen? = nil) {
        isShowing ? close() : show(on: screen)
    }

    func show(on screen: NSScreen? = nil) {
        guard !isShowing else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
        self.session = session

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill

        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = targetScreen?.frame else { return }

        let window = MirrorWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .mainMenu + 4 // above the notch window
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.onEscape = { [weak self] in self?.close() }
        window.contentView = NSHostingView(
            rootView: FullscreenMirrorView(previewLayer: previewLayer) { [weak self] in
                self?.close()
            }
        )
        window.setFrame(frame, display: true)
        window.alphaValue = 0

        self.window = window
        isShowing = true

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        sessionQueue.async { session.startRunning() }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func close() {
        guard isShowing, let window else { return }
        isShowing = false
        let session = self.session
        self.session = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                window.orderOut(nil)
                window.contentView = nil
                if self?.window === window { self?.window = nil }
            }
        })

        sessionQueue.async { session?.stopRunning() }
    }
}

private struct FullscreenMirrorView: View {
    let previewLayer: AVCaptureVideoPreviewLayer
    let onClose: () -> Void

    @State private var appeared = false
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black

            CameraPreviewLayerView(previewLayer: previewLayer)
                .scaleEffect(x: -1, y: 1) // mirror, like the notch preview
                .scaleEffect(appeared ? 1 : 0.94)
                .ignoresSafeArea()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 48)
            .padding(.trailing, 28)
            .opacity(hovering ? 1 : 0)
            .help("Close mirror (Esc)")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onClose)
        .onContinuousHover { phase in
            withAnimation(.easeOut(duration: 0.2)) {
                if case .active = phase { hovering = true } else { hovering = false }
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { appeared = true }
        }
    }
}
