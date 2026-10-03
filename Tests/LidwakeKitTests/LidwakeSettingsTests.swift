import Foundation
import Testing
@testable import LidwakeKit

@Suite("LidwakeSettings")
struct LidwakeSettingsTests {
    @Test
    func `defaults are sane`() {
        let s = LidwakeSettings()
        #expect(s.soundOnLidClose == true)
        #expect(s.thermalCutoutEnabled == true)
        #expect(s.thermalThresholdCelsius == 80.0)
        #expect(s.idleReleaseEnabled == true)
        #expect(s.idleReleaseSeconds == 90)
        #expect(s.processSniffingEnabled == true)
        #expect(s.autoAcquireForKnownAgents == false)
        #expect(s.lockOnLidClose == true)
        // The grace default is what makes answering a waiting Claude Code question from a phone
        // possible (the Mac must stay reachable) while still letting an unanswered one sleep.
        #expect(s.agentWaitingPolicy == .grace)
        #expect(s.agentWaitingGraceMinutes == 10)
        // The background-shell keep-awake is opt-in: it holds the Mac awake for a `run_in_background`
        // command with no completion hook, so it must be OFF unless the user turns it on.
        #expect(s.keepAwakeForBackgroundBash == false)
        // The pre-sleep cue defaults ON with each cause on its own synthesized cue — it only
        // fires with the lid closed (the user is away), which is exactly when it's useful.
        #expect(s.sleepSoundEnabled == true)
        #expect(s.sleepChimeWorkComplete == "default")
        #expect(s.sleepChimeHoldExpired == "default")
        #expect(s.sleepChimeSafetyCutout == "default")
        #expect(s.sleepChimeUserAction == "default")
    }

    @Test
    func `codable roundtrip preserves all fields`() throws {
        var original = LidwakeSettings()
        original.soundOnLidClose = false
        original.soundVolume = 0.25
        original.thermalThresholdCelsius = 72.5
        original.idleReleaseSeconds = 120
        original.autoAcquireForKnownAgents = true
        original.keepAwakeForBackgroundBash = true
        original.chimeName = "doot"
        original.sleepSoundEnabled = false
        original.sleepChimeWorkComplete = "Ping"
        original.sleepChimeHoldExpired = "off"
        original.sleepChimeSafetyCutout = "Submarine"
        original.sleepChimeUserAction = "Tink"
        original.lockOnLidClose = false
        original.agentWaitingPolicy = .sleep
        original.agentWaitingGraceMinutes = 25

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LidwakeSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func `save and load roundtrip via disk`() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var settings = LidwakeSettings()
        settings.thermalThresholdCelsius = 85
        settings.idleReleaseSeconds = 120

        try settings.save(to: tempURL)
        let loaded = LidwakeSettings.load(from: tempURL)
        #expect(loaded == settings)
    }

    @Test
    func `load from missing file returns defaults`() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let loaded = LidwakeSettings.load(from: missing)
        #expect(loaded == LidwakeSettings())
    }

    /// Regression: a config written by an older build (missing a newer field) must not
    /// throw and reset *all* settings. Each absent field should fall back to its default
    /// while user-set fields are preserved.
    @Test
    func `missing new field falls back without losing others`() throws {
        let json = Data(#"""
        {"soundOnLidClose": false, "soundVolume": 0.25, "chimeName": "Tink",
         "thermalCutoutEnabled": false, "thermalThresholdCelsius": 72.5,
         "idleReleaseEnabled": false, "idleReleaseSeconds": 150,
         "processSniffingEnabled": false, "autoAcquireForKnownAgents": true,
         "lockOnLidClose": false}
        """#.utf8)
        let s = try JSONDecoder().decode(LidwakeSettings.self, from: json)
        #expect(s.idleReleaseSeconds == 150)
        #expect(s.thermalThresholdCelsius == 72.5)
        #expect(s.lockOnLidClose == false)
        #expect(s.chimeName == "Tink")
        #expect(s.requireACPower == false) // absent → default, not a decode failure
        #expect(s.keepAwakeForBackgroundBash == false) // absent → opt-in default (off)
        // Pre-sleep cue fields absent (config from a pre-1.5 build) → defaults, others intact.
        #expect(s.sleepSoundEnabled == true)
        #expect(s.sleepChimeWorkComplete == "default")
    }

    @Test
    func `empty object decodes to all defaults`() throws {
        let s = try JSONDecoder().decode(LidwakeSettings.self, from: Data("{}".utf8))
        #expect(s == LidwakeSettings())
    }

    @Test
    func `unknown extra keys are ignored`() throws {
        let s = try JSONDecoder().decode(
            LidwakeSettings.self,
            from: Data(#"{"idleReleaseSeconds": 70, "futureSetting": 123}"#.utf8),
        )
        #expect(s.idleReleaseSeconds == 70)
    }

    @Test
    func `load from disk missing new field preserves user values`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"idleReleaseSeconds": 220, "thermalThresholdCelsius": 90}"#.utf8).write(to: url)
        let loaded = LidwakeSettings.load(from: url)
        #expect(loaded.idleReleaseSeconds == 220)
        #expect(loaded.thermalThresholdCelsius == 90)
        #expect(loaded.safetyCutoutsWithLidOpen == true)
    }

    /// A config from a build that only knew `idleReleaseMinutes` migrates to the seconds field (×60).
    @Test
    func `legacy minutes migrates to seconds`() throws {
        let s = try JSONDecoder().decode(
            LidwakeSettings.self,
            from: Data(#"{"idleReleaseMinutes": 3}"#.utf8),
        )
        #expect(s.idleReleaseSeconds == 180)
        // An explicit seconds field wins over a stale minutes field if both somehow appear.
        let both = try JSONDecoder().decode(
            LidwakeSettings.self,
            from: Data(#"{"idleReleaseMinutes": 3, "idleReleaseSeconds": 45}"#.utf8),
        )
        #expect(both.idleReleaseSeconds == 45)
    }

    @Test
    func `safety scope defaults: cutouts guard an open lid, AC-only is off`() throws {
        let s = LidwakeSettings()
        #expect(s.safetyCutoutsWithLidOpen)
        #expect(!s.requireACPower)
        let decoded = try JSONDecoder().decode(LidwakeSettings.self, from: Data(#"{"requireACPower": true, "safetyCutoutsWithLidOpen": false}"#.utf8))
        #expect(decoded.requireACPower)
        #expect(!decoded.safetyCutoutsWithLidOpen)
    }
}
