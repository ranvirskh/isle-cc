import AppKit
import Foundation
import IsleCore

/// Spotify / Apple Music through AppleScript (needs the Automation permission). Never launches the app:
/// every call first checks that it is already running.
final class PlayerScripting {
    let bundleID: String
    private let queue = DispatchQueue(label: "isle.applescript", qos: .userInitiated)

    init(bundleID: String) { self.bundleID = bundleID }

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    private var isSpotify: Bool { bundleID == KnownBundle.spotify }

    private var statusScript: String {
        let sep = "(character id 31)"
        if isSpotify {
            return """
            tell application id "\(bundleID)"
              set st to (player state as string)
              if st is "stopped" then return "state=stopped"
              set t to current track
              return "state=" & st & \(sep) & "title=" & (name of t) & \(sep) & "artist=" & (artist of t) & \(sep) & "album=" & (album of t) & \(sep) & "duration=" & (duration of t) & \(sep) & "durationUnit=ms" & \(sep) & "position=" & (player position) & \(sep) & "shuffle=" & (shuffling) & \(sep) & "id=" & (id of t)
            end tell
            """
        }
        return """
        tell application id "\(bundleID)"
          set st to (player state as string)
          if st is "stopped" then return "state=stopped"
          set t to current track
          return "state=" & st & \(sep) & "title=" & (name of t) & \(sep) & "artist=" & (artist of t) & \(sep) & "album=" & (album of t) & \(sep) & "duration=" & (duration of t) & \(sep) & "position=" & (player position) & \(sep) & "shuffle=" & (shuffle enabled)
        end tell
        """
    }

    enum QueryResult {
        case snapshot(PlayerSnapshot)
        case notRunning
        case denied
        case failed
    }

    func query(_ completion: @escaping (QueryResult) -> Void) {
        guard isRunning else { completion(.notRunning); return }
        let script = statusScript
        let id = bundleID
        queue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
            var out: QueryResult = .failed
            if let err {
                let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
                out = (code == -1743) ? .denied : .failed   // -1743: not authorized to send Apple events
            } else if let raw = result?.stringValue, let snap = ScriptStatusParser.parse(raw, bundleID: id) {
                out = .snapshot(snap)
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    func artworkData(_ completion: @escaping (Data?) -> Void) {
        // Spotify exposes only a URL, which would need a network fetch; its artwork comes from the system helper.
        guard !isSpotify, isRunning else { completion(nil); return }
        let script = """
        tell application id "\(bundleID)"
          try
            return data of artwork 1 of current track
          end try
        end tell
        """
        queue.async {
            var err: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
            let data = err == nil ? result?.data : nil
            DispatchQueue.main.async { completion(data) }
        }
    }

    enum Command { case playPause, next, previous, shuffleToggle, seek(Double) }

    func perform(_ command: Command) {
        guard isRunning else { return }
        let body: String
        switch command {
        case .playPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .shuffleToggle: body = isSpotify ? "set shuffling to not shuffling" : "set shuffle enabled to not shuffle enabled"
        case .seek(let s): body = "set player position to \(max(0, s))"
        }
        let script = "tell application id \"\(bundleID)\" to \(body)"
        queue.async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let err { Log.write("applescript \(body): \(err[NSAppleScript.errorNumber] ?? "?")") }
        }
    }
}
