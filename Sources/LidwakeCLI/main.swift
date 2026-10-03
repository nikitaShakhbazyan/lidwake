import LidwakeKit
import Foundation

// A SIGPIPE (daemon closed the socket mid-write, MCP client closed stdout) would kill the
// process by signal — which an agent hook reports as a hard failure. Write errors are handled
// at the call sites instead.
signal(SIGPIPE, SIG_IGN)

let args = Array(CommandLine.arguments.dropFirst())

guard let first = args.first else {
    CLIUsage.printShortUsage()
    exit(1)
}

let rest = Array(args.dropFirst())

do {
    switch first {
    case "on": ControlCommands.setOn(true)
    case "off": ControlCommands.setOn(false)
    case "timer": ControlCommands.timer(args: rest)
    case "stats", "--stats", "top": StatsCommand.run(args: rest)
    case "run": RunCommand.run(args: rest)
    case "config": ConfigCommand.run(args: rest)
    case "acquire": try AcquireCommand.run(args: rest)
    case "hold": try HoldCommand.run(args: rest)
    case "release": try ReleaseCommand.run(args: rest)
    case "status": try StatusCommand.run(args: rest)
    case "install-hooks": try InstallHooksCommand.run(args: rest)
    case "uninstall-hooks": try UninstallHooksCommand.run(args: rest)
    case "daemon-status": try DaemonStatusCommand.run(args: rest)
    case "mcp": MCPServer.run(args: rest)
    case "version", "--version", "-v":
        print("lidwake \(LidwakeConstants.marketingVersion)")
    case "help", "--help", "-h":
        CLIUsage.printFullUsage()
    default:
        FileHandle.standardError.write(Data("Unknown command: \(first)\n".utf8))
        CLIUsage.printShortUsage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

enum CLIUsage {
    static func printShortUsage() {
        print("""
        usage: lidwake <command> [args]
        commands: stats | on | off | timer | run | config | hold | release | status | acquire | install-hooks | uninstall-hooks | daemon-status | mcp | version
        """)
    }
    static func printFullUsage() {
        print("""
        lidwake — keep your Mac awake only while AI agents are working, lid closed or not

        USAGE:
          lidwake stats [--once]                 live dashboard (space on/off, t timer, r release, q quit)
          lidwake on | off                       let agents keep the Mac awake, or stop and release all
          lidwake timer <duration> | off         turn off automatically, e.g. lidwake timer 1h
          lidwake run [--for <d>] -- <command>   keep the Mac awake while <command> runs
          lidwake config [<key> [<value>]]       show or change a setting
          lidwake hold [--reason <text>] [--for <duration>] [--pid <n>] [--tool <name>] [--display]
          lidwake release <hold-id | session-key> | --all
          lidwake acquire <session-key> --tool <name> [--reason <text>] [--ttl <seconds>] [--display]
          lidwake status [--json]
          lidwake install-hooks [--tool <name>] [--dry-run]
          lidwake uninstall-hooks [--tool <name>] [--dry-run]
          lidwake daemon-status
          lidwake mcp
          lidwake version
        
        AGENT HOLDS:
          `hold` keeps the Mac awake past the end of your turn — for a background job you
          kicked off — and prints a hold id. The hold ends when you `release <id>`, when the
          --pid you named exits, or when its time runs out (default 1h, capped in settings).
        
            HOLD=$(lidwake hold --reason "running migration" --for 30m)
            ./migrate.sh
            lidwake release "$HOLD"
        
          --display additionally keeps the DISPLAY awake (and wakes it if dark) — for agents
          that read the screen: a sleeping display collapses every app's accessibility tree,
          so a system-only hold keeps the machine on while blinding the agent.
        
        `acquire`/`release` are the reference-counted hooks wired into agents at setup.
        `release` accepts a key in any form `status --json` prints: a bare session id, the
        prefixed `<tool>:<session>`, a `sniffed:` key, or a `hold:` id. Releasing a key that
        matches nothing warns and exits 1 at a TTY (hooks always exit 0).
        `mcp` runs a Model Context Protocol server exposing holds as agent-callable tools.
        """)
    }
}
