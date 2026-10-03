import Foundation
import LidwakeKit

/// `lidwake config [<key> [<value>]]` — read or change a setting without the app. Values are typed
/// after the current one (true/false, numbers, text) and go through the same validation and
/// clamping as the settings file, then the daemon reloads them.
enum ConfigCommand {
    static func run(args: [String]) {
        let url = LidwakeConstants.appSupportURL.appendingPathComponent(LidwakeConstants.configFilename)
        let settings = LidwakeSettings.load(from: url)
        var dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) as? [String: Any] ?? [:]

        switch args.count {
        case 0:
            for key in dict.keys.sorted() {
                print("\(key) = \(format(dict[key]!))")
            }
        case 1:
            guard let value = dict[args[0]] else { unknown(args[0], in: dict) }
            print(format(value))
        case 2:
            let key = args[0]
            guard let current = dict[key] else { unknown(key, in: dict) }
            guard let value = parse(args[1], like: current) else {
                ControlCommands.fail("\(key) expects \(kind(of: current)), got '\(args[1])'")
            }
            dict[key] = value
            do {
                let data = try JSONSerialization.data(withJSONObject: dict)
                let updated = try JSONDecoder().decode(LidwakeSettings.self, from: data)
                try updated.save(to: url)
                let applied = ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(updated))) as? [String: Any])?[key]
                print("\(key) = \(applied.map(format) ?? args[1])")
            } catch {
                ControlCommands.fail("could not save settings: \(error.localizedDescription)")
            }
            let req = CLIRequest(op: .reloadSettings, key: nil, tool: nil, reason: nil, pid: nil, processName: nil, ttlSeconds: nil)
            if (try? DaemonSocketClient.send(req)) == nil {
                FileHandle.standardError.write(Data("lidwake: saved; the daemon is not running, so it applies on next start\n".utf8))
            }
        default:
            ControlCommands.fail("usage: lidwake config [<key> [<value>]]")
        }
    }

    private static func parse(_ text: String, like current: Any) -> Any? {
        if let number = current as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                switch text.lowercased() {
                case "true", "on", "yes", "1": return true
                case "false", "off", "no", "0": return false
                default: return nil
                }
            }
            return Double(text).map { $0.rounded() == $0 && !text.contains(".") ? Int($0) as Any : $0 as Any }
        }
        return text
    }

    private static func kind(of value: Any) -> String {
        if let n = value as? NSNumber {
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? "true or false" : "a number"
        }
        return "text"
    }

    private static func format(_ value: Any) -> String {
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return n.boolValue ? "true" : "false"
        }
        return "\(value)"
    }

    private static func unknown(_ key: String, in dict: [String: Any]) -> Never {
        ControlCommands.fail("unknown setting '\(key)'. Known: \(dict.keys.sorted().joined(separator: ", "))")
    }
}
