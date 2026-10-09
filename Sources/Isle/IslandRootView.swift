import SwiftUI
import IsleCore

/// The black shape with inverted top corners: the top edge is full width, the body below is inset by `flare`
/// on both sides, joined by concave quarter-circles so the shape appears to flow out of the notch.
struct IslandShape: Shape {
    var flare: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottom) }
        set { flare = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = max(0, min(flare, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottom, (rect.width - 2 * f) / 2, rect.height - f))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Concave corner into the right side.
        p.addArc(center: CGPoint(x: rect.maxX, y: rect.minY + f), radius: f, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.maxY - b))
        p.addArc(center: CGPoint(x: rect.maxX - f - b, y: rect.maxY - b), radius: b, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + f + b, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + f + b, y: rect.maxY - b), radius: b, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.minY + f))
        p.addArc(center: CGPoint(x: rect.minX, y: rect.minY + f), radius: f, startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct IslandRootView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var env: AppEnv
    @State private var shownPhase: IslandStateMachine.Phase = .expanded
    private var style: ThemeStyle { ThemeStyle(theme: model.theme) }
    /// The expanded views stay built (so opening never pays for creating them) but every timeline in them is paused while collapsed.
    @State private var renderContent = true
    @State private var teardown: DispatchWorkItem?
    /// Size the content was last laid out at while open. On closing, the content stays at this size and the shrinking
    /// clip shape hides it, so the big view tree is not re-laid-out on every frame of the animation.
    @State private var openContentSize: CGSize = .zero

    private var flare: CGFloat { model.phase == .collapsed ? (model.liveActive && model.isNotched ? model.liveFlare : 0) : (model.isNotched ? 14 : 12) }
    private var bottom: CGFloat {
        switch model.phase {
        case .collapsed: return model.isNotched ? 9 : 4.5
        case .popup: return 24
        case .expanded: return 30
        }
    }

    var body: some View {
        let size = model.shapeSize
        ZStack(alignment: .top) {
            Color.clear
            ZStack(alignment: .top) {
                IslandShape(flare: flare, bottom: bottom)
                    .fill(style.background)
                    .overlay(GlossOverlay(flare: flare, bottom: bottom).opacity(style.hasGloss && model.phase != .collapsed ? 1 : 0))
                    .shadow(color: .black.opacity(model.phase == .collapsed ? 0 : 0.4), radius: 10, x: 0, y: 4)
                content(size: size)
                // Laid out at the collapsed size, never the animating shape size, so the cover cannot be stretched or
                // dragged outward while the island grows; it disappears at once on opening and fades in once closed.
                LiveActivityView()
                    .frame(width: model.collapsedLiveSize.width, height: model.collapsedLiveSize.height)
                    .opacity(model.phase == .collapsed && model.liveActive ? 1 : 0)
                    .animation(model.phase == .collapsed ? Motion.ease(0.2, delay: 0.15, .media) : nil, value: model.phase)
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .contentShape(IslandShape(flare: flare, bottom: bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.themeStyle, style)
        .onChange(of: model.shapeSize) { _, new in
            if model.phase != .collapsed { openContentSize = new }
        }
        .onChange(of: model.phase) { _, new in
            teardown?.cancel()
            if new != .collapsed {
                shownPhase = new
                renderContent = true
            }
        }
        .preferredColorScheme(.dark)
    }

    private func layoutSize(_ size: CGSize) -> CGSize {
        model.phase == .collapsed && openContentSize != .zero ? openContentSize : size
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let visible = model.contentVisible
        ZStack(alignment: .top) {
            if !renderContent {
                Color.clear
            } else if shownPhase == .popup {
                PopupView(flare: flare)
                    .transition(.opacity)
            } else {
                ExpandedView(flare: flare)
                    .transition(.opacity)
            }
        }
        .frame(width: layoutSize(size).width, height: layoutSize(size).height, alignment: .top)
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(nil, value: size)
        .clipShape(IslandShape(flare: flare, bottom: bottom))
        .opacity(visible ? 1 : 0)
        .blur(radius: visible ? 0 : Motion.contentInBlur)
        // Only opening scales the content up; closing just fades, which avoids re-rasterising the big view every frame.
        .scaleEffect(visible || model.phase == .collapsed ? 1 : Motion.contentInScale, anchor: .top)
        .animation(Motion.ease(Motion.tabSwitchDuration, .content), value: shownPhase)
        .allowsHitTesting(visible && model.phase != .collapsed)
    }
}

struct ExpandedView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var env: AppEnv
    let flare: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(flare: flare)
                .frame(height: model.headerHeight)
            Group {
                if model.showingDropTargets {
                    DropTargetsView()
                } else {
                    switch model.tab {
                    case .home: HomeView()
                    case .shelf: ShelfView()
                    case .agents: AgentsView()
                    }
                }
            }
            .id(model.showingDropTargets ? "drop" : model.tab.rawValue)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: Motion.tabSlideDistance)), removal: .opacity))
            .padding(.horizontal, flare + 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Motion.ease(Motion.tabSwitchDuration, .tabs), value: model.tab)
        .animation(Motion.ease(Motion.tabSwitchDuration, .tabs), value: model.showingDropTargets)
    }
}

