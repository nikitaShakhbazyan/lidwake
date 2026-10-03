import Foundation

/// Renders `lidwake stats`: one frame of the terminal dashboard from a daemon status. Pure, so the
/// layout is testable; the CLI owns the terminal (raw mode, alternate screen, key handling).
public struct Dashboard {
    public var width: Int
    public var color: Bool
    /// One-line feedback for the last key press ("timer set", "released 2 holds").
    public var flash: String?

    public init(width: Int, color: Bool, flash: String? = nil) {
        self.width = max(48, min(width, 96))
        self.color = color
        self.flash = flash
    }

    /// Temperature axis of the bar, in °C.
    static let tempScale = 30.0 ... 100.0

    public enum TempZone: String, Sendable {
        case normal, warm, hot, critical
    }

    /// Normal well below the cutout, warm approaching it, hot within 5 °C, critical at the cutout.
    public static func tempZone(_ celsius: Double, cutout: Double) -> TempZone {
        if celsius >= cutout { return .critical }
        if celsius >= cutout - 5 { return .hot }
        if celsius >= cutout - 20 { return .warm }
        return .normal
    }

    public static let thermalStateNames = ["nominal", "fair", "serious", "critical"]

    public func render(_ status: DaemonStatus?, now: Date = Date(), daemonError: String? = nil) -> [String] {
        var out: [Line] = []
        let clock = Self.clockFormatter.string(from: now)
        guard let status else {
            out.append(Line(.bold("lidwake")).pad(width, right: [.dim(clock)]))
            out.append(Line(.dim(String(repeating: "─", count: width))))
            out.append(Line(.red("  ✕ daemon not running")))
            if let daemonError { out.append(Line(.dim("    \(daemonError)"))) }
            out.append(Line(.dim("    install it with scripts/install.sh, or check: lidwake daemon-status")))
            out.append(Line(.dim(String(repeating: "─", count: width))))
            out.append(keyHelp)
            return out.map { $0.fit(width).render(color: color) }
        }
        let env = status.environment
        let cutout = env?.settings.thermalThresholdCelsius ?? 80

        out.append(Line([.bold("lidwake  ")] + headline(status)).pad(width, right: [.dim(clock)]))
        out.append(rule)

        // Sleep
        if env?.sleepDisabled == true {
            out.append(row("Lid-close sleep", [.green("blocked"), .plain(" — closing the lid won't sleep the Mac")]))
        } else {
            out.append(row("Lid-close sleep", [.plain("allowed"), .dim(" — the Mac sleeps when the lid closes")]))
        }
        out.append(row("Lid", [.plain(status.lidClosed ? "closed" : "open")]))

        // Off timer
        if status.paused {
            out.append(row("Off timer", [.dim("— (lidwake is off)")]))
        } else if let offAt = env?.offAt {
            let left = max(0, offAt.timeIntervalSince(now))
            out.append(row("Off timer", [.yellow(Self.duration(left, seconds: true)), .plain("  until \(Self.clockShort.string(from: offAt))")]))
        } else {
            out.append(row("Off timer", [.dim("not set — press t")]))
        }

        // Power
        if let pct = env?.batteryPercent {
            let floor = env?.settings.lowBatteryThresholdPercent ?? 20
            let source = env?.onBattery == true ? "on battery" : "on AC"
            var segs = batteryBar(pct, floor: floor, cells: barCells)
            segs.append(.plain("  \(pct)% \(source)"))
            if env?.settings.requireACPower == true {
                segs.append(.dim(" · AC only"))
            } else if env?.settings.lowBatteryCutoutEnabled != false {
                segs.append(.dim(" · stop at \(floor)%"))
            }
            out.append(row("Battery", segs))
        } else {
            out.append(row("Power", [.plain("AC (no battery)")]))
        }

        // Temperature
        if let t = status.cpuTemperatureCelsius {
            let zone = Self.tempZone(t, cutout: cutout)
            var segs = temperatureBar(t, cutout: cutout, cells: barCells)
            segs.append(.styled(String(format: "  %.0f°C %@", t, zone.rawValue), zoneStyle(zone)))
            if env?.settings.thermalCutoutEnabled == false { segs.append(.dim(" · cutout off")) }
            out.append(row("CPU temp", segs))
            out.append(row("", temperatureLegend(cutout: cutout, cells: barCells)))
        } else {
            out.append(row("CPU temp", [.dim("unreadable")]))
        }
        if let state = env?.thermalState {
            var segs: [Seg] = []
            for (i, name) in Self.thermalStateNames.enumerated() {
                let style: Style = i <= 0 ? .green : i == 1 ? .yellow : .red
                segs.append(i == state ? .styled("● \(name)", style) : .dim("○ \(name)"))
                if i < Self.thermalStateNames.count - 1 { segs.append(.plain("  ")) }
            }
            out.append(row("Thermal", segs))
        }

        // Agents
        out.append(rule)
        let agents = status.assertions.sorted { $0.acquiredAt < $1.acquiredAt }
        out.append(Line([.bold("  AGENTS  "), .dim(agents.isEmpty ? "none working" : "\(agents.count) keeping the Mac awake")]))
        for a in agents.prefix(8) {
            out.append(agentLine(a, now: now))
        }
        if agents.count > 8 { out.append(Line(.dim("  … and \(agents.count - 8) more"))) }

        // Warnings and feedback
        let warnings = status.warnings + (status.helperConnected ? [] : ["The privileged helper is not connected — lid-close sleep can't be blocked."])
        if !warnings.isEmpty || flash != nil { out.append(rule) }
        for w in warnings.prefix(3) {
            out.append(Line(.yellow("  ! " + Self.truncate(w, width - 4))))
        }
        if let flash { out.append(Line(.cyan("  " + Self.truncate(flash, width - 2)))) }

        out.append(rule)
        out.append(keyHelp)
        // Never wider than the terminal: a wrapped line would scroll the whole frame.
        return out.map { $0.fit(width).render(color: color) }
    }

