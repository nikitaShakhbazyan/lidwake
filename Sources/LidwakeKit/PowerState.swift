import Foundation
import IOKit

public enum PowerState {
    /// The `SleepDisabled` flag as the kernel enforces it, read from `IOPMrootDomain`. `pmset -g`
    /// only lists it once the key exists in the power-management preferences.
    public static func sleepDisabled() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }
}
