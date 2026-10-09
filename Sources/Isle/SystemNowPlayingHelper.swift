import Foundation
import IsleCore

/// Runs Isle's own Now Playing helper (Helper/isle_nowplaying.m) inside /usr/bin/perl.
///
/// Why perl: since macOS 15.4 the private MediaRemote framework only answers Apple-signed processes, and
/// /usr/bin/perl is one. The helper dylib is loaded into perl with DynaLoader and talks MediaRemote itself.
/// If anything about this is unavailable the helper reports `supported:false` (or never starts) and the
/// controller falls back to Spotify / Music scripting. Nothing here uses the network.
final class SystemNowPlayingHelper {
    var onSnapshot: ((SystemNowPlayingSnapshot) -> Void)?
    /// Called on the main queue when the helper cannot work, with a human-readable reason.
    var onUnsupported: ((String) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 1
    private var stopped = true
    private var gotAnyLine = false

    static var resourcePaths: (launcher: String, dylib: String)? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let launcher = res.appendingPathComponent("launcher.pl").path
        let dylib = res.appendingPathComponent("libisle_nowplaying.dylib").path
        let fm = FileManager.default
        guard fm.fileExists(atPath: launcher), fm.fileExists(atPath: dylib) else { return nil }
        return (launcher, dylib)
    }

    func start() {
        guard stopped else { return }
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdin = nil
    }

    func send(_ command: String) {
        guard let stdin, let data = (command + "\n").data(using: .utf8) else { return }
        try? stdin.write(contentsOf: data)
    }

    private func launch() {
        guard let paths = Self.resourcePaths else {
            DispatchQueue.main.async { self.onUnsupported?("Helper files are missing from the app bundle") }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.launcher, paths.dylib]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        buffer = Data()
        gotAnyLine = false
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.process === proc else { return }
                Log.write("nowplaying helper exited (\(proc.terminationStatus)); restarting in \(self.restartDelay)s")
                if !self.gotAnyLine, self.restartDelay >= 8 {
                    self.onUnsupported?("The Now Playing helper keeps failing to start")
                    return
                }
                let delay = self.restartDelay
                self.restartDelay = min(self.restartDelay * 2, 30)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if !self.stopped { self.launch() } }
            }
        }
        do {
            try p.run()
            process = p
            stdin = inp.fileHandleForWriting
        } catch {
            Log.write("nowplaying helper failed to run: \(error.localizedDescription)")
            onUnsupported?("Could not start the Now Playing helper")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8), let snap = SystemNowPlayingParser.parse(line: line) else { continue }
            gotAnyLine = true
            restartDelay = 1
            if !snap.supported {
                onUnsupported?(snap.error ?? "Now Playing is not available on this macOS version")
            } else {
                onSnapshot?(snap)
            }
        }
    }
}
