import Foundation

/// The "turn off in an hour" timer: when it is due, the daemon pauses itself, so every hold is
/// released and the Mac sleeps normally until someone turns lidwake back on.
public enum OffTimer {
    public static let minimum: TimeInterval = 60
    public static let maximum: TimeInterval = 24 * 3_600

    /// The deadline for a request of `seconds` from `now`, clamped to 1 minute … 24 hours; nil
    /// (cancel) for a missing, zero or negative request.
    public static func deadline(after seconds: TimeInterval?, now: Date = Date()) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return now.addingTimeInterval(min(max(seconds, minimum), maximum))
    }

    /// What the dashboard's timer key steps through.
    public static let presets: [TimeInterval] = [15, 30, 60, 120, 240].map { $0 * 60 }

    /// Off → 15m → 30m → 1h → 2h → 4h → off, starting from whatever is left now; nil means off.
    public static func nextPreset(after left: TimeInterval?) -> TimeInterval? {
        guard let left else { return presets[0] }
        return presets.first { $0 > left + 30 }
    }

    public static func isDue(_ deadline: Date?, now: Date = Date()) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }
}
