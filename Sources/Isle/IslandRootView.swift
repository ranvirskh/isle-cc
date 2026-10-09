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

    private var flare: CGFloat { model.phase == .collapsed ? 0 : (model.isNotched ? 14 : 12) }
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
                    .fill(Color.black)
                    .shadow(color: .black.opacity(model.phase == .collapsed ? 0 : 0.5), radius: 14, x: 0, y: 6)
                content(size: size)
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .contentShape(IslandShape(flare: flare, bottom: bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.phase) { _, new in if new != .collapsed { shownPhase = new } }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let visible = model.contentVisible
        ZStack(alignment: .top) {
            if shownPhase == .popup {
                PopupView(flare: flare)
                    .transition(.opacity)
            } else {
                ExpandedView(flare: flare)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(nil, value: size)
        .clipShape(IslandShape(flare: flare, bottom: bottom))
        .opacity(visible ? 1 : 0)
        .blur(radius: visible ? 0 : Motion.contentInBlur)
        .scaleEffect(visible ? 1 : Motion.contentInScale, anchor: .top)
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
                    case .airdrop: AirDropView()
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
    let flare: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { tab in
                TabButton(tab: tab, selected: model.tab == tab && !model.showingDropTargets) {
                    env.island.setTab(tab)
                }
            }
            Spacer(minLength: model.isNotched ? model.collapsedSize.width + 16 : 8)
            if settings.agentHeaderChip, settings.agentsEnabled, let top = LimitFormat.highestPercent(agents.snapshots, now: Date()) {
                Text("\(Int(top.rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(severity: LimitSeverity(usedPercent: top)))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            HeaderIconButton(symbol: "gearshape.fill", help: "Settings") { AppDelegate.shared.showSettings() }
            if settings.batteryInHeader, devices.battery.hasBattery { BatteryChip(state: devices.battery) }
        }
        .padding(.horizontal, flare + 14)
        .padding(.top, model.isNotched ? 0 : 4)
    }

    private var tabs: [IslandTab] { settings.agentsEnabled ? IslandTab.allCases : [.home, .airdrop, .shelf] }
}

struct TabButton: View {
    let tab: IslandTab
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var symbol: String {
        switch tab {
        case .home: return "house.fill"
        case .airdrop: return "airplayaudio"
        case .shelf: return "tray.fill"
        case .agents: return "sparkles"
        }
    }
    var title: String {
        switch tab {
        case .home: return "Home"
        case .airdrop: return "AirDrop"
        case .shelf: return "Shelf"
        case .agents: return "AI agents"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: tab == .airdrop ? "dot.radiowaves.left.and.right" : symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(hover ? 0.85 : 0.5))
                .frame(width: 32, height: 24)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.18 : (hover ? 0.08 : 0))))
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
        VStack(spacing: 7) {
            Group {
                if let image = media.artwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack { Color.white.opacity(0.12); Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(.white.opacity(0.5)) }
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            VStack(spacing: 1) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            .opacity(textIn ? 1 : 0)
            .offset(y: textIn ? 0 : 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, model.isNotched ? model.collapsedSize.height + 6 : 14)
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
