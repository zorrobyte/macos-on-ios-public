#!/bin/bash
# macOS-on-iOS probe: run an unmodified macOS arm64 app on iPad via an AppKit shim.
# Steps: mac | shim | convert | install | launch   (e.g. ./build.sh mac shim convert install launch)
#   mac      build the plain macOS probe app (macapp/) against the macOS SDK
#   shim     build AppKitShim.framework for iOS
#   convert  copy the Mac binary, retag it as iOS, point AppKit at the shim, bundle + sign
set -e
cd "$(dirname "$0")"
UDID=${UDID:?set UDID (xcrun devicectl list devices)}
BID=${BUNDLE_PREFIX:-com.example}.macprobe
TEAM=${TEAM:?set TEAM to your Apple developer Team ID}
IDENTITY=${IDENTITY:?set IDENTITY to your signing identity}
T=${T:-${TMPDIR:-/tmp/}macos-on-ios}
PROFILE=${PROFILE:-$T/profiles/$BID.mobileprovision}  # ../tools/make_profile.sh $BID
MAC=$T/MacProbe.app
SHIM=$T/AppKitShim.framework
APP=$T/MacProbe-ios.app
mkdir -p "$T"

convert_binary() {  # $1 = Mach-O to rewrite in place
    vtool -set-build-version ios 17.0 27.1 -replace -output "$1" "$1"
    otool -L "$1" | tail -n +2 | awk '{print $1}' | while read -r lib; do
        case $lib in
            */AppKit.framework/*) new=@rpath/AppKitShim.framework/AppKitShim ;;
            */Cocoa.framework/*)  new=@rpath/CocoaShim.framework/CocoaShim ;;
            /System/Library/Frameworks/*.framework/Versions/*)
                name=${lib##*/}; new=/System/Library/Frameworks/$name.framework/$name ;;
            *) continue ;;
        esac
        install_name_tool -change "$lib" "$new" "$1" 2>/dev/null
    done
    install_name_tool -add_rpath @executable_path/Frameworks "$1" 2>/dev/null || true
}

for step in "$@"; do case $step in
  mac)
    mkdir -p "$MAC/Contents/MacOS" "$MAC/Contents/Resources"
    xcrun -sdk macosx clang -fobjc-arc -arch arm64 -mmacosx-version-min=14.0 \
      -framework Cocoa -framework Metal -framework QuartzCore macapp/main.m -o "$MAC/Contents/MacOS/MacProbe"
    xcrun -sdk macosx metal macapp/probe.metal -o "$MAC/Contents/Resources/probe.metallib"
    plutil -create xml1 "$MAC/Contents/Info.plist"  # tools/convert_app.py reads it
    plutil -insert CFBundleExecutable -string MacProbe "$MAC/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string $BID "$MAC/Contents/Info.plist"
    plutil -insert CFBundlePackageType -string APPL "$MAC/Contents/Info.plist" ;;
  shim)
    mkdir -p "$SHIM"
    xcrun -sdk iphoneos clang -fobjc-arc -target arm64-apple-ios17.0 -dynamiclib \
      -install_name @rpath/AppKitShim.framework/AppKitShim \
      -framework UIKit -framework QuartzCore -framework CoreGraphics -framework Foundation ../shim/overrides/AppKit.m -o "$SHIM/AppKitShim"
    plutil -create xml1 "$SHIM/Info.plist"
    plutil -insert CFBundleExecutable -string AppKitShim "$SHIM/Info.plist"
    plutil -insert CFBundleIdentifier -string $BID.appkitshim "$SHIM/Info.plist"
    plutil -insert CFBundlePackageType -string FMWK "$SHIM/Info.plist"
    plutil -insert CFBundleVersion -string 1 "$SHIM/Info.plist"
    plutil -insert CFBundleShortVersionString -string 1.0 "$SHIM/Info.plist"
    plutil -insert MinimumOSVersion -string 17.0 "$SHIM/Info.plist"
    # Cocoa umbrella: empty library that re-exports the AppKit shim
    COCOA=$T/CocoaShim.framework; mkdir -p "$COCOA"
    echo > "$T/empty.c"
    xcrun -sdk iphoneos clang -target arm64-apple-ios17.0 -dynamiclib -install_name @rpath/CocoaShim.framework/CocoaShim \
      -Wl,-reexport_library,"$SHIM/AppKitShim" "$T/empty.c" -o "$COCOA/CocoaShim"
    sed -e 's/AppKitShim/CocoaShim/g' -e 's/appkitshim/cocoashim/' "$SHIM/Info.plist" > "$COCOA/Info.plist" ;;
  convert)
    rm -rf "$APP"; mkdir -p "$APP/Frameworks"
    cp "$MAC/Contents/MacOS/MacProbe" "$APP/MacProbe"
    cp "$MAC"/Contents/Resources/* "$APP/"
    convert_binary "$APP/MacProbe"
    cp -R "$SHIM" "$T/CocoaShim.framework" "$APP/Frameworks/"
    cp ../shim/Info-ios.plist "$APP/Info.plist"
    plutil -replace CFBundleIdentifier -string $BID "$APP/Info.plist"
    cp "$PROFILE" "$APP/embedded.mobileprovision"
    sed -e "s/TEAM/$TEAM/g" -e "s/BID/$BID/g" ../shim/entitlements.plist > "$T/entitlements.plist"
    codesign -f -s "$IDENTITY" "$APP/Frameworks/AppKitShim.framework" "$APP/Frameworks/CocoaShim.framework"
    codesign -f -s "$IDENTITY" --entitlements "$T/entitlements.plist" "$APP" ;;
  install) xcrun devicectl device install app --device $UDID "$APP" ;;
  launch)  xcrun devicectl device process launch --device $UDID --terminate-existing --console $BID ;;
esac; done
