# Changelog

## 0.1.0 — unreleased

First release.

- Keeps a MacBook awake with the lid closed only while AI agents work, via hooks for Claude Code,
  Codex, Cursor, Gemini CLI, Aider, Hermes, OpenCode, Cline and Pi, plus an MCP server.
- `lidwake stats`: live terminal dashboard — on/off, lid-close state, off timer, battery, CPU
  temperature against the cutout, thermal pressure, agents.
- `lidwake on | off`, `lidwake timer <duration>`, `lidwake run -- <command>`, `lidwake config`.
- Restores the `disablesleep` value the Mac had before instead of forcing it off.
- Low-battery and thermal cutouts also with the lid open; optional AC-only mode.
- Builds with SwiftPM on macOS 14+; installs without a Developer ID, the helper trusting only a
  hardened daemon from a root-only directory.