struct HeaderView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var env: AppEnv
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var devices: DevicesController
    @EnvironmentObject var agents: AgentsController
    @EnvironmentObject var usage: ClaudeUsageController
    @EnvironmentObject var weather: WeatherController
    let flare: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
                TabButton(tab: tab, selected: model.tab == tab && !model.showingDropTargets) {
                    env.island.setTab(tab)
                }
            }
            Spacer(minLength: model.isNotched ? model.collapsedSize.width + 16 : 8)
            if settings.claudeUsage, !usage.windows.isEmpty {
                UsageChip(windows: usage.windows, stale: usage.failed)
            } else if settings.agentHeaderChip, settings.agentsEnabled, let top = LimitFormat.highestPercent(agents.snapshots, now: Date()) {
                Text("\(Int(top.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(severity: LimitSeverity(usedPercent: top)))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            HeaderIconButton(symbol: "gearshape.fill", help: "Settings") { AppDelegate.shared.showSettings() }
            if settings.weatherEnabled, let w = weather.reading { WeatherChip(reading: w) }
            if settings.privacyIndicator { PrivacyDots(state: model.privacy) }
            if settings.batteryInHeader, devices.battery.hasBattery { BatteryChip(state: devices.battery) }
        }
        .padding(.horizontal, flare + 14)
        .padding(.top, model.isNotched ? 0 : 4)
    }

    private var tabs: [IslandTab] { settings.agentsEnabled ? IslandTab.allCases : [.home, .shelf] }
}

struct TabButton: View {
    @Environment(\.themeStyle) private var style
    let tab: IslandTab
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var symbol: String {
        switch tab {
        case .home: return "house.fill"
        case .shelf: return "tray.fill"
        case .agents: return "sparkles"
        }
    }
    var title: String {
        switch tab {
        case .home: return "Home"
        case .shelf: return "Shelf & AirDrop"
        case .agents: return "AI agents"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(hover ? 0.85 : 0.5))
                .frame(width: 32, height: 24)
                .background(Capsule().fill(selected ? style.selectedTab : Color.white.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(PressStyle())
        .help(title)
        .accessibilityLabel(title)
        .onHover { hover = $0 }
        .animation(Motion.ease(0.15, .tabs), value: selected)
        .animation(Motion.ease(0.15, .tabs), value: hover)
    }
}

struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(hover ? 0.9 : 0.55))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(PressStyle())
        .help(help)
        .accessibilityLabel(help)
        .onHover { hover = $0 }
    }
}

struct BatteryChip: View {
    let state: BatteryState
    var body: some View {
        HStack(spacing: 3) {
            Text(state.percent.map { "\($0)%" } ?? "")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(state.percent ?? 0) percent\(state.isCharging ? ", charging" : "")")
    }
    private var symbol: String {
        if state.isCharging { return "battery.100percent.bolt" }
        let p = state.percent ?? 100
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
    private var color: Color {
        if state.isCharging { return .green }
        return (state.percent ?? 100) <= 20 ? .red : .white.opacity(0.85)
    }
}

/// Buttons scale down with a springy return.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && Motion.isOn(.buttons) ? Motion.buttonPressScale : 1)
            .animation(Motion.spring(Motion.buttonPress, .buttons), value: configuration.isPressed)
    }
}

extension Color {
    init(severity: LimitSeverity) {
        switch severity {
        case .calm: self = Color(red: 0.35, green: 0.85, blue: 0.55)
        case .warning: self = Color(red: 1.0, green: 0.75, blue: 0.25)
        case .critical: self = Color(red: 1.0, green: 0.35, blue: 0.32)
        }
    }
}

