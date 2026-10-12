import Foundation
import IsleCore

/// Runs the shell commands the user saved. Nothing runs unless the user clicks it; output is shown in the tab.
@MainActor
final class ScriptsController: ObservableObject {
    @Published private(set) var items: [ScriptItem] = []
    @Published private(set) var runningID: UUID?
    @Published private(set) var lastOutput: (name: String, text: String, ok: Bool)?
    private let settings = Settings.shared
    private var observer: NSObjectProtocol?
    private var process: Process?
    static let timeout: TimeInterval = 30

    init() {
        load()
        observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if (n.object as? String) == SettingsKey.scripts { self?.load() } }
        }
    }

    private func load() { items = ScriptItem.decode(settings.scripts) }

    func save(_ new: [ScriptItem]) { settings.scripts = ScriptItem.encode(new) }

    func run(_ item: ScriptItem) {
        guard item.isRunnable, runningID == nil else { return }
        runningID = item.id
        lastOutput = (item.displayName, "Running…", true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", item.command]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        process = p
        let name = item.displayName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do { try p.run() } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(name, "Could not start: \(error.localizedDescription)", false) } }
                return
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let text = String(decoding: data, as: UTF8.self)
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(name, text.isEmpty ? (ok ? "Done (no output)" : "Failed (exit \(p.terminationStatus))") : text, ok) } }
        }
    }

    private func finish(_ name: String, _ text: String, _ ok: Bool) {
        lastOutput = (name, ScriptOutput.trimmed(text), ok)
        runningID = nil; process = nil
    }

    func stop() { process?.terminate() }
}
