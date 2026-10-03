# lidwake

Keep your MacBook awake with the lid closed — **only while your AI agents are working** — and
watch it from the terminal.

```text
lidwake  ● ON · keeping the Mac awake                                   23:32:05
────────────────────────────────────────────────────────────────────────────────
  Lid-close sleep  blocked — closing the lid won't sleep the Mac
  Lid              closed
  Off timer        55m 17s  until 00:27
  Battery          ▕██████┃██████████████░░░░░░░░▏  71% on battery · stop at 20%
  CPU temp         ▕███████████████░░░░░░┃░░░░░░░▏  67°C warm
                   30°              80° cutout
  Thermal          ○ nominal  ● fair  ○ serious  ○ critical
────────────────────────────────────────────────────────────────────────────────
  AGENTS  3 keeping the Mac awake
  claude-code   pid 48211  working  41m
  codex         pid 48907  waiting: permission  7m
  make          pid 49120  hold  1m, 3h 56m left  lidwake run make test
────────────────────────────────────────────────────────────────────────────────
  [space] on/off  [t] timer  [+/-] ±15m  [r] release all  [q] quit
```

## Why

Close the lid of a MacBook and it sleeps — and so does the agent you left running.
`caffeinate` and every other power assertion only prevent *idle* sleep; the lid is a direct order
that outranks them. The one switch that overrides it is `pmset disablesleep 1`, and it is a
foot-gun:

- it is global and it **survives reboots** (it is stored in the power-management preferences);
- it outlives the process that set it — crash, and the Mac never sleeps again;
- while it is set, the kernel refuses even its **own emergency sleep** for overheating
  (`IOPMrootDomain::checkSystemSleepAllowed` in XNU), whatever the lid does.

lidwake flips that switch only while an agent is actually mid-task, puts it back the moment the
work ends, and keeps a safety net under it the whole time.

## Features

- **Agent-aware.** Hooks for Claude Code, Codex, Cursor, Gemini CLI, Aider, Hermes, OpenCode, Cline
  and Pi keep the Mac awake only while a turn is running; an idle session at the prompt lets it
  sleep. Process-exit and CPU-idle sweeps catch interrupted turns.
- **Live dashboard.** `lidwake stats` shows on/off, the real lid-close state, an off timer,
  battery, CPU temperature on a normal → critical scale, macOS thermal pressure and every agent
  holding the Mac awake. Keys toggle lidwake, set the timer and release holds.
- **Off timer.** `lidwake timer 1h` (or `t` in the dashboard): lidwake turns itself off at the
  deadline — even if the terminal is gone, the daemon restarted or the Mac slept in between.
- **Wrap any command.** `lidwake run -- ./long-job.sh` keeps the Mac awake exactly as long as the
  command runs and passes its exit code through.
- **Safety cutouts, lid open or closed.** Low battery (default 20%) and CPU temperature (default
  80 °C) release every hold so macOS can sleep. Optional **AC-only** mode. A cutout latches until
  the hazard recedes, so a busy agent can't immediately re-pin a hot or flat Mac.
- **Your own setting survives.** If you had `disablesleep` on before (a Mac used as a server),
  lidwake restores *that* value instead of forcing sleep back on.
- **Crash-proof.** The root helper restores the saved value at boot, on shutdown and 60 s after
  the daemon disappears.
- **Runs on macOS 14 and later**, builds from source with SwiftPM — no Xcode project, no Apple
  Developer account.

## Install

Requirements: macOS 14+, Apple Silicon or Intel, and a Swift 6.2 toolchain — Xcode 26, or on
macOS 14/15 without Xcode the [swift.org toolchain](https://www.swift.org/install/macos/), which
installs into your home folder without admin rights:

```sh
curl -fLO https://download.swift.org/swift-6.2.4-release/xcode/swift-6.2.4-RELEASE/swift-6.2.4-RELEASE-osx.pkg
installer -pkg swift-6.2.4-RELEASE-osx.pkg -target CurrentUserHomeDirectory
```

Then build and install (asks for your password once, for the root helper):

```sh
git clone https://github.com/nikitaShakhbazyan/lidwake.git
cd lidwake
make install            # builds, signs ad-hoc, installs the helper, the daemon and the CLI
lidwake install-hooks   # wires lidwake into the agents it finds (--dry-run to preview)
lidwake stats
```

`make` picks up the swift.org toolchain from `~/Library/Developer/Toolchains` automatically.

## Usage

```text
lidwake stats [--once]                 live dashboard; --once prints one frame
lidwake on | off                       let agents keep the Mac awake, or stop and release all
lidwake timer <duration> | off         turn lidwake off later: 30m, 1h, 1h30m
lidwake run [--for <d>] -- <command>   keep the Mac awake while <command> runs
lidwake hold [--for <d>] [--pid <n>]   keep it awake for a background job; prints a hold id
lidwake release <id> | --all           end a hold, or everything
lidwake config [<key> [<value>]]       show or change a setting
lidwake install-hooks | uninstall-hooks [--tool <name>] [--dry-run]
lidwake status [--json] | daemon-status | mcp | version
```

Agents that speak MCP can place holds themselves through `lidwake mcp`.

### Settings

`lidwake config` lists everything; the daemon picks changes up immediately.

| Key | Default | |
|---|---|---|
| `lowBatteryThresholdPercent` | `20` | release all holds at or below this charge on battery |
| `thermalThresholdCelsius` | `80` | release all holds at this CPU temperature |
| `safetyCutoutsWithLidOpen` | `true` | run both cutouts with the lid open too |
| `requireACPower` | `false` | keep the Mac awake on AC power only |
| `manualHoldMaxHours` | `4` | cap for `hold` and `run` |
| `idleReleaseSeconds` | `90` | drop a hold whose agent has been CPU-idle this long |
| `lockOnLidClose` | `true` | lock the screen when the lid closes over a working agent |
| `agentWaitingPolicy` | `grace` | while an agent waits for you: `keepAwake`, `grace` or `sleep` |

## How it works

Three processes, three privilege levels:

```text
lidwake (CLI) ──unix socket──▶ lidwake-daemon (you, LaunchAgent) ──XPC──▶ lidwake-helper (root, LaunchDaemon)
  hooks, stats, run              holds, timer, cutouts, lid/battery/      setSleepBlocked(Bool) only:
                                 temperature monitors — all policy        pmset disablesleep + idle assertion
```

The helper is the only privileged code and holds no policy. It trusts a caller only if its
executable lives in `/usr/local/libexec/lidwake` — a directory only root can write, checked up to
`/` — and runs with the hardened runtime. That is what makes an ad-hoc, built-from-source install
safe without a Developer ID. Details: [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md).

## Things to know

- **Heat.** A closed MacBook under sustained load in a bag gets hot. The thermal cutout is a net,
  not a cooling system — leave it somewhere with air.
- **Network.** Wi-Fi stays up with the lid closed, so cloud agents keep talking to their APIs.
- `pmset -g` lists the flag as `SleepDisabled`, and only once it has been set at least once.

## Uninstall

```sh
make uninstall    # removes the hooks from agent configs, the helper, the daemon and the CLI
```

Settings and logs stay in `~/Library/Application Support/lidwake`.

## Development

```sh
make test         # 400+ unit tests, no root needed
make build        # release binaries in .build/release
```

Sources: `Sources/LidwakeKit` (policy, protocol, dashboard — where the tests point),
`Sources/LidwakeCLI`, `Sources/LidwakeDaemon`, `Sources/LidwakeHelper`.

## License

[MIT](LICENSE).