    // MARK: - Pieces

    /// Room left for the bars after the label column and the text that follows them.
    private var barCells: Int {
        max(8, width - 2 - Self.labelWidth - 2 - 30)
    }

    static let labelWidth = 17

    private var rule: Line {
        Line(.dim(String(repeating: "─", count: width)))
    }

    private var keyHelp: Line {
        Line(.dim("  [space] on/off  [t] timer  [+/-] ±15m  [r] release all  [q] quit"))
    }

    private func headline(_ s: DaemonStatus) -> [Seg] {
        let cutouts = s.environment?.activeCutouts ?? []
        if s.paused {
            return [.dim("○ OFF"), .dim(" · the Mac sleeps normally")]
        }
        if !cutouts.isEmpty {
            return [.red("▲ CUTOUT"), .plain(" · \(cutouts.map(Self.cutoutName).joined(separator: ", "))")]
        }
        if s.isBlocking {
            return [.green("● ON"), .plain(" · keeping the Mac awake")]
        }
        return [.cyan("● ON"), .plain(" · idle, no agents working")]
    }

    static func cutoutName(_ raw: String) -> String {
        switch raw {
        case "thermal": "overheating"
        case "lowBattery": "low battery"
        case "onBattery": "on battery (AC only)"
        default: raw
        }
    }

    private func row(_ label: String, _ value: [Seg]) -> Line {
        Line([.dim("  " + label.padding(toLength: Self.labelWidth, withPad: " ", startingAt: 0))] + value)
    }

    private func agentLine(_ a: Assertion, now: Date) -> Line {
        let state: Seg = if let waiting = a.waitingFor {
            .yellow("waiting: \(waiting)")
        } else if a.origin == .manual {
            .cyan("hold")
        } else {
            .green("working")
        }
        var segs: [Seg] = [
            .plain("  " + Self.truncate(a.tool, 14).padding(toLength: 14, withPad: " ", startingAt: 0)),
            .dim(a.pid > 0 ? "pid \(a.pid)".padding(toLength: 11, withPad: " ", startingAt: 0) : "".padding(toLength: 11, withPad: " ", startingAt: 0)),
            state,
            .dim("  " + Self.duration(now.timeIntervalSince(a.acquiredAt), seconds: false)),
        ]
        if let expires = a.expiresAt {
            segs.append(.dim(", \(Self.duration(max(0, expires.timeIntervalSince(now)), seconds: false)) left"))
        }
        if let reason = a.reason, !reason.isEmpty {
            let used = segs.reduce(0) { $0 + $1.text.count }
            segs.append(.dim("  " + Self.truncate(reason, max(8, width - used - 2))))
        }
        return Line(segs)
    }

    private func zoneStyle(_ zone: TempZone) -> Style {
        switch zone {
        case .normal: .green
        case .warm: .yellow
        case .hot, .critical: .red
        }
    }

    /// `▕████████▒▒░░░░┃░░▏` — filled up to the reading, each cell colored by the zone it stands
    /// for, with the cutout marked.
    private func temperatureBar(_ t: Double, cutout: Double, cells: Int) -> [Seg] {
        let span = Self.tempScale.upperBound - Self.tempScale.lowerBound
        let cutoutCell = Int(((cutout - Self.tempScale.lowerBound) / span * Double(cells)).rounded())
        let filled = Int(((min(max(t, Self.tempScale.lowerBound), Self.tempScale.upperBound) - Self.tempScale.lowerBound) / span * Double(cells)).rounded())
        var segs: [Seg] = [.dim("▕")]
        for i in 0 ..< cells {
            let cellTemp = Self.tempScale.lowerBound + (Double(i) + 0.5) / Double(cells) * span
            let style = zoneStyle(Self.tempZone(cellTemp, cutout: cutout))
            if i == cutoutCell {
                segs.append(.styled("┃", .red))
            } else if i < filled {
                segs.append(.styled("█", style))
            } else {
                segs.append(.styled("░", color ? style.dimmed : .plain))
            }
        }
        segs.append(.dim("▏"))
        return segs
    }

