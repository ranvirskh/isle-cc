import SwiftUI
import IsleCore

struct HomeView: View {
    @Environment(\.themeStyle) private var style
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var calendar: CalendarController
    @EnvironmentObject var settings: Settings

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let now = media.now {
                ArtworkView(identity: now.track.identity)
                    .frame(width: style.theme.artworkSide, height: style.theme.artworkSide)
                    .frame(maxHeight: .infinity, alignment: .center)
                PlayerColumn(now: now)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                EmptyPlayerView()
                    .frame(maxWidth: .infinity)
            }
            if settings.showCalendar && style.showsCalendar {
                Divider().overlay(Color.white.opacity(0.12))
                AgendaView()
                    .frame(width: 190)
            }
        }
        .animation(Motion.spring(Motion.artworkFlip, .media), value: media.now?.track.identity)
        .onAppear { AppDelegate.shared.env.usage.refreshIfStale() }
    }
}

struct ArtworkView: View {
    @Environment(\.themeStyle) private var style
    @EnvironmentObject var media: MediaController
    let identity: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = media.artwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .frame(width: style.theme.artworkSide, height: style.theme.artworkSide)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .id(media.artwork == nil ? identity : "art-\(identity)")
            .transition(.asymmetric(insertion: .scale(scale: 0.88).combined(with: .opacity), removal: .opacity))

            if let icon = media.sourceAppIcon() {
                Image(nsImage: icon)
                    .resizable().frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.black, lineWidth: 2))
                    .offset(x: 6, y: 6)
                    .accessibilityHidden(true)
            }
        }
        .animation(Motion.spring(Motion.artworkFlip, .media), value: media.artwork == nil)
        .onTapGesture { media.openSourceApp() }
        .accessibilityLabel("Album artwork")
    }
}

struct PlayerColumn: View {
    @Environment(\.themeStyle) private var style
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var settings: Settings
    let now: NowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(now.track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if now.track.isExplicit == true {
                    Text("E")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 14, height: 14)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.65)))
                        .accessibilityLabel("Explicit")
                }
            }
            .id("title-\(now.track.identity)")
            .transition(.asymmetric(insertion: .offset(y: 8).combined(with: .opacity), removal: .opacity))
            Text(now.track.artist.isEmpty ? " " : now.track.artist)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .id("artist-\(now.track.identity)")
                .transition(.asymmetric(insertion: .offset(y: 8).combined(with: .opacity), removal: .opacity))
            if settings.lyricsEnabled {
                LyricLineView(font: .system(size: 12, weight: .medium), color: style.accent)
                    .frame(height: 16)
            }
            ProgressView_(now: now)
                .padding(.top, 3)
            ControlsRow(now: now)
        }
        .foregroundStyle(.white)
        .animation(Motion.ease(Motion.trackChangeDuration, .media), value: now.track.identity)
    }
}

/// The current lyric as one line, scrolling horizontally when it does not fit.
struct LyricLineView: View {
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var model: IslandModel
    let font: Font
    let color: Color

    var body: some View {
        let playing = media.now?.isPlaying ?? false
        TimelineView(.animation(minimumInterval: 0.2, paused: !playing || !hasLyrics || model.phase == .collapsed)) { ctx in
            let line = media.currentLyric(at: ctx.date).current
            ZStack(alignment: .leading) {
                if let line {
                    MarqueeText(text: line.text, font: font, color: color, active: playing && model.phase != .collapsed)
                        .id(line.time)
                        .transition(.asymmetric(insertion: .offset(y: Motion.lyricLineOffset).combined(with: .opacity),
                                                removal: .offset(y: -Motion.lyricLineOffset).combined(with: .opacity)))
                }
            }
            .animation(Motion.ease(Motion.lyricLineDuration, .lyrics), value: line?.time)
            .clipped()
        }
    }

    private var hasLyrics: Bool { if case .timed = media.lyrics?.state { return true }; return false }
}

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    /// False while paused (or the island is closed): the line returns to its starting position and waits.
    let active: Bool
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var generation = 0

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .background(GeometryReader { t in Color.clear.onAppear { textWidth = t.size.width; containerWidth = geo.size.width; update() } })
                .offset(x: offset)
        }
        .onChange(of: active) { _, _ in update() }
        .accessibilityLabel(text)
    }

    private func update() {
        generation += 1
        let mine = generation
        guard active else {
            // Paused: glide back to the start (replaces the running scroll animation).
            let travelled = Double(abs(offset))
            let seconds = min(Motion.lyricReturnMax, max(Motion.lyricReturnMin, travelled / Motion.lyricReturnPointsPerSecond))
            withAnimation(Motion.ease(seconds, .lyrics)) { offset = 0 }
            return
        }
        guard textWidth > containerWidth, containerWidth > 0, !Motion.reduceMotion, Motion.isOn(.lyrics) else { return }
        let distance = textWidth - containerWidth + 8
        let duration = Double(distance) / Motion.lyricMarqueeSpeed
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.lyricMarqueePause) {
            guard mine == generation, active else { return }
            withAnimation(.linear(duration: duration)) { offset = -distance }
        }
    }
}

struct ProgressView_: View {
    @Environment(\.themeStyle) private var style
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var model: IslandModel
    let now: NowPlaying
    @State private var scrub: Double?

