#!/usr/bin/env bash
# Runs both suites. Set GODOT to your binary if it is not on the PATH.
set -u
GODOT="${GODOT:-godot}"
cd "$(dirname "$0")"

"$GODOT" --headless --path . --import >/dev/null 2>&1   # build the class cache

echo "=== core ==="
"$GODOT" --headless --path . --script res://tests/test_runner.gd 2>&1 | grep -v "ALSA\|pulse"
core=${PIPESTATUS[0]}

echo
echo "=== interface ==="
"$GODOT" --headless --path . --script res://tests/smoke_ui.gd 2>&1 | grep -v "ALSA\|pulse"
ui=${PIPESTATUS[0]}

exit $(( core + ui ))
