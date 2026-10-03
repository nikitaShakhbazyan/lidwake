import Foundation

/// What the daemon persists across restarts: the live assertions plus the user-facing paused
/// bit. Persisting `paused` keeps "lidwake is off" true across a daemon relaunch or reboot —
/// the user quit the app expecting their Mac to sleep normally, and a fresh daemon coming up
/// unpaused would let agent hooks re-pin it with no menu bar icon showing why.
public struct PersistedDaemonState: Codable, Sendable {
    public var assertions: [Assertion]
    public var paused: Bool
    /// The off timer survives a daemon restart; a deadline that passed meanwhile pauses at once.
    public var offAt: Date?

    public init(assertions: [Assertion], paused: Bool, offAt: Date? = nil) {
        self.assertions = assertions
        self.paused = paused
        self.offAt = offAt
    }

    /// Decodes the envelope, falling back to the bare `[Assertion]` array older builds wrote.
    public static func decode(from data: Data) -> PersistedDaemonState? {
        if let state = try? JSONDecoder().decode(PersistedDaemonState.self, from: data) {
            return state
        }
        if let assertions = try? JSONDecoder().decode([Assertion].self, from: data) {
            return PersistedDaemonState(assertions: assertions, paused: false)
        }
        return nil
    }
}
