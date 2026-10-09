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

    static let size = CGSize(width: 440, height: 168)

    private var showLyrics: Bool { settings.lockScreenLyrics && settings.lyricsEnabled }

    private func card(_ now: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    if let image = media.artwork {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack { Color.white.opacity(0.1); Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5)) }
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(now.track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(now.track.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if showLyrics {
                TimelineView(.animation(minimumInterval: 0.25, paused: !now.isPlaying)) { ctx in
                    let lines = media.currentLyric(at: ctx.date)
                    VStack(alignment: .leading, spacing: 3) {
                        ZStack(alignment: .leading) {
                            if let cur = lines.current {
                                Text(cur.text)
                                    .font(.system(size: 19, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.7)
                                    .id(cur.time)
                                    .transition(.asymmetric(insertion: .offset(y: 12).combined(with: .opacity), removal: .offset(y: -12).combined(with: .opacity)))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                        .animation(Motion.ease(Motion.lockLyricDuration, .lyrics), value: lines.current?.time)
                        Text(lines.next?.text ?? " ")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                    }
                }
            }
            TimelineView(.animation(minimumInterval: 1, paused: !now.isPlaying)) { ctx in
                let d = now.track.duration ?? 0
                let f = d > 0 ? min(1, media.position(at: ctx.date) / d) : 0
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(Color.white.opacity(0.85)).frame(width: max(3, g.size.width * f))
                    }
                }
                .frame(height: 3)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(width: LockCardView.size.width, height: LockCardView.size.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Color.black))
        .accessibilityHidden(true)
    }
}
