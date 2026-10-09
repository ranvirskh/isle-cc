import SwiftUI
import IsleCore

/// What the lock screen shows. Display only: no buttons, no gestures, no hit testing.
struct LockCardView: View {
    @ObservedObject var media: MediaController
    @ObservedObject var settings: Settings

    var body: some View {
        Group {
            if let now = media.now {
                card(now)
            } else {
                Color.clear
            }
        }
        .frame(width: LockCardView.size.width, height: LockCardView.size.height)
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
    }

    static let size = CGSize(width: 480, height: 204)

    private var showLyrics: Bool { settings.lockScreenLyrics && settings.lyricsEnabled }

    private func card(_ now: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Group {
                    if let image = media.artwork {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack { Color.white.opacity(0.1); Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5)) }
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(now.track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(now.track.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            // One timeline drives the lyric lines, the clock labels and the bar, so they always agree.
            TimelineView(.animation(minimumInterval: 0.25, paused: !now.isPlaying)) { ctx in
                let position = media.position(at: ctx.date)
                let duration = now.track.duration ?? 0
                let fraction = duration > 0 ? min(1, position / duration) : 0
                VStack(alignment: .leading, spacing: 10) {
                    if showLyrics {
                        let lines = media.currentLyric(at: ctx.date)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lines.current?.text ?? " ")
                                .font(.system(size: 19, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                                .id(lines.current?.time)
                                .transition(.opacity)
                                .animation(Motion.ease(Motion.lockLyricDuration, .lyrics), value: lines.current?.time)
                            Text(lines.next?.text ?? " ")
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }
                    VStack(spacing: 5) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.22))
                                Capsule().fill(Color.white.opacity(0.9)).frame(width: max(3, g.size.width * fraction))
                            }
                        }
                        .frame(height: 4)
                        HStack {
                            Text(TimeFormat.clock(position))
                            Spacer()
                            Text(duration > 0 ? TimeFormat.clock(duration) : "--:--")
                        }
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28).padding(.vertical, 26)
        .frame(width: LockCardView.size.width, height: LockCardView.size.height, alignment: .topLeading)
        .modifier(LockGlass(cornerRadius: 36))
        .accessibilityHidden(true)
    }
}

/// Liquid Glass on macOS 26 and later; a frosted material with a soft edge highlight before that.
struct LockGlass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }
}
