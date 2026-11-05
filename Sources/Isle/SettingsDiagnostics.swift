import AppKit
import SwiftUI

/// Shown under the usage setting when Claude Code has no sign-in token, which is why the usage chip would be missing.
struct SignInHint: View {
    @ObservedObject var usage: ClaudeUsageController

    var body: some View {
        if usage.needsSignIn {
            Label("Claude Code isn't signed in, so there is no usage to show. Open Claude Code and run /login.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

/// The last lines of Isle's own log, so a problem can be looked at (or copied into a bug report) without hunting for the file.
/// The log never holds prompt text or media content.
struct DiagnosticsRow: View {
    @State private var lines: [String] = []

    var body: some View {
        DisclosureGroup("Recent log") {
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            HStack {
                Button("Refresh") { load() }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let handle = try? FileHandle(forReadingFrom: Log.url) else { lines = ["No log yet."]; return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        lines = Array(text.split(separator: "\n").suffix(40).map(String.init))
    }
}
