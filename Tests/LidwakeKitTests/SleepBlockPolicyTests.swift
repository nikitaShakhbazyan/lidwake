import Foundation
import Testing
@testable import LidwakeKit

@Suite("SleepBlockPolicy")
struct SleepBlockPolicyTests {
    /// Models the real idle assertion: `acquire()` is idempotent (the production conformer guards
    /// on a non-zero assertion id), so a double-acquire holds exactly one assertion.
    final class FakeIdle: IdleSleepAsserting {
        private(set) var isHeld = false
        private(set) var acquireCount = 0
        private(set) var releaseCount = 0
        func acquire() {
            guard !isHeld else { return }
            acquireCount += 1
            isHeld = true
        }

        func release() {
            guard isHeld else { return }
            releaseCount += 1
            isHeld = false
        }
    }

    /// The machine-global flag: `isDisabled` reflects the last successful `setDisabled`.
    final class FakeClamshell: ClamshellSleepControlling {
        struct Boom: Error {}
        private(set) var calls: [Bool] = []
        private(set) var isDisabled: Bool
        /// When set, `setDisabled(throwOn)` throws.
        var throwOn: Bool?
        init(disabled: Bool = false) {
            isDisabled = disabled
        }

        func setDisabled(_ disabled: Bool) throws {
            if let throwOn, throwOn == disabled { throw Boom() }
            calls.append(disabled)
            isDisabled = disabled
        }
    }

    final class FakeStore: OriginalSleepSettingStoring {
        struct Full: Error {}
        var value: Bool?
        private(set) var saveCount = 0
        var failSave = false
        init(_ value: Bool? = nil) {
            self.value = value
        }

        func load() -> Bool? {
            value
        }

        func save(_ disabled: Bool) throws {
            if failSave { throw Full() }
            saveCount += 1
            value = disabled
        }

        func clear() {
            value = nil
        }
    }

    @Test
    func `init leaves the flag alone when nothing was saved`() {
        let clam = FakeClamshell(disabled: true)
        let policy = SleepBlockPolicy(idle: FakeIdle(), clamshell: clam, original: FakeStore())
        #expect(clam.calls.isEmpty)
        #expect(clam.isDisabled) // the owner's own disablesleep=1 survives
        #expect(!policy.isBlocked)
    }

    @Test(arguments: [false, true])
    func `init restores a value saved by a crashed instance`(saved: Bool) {
        let clam = FakeClamshell(disabled: true), store = FakeStore(saved)
        _ = SleepBlockPolicy(idle: FakeIdle(), clamshell: clam, original: store)
        #expect(clam.calls == [saved])
        #expect(store.value == nil)
    }

    @Test
    func `set(true) saves the original once, then disables clamshell sleep`() throws {
        let idle = FakeIdle(), clam = FakeClamshell(), store = FakeStore()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam, original: store)
        try policy.set(blocked: true)
        #expect(idle.acquireCount == 1)
        #expect(idle.isHeld)
        #expect(store.value == false)
        #expect(clam.calls == [true])
        #expect(policy.isBlocked)
    }

    @Test(arguments: [false, true])
    func `set(false) puts back the value the Mac had before`(before: Bool) throws {
        let idle = FakeIdle(), clam = FakeClamshell(disabled: before), store = FakeStore()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam, original: store)
        try policy.set(blocked: true)
        try policy.set(blocked: false)
        #expect(idle.releaseCount == 1)
        #expect(!idle.isHeld)
        #expect(clam.isDisabled == before)
        #expect(store.value == nil)
        #expect(!policy.isBlocked)
    }

    @Test
    func `repeated set(true) re-asserts clamshell but keeps the first saved value`() throws {
        let idle = FakeIdle(), clam = FakeClamshell(), store = FakeStore()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam, original: store)
        try policy.set(blocked: true)
        try policy.set(blocked: true)
        #expect(idle.acquireCount == 1) // idempotent acquire
        #expect(clam.calls == [true, true]) // clamshell re-asserted (wake recovery)
        #expect(store.saveCount == 1)
        #expect(store.value == false) // not overwritten by our own block
    }

    @Test
    func `a clamshell failure while blocking propagates but keeps the restore point`() {
        let idle = FakeIdle(), clam = FakeClamshell(), store = FakeStore()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam, original: store)
        clam.throwOn = true
        #expect(throws: FakeClamshell.Boom.self) {
            try policy.set(blocked: true)
        }
        #expect(!policy.isBlocked) // block did not complete
        #expect(idle.isHeld) // but the idle assertion was already acquired (matches original)
        #expect(store.value == false)
    }

    @Test
    func `a failure to save the original refuses to block`() {
        let clam = FakeClamshell(), store = FakeStore()
        store.failSave = true
        let policy = SleepBlockPolicy(idle: FakeIdle(), clamshell: clam, original: store)
        #expect(throws: FakeStore.Full.self) {
            try policy.set(blocked: true)
        }
        #expect(clam.calls.isEmpty) // never disabled sleep without a way back
    }

    @Test
    func `a clamshell failure while unblocking is swallowed and retried later`() throws {
        let idle = FakeIdle(), clam = FakeClamshell(), store = FakeStore()
        let policy = SleepBlockPolicy(idle: idle, clamshell: clam, original: store)
        try policy.set(blocked: true)
        clam.throwOn = false
        try policy.set(blocked: false) // must not throw
        #expect(!policy.isBlocked)
        #expect(!idle.isHeld)
        #expect(store.value == false) // kept for the next attempt
        clam.throwOn = nil
        _ = SleepBlockPolicy(idle: FakeIdle(), clamshell: clam, original: store)
        #expect(!clam.isDisabled)
        #expect(store.value == nil)
    }

    @Test
    func `unblocking without a saved value clears the flag only if we blocked`() throws {
        let clam = FakeClamshell(), store = FakeStore()
        let policy = SleepBlockPolicy(idle: FakeIdle(), clamshell: clam, original: store)
        try policy.set(blocked: false)
        #expect(clam.calls.isEmpty) // never blocked: nothing to undo

        try policy.set(blocked: true)
        store.clear() // the restore point went missing
        try policy.set(blocked: false)
        #expect(!clam.isDisabled) // fail safe: sleep is allowed again
    }
}
