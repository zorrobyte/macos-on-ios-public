#!/bin/bash
# Convert a Mac app, install it on the iPad, launch it and print its console.
# usage: UDID=<device> run_app.sh <Mac.app> <bundle-id> [seconds=10]   (SKIP_CONVERT=1 reuses the last build)
# The launch returns as soon as the app exits, or after <seconds>.
set -eo pipefail
cd "$(dirname "$0")"
MAC_APP=$1; BID=$2; SECS=${3:-10}
UDID=${UDID:?set UDID (xcrun devicectl list devices)}
T=${T:-${TMPDIR:-/tmp/}macos-on-ios}
OUT=$T/$BID/$(basename "$MAC_APP")
PROFILE=${PROFILE:-$T/profiles/$BID.mobileprovision}  # tools/make_profile.sh <bundle-id> makes it
if [ -z "$SKIP_CONVERT" ]; then  # (not "a || b": set -e ignores failures there)
  python3 -I -u convert_app.py "$MAC_APP" "$OUT" "$BID" --profile "$PROFILE" $CONVERT_ARGS | tail -3
fi
xcrun devicectl device install app --device "$UDID" "$OUT" 2>&1 | grep -iE '^error|App installed' || true
# The console stream stays attached in the background (stopping it can take the app down);
# we wait until the app exits or <seconds> pass, then print what it logged so far.
LOG="$T/$BID.console.log"
nohup xcrun devicectl device process launch --device "$UDID" --terminate-existing --console \
  --environment-variables '{"MTL_HUD_ENABLED": "1"}' "$BID" > "$LOG" 2>&1 &
for _ in $(seq "$SECS"); do grep -qE 'terminated due to|exit code|ERROR: ' "$LOG" && break; /bin/sleep 1; done
grep -vE '^\s*•|^$|Waiting for the application' "$LOG" | cut -c1-300 | head -"${LINES_MAX:-60}"
grep -q 'terminated due to signal' "$LOG" && python3 -I crash.py "$(plutil -extract CFBundleExecutable raw "$OUT/Info.plist")" "$UDID" || true
