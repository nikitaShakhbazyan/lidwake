import Darwin
import Foundation
import LidwakeKit

/// `lidwake run [--for <d>] [--reason <text>] [--display] -- <command> [args…]`
///
/// Places a hold on its own PID, then `exec`s the command: the PID (and so the hold) belongs to the
/// command from then on, its exit code passes straight through, and the daemon releases the hold
/// the moment it exits. The command runs even if the hold can't be placed — lidwake never stands
/// between you and your work — but says so on stderr.
enum RunCommand {
    static func run(args: [String]) {
        var duration: TimeInterval?
        var reason: String?
        var display = false
        var rest = args[...]
        parsing: while let arg = rest.first {
            switch arg {
            case "--":
                rest = rest.dropFirst()
                break parsing
            case "--for":
                guard rest.count >= 2, let secs = DurationParser.seconds(from: rest[rest.startIndex + 1]), secs > 0 else {
                    ControlCommands.fail("--for needs a duration such as 2h or 1h30m")
                }
                duration = secs
                rest = rest.dropFirst(2)
            case "--reason":
                guard rest.count >= 2 else { ControlCommands.fail("--reason needs a value") }
                reason = rest[rest.startIndex + 1]
                rest = rest.dropFirst(2)
            case "--display":
                display = true
                rest = rest.dropFirst()
            case "-h", "--help":
                print("usage: lidwake run [--for <duration>] [--reason <text>] [--display] -- <command> [args...]")
                exit(0)
            default:
                if arg.hasPrefix("-") { ControlCommands.fail("unknown option \(arg) (put the command after --)") }
                break parsing
            }
        }
        let command = Array(rest)
        guard let program = command.first else {
            ControlCommands.fail("usage: lidwake run [--for <duration>] [--reason <text>] -- <command> [args...]")
        }
        let name = (program as NSString).lastPathComponent

        // Ask for the configured cap when no --for is given: the hold should last as long as the
        // command, and the PID binding ends it as soon as the command does.
        let req = CLIRequest(
            op: .hold,
            key: nil,
            tool: name,
            reason: reason ?? "lidwake run \(name)",
            pid: getpid(),
            processName: name,
            ttlSeconds: duration ?? 24 * 3_600,
            display: display ? true : nil,
        )
        do {
            let resp = try DaemonSocketClient.send(req)
            if resp.ok, let ttl = resp.appliedTTLSeconds {
                note("keeping the Mac awake while \(name) runs (at most \(Dashboard.duration(ttl, seconds: false)))")
            } else {
                note("could not keep the Mac awake: \(resp.error ?? "unknown error") — running \(name) anyway")
            }
        } catch {
            note("\(error.localizedDescription) Running \(name) without keeping the Mac awake.")
        }

        let argv = command.map { strdup($0) } + [nil]
        execvp(program, argv)
        ControlCommands.fail("\(program): \(String(cString: strerror(errno)))")
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("lidwake: \(message)\n".utf8))
    }
}
