import SwiftUI
import IsleCore

struct ScriptsView: View {
    @EnvironmentObject var scripts: ScriptsController

    var body: some View {
        Group {
            if scripts.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
                    Text("No scripts yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    Text("Add shell commands in Settings > Scripts. They run only when you click them.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ScrollView {
                        VStack(spacing: 4) { ForEach(scripts.items) { row($0) } }
                    }
                    .frame(width: 230)
                    outputPane
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func row(_ item: ScriptItem) -> some View {
        Button { scripts.run(item) } label: {
            HStack(spacing: 8) {
                Image(systemName: scripts.runningID == item.id ? "hourglass" : "play.fill").font(.system(size: 10))
                Text(item.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!item.isRunnable || scripts.runningID != nil)
    }

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let out = scripts.lastOutput {
                HStack {
                    Text(out.name).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if scripts.runningID != nil { Button("Stop") { scripts.stop() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)) }
                }
                ScrollView { Text(out.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(out.ok ? .white.opacity(0.85) : Color.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            } else {
                Text("Click a script to run it").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
    }
}
