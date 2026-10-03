import Foundation

/// Latches a fired safety cutout until its hazard has actually receded.
///
/// A cutout releases every assertion — but the agent that was pinning the Mac is usually still
/// running, and its very next hook event (or the sniff sweep) would re-acquire within seconds.
/// The monitors re-seed a reading the moment blocking resumes, so without a latch the system
/// oscillates: acquire → cutout → release → re-acquire…, each cycle burning more charge below
/// the threshold meant to protect it, or re-heating the Mac the cutout just saved. While
/// latched, the daemon rejects acquires.
///
/// Clearing requires the hazard to recede with margin (hysteresis). When the cutouts only guard a
/// closed lid (`clearsOnLidOpen`), opening the lid clears them too: a present user can re-close it
/// to re-arm protection deliberately. The AC-only cutout (`onBattery`) clears only on AC power.
public struct CutoutLatch: Equatable, Sendable {
    public enum Cause: String, Sendable, CaseIterable {
        case thermal
        case lowBattery
        /// `requireACPower` is on and the Mac was unplugged.
        case onBattery
    }

    public static let thermalHysteresisCelsius = 5.0
    public static let batteryHysteresisPercent = 5

    public private(set) var active: Set<Cause> = []
    /// False when the cutouts also run with the lid open — then the lid says nothing about safety.
    public var clearsOnLidOpen = true

    public init() {}

    public var isLatched: Bool {
        !active.isEmpty
    }

    public mutating func trip(_ cause: Cause) {
        active.insert(cause)
    }

    /// Drops the causes whose safety net the user switched off: a latch for a disabled cutout
    /// would otherwise refuse acquires until a hazard nobody is watching for recedes.
    @discardableResult
    public mutating func dropDisabled(thermal: Bool, lowBattery: Bool, acOnly: Bool) -> Set<Cause> {
        var dropped: Set<Cause> = []
        for (cause, enabled) in [(Cause.thermal, thermal), (.lowBattery, lowBattery), (.onBattery, acOnly)] where !enabled {
            if active.remove(cause) != nil { dropped.insert(cause) }
        }
        return dropped
    }

    /// Re-evaluates the latch against current conditions; returns the causes that cleared.
    /// Unknown readings (`nil`) keep a latch held — a cutout must not clear on missing data.
    @discardableResult
    public mutating func update(
        temperatureCelsius: Double?,
        thermalThresholdCelsius: Double,
        batteryPercent: Int?,
        onBattery: Bool?,
        batteryThresholdPercent: Int,
        lidClosed: Bool,
    ) -> Set<Cause> {
        var cleared: Set<Cause> = []
        let lidOpened = clearsOnLidOpen && !lidClosed
        if active.contains(.thermal) {
            let cooled = temperatureCelsius.map { $0 <= thermalThresholdCelsius - Self.thermalHysteresisCelsius } ?? false
            if lidOpened || cooled {
                active.remove(.thermal)
                cleared.insert(.thermal)
            }
        }
        if active.contains(.lowBattery) {
            let charged = batteryPercent.map { $0 >= batteryThresholdPercent + Self.batteryHysteresisPercent } ?? false
            if lidOpened || onBattery == false || charged {
                active.remove(.lowBattery)
                cleared.insert(.lowBattery)
            }
        }
        if active.contains(.onBattery), onBattery == false {
            active.remove(.onBattery)
            cleared.insert(.onBattery)
        }
        return cleared
    }

    /// User-facing explanation for a rejected acquire.
    public var rejectionMessage: String? {
        guard isLatched else { return nil }
        let orLid = clearsOnLidOpen ? " or the lid opens" : ""
        var hazards: [String] = []
        if active.contains(.thermal) { hazards.append("overheating") }
        if active.contains(.lowBattery) { hazards.append("low battery") }
        if active.contains(.onBattery) { hazards.append("running on battery with AC-only mode on") }
        if hazards.count > 1 {
            return "Safety cutouts are active (\(hazards.joined(separator: ", "))) — acquires are paused until conditions recover\(orLid)."
        }
        if active.contains(.thermal) {
            return "The thermal cutout fired — acquires are paused until the Mac cools down\(orLid)."
        }
        if active.contains(.lowBattery) {
            return "The low-battery cutout fired — acquires are paused until charging resumes\(orLid)."
        }
        return "AC-only mode is on and the Mac is on battery — acquires are paused until it is plugged in."
    }
}
