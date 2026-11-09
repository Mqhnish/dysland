//
//  IslandViews.swift
//  boringNotch
//
//  Views for the Dynamic Island–style features: the pop-up that drops out of
//  the closed notch, the live timer (alone, or as a split-off pill next to
//  music), the timer panel, and the search panel.
//

import AppKit
import Defaults
import SwiftUI

// MARK: - Pop-up alert (closed notch)

struct IslandAlertView: View {
    let alert: IslandAlert
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // The hardware notch sits here.
            Color.clear.frame(height: max(notchHeight, 24))
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(alert.tint.opacity(0.18))
                    Image(systemName: alert.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(alert.tint)
                        .symbolEffect(.bounce, value: alert.id)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(alert.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let subtitle = alert.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .frame(height: 50)
        }
        .frame(width: 340)
        .transition(
            .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                removal: .opacity.animation(.easeIn(duration: 0.1))
            )
        )
    }

    @ViewBuilder
    private var trailing: some View {
        switch alert.trailing {
        case .none:
            EmptyView()
        case .text(let text):
            Text(text)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(alert.tint == .white ? .white : alert.tint)
        case .ring(let value):
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(ringColor(value), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value * 100))")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
        }
    }

    private func ringColor(_ v: Double) -> Color {
        v <= 0.2 ? .red : (v <= 0.4 ? .yellow : .green)
    }
}

// MARK: - Timer in the closed notch

/// The timer as the main closed-notch activity (when no music is showing).
struct TimerLiveActivity: View {
    @ObservedObject private var island = IslandCenter.shared
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        if let timer = island.timer {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                HStack(spacing: 0) {
                    TimerRing(timer: timer, date: ctx.date)
                        .frame(width: max(notchHeight - 14, 14), height: max(notchHeight - 14, 14))
                        .frame(width: 44, alignment: .center)
                    Rectangle().fill(.black).frame(width: notchWidth - 10)
                    Text(IslandTimer.format(timer.display(at: ctx.date)))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(timer.isRunning ? .orange : .orange.opacity(0.5))
                        .contentTransition(.numericText(countsDown: timer.kind == .countdown))
                        .frame(width: 56, alignment: .trailing)
                        .padding(.trailing, 6)
                }
                .frame(height: notchHeight)
            }
        }
    }
}

/// The timer split off into its own small pill beside the notch, like the
/// iPhone island does when two activities run at once.
struct TimerSplitPill: View {
    let timer: IslandTimer
    let height: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            HStack(spacing: 5) {
                TimerRing(timer: timer, date: ctx.date)
                    .frame(width: 13, height: 13)
                Text(IslandTimer.format(timer.display(at: ctx.date)))
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .contentTransition(.numericText(countsDown: true))
            }
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(Capsule().fill(.black))
            .fixedSize()
        }
    }
}

struct TimerRing: View {
    let timer: IslandTimer
    let date: Date

