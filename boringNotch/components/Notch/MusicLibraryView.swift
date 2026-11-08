//
//  MusicLibraryView.swift
//  boringNotch
//
//  Browse your Apple Music playlists inside the notch and play a playlist or
//  a single song from it. Uses AppleScript (Music is already an allowed
//  Apple Events target). Spotify has no scripting access to playlists, so
//  this always shows the Apple Music library.
//

import Defaults
import SwiftUI

struct LibraryPlaylist: Identifiable, Hashable {
    let id: String      // persistent ID
    let name: String
}

struct LibraryTrack: Identifiable, Hashable {
    let id: String      // persistent ID
    let name: String
    let artist: String
    let duration: Double
}

@MainActor
final class MusicLibrary: ObservableObject {
    static let shared = MusicLibrary()

    @Published private(set) var playlists: [LibraryPlaylist] = []
    @Published private(set) var tracks: [LibraryTrack] = []
    @Published var selected: LibraryPlaylist?
    @Published private(set) var loadingPlaylists = false
    @Published private(set) var loadingTracks = false
    @Published private(set) var error: String?

    /// How many songs of a playlist to list (AppleScript gets slow beyond this).
    private let trackLimit = 300
    private var lastPlaylistLoad: Date = .distantPast

    func loadPlaylists(force: Bool = false) {
        guard !loadingPlaylists else { return }
        if !force, !playlists.isEmpty, Date().timeIntervalSince(lastPlaylistLoad) < 60 { return }
        loadingPlaylists = true
        error = nil
        Task {
            let script = """
            tell application "Music"
                set ps to (every user playlist whose special kind is none)
                return {persistent ID of ps, name of ps}
            end tell
            """
            do {
                let result = try await AppleScriptHelper.execute(script)
                let ids = Self.strings(result?.atIndex(1))
                let names = Self.strings(result?.atIndex(2))
                playlists = zip(ids, names).map { LibraryPlaylist(id: $0, name: $1) }
                lastPlaylistLoad = Date()
                if selected == nil || !playlists.contains(where: { $0.id == selected?.id }) {
                    if let first = playlists.first { select(first) }
                }
            } catch {
                self.error = "Couldn't read your Music library. Allow Boring Notch to control Music in System Settings › Privacy › Automation."
            }
            loadingPlaylists = false
        }
    }

    func select(_ playlist: LibraryPlaylist) {
        selected = playlist
        tracks = []
        loadingTracks = true
        let pid = Self.safeID(playlist.id)
        Task {
            let script = """
            tell application "Music"
                set p to (first user playlist whose persistent ID is "\(pid)")
                set n to count of tracks of p
                if n is 0 then return {{}, {}, {}, {}}
                if n > \(trackLimit) then set n to \(trackLimit)
                set ts to tracks 1 thru n of p
                return {persistent ID of ts, name of ts, artist of ts, duration of ts}
            end tell
            """
            let result = try? await AppleScriptHelper.execute(script)
            guard selected?.id == playlist.id else { return }
            let ids = Self.strings(result?.atIndex(1))
            let names = Self.strings(result?.atIndex(2))
            let artists = Self.strings(result?.atIndex(3))
            let durations = Self.doubles(result?.atIndex(4))
            tracks = ids.indices.map { i in
                LibraryTrack(
                    id: ids[i],
                    name: i < names.count ? names[i] : "",
                    artist: i < artists.count ? artists[i] : "",
                    duration: i < durations.count ? durations[i] : 0
                )
            }
            loadingTracks = false
        }
    }

    func play(_ playlist: LibraryPlaylist, shuffled: Bool) {
        let pid = Self.safeID(playlist.id)
        run("""
        tell application "Music"
            set shuffle enabled to \(shuffled ? "true" : "false")
            play (first user playlist whose persistent ID is "\(pid)")
        end tell
        """)
    }

    /// Plays a song in the context of its playlist, so the rest follows.
    func play(_ track: LibraryTrack, in playlist: LibraryPlaylist) {
        let pid = Self.safeID(playlist.id)
        let tid = Self.safeID(track.id)
        run("""
        tell application "Music"
            set p to (first user playlist whose persistent ID is "\(pid)")
            play (first track of p whose persistent ID is "\(tid)")
        end tell
        """)
    }

    private func run(_ script: String) {
        Task {
            try? await AppleScriptHelper.executeVoid(script)
            try? await Task.sleep(for: .milliseconds(400))
            MusicManager.shared.forceUpdate()
        }
    }

    // MARK: - Descriptor helpers

    /// Persistent IDs are hex; strip anything else so nothing can break the script.
    private static func safeID(_ id: String) -> String {
        id.filter { $0.isHexDigit }
    }