    var body: some View {
        let duration = now.track.duration
        let canSeek = now.capabilities.contains(.seek) && (duration ?? 0) > 0
        TimelineView(.animation(minimumInterval: Motion.progressTick, paused: !now.isPlaying || model.phase != .expanded)) { ctx in
            let position = scrub ?? media.position(at: ctx.date)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    let fraction = (duration ?? 0) > 0 ? min(1, max(0, position / (duration ?? 1))) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(style.progressFill).frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: scrub == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard canSeek, let d = duration else { return }
                            scrub = min(d, max(0, Double(v.location.x / geo.size.width) * d))
                        }
                        .onEnded { _ in
                            if let s = scrub { media.seek(to: s) }
                            scrub = nil
                        })
                    .animation(Motion.ease(0.12, .media), value: scrub == nil)
                }
                .frame(height: 12)
                if !style.theme.isCompact { HStack {
                    Text(TimeFormat.clock(position))
                    Spacer()
                    if let d = duration { Text(TimeFormat.remaining(position: position, duration: d)) }
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5)) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(TimeFormat.clock(media.position()))
    }
}

struct ControlsRow: View {
    @Environment(\.themeStyle) private var style
    @EnvironmentObject var media: MediaController
    let now: NowPlaying

    var body: some View {
        HStack(spacing: 0) {
            slot { if now.capabilities.contains(.shuffle) { shuffle } }
            slot { if now.capabilities.contains(.previous) { transport("backward.fill", "Previous") { media.previous() } } }
            slot { playPause }
            slot { if now.capabilities.contains(.next) { transport("forward.fill", "Next") { media.next() } } }
            slot { OutputIndicator() }
        }
        .frame(height: 30)
    }

    private func slot<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(maxWidth: .infinity)
    }

    private var shuffle: some View {
        Button { media.toggleShuffle() } label: {
            Image(systemName: "shuffle").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(now.shuffle == true ? style.accent : .white.opacity(0.5))
        }
        .buttonStyle(PressStyle()).help("Shuffle").accessibilityLabel("Shuffle")
    }

    private func transport(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17))
        }
        .buttonStyle(PressStyle()).help(label).accessibilityLabel(label)
    }

    private var playPause: some View {
        Button { media.togglePlayPause() } label: {
            Image(systemName: now.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 22))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 30)
        }
        .buttonStyle(PressStyle())
        .animation(Motion.ease(Motion.playPauseSwap, .media), value: now.isPlaying)
        .help(now.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(now.isPlaying ? "Pause" : "Play")
    }
}

struct OutputIndicator: View {
    @EnvironmentObject var media: MediaController
    var body: some View {
        Image(systemName: media.output.symbol)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.5))
            .help("Playing on \(media.output.name)")
            .accessibilityLabel("Output: \(media.output.name)")
    }
}

struct EmptyPlayerView: View {
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var settings: Settings
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.white.opacity(0.35))
            Text("Nothing playing").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            if media.automationDenied {
                Text("Isle isn't allowed to control \(settings.mediaSource == .spotify ? "Spotify" : "Music").")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Button("Open Automation Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.bordered).controlSize(.small)
            } else if settings.mediaSource == .system, let reason = media.systemUnsupportedReason {
                Text(reason).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            } else {
                Text("Play something in \(sourceName) to see it here.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxHeight: .infinity)
    }
    private var sourceName: String {
        switch settings.mediaSource { case .system: return "any app"; case .spotify: return "Spotify"; case .appleMusic: return "Music" }
    }
}

struct AgendaView: View {
    @EnvironmentObject var calendar: CalendarController
    @EnvironmentObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Button { calendar.resetDay() } label: {
                    HStack(spacing: 4) {
                        Text(dayTitle).font(.system(size: 12, weight: .semibold))
                        Text(isOtherDay ? dayDate.formatted(.dateTime.month(.abbreviated).day()) : dayDate.formatted(.dateTime.weekday(.abbreviated).day()))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .help("Back to today")
                Spacer(minLength: 2)
                dayButton("chevron.left", "Previous day") { calendar.shiftDay(-1) }
                dayButton("chevron.right", "Next day") { calendar.shiftDay(1) }
                dayButton("calendar", "Open Calendar") { calendar.openCalendarApp() }
            }
            switch calendar.access {
            case .denied:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calendar access is off.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    Button("Open Privacy Settings") { calendar.openPrivacySettings() }.buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
            case .unknown:
                Button("Allow Calendar Access") { calendar.requestIfNeeded() }.buttonStyle(.bordered).controlSize(.small)
                Spacer()
            case .granted:
                if calendar.agenda.rows.isEmpty {
                    Text("No events").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 5) {
                            ForEach(calendar.agenda.rows) { row in AgendaRow(row: row).onTapGesture { calendar.openCalendarApp() } }
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }
}

extension AgendaView {
    private var isOtherDay: Bool { if case .other = calendar.agenda.day { return true }; return false }
    private var dayDate: Date {
        switch calendar.agenda.day {
        case .today: return Date()
        case .tomorrow: return Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        case .other(let d): return d
        }
    }
    private var dayTitle: String {
        switch calendar.agenda.day {
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .other(let d): return Calendar.current.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.weekday(.wide))
        }
    }
    private func dayButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).help(label).accessibilityLabel(label)
    }
}

struct AgendaRow: View {
    let row: Agenda.Row

    var body: some View {
        let c = row.event.color
        HStack(spacing: 7) {
            Capsule().fill(Color(red: c.r, green: c.g, blue: c.b)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(timeText).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(row.status == .current ? 0.14 : 0)))
        .opacity(row.status == .past ? 0.4 : 1)
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        if row.event.isAllDay { return "All day" }
        let f = Date.FormatStyle.dateTime.hour().minute()
        return "\(row.event.start.formatted(f)) – \(row.event.end.formatted(f))"
    }
}
