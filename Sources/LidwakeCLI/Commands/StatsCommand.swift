import Darwin
import Foundation
import LidwakeKit

/// `lidwake stats [--once]` — live dashboard: on/off, lid-close sleep, off timer, battery, CPU
/// temperature against the cutout, thermal pressure and the agents keeping the Mac awake.
///
/// Keys: space on/off · t cycle the off timer · +/- move it by 15 min · r release all · q quit.
/// `--once` (or a non-terminal stdout) prints a single frame, for scripts and SSH one-liners.
enum StatsCommand {
    static func run(args: [String]) {
        let parser = ArgParser(args: args)
        let interactive = !parser.flag("--once") && isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        let color = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

        guard interactive else {
            let (status, error) = fetch()
            print(Dashboard(width: terminalWidth(), color: color).render(status, daemonError: error).joined(separator: "\n"))
            exit(status == nil ? 1 : 0)
        }

        let terminal = RawTerminal()
        terminal.enter()
        var flash: (text: String, at: Date)?
        while true {
            let (status, error) = fetch()
            let message = flash.flatMap { Date().timeIntervalSince($0.at) < 4 ? $0.text : nil }
            terminal.draw(Dashboard(width: terminalWidth(), color: color, flash: message).render(status, daemonError: error))
            guard let key = terminal.readKey(timeoutMilliseconds: 1_000) else { continue }
            switch key {
            case "q", "Q", "\u{1B}", "\u{03}":
                terminal.leave()
                exit(0)
            case " ", "o", "O":
                guard let status else { continue }
                let resp = send(status.paused ? .resume : .pause)
                flash = (status.paused ? "lidwake is on" : "lidwake is off\(released(resp))", Date())
            case "t", "T":
                flash = (setTimer(OffTimer.nextPreset(after: remaining(status))), Date())
            case "+", "=":
                flash = (setTimer((remaining(status) ?? 0) + 15 * 60), Date())
            case "-", "_":
                let left = (remaining(status) ?? 0) - 15 * 60
                flash = (setTimer(left >= 60 ? left : nil), Date())
            case "r", "R":
                let resp = send(.releaseAll)
                let n = resp?.releasedCount ?? 0
                flash = (n > 0 ? "released \(n) hold\(n == 1 ? "" : "s")" : "nothing to release", Date())
            default:
                continue
            }
        }
    }

    // MARK: - Timer keys

    private static func remaining(_ status: DaemonStatus?) -> TimeInterval? {
        guard let status, !status.paused, let offAt = status.environment?.offAt else { return nil }
        return max(0, offAt.timeIntervalSinceNow)
    }

    private static func setTimer(_ seconds: TimeInterval?) -> String {
        guard let resp = send(.timer, ttl: seconds ?? 0) else { return "the daemon did not answer" }
        guard let left = resp.appliedTTLSeconds else { return "off timer cancelled" }
        let at = ControlCommands.clock(Date().addingTimeInterval(left))
        return "lidwake turns off at \(at) (in \(Dashboard.duration(left, seconds: false)))"
    }

    // MARK: - Daemon

    private static func send(_ op: CLIRequest.Op, ttl: TimeInterval? = nil) -> CLIResponse? {
        let req = CLIRequest(op: op, key: nil, tool: nil, reason: nil, pid: nil, processName: nil, ttlSeconds: ttl)
        return try? DaemonSocketClient.send(req)
    }

    private static func released(_ resp: CLIResponse?) -> String {
        guard let n = resp?.releasedCount, n > 0 else { return "" }
        return " — released \(n) hold\(n == 1 ? "" : "s")"
    }

    private static func fetch() -> (DaemonStatus?, String?) {
        let req = CLIRequest(op: .status, key: nil, tool: nil, reason: nil, pid: nil, processName: nil, ttlSeconds: nil)
        do {
            let resp = try DaemonSocketClient.send(req)
            guard let data = resp.statusJSON else { return (nil, "the daemon sent no status") }
            let decoder = JSONDecoder()
            return (try decoder.decode(DaemonStatus.self, from: data), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private static func terminalWidth() -> Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
        return Int(size.ws_col)
    }
}

/// Raw, unechoed keyboard input on the alternate screen, restored on exit and on SIGTERM/SIGHUP.
final class RawTerminal: @unchecked Sendable {
    private var original = termios()
    private var active = false
    private var signalSources: [DispatchSourceSignal] = []

    func enter() {
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        // ISIG off: Ctrl-C arrives as a key, so quitting always goes through `leave()`.
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        write("\u{1B}[?1049h\u{1B}[?25l")
        active = true
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [self] in
                leave()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func leave() {
        guard active else { return }
        active = false
        write("\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    }

    func draw(_ lines: [String]) {
        var frame = "\u{1B}[H"
        for line in lines {
            frame += line + "\u{1B}[K\r\n"
        }
        write(frame + "\u{1B}[J")
    }

    /// The next key, or nil after the timeout. Escape sequences (arrows…) come back as one string.
    func readKey(timeoutMilliseconds: Int32) -> String? {
        var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&fds, 1, timeoutMilliseconds) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        guard n > 0 else { return nil }
        return String(decoding: buffer[0 ..< n], as: UTF8.self)
    }

    private func write(_ s: String) {
        let data = Array(s.utf8)
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { return }
                offset += n
            }
        }
    }
}
