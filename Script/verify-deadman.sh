#!/bin/bash
# Verify the safety claim that matters: if LidCode dies while the lid is held shut,
# does the Mac get its normal sleep back?
#
# This is the difference between LidCode and a raw `pmset -a disablesleep 1`. If this
# test fails, closed-lid mode is not safe to rely on overnight — do not use it until
# it passes.
#
# Requires: the helper installed (Script/install-helper.sh) and LidCode.app running.
# Asks for sudo only to read/clear the setting if something goes wrong.
set -uo pipefail

cd "$(dirname "$0")/.."
LIDCODE="${LIDCODE:-.build/release/lidcode}"
DEADMAN_SECOND=15

fail() { echo "FAIL: $*" >&2; exit 1; }

disablesleep_state() {
  pmset -g | grep -i disablesleep | tr -d ' ' | tail -c 2
}

echo "==> preflight"
[[ -x "$LIDCODE" ]]                          || fail "no lidcode binary at $LIDCODE (swift build -c release)"
[[ -S /var/run/lidcode-helper.sock ]]        || fail "helper not running — Script/install-helper.sh"
pgrep -x LidCode >/dev/null                  || fail "LidCode.app not running — open dist/LidCode.app"
[[ "$(disablesleep_state)" != "1" ]]       || fail "disablesleep is already 1 before we start"
echo "    ok"

echo "==> turning closed-lid mode on"
"$LIDCODE" lid on --timer 30m || fail "could not enable closed-lid mode"
sleep 2

STATE="$(disablesleep_state)"
[[ "$STATE" == "1" ]] || fail "disablesleep should be 1, got '${STATE:-unset}'"
echo "    disablesleep = 1"

echo "==> simulating a crash (kill -9 LidCode)"
pkill -9 -x LidCode
echo "    app killed; helper should revert on socket close, well inside ${DEADMAN_SECOND}s"

for i in $(seq 1 $((DEADMAN_SECOND + 5))); do
  if [[ "$(disablesleep_state)" != "1" ]]; then
    echo
    echo "PASS: disablesleep reverted to 0 after ${i}s (deadman window ${DEADMAN_SECOND}s)"
    echo "      A crash cannot leave this Mac unable to sleep."
    exit 0
  fi
  printf '\r    waiting… %ds' "$i"
  sleep 1
done

echo
echo "!! disablesleep is STILL 1 after $((DEADMAN_SECOND + 5))s — clearing it by hand"
sudo pmset -a disablesleep 0
fail "deadman switch did not fire. Closed-lid mode is NOT safe to use until this passes.
      Check: sudo launchctl print system/com.lidcode.helper
             tail /var/log/lidcode-helper.log"
