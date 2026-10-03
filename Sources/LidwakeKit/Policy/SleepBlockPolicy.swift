import Foundation

/// Holds and releases the idle-system-sleep assertion — the standard, reference-counted
/// `IOPMAssertion` (`kIOPMAssertPreventUserIdleSystemSleep`). Stateful: it tracks whether the
/// assertion is currently held, so a repeated `acquire()` is a no-op.
public protocol IdleSleepAsserting: AnyObject {
    var isHeld: Bool { get }
    func acquire()
    func release()
}

/// Applies and clears the global clamshell-sleep block — the `SleepDisabled` power setting
/// (`pmset -a disablesleep`). Throwing because the underlying mechanism can fail.
public protocol ClamshellSleepControlling: AnyObject {
    /// The flag as the kernel enforces it right now.
    var isDisabled: Bool { get }
    func setDisabled(_ disabled: Bool) throws
}

/// Remembers the `SleepDisabled` value the Mac had before the first block. It must outlive the
/// process (and a reboot), because so does the flag.
public protocol OriginalSleepSettingStoring: AnyObject {
    func load() -> Bool?
    func save(_ disabled: Bool) throws
    func clear()
}

/// The compose / idempotence / crash-recovery logic for keeping the Mac awake, independent of the
/// concrete IOKit and `pmset` mechanisms (which live behind `IdleSleepAsserting` and
/// `ClamshellSleepControlling`). This is the policy worth testing; the conformers are the
/// untestable API boundary.
///
/// Before the first block it saves the current `SleepDisabled` value, and every release puts
/// *that* value back instead of forcing `0`: a Mac its owner set up never to sleep stays that way.
/// On construction it restores a value saved by a prior — possibly crashed — instance, since
/// `disablesleep` persists across process death and reboot. With nothing saved it leaves the flag
/// alone.
///
/// `set(blocked:)` is deliberately **not** short-circuited on an unchanged value: a repeated
/// `set(true)` re-asserts the clamshell block, which the daemon relies on to recover after a
/// sleep/wake transition. Every step is idempotent. An error applying the block propagates (the
/// XPC layer surfaces it); an error *restoring* on unblock is swallowed and the saved value kept,
/// so the next release or launch retries.
public final class SleepBlockPolicy {
    public private(set) var isBlocked = false
    private let idle: IdleSleepAsserting
    private let clamshell: ClamshellSleepControlling
    private let original: OriginalSleepSettingStoring

    public init(idle: IdleSleepAsserting, clamshell: ClamshellSleepControlling, original: OriginalSleepSettingStoring) {
        self.idle = idle
        self.clamshell = clamshell
        self.original = original
        restoreOriginal()
    }

    public func set(blocked: Bool) throws {
        if blocked {
            // Keep the idle assertion even if the clamshell block throws: partial protection (idle
            // sleep still blocked) serves the app's purpose better than rolling back to none, and the
            // daemon re-issues `set(true)` on its next reconcile — every step is idempotent, so the
            // clamshell block is retried while the idle assertion stays continuously held. The error
            // propagates so the daemon knows the block isn't yet complete.
            idle.acquire()
            if original.load() == nil {
                try original.save(clamshell.isDisabled)
            }
            try clamshell.setDisabled(true)
        } else {
            idle.release()
            if !restoreOriginal(), isBlocked {
                // We blocked but lost the saved value: leaving sleep disabled forever is the worse
                // failure, so fall back to clearing it.
                try? clamshell.setDisabled(false)
            }
        }
        isBlocked = blocked
    }

    /// Puts back the saved value, if any. Returns whether there was one.
    @discardableResult
    private func restoreOriginal() -> Bool {
        guard let saved = original.load() else { return false }
        if (try? clamshell.setDisabled(saved)) != nil {
            original.clear()
        }
        return true
    }
}
