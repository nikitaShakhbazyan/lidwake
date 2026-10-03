import Foundation
import LidwakeKit

/// `lidwake on | off | timer` — turn the whole thing on or off, now or later.
enum ControlCommands {
    static func request(_ op: CLIRequest.Op, ttl: TimeInterval? = nil) -> CLIResponse {
        let req = CLIRequest(op: op, key: nil, tool: nil, reason: nil, pid: nil, processName: nil, ttlSeconds: ttl)
        do {
            let resp = try DaemonSocketClient.send(req)
            guard resp.ok else { fail(resp.error ?? "the daemon refused the request") }
            return resp
        } catch {
            fail(error.localizedDescription)
        }
    }

    static func setOn(_ on: Bool) {
        let resp = request(on ? .resume : .pause)
        if on {
            print("lidwake is on — working agents keep the Mac awake, lid closed or not.")
        } else {
            let n = resp.releasedCount ?? 0
            print("lidwake is off\(n > 0 ? " — released \(n) hold\(n == 1 ? "" : "s")" : "") · the Mac sleeps normally.")
        }
    }

    /// `lidwake timer 1h` / `lidwake timer off`
    static func timer(args: [String]) {
        guard args.count == 1 else { fail("usage: lidwake timer <duration, e.g. 30m, 1h, 1h30m> | off") }
        var seconds: TimeInterval = 0
        if !["off", "cancel", "none"].contains(args[0]) {
            guard let parsed = DurationParser.seconds(from: args[0]), parsed > 0 else {
                fail("could not understand duration '\(args[0])' (try 30m, 1h, 1h30m)")
            }
            seconds = parsed
        }
        let resp = request(.timer, ttl: seconds)
        if let left = resp.appliedTTLSeconds {
            print("lidwake turns off at \(clock(Date().addingTimeInterval(left))) (in \(Dashboard.duration(left, seconds: false))).")
        } else {
            print("Off timer cancelled.")
        }
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("lidwake: \(message)\n".utf8))
        exit(1)
    }
}
