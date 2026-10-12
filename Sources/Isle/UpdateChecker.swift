import AppKit
import IsleCore

/// Looks for a newer Isle release on GitHub. Nothing is sent until the user turns this on or presses "Check now";
/// the request is one GET to the public releases API (no account, no identifiers). Updating means opening the release page.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable { case idle, checking, upToDate, available(ReleaseInfo), failed }
    @Published private(set) var status: Status = .idle
    static let endpoint = URL(string: "https://api.github.com/repos/ranvirskh/isle-cc/releases/latest")!

    private let settings = Settings.shared
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if (n.object as? String) == SettingsKey.autoUpdateCheck { self?.sync() } }
        }
        sync()
    }

    private func sync() {
        timer?.invalidate(); timer = nil
        guard settings.autoUpdateCheck else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        guard status != .checking else { return }
        status = .checking
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Isle/\(IsleInfo.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let info = ok ? data.flatMap(ReleaseInfo.parse) : nil
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                if let info {
                    self.status = AppVersion.isNewer(info.version, than: IsleInfo.version) ? .available(info) : .upToDate
                } else { self.status = ok ? .upToDate : .failed }
            } }
        }.resume()
    }

    func openRelease(_ info: ReleaseInfo) { NSWorkspace.shared.open(info.pageURL) }
}