struct PopupView: View {
    @EnvironmentObject var model: IslandModel
    let flare: CGFloat

    var body: some View {
        let item = model.popup
        if let item, item.kind == .nowPlaying {
            NowPlayingBanner(item: item).id(item.id)
        } else {
        HStack(spacing: 14) {
            if let item {
                Image(systemName: item.symbol)
                    .font(.system(size: 30, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    ForEach(Array(item.batteries.enumerated()), id: \.offset) { _, b in
                        BatteryReadout(reading: b)
                    }
                }
            }
        }
        .padding(.horizontal, flare + 18)
        .padding(.top, model.isNotched ? model.collapsedSize.height + 2 : 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        }
    }
}

struct BatteryReadout: View {
    let reading: PopupItem.BatteryReading
    var body: some View {
        VStack(spacing: 2) {
            Text("\(reading.percent)%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(reading.percent <= 20 ? Color.red : Color.white)
            if !reading.label.isEmpty {
                Text(reading.label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// New song: the cover flips in, with the title and artist underneath.
struct NowPlayingBanner: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var media: MediaController
    let item: PopupItem
    @State private var angle: Double = -90
    @State private var textIn = false

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if let image = media.artwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack { Color.white.opacity(0.12); Image(systemName: "music.note").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .opacity(textIn ? 1 : 0)
            .offset(x: textIn ? 0 : -6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, model.isNotched ? model.collapsedSize.height + 4 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(Motion.spring(Motion.bannerFlip, .banner)) { angle = 0 }
                withAnimation(Motion.easeOut(0.3, delay: 0.18, .banner)) { textIn = true }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now playing \(item.title) by \(item.subtitle)")
    }
}

/// Collapsed "live activity": cover on the left of the notch, equalizer and privacy dots on the right.
struct LiveActivityView: View {
    @EnvironmentObject var model: IslandModel
    @EnvironmentObject var media: MediaController

    private var liveDescription: String {
        var parts: [String] = []
        if let p = model.usagePercent { parts.append("Claude usage \(Int(p.rounded())) percent") }
        if let a = model.usageAlert { parts.append("Claude 5-hour usage \(Int(a.percent.rounded())) percent, resets in \(ClaudeUsage.timeLeftLabel(until: a.resetsAt, now: Date()))") }
        parts += model.privacy.active.map(\.title)
        if model.chargingLive { parts.append("Charging \(model.battery.percent ?? 0) percent") }
        if let d = model.download { parts.append("Downloading \(d.firstName)") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
            Group {
                if !model.mediaLive, model.downloadLive {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 0.4, green: 0.8, blue: 1))
                } else if !model.mediaLive, model.chargingLive {
                    Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(red: 0.35, green: 0.9, blue: 0.5))
                } else if model.mediaLive {
                    Group {
                        if let image = media.artwork {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack { Color.white.opacity(0.15); Image(systemName: "music.note").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)) }
                        }
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .id(media.now?.track.identity ?? "none")
                }
            }
            if let alert = model.usageAlert { UsageAlertView(alert: alert) }
            }
            .padding(.leading, 8)
            .frame(width: model.liveSide, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                PrivacyDots(state: model.privacy)
                if let p = model.usagePercent {
                    Text("\(Int(p.rounded()))%").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Color(severity: LimitSeverity(usedPercent: p))).lineLimit(1).fixedSize()
                }
                if !model.mediaLive, let d = model.download {
                    Text(DownloadTracker.format(bytes: d.bytes)).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9)).lineLimit(1).fixedSize()
                } else if !model.mediaLive, model.chargingLive, let p = model.battery.percent {
                    Text("\(p)%").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                }
                if model.mediaLive {
                    EqualizerView(active: (media.now?.isPlaying ?? false) && model.phase == .collapsed)
                        .frame(width: 14)
                }
            }
            .frame(width: model.liveSide, alignment: .center)
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, model.liveFlare)
        .padding(.bottom, model.isNotched ? 2 + model.liveThickness : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(liveDescription)
    }
}

/// Orange microphone, green camera, purple screen recording. Display only.
struct PrivacyDots: View {
    let state: PrivacyState
    var body: some View {
        HStack(spacing: 4) {
            ForEach(state.active, id: \.self) { kind in
                Image(systemName: kind.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color(kind))
                    .transition(.scale.combined(with: .opacity))
                    .help(kind.title)
            }
        }
        .animation(Motion.spring(Motion.popup, .media), value: state)
    }
    private func color(_ k: PrivacyState.Kind) -> Color {
        switch k {
        case .microphone: return Color(red: 1.0, green: 0.62, blue: 0.2)
        case .camera: return Color(red: 0.3, green: 0.85, blue: 0.4)
        case .screen: return Color(red: 0.7, green: 0.45, blue: 1.0)
        }
    }
}

/// Four bars animated by Core Animation, so the motion runs on the GPU and costs almost no CPU.
struct EqualizerView: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> EqualizerNSView { EqualizerNSView() }
    func updateNSView(_ v: EqualizerNSView, context: Context) { v.setActive(active && !Motion.reduceMotion) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EqualizerNSView, context: Context) -> CGSize? { CGSize(width: 14, height: 11) }
}

