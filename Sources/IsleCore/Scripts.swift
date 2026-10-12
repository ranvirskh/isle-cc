import Foundation

/// A shell command the user saved to run from the Scripts tab.
public struct ScriptItem: Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var command: String
    public init(id: UUID = UUID(), name: String, command: String) { self.id = id; self.name = name; self.command = command }

    public var isRunnable: Bool { !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? String(command.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)) : n
    }

    // Stored in UserDefaults as [name, command] pairs.
    public static func decode(_ raw: [[String]]) -> [ScriptItem] {
        raw.compactMap { $0.count == 2 ? ScriptItem(name: $0[0], command: $0[1]) : nil }
    }
    public static func encode(_ items: [ScriptItem]) -> [[String]] { items.map { [$0.name, $0.command] } }
}

public enum ScriptOutput {
    public static let maxCharacters = 4_000

    /// Keeps the end of long output (the part that usually matters) and strips trailing whitespace.
    public static func trimmed(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxCharacters else { return t }
        return "…" + t.suffix(maxCharacters)
    }
}
