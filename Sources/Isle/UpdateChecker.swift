import AppKit
import IsleCore

/// Looks for a newer Isle release on GitHub. Nothing is sent until the user turns this on or presses "Check now";
/// the request is one GET to the public releases API (no account, no identifiers). "Install" downloads the release zip and its
/// signature, installs only if the signature verifies against the developer's public key, and relaunches.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable { case idle, checking, upToDate, available(ReleaseInfo), failed, installing, installFailed(String) }
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
        timer?.tolerance = 3600   // a daily check needs no precision; lets macOS batch the wake-up
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

    /// Downloads, verifies and installs the release over the running copy, then relaunches. Nothing is replaced unless the
    /// signature checks out, the bundle is Isle's, and its code signature is intact.
    func install(_ info: ReleaseInfo) {
        guard let zipURL = info.zipURL, let sigURL = info.signatureURL else { NSWorkspace.shared.open(info.pageURL); return }
        guard status != .installing else { return }
        status = .installing
        let target = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                await Self.download(zipURL: zipURL, sigURL: sigURL, replacing: target, bundleID: bundleID)
            }.value
            if let result { self.status = .installFailed(result); return }
            Log.write("update: installed \(info.version); relaunching")
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", target.path]
            try? open.run()
            NSApp.terminate(nil)
        }
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let host = request.url?.host?.lowercased() ?? ""
            let ok = request.url?.scheme == "https" && (host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com"))
            completionHandler(ok ? request : nil)
        }
    }

    /// Returns nil on success, or a short reason.
    nonisolated private static func download(zipURL: URL, sigURL: URL, replacing target: URL, bundleID: String?) async -> String? {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else { return "Isle's folder isn't writable; update from the release page instead" }
        let work = fm.temporaryDirectory.appendingPathComponent("IsleUpdate-\(UUID().uuidString)")
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch { return "Could not create a temporary folder" }
        defer { try? fm.removeItem(at: work) }
        let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)
        guard let (zipFile, zr) = try? await session.download(from: zipURL), (zr as? HTTPURLResponse)?.statusCode == 200,
              let (sig, sr) = try? await session.data(from: sigURL), (sr as? HTTPURLResponse)?.statusCode == 200,
              let zipData = try? Data(contentsOf: zipFile, options: .mappedIfSafe) else { return "Download failed" }
        guard UpdateSignature.isValid(signature: sig, for: zipData) else { return "The download's signature didn't check out, so it was not installed" }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipFile.path, work.path]
        guard (try? unzip.run()) != nil else { return "Could not unpack the update" }
        unzip.waitUntilExit()
        let newApp = work.appendingPathComponent("Isle.app")
        guard unzip.terminationStatus == 0, let bundle = Bundle(url: newApp), bundle.bundleIdentifier == bundleID else { return "The update isn't a valid Isle" }
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", newApp.path]
        verify.standardOutput = FileHandle.nullDevice; verify.standardError = FileHandle.nullDevice
        guard (try? verify.run()) != nil else { return "Could not check the update" }
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { return "The update's code signature is damaged" }

        // Swap, keeping the old copy aside until the new one is in place.
        let backup = work.appendingPathComponent("previous.app")
        do {
            try fm.moveItem(at: target, to: backup)
            do { try fm.copyItem(at: newApp, to: target) } catch {
                try? fm.moveItem(at: backup, to: target)
                return "Could not install the update"
            }
        } catch { return "Could not replace the running copy" }
        return nil
    }
}
