import Foundation

/// What happens to an agent's hold while that agent is waiting for the user — a question, a plan
/// approval, a permission prompt. The agent has declared it is not working, but the person may be
/// answering from a phone (Claude Code Remote Control), which needs the Mac awake to receive the
/// answer.
public enum AgentWaitingPolicy: String, Codable, Sendable, CaseIterable {
    /// Keep the Mac awake for as long as the agent waits.
    case keepAwake
    /// Keep it awake for a grace window, then let it sleep. Answering within the window — at the
    /// keyboard or from a phone — resumes seamlessly; walking away lets the Mac sleep.
    case grace
    /// Let the Mac sleep as soon as the agent starts waiting.
    case sleep
}

public struct LidwakeSettings: Codable, Sendable, Equatable {
    public var soundOnLidClose: Bool = true
    public var soundVolume: Float = 0.5
    public var chimeName: String = "default"

    /// Play a cue the moment before the closed-lid Mac goes back to sleep — when the last
    /// assertion releases and the sleep block is about to clear. On by default: the cue only
    /// fires with the lid closed (the user is away and can't see the screen), which is exactly
    /// when it's useful. Per-cause sounds below; `"default"` is the synthesized cue for that
    /// cause, `"off"` silences just that cause, anything else names a macOS system sound.
    public var sleepSoundEnabled: Bool = true
    /// Sound when the agents finished (end hook, process exit, or CPU-idle release).
    public var sleepChimeWorkComplete: String = "default"
    /// Sound when a hold's TTL ran out — the work may not be done.
    public var sleepChimeHoldExpired: String = "default"
    /// Sound when a thermal/low-battery cutout stopped the work mid-task.
    public var sleepChimeSafetyCutout: String = "default"
    /// Sound when the user released it themselves (force release or pause). Only audible with
    /// the lid closed — i.e. a *remote* release, typically over SSH — where it confirms the
    /// command took and the Mac is going to sleep.
    public var sleepChimeUserAction: String = "default"

    /// Lock the screen when the lid closes while an agent is active, so the awake machine is
    /// still secured. Issues an explicit lock (overrides idle-lock-prevention from other apps).
    public var lockOnLidClose: Bool = true

    public var thermalCutoutEnabled: Bool = true
    public var thermalThresholdCelsius: Double = 80.0

    /// Force-release all assertions when, on battery with the lid closed, the charge falls to or
    /// below this percentage — so a kept-awake Mac can sleep normally instead of draining to a
    /// hard shutdown in a bag (the battery sibling of the thermal cutout).
    public var lowBatteryCutoutEnabled: Bool = true
    public var lowBatteryThresholdPercent: Int = 20

    /// Run the thermal and low-battery cutouts with the lid open too. While `disablesleep` is set
    /// the kernel refuses even its own emergency sleep (overheating; low battery on Macs that sleep
    /// rather than shut down) whatever the lid does, so a Mac left open on a desk overnight has no
    /// other safety net.
    public var safetyCutoutsWithLidOpen: Bool = true

    /// Keep the Mac awake on AC power only: unplugging it releases every hold, and acquires are
    /// refused until the charger is back.
    public var requireACPower: Bool = false

    /// Policy for a Claude Code session that has stopped mid-turn to wait for the user (detected
    /// via its session status file — see `ClaudeSessionStatus`). Grace by default: long enough to
    /// answer from a phone, bounded so an unanswered question can't pin the Mac awake for hours.
    public var agentWaitingPolicy: AgentWaitingPolicy = .grace
    /// Length of the grace window, in minutes, when `agentWaitingPolicy` is `.grace`.
    public var agentWaitingGraceMinutes: Int = 10

    public var idleReleaseEnabled: Bool = true
    /// Release a hook/sniffed hold once the agent's process tree has been CPU-idle this long. This is
    /// what catches an Esc-interrupt (no `Stop` hook fires), so it's tens of seconds, not minutes.
    public var idleReleaseSeconds: Int = 90

    public var processSniffingEnabled: Bool = true
    public var autoAcquireForKnownAgents: Bool = false