final class EqualizerNSView: NSView {
    private var bars: [CALayer] = []
    private var running = false
    private let durations: [Double] = [0.42, 0.31, 0.5, 0.36]
    private let lows: [Double] = [0.35, 0.5, 0.3, 0.45]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let l = CALayer()
            l.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            l.cornerRadius = 1
            layer?.addSublayer(l)
            bars.append(l)
        }
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let w: CGFloat = 2, gap: CGFloat = 1.5, h = bounds.height
        let total = 4 * w + 3 * gap
        let x0 = (bounds.width - total) / 2
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            bar.position = CGPoint(x: x0 + CGFloat(i) * (w + gap) + w / 2, y: h / 2)
        }
    }

    func setActive(_ on: Bool) {
        guard on != running else { return }
        running = on
        for (i, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            if on {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = lows[i]; a.toValue = 1.0
                a.duration = durations[i]; a.autoreverses = true; a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.timeOffset = Double(i) * 0.11
                bar.add(a, forKey: "eq")
            } else {
                bar.transform = CATransform3DMakeScale(1, 0.3, 1)
            }
        }
    }
}

/// Frutiger Aero glass: a soft highlight across the top and a thin bright rim.
struct GlossOverlay: View {
    let flare: CGFloat
    let bottom: CGFloat
    var body: some View {
        ZStack {
            IslandShape(flare: flare, bottom: bottom)
                .fill(LinearGradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.0), Color.white.opacity(0.16), Color.white.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
            IslandShape(flare: flare, bottom: bottom)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.45)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

struct WeatherChip: View {
    let reading: WeatherReading
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: reading.symbol).symbolRenderingMode(.multicolor).font(.system(size: 12))
            Text(reading.temperatureText).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 6)
        .help("\(reading.place.name): \(reading.summary)" + (reading.high.map { h in reading.low.map { " · H \(Int(h.rounded()))° L \(Int($0.rounded()))°" } ?? "" } ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.place.name) \(reading.temperatureText), \(reading.summary)")
    }
}

/// "5h 70% · wk 20%", each part coloured by how close it is to the limit. Tooltip shows the reset times.
struct UsageChip: View {
    let windows: [LimitWindow]
    let stale: Bool

    var body: some View {
        let now = Date()
        let shown = windows.filter { LimitFormat.isCurrent($0, now: now) && ($0.id == "five_hour" || $0.id == "seven_day") }
        if !shown.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                ForEach(shown) { w in
                    HStack(spacing: 3) {
                        Text(w.id == "five_hour" ? "5h" : "wk").foregroundStyle(.white.opacity(0.55))
                        Text("\(Int(w.usedPercent.rounded()))%").foregroundStyle(Color(severity: LimitSeverity(usedPercent: w.usedPercent)))
                    }
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .opacity(stale ? 0.6 : 1)
            .help(shown.map { w in
                "\(LimitFormat.windowName(w)): \(Int(w.usedPercent.rounded()))% used" + (LimitFormat.countdown(to: w.resetsAt, now: now).map { ", resets in \($0)" } ?? "")
            }.joined(separator: "\n") + (stale ? "\nCould not refresh just now" : ""))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Claude usage: " + ClaudeUsage.summary(shown, now: now))
        }
    }
}

/// Left of the notch once the 5-hour limit is nearly used: the percentage over the time left until it resets.
struct UsageAlertView: View {
    let alert: ClaudeUsage.Alert

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Int(alert.percent.rounded()))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color(severity: LimitSeverity(usedPercent: alert.percent)))
                Text(ClaudeUsage.timeLeftLabel(until: alert.resetsAt, now: ctx.date))
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.65))
            }
            .lineLimit(1).fixedSize()
        }
    }
}
