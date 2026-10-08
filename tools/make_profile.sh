#!/bin/bash
# Get a development provisioning profile for <bundle-id> (optionally with extra boolean
# entitlements) by letting Xcode's automatic signing build a throwaway app for the device.
# Xcode registers the App ID, enables the capabilities and downloads the profile.
# Profiles are per developer and per device: never share or redistribute them.
# usage: UDID=<device> TEAM=<team id> make_profile.sh <bundle-id> [entitlement ...]
#   e.g. make_profile.sh com.example.mygame \
#          com.apple.developer.kernel.increased-memory-limit com.apple.developer.kernel.extended-virtual-addressing
# Output: $T/profiles/<bundle-id>.mobileprovision   (needs: brew install xcodegen; Xcode signed in)
set -eo pipefail
BID=${1:?bundle id}; shift
UDID=${UDID:?set UDID (xcrun devicectl list devices)}
TEAM=${TEAM:?set TEAM to your Apple developer Team ID}
T=${T:-${TMPDIR:-/tmp/}macos-on-ios}
W="$T/profilegen/$BID"; mkdir -p "$W/Src" "$T/profiles"; cd "$W"
printf '@main struct A { static func main() {} }\n' > Src/main.swift
cat > project.yml <<YML
name: ProfileGen
targets:
  App:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources: [Src]
    settings: {PRODUCT_BUNDLE_IDENTIFIER: $BID, DEVELOPMENT_TEAM: $TEAM, CODE_SIGN_STYLE: Automatic, GENERATE_INFOPLIST_FILE: YES}
YML
if [ $# -gt 0 ]; then
  printf '    entitlements:\n      path: Src/app.entitlements\n      properties:\n' >> project.yml
  for e in "$@"; do echo "        $e: true" >> project.yml; done
fi
xcodegen -q
# The throwaway app may fail to compile/link; only its embedded profile matters.
xcodebuild -project ProfileGen.xcodeproj -scheme App -configuration Debug -destination "id=$UDID" \
  -derivedDataPath dd -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > build.log 2>&1 || true
P=$(find dd -path '*Debug-iphoneos/App.app/embedded.mobileprovision' | head -1)
[ -n "$P" ] || { echo "no profile produced; see $W/build.log"; exit 1; }
cp "$P" "$T/profiles/$BID.mobileprovision"
security cms -D -i "$T/profiles/$BID.mobileprovision" | plutil -extract Entitlements xml1 -o - - | grep -oE '<key>[^<]+' | sed 's/<key>/  /'
echo "-> $T/profiles/$BID.mobileprovision"
