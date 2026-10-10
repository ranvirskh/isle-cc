import SwiftUI
import IsleCore

struct StatsView: View {
    @EnvironmentObject var stats: StatsController

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            card("CPU", symbol: "cpu") {
                Text(stats.cpu.map(StatsFormat.percent) ?? "–").font(.system(size: 22, weight: .bold).monospacedDigit())
                Sparkline(values: stats.cpuHistory).frame(height: 28)
            }
            card("Memory", symbol: "memorychip") {
                Text(stats.memory.map(StatsFormat.percent) ?? "–").font(.system(size: 22, weight: .bold).monospacedDigit())
                bar(stats.memory ?? 0)
                Text("\(StatsFormat.bytes(stats.memoryUsed)) of \(StatsFormat.bytes(stats.memoryTotal))").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            card("Network", symbol: "arrow.up.arrow.down") {
                Label(StatsFormat.rate(stats.down), systemImage: "arrow.down").font(.system(size: 13, weight: .semibold).monospacedDigit())
                Label(StatsFormat.rate(stats.up), systemImage: "arrow.up").font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            card("Disk", symbol: "internaldrive") {
                let used = stats.diskTotal > stats.diskFree ? Double(stats.diskTotal - stats.diskFree) / Double(max(1, stats.diskTotal)) : 0
                Text(StatsFormat.percent(used)).font(.system(size: 22, weight: .bold).monospacedDigit())
                bar(used)
                Text("\(StatsFormat.bytes(stats.diskFree)) free").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .foregroundStyle(.white)
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }

    private func card<C: View>(_ title: String, symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func bar(_ f: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(Color.white).frame(width: g.size.width * min(1, max(0, f)))
            }
        }
        .frame(height: 5)
    }
}

private struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            Path { p in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(max(1, 39))
                    let y = g.size.height * (1 - CGFloat(min(1, max(0, v))))
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