    /// Allow agents to place explicit, reasoned "keep awake" holds (via `lidwake hold` or the
    /// MCP server). When false, hold requests are rejected, so only a live agent session — via its
    /// editor hooks — can keep the Mac awake.
    public var agentHoldsEnabled: Bool = true
    /// Hard cap, in hours, on how long a single agent hold can last. Any longer request is clamped
    /// down to this — a forgetful agent can never pin the Mac awake indefinitely.
    public var manualHoldMaxHours: Double = 4

    /// Opt-in: keep the Mac awake while a shell command an agent launched with `run_in_background`
    /// keeps running. Such a command outlives the turn's `Stop` and fires *no* completion hook, so
    /// the only signal is the `PreToolUse` that starts it — the resulting hold has no symmetric
    /// release and is therefore TTL-bounded (capped by `manualHoldMaxHours`), which is why it's a
    /// separately-installed, default-OFF opt-in. Claude Code only for now (see `BackgroundBashHold`).
    public var keepAwakeForBackgroundBash: Bool = false


    public init() {}

    enum CodingKeys: String, CodingKey {
        case soundOnLidClose
        case soundVolume
        case chimeName
        case sleepSoundEnabled
        case sleepChimeWorkComplete
        case sleepChimeHoldExpired
        case sleepChimeSafetyCutout
        case sleepChimeUserAction
        case lockOnLidClose
        case thermalCutoutEnabled
        case thermalThresholdCelsius
        case lowBatteryCutoutEnabled
        case lowBatteryThresholdPercent
        case safetyCutoutsWithLidOpen
        case requireACPower
        case agentWaitingPolicy
        case agentWaitingGraceMinutes
        case idleReleaseEnabled
        case idleReleaseSeconds
        case processSniffingEnabled
        case autoAcquireForKnownAgents
        case agentHoldsEnabled
        case manualHoldMaxHours
        case keepAwakeForBackgroundBash
    }

    /// Decode-only key for the retired `idleReleaseMinutes` field, migrated to `idleReleaseSeconds`.
    private enum LegacyCodingKeys: String, CodingKey {
        case idleReleaseMinutes
    }

