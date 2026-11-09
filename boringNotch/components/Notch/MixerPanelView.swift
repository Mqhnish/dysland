//
//  MixerPanelView.swift
//  boringNotch
//
//  The island's per-app volume panel. AppAudioMixer does the audio.
//

import SwiftUI

struct MixerPanelView: View {
    @ObservedObject private var mixer = AppAudioMixer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PanelBackButton()
                Text("Mixer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if !mixer.isSupported {
                message("Per-app volume needs macOS 14.2 or later")
            } else if mixer.apps.isEmpty {
                message("No apps are using audio right now")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(mixer.apps) { MixerRow(app: $0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassTile(cornerRadius: 18, padding: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { mixer.setPanelVisible(true) }
        .onDisappear { mixer.setPanelVisible(false) }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MixerRow: View {
    let app: AppAudioMixer.App
    @ObservedObject private var mixer = AppAudioMixer.shared
    @State private var dragging = false
    @State private var lastDragged = Date.distantPast

    private var value: Binding<Double> {
        Binding(get: { app.volume }, set: { mixer.setVolume($0, for: app.id) })
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 22, height: 22)
            .opacity(app.isPlaying ? 1 : 0.55)

            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(app.isPlaying ? 0.95 : 0.6))
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)

            if app.isAdjustable {
                Button { mixer.toggleMute(app.id) } label: {
                    Image(systemName: muteIcon)
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(app.isMuted ? Color.red.opacity(0.9) : .white.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                CustomSlider(value: value, range: 0...1,
                             color: app.isMuted ? .gray : .white,
                             dragging: $dragging, lastDragged: $lastDragged)
                    .frame(height: 10)
                    .opacity(app.isMuted ? 0.5 : 1)

                Text("\(Int((app.volume * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 36, alignment: .trailing)
            } else {
                Text("Call apps keep their own volume")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
    }

    private var muteIcon: String {
        if app.isMuted || app.volume == 0 { return "speaker.slash.fill" }
        return app.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }
}
