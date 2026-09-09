#!/bin/bash
#
# install-usage-agent.sh — install the usage fetcher as a launchd agent.
#
# The fetcher writes /tmp/warp-monitor-usage.json every five minutes; LidCode only
# ever reads that file. See Script/fetch-usage.py for what it does and, more
# importantly, what it refuses to write down.
#
# This runs as **you**, not as root. It has to: the credentials it reads live in
# your login keychain, and a root daemon could not reach them without a prompt.
#
# Safe to re-run. It replaces the script and the plist, then reloads the agent.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SRC="$SOURCE_DIR/fetch-usage.py"

INSTALL_DIR="$HOME/Library/Scripts/warp-monitor"
INSTALL_PATH="$INSTALL_DIR/fetch-usage.py"
LABEL="com.warp-monitor.fetch-usage"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -f "$SCRIPT_SRC" ]; then
    echo "error: $SCRIPT_SRC not found" >&2
    exit 1
fi

echo "==> Installing fetcher to $INSTALL_PATH"
mkdir -p "$INSTALL_DIR"
install -m 700 "$SCRIPT_SRC" "$INSTALL_PATH"

echo "==> Writing $PLIST_PATH"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$INSTALL_PATH</string>
    </array>

    <!-- Every five minutes. Anthropic's own windows move slowly, and launchd
         fires a missed interval once on wake rather than replaying every one
         that elapsed while the Mac was asleep. -->
    <key>StartInterval</key>
    <integer>300</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/warp-monitor-fetch-usage.stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/warp-monitor-fetch-usage.stderr.log</string>
</dict>
</plist>
PLIST

echo "==> Reloading the agent"
# `bootout` fails when nothing is loaded, which is the normal first-install case.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

echo "==> Running once now"
if /usr/bin/python3 "$INSTALL_PATH"; then
    echo "    wrote /tmp/warp-monitor-usage.json"
else
    echo "    fetcher reported a problem — see /tmp/warp-monitor-usage-error.txt" >&2
fi

echo
echo "Done. LidCode picks the file up on its next tick (within 5s)."