    var body: some View {
        ZStack {
            Circle().stroke(.orange.opacity(0.25), lineWidth: 2.2)
            if timer.kind == .countdown {
                Circle()
                    .trim(from: 0, to: 1 - timer.progress(at: date))
                    .stroke(.orange, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: timer.progress(at: date))
            } else {
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Timer panel (open notch)

struct TimerPanelView: View {
    @ObservedObject private var island = IslandCenter.shared
    @State private var customMinutes: Double = 20

    private let presets: [Double] = [1, 3, 5, 10, 15, 25, 45, 60]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    PanelBackButton()
                    Text("Timer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                if let timer = island.timer {
                    running(timer)
                } else {
                    idle
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassTile(cornerRadius: 18, padding: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(presets, id: \.self) { m in
                    PresetChip(title: m >= 60 ? "\(Int(m / 60))h" : "\(Int(m))m") {
                        island.startCountdown(minutes: m)
                    }
                }
            }
            HStack(spacing: 10) {
                Slider(value: $customMinutes, in: 1...120, step: 1)
                    .controlSize(.small)
                    .tint(.orange)
                Text("\(Int(customMinutes)) min")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 50, alignment: .trailing)
                PillButton(icon: "play.fill", title: "Start", tint: .orange) {
                    island.startCountdown(minutes: customMinutes)
                }
                PillButton(icon: "stopwatch", title: "Stopwatch", tint: .orange) {
                    island.startStopwatch()
                }
            }
        }
    }

    private func running(_ timer: IslandTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            HStack(spacing: 16) {
                TimerRing(timer: timer, date: ctx.date)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(IslandTimer.format(timer.display(at: ctx.date)))
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText(countsDown: timer.kind == .countdown))
                        .animation(.smooth(duration: 0.25), value: Int(timer.display(at: ctx.date)))
                    Text(timer.kind == .countdown
                         ? "of \(IslandTimer.format(timer.duration))" + (timer.isRunning ? "" : "  ·  paused")
                         : (timer.isRunning ? "Stopwatch" : "Stopwatch  ·  paused"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                if timer.kind == .countdown {
                    RoundIconButton(icon: "plus", label: "1m") { island.extend(by: 1) }
                }
                RoundIconButton(icon: timer.isRunning ? "pause.fill" : "play.fill", tint: .orange) {
                    island.pauseOrResume()
                }
                RoundIconButton(icon: "xmark", tint: .red) { island.cancelTimer() }
            }
            .padding(.top, 6)
        }
    }
}

private struct PresetChip: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.orange.opacity(hovering ? 0.28 : 0.15)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

private struct RoundIconButton: View {
    let icon: String
    var label: String? = nil
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                if let label { Text(label).font(.system(size: 10, weight: .bold)) }
            }
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(Circle().fill(tint.opacity(hovering ? 0.3 : 0.17)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

// MARK: - Header buttons

struct IslandHeaderButtons: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    var body: some View {
        HStack(spacing: 4) {
            if Defaults[.islandSearch] {
                headerButton("magnifyingglass") { open(.search) }
            }
            headerButton("timer") { open(.timer) }
        }
    }

    private func open(_ panel: HomePanel) {
        coordinator.currentView = .home
        withAnimation(.smooth(duration: 0.35)) {
            vm.homePanel = vm.homePanel == panel ? .home : panel
        }
    }

    private func headerButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HeaderButtonBackground()
                .overlay {
                    Image(systemName: icon)
                        .foregroundColor(.white)
                        .imageScale(.medium)
                }
        }
        .buttonStyle(.plain)
    }
}

/// Opens the per-app mixer. Sits with the right-hand header buttons because
/// the left group has no room before the camera.
struct IslandMixerButton: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    var body: some View {
        Button {
            coordinator.currentView = .home
            withAnimation(.smooth(duration: 0.35)) { vm.homePanel = vm.homePanel == .mixer ? .home : .mixer }
        } label: {
            HeaderButtonBackground()
                .overlay {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.white)
                        .imageScale(.medium)
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search

struct IslandSearchResult: Identifiable {
    enum Kind { case app(URL), calc(String), timer(Double), web(String) }
    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: NSImage?
    let symbol: String
}

@MainActor
final class IslandSearchEngine: ObservableObject {
    static let shared = IslandSearchEngine()

    @Published var query = "" { didSet { update() } }
    @Published private(set) var results: [IslandSearchResult] = []
    @Published var selection = 0

    private struct AppEntry { let name: String; let url: URL }
    private var apps: [AppEntry] = []
    private var iconCache: [URL: NSImage] = [:]
    private var loaded = false

    func prepare() {
        query = ""
        selection = 0
        guard !loaded else { return }
        loaded = true
        Task.detached(priority: .userInitiated) {
            let found = Self.scanApps()
            await MainActor.run {
                self.apps = found.map { AppEntry(name: $0.0, url: $0.1) }
                self.update()
            }
        }
    }

    nonisolated private static func scanApps() -> [(String, URL)] {
        var home = NSHomeDirectory()
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { home = String(cString: dir) }
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", home + "/Applications"]
        var seen = Set<String>()
        var out: [(String, URL)] = []
        let fm = FileManager.default
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                if seen.insert(name.lowercased()).inserted {
                    out.append((name, URL(fileURLWithPath: root).appendingPathComponent(item)))
                }
            }
        }
        return out
    }

    private func update() {
        let q = query.trimmingCharacters(in: .whitespaces)
        selection = 0
        guard !q.isEmpty else { results = []; return }
        var list: [IslandSearchResult] = []

        if let value = Calculator.evaluate(q) {
            let text = Calculator.format(value)
            list.append(.init(kind: .calc(text), title: "= " + text, subtitle: "Copy result", icon: nil, symbol: "equal.circle.fill"))
        }
        if let minutes = Self.timerMinutes(q) {
            let label = minutes >= 1 ? "\(Calculator.format(minutes))-minute" : "\(Int(minutes * 60))-second"
            list.append(.init(kind: .timer(minutes), title: "Start a \(label) timer", subtitle: "Timer", icon: nil, symbol: "timer"))
        }

        let lower = q.lowercased()
        let matches = apps
            .compactMap { app -> (AppEntry, Int)? in
                let n = app.name.lowercased()
                if n.hasPrefix(lower) { return (app, 0) }
                if n.split(separator: " ").contains(where: { $0.hasPrefix(lower) }) { return (app, 1) }
                if n.contains(lower) { return (app, 2) }
                return nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name.count < $1.0.name.count }
            .prefix(4)
        for (app, _) in matches {
            list.append(.init(kind: .app(app.url), title: app.name, subtitle: "Application", icon: icon(for: app.url), symbol: "app"))
        }

        list.append(.init(kind: .web(q), title: "Search the web for “\(q)”", subtitle: "Web", icon: nil, symbol: "globe"))
        results = Array(list.prefix(4))
    }

    private func icon(for url: URL) -> NSImage {
        if let cached = iconCache[url] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[url] = image
        return image
    }

