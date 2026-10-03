import Foundation

public enum LidwakeConstants {
    public static let appBundleID = "io.github.nikitashakhbazyan.lidwake"
    public static let daemonBundleID = "io.github.nikitashakhbazyan.lidwake.daemon"
    public static let helperBundleID = "io.github.nikitashakhbazyan.lidwake.helper"

    public static let daemonMachServiceName = "io.github.nikitashakhbazyan.lidwake.daemon"
    public static let helperMachServiceName = "io.github.nikitashakhbazyan.lidwake.helper"

    public static let appSupportDirectoryName = "lidwake"
    public static let cliSocketFilename = "cli.sock"
    public static let stateFilename = "state.json"
    public static let configFilename = "config.json"
    public static let eventLogFilename = "events.log"
    /// Root-only state of the privileged helper: the `disablesleep` value to restore.
    public static let helperStateDirectory = "/var/db/lidwake"

    /// Version the daemon, helper, and CLI report over their version endpoints. The app bundle reads
    /// its own `CFBundleShortVersionString`; keep this in step with the project's `MARKETING_VERSION`
    /// at release time so every component agrees on a single number.
    public static let marketingVersion = "0.1.0"

    public static let cliBinaryName = "lidwake"
    public static let cliInstallPath = "/usr/local/bin/lidwake"
    public static let cliFallbackInstallPath = "\(NSHomeDirectory())/.local/bin/lidwake"

    public static var appSupportURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var cliSocketURL: URL {
        appSupportURL.appendingPathComponent(cliSocketFilename)
    }
}
