#!/bin/bash
# Cyberpunk 2077 (Steam Mac build) on an iPad: convert + install + launch.
# One-time setup in this folder's README.md (profile with memory entitlements, data push).
# usage: UDID=<device> games/cyberpunk/run.sh [seconds to watch the console, default 30]
cd "$(dirname "$0")"
export CONVERT_ARGS="${EXTRA_ARGS:-} --keep-original libsteam_api --bounded-reservations \
  --redirect-app-parent Documents/cyberpunk \
  --trace GameApplicationDelegate.controllerDidConnect: --trace GameApplicationDelegate.setupController: \
  --trace GameApplicationDelegate.mouseDidConnect: --trace GameView.mouseEntered: --trace GameView.mouseDown: \
  --trace GameView.handleWindowDidBecameKey --trace GameWindowDelegate.windowDidBecomeKey: \
  --trace GameApplicationDelegate.applicationDidFinishLaunching: --trace GameApplicationDelegate.setupControllerNotifications \
  --trace GameApplicationDelegate.assignControllerToPlayers --trace GameApplicationDelegate.setupTimer \
  --trace GameView.scrollWheel: --trace GameView.mouseDragged: --trace GameView.mouseMoved: \
  --entitlement com.apple.developer.kernel.increased-memory-limit \
  --entitlement com.apple.developer.kernel.extended-virtual-addressing"
GAME=${GAME:-"$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app"}
exec ../../tools/run_app.sh "$GAME" "${BUNDLE_PREFIX:-com.example}.cyberpunk" "${1:-30}"
