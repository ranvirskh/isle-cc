import SwiftUI

/// First-run walkthrough. Shown once; reopen it from the menu bar item.
struct OnboardingView: View {
    let done: () -> Void
    @State private var page = 0

    private let pages: [(symbol: String, title: String, text: String)] = [
        ("macwindow.on.rectangle", "Meet Isle", "Isle lives in your notch. Move the pointer to the top center of the screen and it opens; move away and it closes. Click the menu bar icon for Settings."),
        ("switch.2", "Turn on what you want", "Home and Shelf are on. Tools, Clipboard, System, Reminders, Mirror, Scripts, AI agents, the volume and brightness indicator and global shortcuts are all optional. Switch them on in Settings under Look."),
        ("lock.shield", "Permissions, only when needed", "Isle asks macOS for Calendar, Reminders, Camera or Accessibility only when you turn on a feature that needs it. Nothing is sent anywhere unless a setting says so."),
    ]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: pages[page].symbol).font(.system(size: 44)).foregroundStyle(.tint).padding(.top, 8)
            Text(pages[page].title).font(.title2.bold())
            Text(pages[page].text).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
            Spacer(minLength: 0)
            HStack {
                HStack(spacing: 6) { ForEach(pages.indices, id: \.self) { Circle().fill($0 == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7) } }
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                if page < pages.count - 1 { Button("Next") { page += 1 }.keyboardShortcut(.defaultAction) }
                else { Button("Get started", action: done).keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24)
        .frame(width: 440, height: 300)
    }
}