    private static func strings(_ d: NSAppleEventDescriptor?) -> [String] {
        guard let d else { return [] }
        if d.numberOfItems == 0 { return d.stringValue.map { [$0] } ?? [] }
        return (1...d.numberOfItems).map { d.atIndex($0)?.stringValue ?? "" }
    }

    private static func doubles(_ d: NSAppleEventDescriptor?) -> [Double] {
        guard let d else { return [] }
        if d.numberOfItems == 0 { return d.stringValue.flatMap(Double.init).map { [$0] } ?? [] }
        return (1...d.numberOfItems).map { d.atIndex($0)?.doubleValue ?? 0 }
    }
}

// MARK: - Library view

struct MusicLibraryView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var library = MusicLibrary.shared
    @ObservedObject private var music = MusicManager.shared

    private var accent: Color {
        Color(nsColor: music.avgColor).ensureMinimumBrightness(factor: 0.7)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            playlistColumn
                .frame(width: 180)
                .glassTile(cornerRadius: 18, padding: 6)
            trackColumn
                .frame(maxWidth: .infinity)
                .glassTile(cornerRadius: 18, padding: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { library.loadPlaylists() }
    }

    // MARK: Playlists

    private var playlistColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PanelBackButton()
                Text("Playlists")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
            }
            .padding(.horizontal, 2)

            if let error = library.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(4)
            } else if library.loadingPlaylists && library.playlists.isEmpty {
                loadingRow
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(library.playlists) { playlist in
                            playlistRow(playlist)
                        }
                    }
                }
            }
        }
    }

    private func playlistRow(_ playlist: LibraryPlaylist) -> some View {
        let isSelected = library.selected?.id == playlist.id
        return Button {
            withAnimation(.smooth(duration: 0.2)) { library.select(playlist) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : .white.opacity(0.45))
                    .frame(width: 14)
                Text(playlist.name)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.75))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Tracks

    private var trackColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(library.selected?.name ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                if let playlist = library.selected {
                    PillButton(icon: "play.fill", title: "Play", tint: accent) {
                        library.play(playlist, shuffled: false)
                    }
                    PillButton(icon: "shuffle", title: "Shuffle", tint: accent) {
                        library.play(playlist, shuffled: true)
                    }
                }
            }
            .padding(.horizontal, 4)

            if library.loadingTracks {
                loadingRow
            } else if library.tracks.isEmpty {
                Text(library.selected == nil ? "" : "This playlist is empty")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(library.tracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(track, number: index + 1)
                        }
                    }
                }
            }
        }
    }

    private func trackRow(_ track: LibraryTrack, number: Int) -> some View {
        let isCurrent = !music.isPlayerIdle && track.name == music.songTitle && track.artist == music.artistName
        return TrackRowButton(isCurrent: isCurrent) {
            if let playlist = library.selected { library.play(track, in: playlist) }
        } label: {
            HStack(spacing: 8) {
                Group {
                    if isCurrent {
                        Image(systemName: music.isPlaying ? "waveform" : "pause.fill")
                            .symbolEffect(.variableColor.iterative, isActive: music.isPlaying)
                            .foregroundStyle(accent)
                    } else {
                        Text("\(number)")
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .frame(width: 22, alignment: .trailing)

                VStack(alignment: .leading, spacing: 0) {
                    Text(track.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isCurrent ? accent : .white.opacity(0.92))
                        .lineLimit(1)
                    if !track.artist.isEmpty {
                        Text(track.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(Self.time(track.duration))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var loadingRow: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A list row with a soft hover highlight.
private struct TrackRowButton<Label: View>: View {
    let isCurrent: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 6)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(isCurrent ? 0.1 : hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct PillButton: View {
    let icon: String
    let title: String
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(hovering ? 0.18 : 0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// Small round button that returns to the normal home view.
struct PanelBackButton: View {
    @EnvironmentObject var vm: BoringViewModel
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) { vm.homePanel = .home }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hovering ? 0.18 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

/// The two small buttons in the music tile that open the library / lyrics.
struct MusicPanelButtons: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var music = MusicManager.shared

    var body: some View {
        HStack(spacing: 4) {
            if Defaults[.enableLyrics] {
                small("quote.bubble", active: false) {
                    withAnimation(.smooth(duration: 0.35)) { vm.homePanel = .lyrics }
                }
                .opacity(music.syncedLyrics.isEmpty && music.currentLyrics.isEmpty ? 0.35 : 1)
            }
            small("music.note.list", active: false) {
                withAnimation(.smooth(duration: 0.35)) { vm.homePanel = .library }
            }
        }
    }

    private func small(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        HoverIcon(icon: icon, action: action)
    }
}

private struct HoverIcon: View {
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.6))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hovering ? 0.15 : 0.0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}