    private func temperatureLegend(cutout: Double, cells: Int) -> [Seg] {
        let span = Self.tempScale.upperBound - Self.tempScale.lowerBound
        let cutoutCell = Int(((cutout - Self.tempScale.lowerBound) / span * Double(cells)).rounded())
        var text = Array(repeating: Character(" "), count: cells + 2)
        func put(_ s: String, at col: Int) {
            for (i, ch) in s.enumerated() where col + i >= 0 && col + i < text.count {
                text[col + i] = ch
            }
        }
        put("\(Int(Self.tempScale.lowerBound))°", at: 0)
        let label = "\(Int(cutout))° cutout"
        put(label, at: min(max(1, cutoutCell + 1 - label.count / 2), cells + 2 - label.count))
        let top = "\(Int(Self.tempScale.upperBound))°"
        if cutoutCell + label.count / 2 + 2 < cells + 2 - top.count { put(top, at: cells + 2 - top.count) }
        return [.dim(String(text))]
    }

    private func batteryBar(_ pct: Int, floor: Int, cells: Int) -> [Seg] {
        let filled = Int((Double(min(max(pct, 0), 100)) / 100 * Double(cells)).rounded())
        let floorCell = Int((Double(floor) / 100 * Double(cells)).rounded())
        let style: Style = pct <= floor ? .red : pct <= floor + 15 ? .yellow : .green
        var segs: [Seg] = [.dim("▕")]
        for i in 0 ..< cells {
            if i == floorCell, floor > 0 {
                segs.append(.styled("┃", .red))
            } else {
                segs.append(i < filled ? .styled("█", style) : .dim("░"))
            }
        }
        segs.append(.dim("▏"))
        return segs
    }

    // MARK: - Formatting

    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let clockShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// `1h 05m`, `12m 03s` (with seconds) or `12m`, `45s`.
    public static func duration(_ interval: TimeInterval, seconds: Bool) -> String {
        let total = Int(interval.rounded(.down))
        let h = total / 3_600, m = total % 3_600 / 60, s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return seconds ? String(format: "%dm %02ds", m, s) : "\(m)m" }
        return "\(s)s"
    }

    static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(Swift.max(1, max - 1))) + "…"
    }
}

// MARK: - Styled text

enum Style {
    case plain, bold, dim, red, green, yellow, cyan
    case dimRed, dimGreen, dimYellow

    var code: String {
        switch self {
        case .plain: ""
        case .bold: "\u{1B}[1m"
        case .dim: "\u{1B}[2m"
        case .red: "\u{1B}[31m"
        case .green: "\u{1B}[32m"
        case .yellow: "\u{1B}[33m"
        case .cyan: "\u{1B}[36m"
        case .dimRed: "\u{1B}[2;31m"
        case .dimGreen: "\u{1B}[2;32m"
        case .dimYellow: "\u{1B}[2;33m"
        }
    }

    var dimmed: Style {
        switch self {
        case .red: .dimRed
        case .green: .dimGreen
        case .yellow: .dimYellow
        default: .dim
        }
    }
}

struct Seg {
    let text: String
    let style: Style

    static func styled(_ text: String, _ style: Style) -> Seg {
        Seg(text: text, style: style)
    }

    static func plain(_ t: String) -> Seg { Seg(text: t, style: .plain) }
    static func bold(_ t: String) -> Seg { Seg(text: t, style: .bold) }
    static func dim(_ t: String) -> Seg { Seg(text: t, style: .dim) }
    static func red(_ t: String) -> Seg { Seg(text: t, style: .red) }
    static func green(_ t: String) -> Seg { Seg(text: t, style: .green) }
    static func yellow(_ t: String) -> Seg { Seg(text: t, style: .yellow) }
    static func cyan(_ t: String) -> Seg { Seg(text: t, style: .cyan) }
}

struct Line {
    var segs: [Seg]

    init(_ segs: [Seg]) {
        self.segs = segs
    }

    init(_ seg: Seg) {
        segs = [seg]
    }

    var plainWidth: Int {
        segs.reduce(0) { $0 + $1.text.count }
    }

    /// Right-aligns `right` within `width`.
    func pad(_ width: Int, right: [Seg]) -> Line {
        let gap = max(1, width - plainWidth - right.reduce(0) { $0 + $1.text.count })
        return Line(segs + [.plain(String(repeating: " ", count: gap))] + right)
    }

    /// Cuts the line to `width` columns, ending in "…" when something was dropped.
    func fit(_ width: Int) -> Line {
        guard plainWidth > width else { return self }
        var kept: [Seg] = []
        var room = width - 1
        for seg in segs {
            guard room > 0 else { break }
            if seg.text.count <= room {
                kept.append(seg)
                room -= seg.text.count
            } else {
                kept.append(Seg(text: String(seg.text.prefix(room)), style: seg.style))
                room = 0
            }
        }
        return Line(kept + [.dim("…")])
    }

    func render(color: Bool) -> String {
        guard color else { return segs.map(\.text).joined() }
        return segs.map { $0.style == .plain ? $0.text : $0.style.code + $0.text + "\u{1B}[0m" }.joined()
    }
}
