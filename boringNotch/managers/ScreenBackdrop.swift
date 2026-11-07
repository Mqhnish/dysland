//
//  ScreenBackdrop.swift
//  boringNotch
//
//  Captures what's on screen *behind* the notch window (our own windows are
//  excluded) so the custom liquid glass can refract it. Uses ScreenCaptureKit,
//  which needs the Screen Recording permission.
//
//  Only runs while the notch is open; frames are delivered at up to 30 fps
//  and only when the content behind actually changes.
//

import AppKit
import CoreImage
import Defaults
import OSLog
@preconcurrency import ScreenCaptureKit

@MainActor
final class ScreenBackdrop: NSObject, ObservableObject {
    static let shared = ScreenBackdrop()

    /// Latest frame of the area behind the notch window, in window coordinates.
    @Published private(set) var image: CGImage?
    /// The window-sized rect the image covers (top-left origin, points).
    @Published private(set) var windowSize: CGSize = .zero

    private let log = Logger(subsystem: "boringnotch.liquid", category: "backdrop")
    private var stream: SCStream?
    private var output: FrameOutput?
    private var starting = false
    private weak var window: NSWindow?
    private var stopTask: Task<Void, Never>?
    private var askedForPermission = false

    var hasFrame: Bool { image != nil }

    /// Call when the notch opens.
    func start(for window: NSWindow?) {
        stopTask?.cancel()
        guard Defaults[.realRefraction], Defaults[.glassBackground], let window else { return }
        self.window = window
        guard stream == nil, !starting else { return }

        guard CGPreflightScreenCaptureAccess() else {
            if !askedForPermission {
                askedForPermission = true
                log.info("Requesting Screen Recording permission")
                CGRequestScreenCaptureAccess()
            }
            return
        }

        starting = true
        Task { await self.beginCapture() }
    }

    /// Call when the notch closes. Keeps the stream briefly in case it reopens.
    func stop() {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.endCapture()
        }
    }

    private func beginCapture() async {
        defer { starting = false }
        guard let window, let screen = window.screen else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else {
                log.error("No matching display for capture")
                return
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

            // Window frame → display-local, top-left origin.
            let frame = window.frame
            let source = CGRect(
                x: frame.minX - screen.frame.minX,
                y: screen.frame.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
            let scale = screen.backingScaleFactor

            let config = SCStreamConfiguration()
            config.sourceRect = source
            config.width = Int(source.width * scale)
            config.height = Int(source.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.queueDepth = 3
            config.colorSpaceName = CGColorSpace.sRGB

            let output = FrameOutput { [weak self] cgImage in
                Task { @MainActor in self?.image = cgImage }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()

            self.output = output
            self.stream = stream
            self.windowSize = frame.size
            log.info("Backdrop capture running: \(Int(source.width), privacy: .public)x\(Int(source.height), privacy: .public) pt")
        } catch {
            log.error("Backdrop capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func endCapture() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        self.output = nil
        self.image = nil
        log.info("Backdrop capture stopped")
    }
}

/// Receives frames on a background queue and turns them into CGImages.
private final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "boringnotch.backdrop", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: (CGImage) -> Void

    init(onFrame: @escaping (CGImage) -> Void) {
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        onFrame(cgImage)
    }
}
