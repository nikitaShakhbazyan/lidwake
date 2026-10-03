# Architecture

## Components

| Process | Runs as | Started by | Job |
|---|---|---|---|
| `lidwake` | you | you, agent hooks | CLI: `stats`, `on`/`off`, `timer`, `run`, `hold`, hooks, MCP server |
| `lidwake-daemon` | you | `~/Library/LaunchAgents/io.github.nikitashakhbazyan.lidwake.daemon.plist` | all policy |
| `lidwake-helper` | root | `/Library/LaunchDaemons/io.github.nikitashakhbazyan.lidwake.helper.plist` | flips the sleep block, nothing else |

Binaries live in `/usr/local/libexec/lidwake`, with `/usr/local/bin/lidwake` linking to the CLI.

- **CLI → daemon:** length-prefixed JSON over a Unix socket at
  `~/Library/Application Support/lidwake/cli.sock`. Ops: `acquire`, `release`, `hold`,
  `releaseAll`, `status`, `ping`, `pause`, `resume`, `timer`, `reloadSettings`.
- **Daemon → helper:** XPC Mach service `io.github.nikitashakhbazyan.lidwake.helper`, one
  mutating call: `setSleepBlocked(Bool)`.

## Blocking sleep

Two mechanisms, both held by the helper:

1. an `IOPMAssertion` (`PreventUserIdleSystemSleep`) for idle sleep, which the kernel drops if
   the helper dies;
2. `pmset -a disablesleep 1` for lid-close sleep. Public assertions — and so `caffeinate` — never
   override a closed lid, and the in-process IOKit routes to `SleepDisabled` either fail as root
   or don't stick. `/usr/bin/pmset` is Apple's own implementation of the whole sequence.

`disablesleep` is stored in the power-management preferences, so it outlives the helper and
survives a reboot. `SleepBlockPolicy`:

- saves the current value (`/var/db/lidwake/sleep-disabled-before`, root-only) before the first
  block and restores *that* value on release, so a Mac its owner set never to sleep stays so;
- restores a saved value when the helper starts — at boot (`RunAtLoad`) or after a crash — and
  leaves the flag alone when nothing was saved;
- re-applies the block on every repeated `set(true)`; the daemon repeats it every 60 s and on
  wake, healing anything that reset the flag.

The helper also restores on SIGTERM (shutdown, uninstall) and when no daemon has been connected
for 60 s while blocked.

## Trusting the daemon without a Developer ID

The helper must accept only our daemon. A signed build would anchor that in the Team ID, but a
built-from-source install is ad-hoc signed, and an ad-hoc binary can claim any code identifier.
`CallerVerifier` therefore trusts *location*:

- the caller's executable, resolved from its audit token, lies under
  `/usr/local/libexec/lidwake/`, and that file and every directory up to `/` are owned by root and
  not group- or world-writable — so only root could have put it there;
- the caller runs with the hardened runtime, so a user-editable LaunchAgent plist can't inject a
  library through `DYLD_INSERT_LIBRARIES`;
- its dynamic code is valid (`SecCodeCheckValidity`).

A Developer-ID-signed build keeps the stricter team-plus-identifier check.

## Knowing when agents work

- **Hooks** (`lidwake install-hooks`): each agent's own hook system calls `lidwake acquire` when a
  turn starts and `lidwake release` when it ends. Entries are tagged `_lidwake` so uninstalling
  removes exactly what was added.
- **Process exit:** kqueue `NOTE_EXIT` on the owning PID releases a hold the moment its process
  dies; `run` and `hold --pid` rely on this.
- **CPU-idle sweep:** a hold whose process tree stays under ~3% of a core for
  `idleReleaseSeconds` is dropped — the catch for an interrupted turn that fired no end hook.
- **Process sniffing** (opt-in): auto-acquire for a known agent running without hooks.

Holds are reference-counted by key; the Mac is blocked while at least one exists.

## Safety cutouts

- **Thermal:** CPU temperature from the SMC (`Tp…`/`Te…` sensors on Apple Silicon, `TC0P` on
  Intel) at or above `thermalThresholdCelsius`.
- **Low battery:** on battery at or below `lowBatteryThresholdPercent`.
- **AC only** (`requireACPower`): any battery power.

A cutout releases every hold and *latches* (`CutoutLatch`): acquires are refused until the hazard
recedes with margin (5 °C cooler, 5% more charge, or AC power), so a still-running agent can't
re-pin the Mac seconds later. With `safetyCutoutsWithLidOpen` (the default) the cutouts run whatever
the lid does — `SleepDisabled` blocks the kernel's emergency sleep with the lid open as well — and
opening the lid does not clear them. Switching a cutout off drops its latch.

## Off timer

`lidwake timer` stores a deadline in the daemon (`OffTimer`), persisted in `state.json`. At the
deadline the daemon pauses itself: every hold is released and acquires are ignored until
`lidwake on`. A deadline that passed while the Mac slept or the daemon was down fires at once.
Setting a timer turns a paused lidwake back on.

## Files

`~/Library/Application Support/lidwake/`: `config.json` (settings), `state.json` (holds, paused
bit, off timer), `cli.sock`, `events.log`.
