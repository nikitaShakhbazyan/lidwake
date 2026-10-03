#!/bin/bash
#
# Installs the headless lidwake (CLI + per-user daemon + root helper) from .build/release:
#
#   /usr/local/libexec/lidwake/           root-owned binaries; the helper trusts only a daemon
#                                         that runs from here, so this directory must stay
#                                         writable by root alone
#   /usr/local/bin/lidwake                symlink to the CLI
#   /Library/LaunchDaemons/<label>.helper.plist   root helper (pmset disablesleep)
#   ~/Library/LaunchAgents/<label>.daemon.plist   policy daemon for the current user
#
#   scripts/install.sh              install or upgrade (run `make build` first)
#   scripts/install.sh --uninstall  remove agent hooks and everything above

set -euo pipefail

LABEL=io.github.nikitashakhbazyan.lidwake
LIBEXEC=/usr/local/libexec/lidwake
BIN_LINK=/usr/local/bin/lidwake
HELPER_PLIST=/Library/LaunchDaemons/$LABEL.helper.plist
DAEMON_PLIST=$HOME/Library/LaunchAgents/$LABEL.daemon.plist
BUILD_DIR=${BUILD_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.build/release}
GUI=gui/$(id -u)

say() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -ne 0 ] || {
	echo "run as your own user, not root: the daemon is installed for whoever runs this" >&2
	exit 1
}

stop_all() {
	# Daemon first: on SIGTERM it tells the helper to restore the sleep setting.
	launchctl bootout "$GUI/$LABEL.daemon" 2>/dev/null || true
	sudo launchctl bootout "system/$LABEL.helper" 2>/dev/null || true
}

if [ "${1:-}" = --uninstall ]; then
	if [ -x "$LIBEXEC/lidwake" ]; then
		say "removing lidwake hooks from agent configs"
		"$LIBEXEC/lidwake" uninstall-hooks || true
	fi
	stop_all
	rm -f "$DAEMON_PLIST"
	sudo rm -f "$HELPER_PLIST" "$BIN_LINK"
	sudo rm -rf "$LIBEXEC"
	say "lidwake removed. Settings and logs stay in ~/Library/Application Support/lidwake."
	exit 0
fi

for b in lidwake lidwake-daemon lidwake-helper; do
	[ -x "$BUILD_DIR/$b" ] || {
		echo "missing $BUILD_DIR/$b — run 'make build' first" >&2
		exit 1
	}
done

say "stopping a running lidwake, if any"
stop_all

# Ad-hoc signatures with the hardened runtime: the helper only trusts a hardened daemon running
# from $LIBEXEC, and the runtime keeps DYLD_INSERT_LIBRARIES out of it.
say "signing (ad-hoc, hardened runtime)"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$BUILD_DIR/lidwake" "$BUILD_DIR/lidwake-daemon" "$BUILD_DIR/lidwake-helper" "$STAGE/"
codesign --force --sign - --options runtime --identifier "$LABEL" "$STAGE/lidwake"
codesign --force --sign - --options runtime --identifier "$LABEL.daemon" "$STAGE/lidwake-daemon"
codesign --force --sign - --options runtime --identifier "$LABEL.helper" "$STAGE/lidwake-helper"

say "installing binaries into $LIBEXEC"
sudo install -d -o root -g wheel -m 755 /usr/local/libexec "$LIBEXEC" /usr/local/bin
sudo install -o root -g wheel -m 755 "$STAGE/lidwake" "$STAGE/lidwake-daemon" "$STAGE/lidwake-helper" "$LIBEXEC/"
sudo ln -sfn "$LIBEXEC/lidwake" "$BIN_LINK"

# The helper refuses a daemon whose path anyone but root could have changed.
for d in / /usr /usr/local /usr/local/libexec "$LIBEXEC" "$LIBEXEC/lidwake-daemon"; do
	read -r owner mode <<<"$(stat -f '%Su %Lp' "$d")"
	if [ "$owner" != root ] || [ $((8#$mode & 8#022)) -ne 0 ]; then
		echo "warning: $d is owned by $owner with mode $mode — the helper will not trust the daemon." >&2
		echo "         Make it root-owned and not group/world-writable (e.g. sudo chown root:wheel $d; sudo chmod go-w $d)." >&2
	fi
done

say "registering the root helper"
sudo tee "$HELPER_PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL.helper</string>
	<key>Program</key>
	<string>$LIBEXEC/lidwake-helper</string>
	<key>MachServices</key>
	<dict>
		<key>$LABEL.helper</key>
		<true/>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$HELPER_PLIST"
sudo chmod 644 "$HELPER_PLIST"
sudo launchctl bootstrap system "$HELPER_PLIST"

say "registering the daemon for $(id -un)"
mkdir -p "$(dirname "$DAEMON_PLIST")"
cat >"$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL.daemon</string>
	<key>Program</key>
	<string>$LIBEXEC/lidwake-daemon</string>
	<key>MachServices</key>
	<dict>
		<key>$LABEL.daemon</key>
		<true/>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
EOF
launchctl bootstrap "$GUI" "$DAEMON_PLIST"

say "done — try: lidwake status"
