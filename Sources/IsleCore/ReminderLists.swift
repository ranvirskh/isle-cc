import Foundation

public enum ReminderLists {
    /// The list a new reminder goes into: the one with the most open reminders. Ties go to `preferred` (the system
    /// default list) when it is among them, otherwise to the alphabetically first id so the choice is stable.
    /// Lists with no open reminders still count (as zero); nil only when there are no lists.
    public static func pick(counts: [String: Int], preferred: String?) -> String? {
        guard let top = counts.values.max() else { return nil }
        let best = counts.filter { $0.value == top }.map(\.key)
        if let preferred, best.contains(preferred) { return preferred }
        return best.sorted().first
    }
}