    /// Resilient decoding: a missing OR type-mismatched key falls back to its default rather
    /// than throwing. Swift's synthesized decoder throws on any absent key — and
    /// `decodeIfPresent` throws on a wrong-typed one — either of which would make `load()`
    /// discard a user's *entire* config over a single bad field (a newer build's new setting,
    /// or a hand-edit like `"idleReleaseSeconds": "90"`). Decoding each field independently
    /// confines the damage to that field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LidwakeSettings()
        self.soundOnLidClose = (try? c.decodeIfPresent(Bool.self, forKey: .soundOnLidClose)) ?? d.soundOnLidClose
        self.soundVolume = (try? c.decodeIfPresent(Float.self, forKey: .soundVolume)) ?? d.soundVolume
        self.chimeName = (try? c.decodeIfPresent(String.self, forKey: .chimeName)) ?? d.chimeName
        self.sleepSoundEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .sleepSoundEnabled)) ?? d.sleepSoundEnabled
        self.sleepChimeWorkComplete = (try? c.decodeIfPresent(String.self, forKey: .sleepChimeWorkComplete)) ?? d.sleepChimeWorkComplete
        self.sleepChimeHoldExpired = (try? c.decodeIfPresent(String.self, forKey: .sleepChimeHoldExpired)) ?? d.sleepChimeHoldExpired
        self.sleepChimeSafetyCutout = (try? c.decodeIfPresent(String.self, forKey: .sleepChimeSafetyCutout)) ?? d.sleepChimeSafetyCutout
        self.sleepChimeUserAction = (try? c.decodeIfPresent(String.self, forKey: .sleepChimeUserAction)) ?? d.sleepChimeUserAction
        self.lockOnLidClose = (try? c.decodeIfPresent(Bool.self, forKey: .lockOnLidClose)) ?? d.lockOnLidClose
        self.thermalCutoutEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .thermalCutoutEnabled)) ?? d.thermalCutoutEnabled
        self.thermalThresholdCelsius = (try? c.decodeIfPresent(Double.self, forKey: .thermalThresholdCelsius)) ?? d.thermalThresholdCelsius
        self.lowBatteryCutoutEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .lowBatteryCutoutEnabled)) ?? d.lowBatteryCutoutEnabled
        self.lowBatteryThresholdPercent = (try? c.decodeIfPresent(Int.self, forKey: .lowBatteryThresholdPercent)) ?? d.lowBatteryThresholdPercent
        self.safetyCutoutsWithLidOpen = (try? c.decodeIfPresent(Bool.self, forKey: .safetyCutoutsWithLidOpen)) ?? d.safetyCutoutsWithLidOpen
        self.requireACPower = (try? c.decodeIfPresent(Bool.self, forKey: .requireACPower)) ?? d.requireACPower
        self.agentWaitingPolicy = (try? c.decodeIfPresent(AgentWaitingPolicy.self, forKey: .agentWaitingPolicy)) ?? d.agentWaitingPolicy
        self.agentWaitingGraceMinutes = (try? c.decodeIfPresent(Int.self, forKey: .agentWaitingGraceMinutes)) ?? d.agentWaitingGraceMinutes
        self.idleReleaseEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .idleReleaseEnabled)) ?? d.idleReleaseEnabled
        // Prefer the seconds field; migrate a legacy `idleReleaseMinutes` (×60) if that's all that's
        // present; otherwise fall back to the default.
        if let secs = try? c.decodeIfPresent(Int.self, forKey: .idleReleaseSeconds) {
            self.idleReleaseSeconds = secs
        } else if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self),
                  let mins = try? legacy.decodeIfPresent(Int.self, forKey: .idleReleaseMinutes) {
            self.idleReleaseSeconds = mins * 60
        } else {
            self.idleReleaseSeconds = d.idleReleaseSeconds
        }
        self.processSniffingEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .processSniffingEnabled)) ?? d.processSniffingEnabled
        self.autoAcquireForKnownAgents = (try? c.decodeIfPresent(Bool.self, forKey: .autoAcquireForKnownAgents)) ?? d.autoAcquireForKnownAgents
        self.agentHoldsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .agentHoldsEnabled)) ?? d.agentHoldsEnabled
        self.manualHoldMaxHours = (try? c.decodeIfPresent(Double.self, forKey: .manualHoldMaxHours)) ?? d.manualHoldMaxHours
        self.keepAwakeForBackgroundBash = (try? c.decodeIfPresent(Bool.self, forKey: .keepAwakeForBackgroundBash)) ?? d.keepAwakeForBackgroundBash
        clampToSupportedRanges()
    }

    /// Clamps the numeric fields into ranges where the policies stay sane. The UI enforces
    /// tighter bounds; config.json is hand-editable, and e.g. a battery threshold of 150 would
    /// make the cutout fire on every tick, while a thermal threshold of 0 would never not fire.
    /// Non-finite values reset to defaults before clamping.
    private mutating func clampToSupportedRanges() {
        let d = LidwakeSettings()
        if !soundVolume.isFinite { soundVolume = d.soundVolume }
        if !thermalThresholdCelsius.isFinite { thermalThresholdCelsius = d.thermalThresholdCelsius }
        if !manualHoldMaxHours.isFinite { manualHoldMaxHours = d.manualHoldMaxHours }
        soundVolume = min(max(soundVolume, 0), 1)
        thermalThresholdCelsius = min(max(thermalThresholdCelsius, 50), 105)
        lowBatteryThresholdPercent = min(max(lowBatteryThresholdPercent, 1), 99)
        idleReleaseSeconds = min(max(idleReleaseSeconds, 30), 3_600)
        manualHoldMaxHours = min(max(manualHoldMaxHours, 0.25), 24)
        agentWaitingGraceMinutes = min(max(agentWaitingGraceMinutes, 1), 120)
    }

    public static func load(from url: URL = LidwakeConstants.appSupportURL.appendingPathComponent(LidwakeConstants.configFilename)) -> LidwakeSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(LidwakeSettings.self, from: data) else {
            return LidwakeSettings()
        }
        return s
    }

    public func save(to url: URL = LidwakeConstants.appSupportURL.appendingPathComponent(LidwakeConstants.configFilename)) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