    /// "5m", "5 min", "timer 10", "90s", "1h" → minutes.
    static func timerMinutes(_ q: String) -> Double? {
        let s = q.lowercased().replacingOccurrences(of: "timer", with: "").trimmingCharacters(in: .whitespaces)
        guard q.lowercased().contains("timer") || s.range(of: #"^\d+(\.\d+)?\s*(s|sec|secs|seconds|m|min|mins|minutes|h|hr|hour|hours)$"#, options: .regularExpression) != nil
        else { return nil }
        guard let numberRange = s.range(of: #"\d+(\.\d+)?"#, options: .regularExpression),
              let number = Double(s[numberRange]), number > 0 else { return nil }
        let unit = s[numberRange.upperBound...].trimmingCharacters(in: .whitespaces)
        if unit.hasPrefix("s") { return number / 60 }
        if unit.hasPrefix("h") { return number * 60 }
        return number
    }

    func run(_ result: IslandSearchResult, vm: BoringViewModel) {
        switch result.kind {
        case .app(let url):
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            vm.close()
        case .calc(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            vm.close()
        case .timer(let minutes):
            IslandCenter.shared.startCountdown(minutes: minutes)
            withAnimation(.smooth(duration: 0.35)) { vm.homePanel = .timer }
        case .web(let q):
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            if let url = c.url { NSWorkspace.shared.open(url) }
            vm.close()
        }
    }
}

struct IslandSearchView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var engine = IslandSearchEngine.shared
    @FocusState private var focused: Bool
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 6) {
            // The field grows out of a droplet.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                if expanded {
                    TextField("Search apps, calculate, “timer 5m”…", text: $engine.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .focused($focused)
                        .onSubmit(runSelected)
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { vm.close(); return .handled }
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, expanded ? 12 : 0)
            .frame(width: expanded ? nil : 34, height: 34)
            .frame(maxWidth: expanded ? .infinity : 34)
            .background(Capsule().fill(.white.opacity(0.1)))
            .glassTile(cornerRadius: 17, padding: 0)

            VStack(spacing: 1) {
                ForEach(Array(engine.results.enumerated()), id: \.element.id) { i, result in
                    row(result, selected: i == engine.selection)
                        .onTapGesture { engine.run(result, vm: vm) }
                        .onHover { if $0 { engine.selection = i } }
                }
            }
            .animation(.smooth(duration: 0.2), value: engine.results.map(\.title))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            engine.prepare()
            NotchKeyFocus.enable()
            withAnimation(.spring(duration: 0.55, bounce: 0.35).delay(0.1)) { expanded = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focused = true }
        }
        .onDisappear { NotchKeyFocus.disable() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            // Clicking elsewhere dismisses it, like Spotlight.
            if note.object is BoringNotchSkyLightWindow { vm.close() }
        }
    }

    private func row(_ r: IslandSearchResult, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = r.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: r.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(r.symbol == "timer" ? .orange : .white.opacity(0.8))
                }
            }
            .frame(width: 20, height: 20)
            Text(r.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Text(r.subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.13 : 0)))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !engine.results.isEmpty else { return }
        engine.selection = (engine.selection + delta + engine.results.count) % engine.results.count
    }

    private func runSelected() {
        guard engine.results.indices.contains(engine.selection) else { return }
        engine.run(engine.results[engine.selection], vm: vm)
    }
}

/// Lets the notch window take keyboard focus only while search is open.
enum NotchKeyFocus {
    static func enable() {
        BoringNotchSkyLightWindow.allowsKeyFocus = true
        NSApp.windows.first { $0 is BoringNotchSkyLightWindow && $0.isVisible }?.makeKey()
    }

    static func disable() {
        BoringNotchSkyLightWindow.allowsKeyFocus = false
        NSApp.windows.first { $0 is BoringNotchSkyLightWindow && $0.isKeyWindow }?.resignKey()
    }
}

// MARK: - Calculator

/// A tiny, safe arithmetic parser (+ − × ÷ ^ %, parentheses). Returns nil for
/// anything that isn't a sum, so normal searches aren't mistaken for maths.
enum Calculator {
    static func evaluate(_ input: String) -> Double? {
        let s = input.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty,
              s.allSatisfy({ "0123456789.+-*/^%()".contains($0) }),
              s.contains(where: { "+-*/^%".contains($0) }),
              s.contains(where: \.isNumber)
        else { return nil }
        var p = Parser(chars: Array(s))
        guard let v = p.expression(), p.i == p.chars.count, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.maximumFractionDigits = 8
        f.minimumIntegerDigits = 1
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1
                if c == "%", peek() == nil || "+-*/)".contains(peek()!) { v /= 100; continue }
                guard let r = power() else { return nil }
                switch c {
                case "*": v *= r
                case "/": v /= r
                default: v = v.truncatingRemainder(dividingBy: r)
                }
            }
            return v
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = power() else { return nil }
                return pow(base, e)
            }
            return base
        }

        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            return primary()
        }

        mutating func primary() -> Double? {
            if peek() == "(" {
                i += 1
                guard let v = expression(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            guard i > start else { return nil }
            return Double(String(chars[start..<i]))
        }
    }
}
