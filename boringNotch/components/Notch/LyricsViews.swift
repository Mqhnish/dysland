//
//  LyricsViews.swift
//  boringNotch
//
//  Two lyric styles:
//  - CompactLyricLine: the single line in the music tile. The current line
//    fills in left to right as it's sung, and lines roll up as they change.
//  - ExpandedLyricsView: a full lyrics panel (like Apple Music's): the
//    current line large and bright, the others dimmed and softly blurred,
//    scrolling along with the song. Click any line to jump there.
//

import Defaults
import SwiftUI

/// Show each line slightly early: synced lyrics mark when a line starts, so
/// waiting for that moment and then animating in feels late.
private let lyricLead: Double = 0.3

/// Playback time to use for lyrics, extrapolated between updates.
@MainActor
private func playbackPosition(_ music: MusicManager, at date: Date) -> Double {
    guard music.isPlaying else { return music.elapsedTime + lyricLead }
    let delta = date.timeIntervalSince(music.timestampDate)
    return min(max(music.elapsedTime + delta * music.playbackRate + lyricLead, 0), max(music.songDuration, 0))
}

// MARK: - Compact line

struct CompactLyricLine: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var music = MusicManager.shared
    let width: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !music.isPlaying)) { timeline in
            let elapsed = playbackPosition(music, at: timeline.date)
            let index = music.lyricIndex(at: elapsed)
            ZStack(alignment: .leading) {
                if let index {
                    let line = music.syncedLyrics[index]
                    let next = index + 1 < music.syncedLyrics.count
                        ? music.syncedLyrics[index + 1].time
                        : line.time + 5
                    let progress = min(max((elapsed - line.time) / max(next - line.time, 0.3), 0), 1)
                    SweepText(text: line.text, progress: progress, tint: tint, width: width)
                        .id(index)
                        .transition(.asymmetric(
                            insertion: .offset(y: 9).combined(with: .opacity),
                            removal: .offset(y: -9).combined(with: .opacity)
                        ))
                } else if !music.syncedLyrics.isEmpty {
                    // Before the first line: a quiet hint that lyrics are coming.
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .symbolEffect(.variableColor.iterative, isActive: music.isPlaying)
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: 18, alignment: .leading)
            .animation(.smooth(duration: 0.2), value: index)
        }
        .opacity(music.isPlaying || music.lyricIndex(at: music.elapsedTime) != nil ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.smooth(duration: 0.35)) { vm.homePanel = .lyrics }
        }
        .help("Show full lyrics")
    }

    private var tint: Color {
        Defaults[.playerColorTinting]
            ? Color(nsColor: music.avgColor).ensureMinimumBrightness(factor: 0.75)
            : .white
    }
}

/// Text that fills in from left to right with a soft edge. Lines too long to
/// fit glide sideways as they're sung, instead of being cut off.
private struct SweepText: View {
    let text: String
    let progress: Double
    let tint: Color
    let width: CGFloat
    @State private var textWidth: CGFloat = 0

    private var overflow: CGFloat { max(textWidth - width, 0) }
    /// Holds still briefly at each end so the start and finish can be read.
    private var glide: CGFloat { CGFloat(min(max((progress - 0.12) / 0.76, 0), 1)) }

    var body: some View {
        let base = Text(text)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
        base
            .foregroundStyle(.white.opacity(0.32))
            .overlay(alignment: .leading) {
                base
                    .foregroundStyle(
                        LinearGradient(colors: [.white, tint], startPoint: .leading, endPoint: .trailing)
                    )
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: max(progress - 0.08, 0)),
                                .init(color: .clear, location: max(min(progress + 0.08, 1), 0.0001)),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { textWidth = $0 }
            .offset(x: -overflow * glide)
            .frame(width: width, alignment: .leading)
            .mask {
                // Soft edges only on the sides where text runs past the frame.
                let edge = overflow > 0 ? 14 / max(width, 1) : 0
                LinearGradient(
                    stops: [
                        .init(color: glide > 0 && overflow > 0 ? .clear : .white, location: 0),
                        .init(color: .white, location: edge),
                        .init(color: .white, location: 1 - edge),
                        .init(color: glide < 1 && overflow > 0 ? .clear : .white, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            }
    }
}

// MARK: - Expanded panel

struct ExpandedLyricsView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var music = MusicManager.shared

    private var accent: Color {
        Color(nsColor: music.avgColor).ensureMinimumBrightness(factor: 0.75)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            nowPlaying
                .frame(width: 150)
            lyrics
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassTile(cornerRadius: 18, padding: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                PanelBackButton()
                Spacer()
                HoverPlayButton()
            }
            Image(nsImage: music.albumArt)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color(nsColor: music.avgColor).opacity(0.5), radius: 10, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(music.songTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(music.artistName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var lyrics: some View {
        if music.isFetchingLyrics {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !music.syncedLyrics.isEmpty {
            SyncedLyricsScroller(accent: accent)
        } else if !music.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                Text(music.currentLyrics)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 18))
                Text("No lyrics for this song")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SyncedLyricsScroller: View {
    @ObservedObject private var music = MusicManager.shared
    let accent: Color
    @State private var current: Int = -1
    @State private var userScrolledAt: Date = .distantPast

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    Color.clear.frame(height: 30)
                    ForEach(Array(music.syncedLyrics.enumerated()), id: \.offset) { i, line in
                        lineView(line.text, index: i)
                            .id(i)
                            .onTapGesture { music.seek(to: line.time) }
                    }
                    Color.clear.frame(height: 50)
                }
                .padding(.horizontal, 12)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 0.78),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .background {
                TimelineView(.animation(minimumInterval: 0.05, paused: !music.isPlaying)) { t in
                    let idx = music.lyricIndex(at: playbackPosition(music, at: t.date)) ?? -1
                    Color.clear
                        .onChange(of: idx, initial: true) { _, new in
                            withAnimation(.spring(duration: 0.38, bounce: 0.1)) {
                                current = new
                                proxy.scrollTo(max(new, 0), anchor: UnitPoint(x: 0.5, y: 0.35))
                            }
                        }
                }
            }
        }
    }

    private func lineView(_ text: String, index: Int) -> some View {
        let distance = abs(index - current)
        let isCurrent = index == current
        return Text(text)
            .font(.system(size: isCurrent ? 16 : 14, weight: .bold))
            .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(index < current ? 0.28 : 0.4)))
            .blur(radius: isCurrent ? 0 : min(Double(distance) * 0.6, 2.2))
            .scaleEffect(isCurrent ? 1 : 0.98, anchor: .leading)
            .shadow(color: isCurrent ? accent.opacity(0.55) : .clear, radius: 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
    }
}

private struct HoverPlayButton: View {
    @ObservedObject private var music = MusicManager.shared
    var body: some View {
        HoverButton(icon: music.isPlaying ? "pause.fill" : "play.fill", scale: .medium) {
            music.togglePlay()
        }
    }
}
