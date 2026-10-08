# macos-on-ios

> Unofficial project, not affiliated with or endorsed by Apple, Valve, CD PROJEKT or Sony. See
> [Legal and safety](#legal-and-safety).

Run **native Apple-silicon macOS apps and games on iPad/iPhone** without changing their code. The
game code is not recompiled or patched; only the Mach-O platform tag, load paths and signature are
adjusted, the app is re-signed with your own development certificate, and macOS-only system
libraries are redirected to shims built on UIKit and friends.

Proven so far (iPad Pro 13" M5, iPadOS 27.0.1):

- `probe/`: a plain AppKit + Metal Mac app runs, renders a macOS-compiled metallib, takes touch.
- `games/cyberpunk/`: Cyberpunk 2077 (Steam Mac build) playable with a controller: ~30-40 fps real,
  60 with frame generation (Oct 2026). Needed the address-space adapter and polling-loop support.

For games you own, on your own devices, signed with your own Apple developer account. No game
files are included; nothing here bypasses DRM, copy protection, code signing or store-client checks.

## What you need

- Mac with Apple silicon, Xcode (27.1 used) signed in to an Apple **developer** team, `brew install xcodegen`.
- An iPad/iPhone with Developer Mode on, paired with the Mac (`xcrun devicectl list devices`).
- The game installed on the Mac (native arm64 build: `lipo -archs <exe>` must include arm64).

No jailbreak, no JIT, no debugger at runtime. Native code only: Mono/JIT games (Unity Mono) do not
work this way (see "Limits").

## Quick start (toy probe)

```sh
export UDID=<device id>                        # xcrun devicectl list devices
export TEAM=<team id> IDENTITY="Apple Development: <name> (<id>)" BUNDLE_PREFIX=com.yourname
tools/make_profile.sh com.example.macprobe     # dev profile for the bundle id (once)
cd probe && ./build.sh mac shim convert install launch
```

You should see a coloured triangle full screen; taps log `PROBE mouseDown` in the console.

## Converting any Mac app

```sh
tools/make_profile.sh <bundle-id> [entitlements...]      # once per bundle id
UDID=... CONVERT_ARGS="..." tools/run_app.sh <Mac.app> <bundle-id> [seconds]
```

`run_app.sh` = `convert_app.py` (build) + `devicectl install` + launch with console + crash stack.
Useful `convert_app.py` options (pass through `CONVERT_ARGS`):

| option | why |
|---|---|
| `--exclude Resources/<dir>` | keep huge game data out of the bundle (push it once to Documents instead) |
| `--redirect /Resources/Packages=Documents/packages` | rewrite file paths containing the key to `<home>/<value>` |
| `--entitlement com.apple.developer.kernel.increased-memory-limit` | lift the ~5 GB per-app memory cap (profile must have it) |
| `--allow-network` | network is **blocked by default** (stops telemetry/crash uploads from test builds). Allowing it re-enables telemetry, crash uploads and any account traffic the game makes |
| `--no-metal-hud` | Metal performance HUD is on by default |
| `--bounded-reservations` | reduce reservations in recognized arm64 reserve helpers and update their returned bounds; see [Cyberpunk notes](games/cyberpunk/README.md) |

Scratch output goes to `$T` (default `$TMPDIR/macos-on-ios`). Logs: `$T/<bundle-id>.console.log`.
Regression check: `tools/smoke.sh [apps]` builds, installs and launches each app and passes the ones
that render frames without being killed.

## How it works

1. **Bundle layout.** iOS needs the executable at the bundle root and rejects a root `Contents/`, so
   the Mac tree goes to `<app>/Mac/Contents/...`. The shim makes `NSBundle` report `Mac/` as the
   bundle path and `Mac/Contents/Resources` as the resource path, so games find files as on macOS.
2. **Mach-O.** Every binary is thinned to arm64, `LC_BUILD_VERSION` retagged to iOS (`vtool`),
   framework paths rewritten (`Versions/X/...` to iOS paths), rpaths fixed, then dev-signed.
3. **Libraries.** `tools/gap.py` logic finds, per macOS library, what the iOS library doesn't export.
   Each such library gets `Frameworks/libShim_<Name>.dylib` that **re-exports the real iOS library**
   and adds: hand-written code from `shim/overrides/<Name>.m` / `<Name>_*.m`, plus generated logging
   stubs for the rest (`SHIM STUB` / `SHIM MISSING` in the console tell you what to implement next).
   Symbols that moved to a different iOS library are re-exported from there.
4. **App libraries** with an iOS reimplementation in `shim/replace/<name>.m` are rebuilt for iOS (none included).
5. **Info.plist.** Mac keys + iOS keys (`shim/Info-ios.plist`), scene manifest, Game Mode for games.

### Shims (shim/overrides)

| file | provides |
|---|---|
| `AppKit.m` | NSApplication/NSWindow/NSView/NSViewController/NSScreen/NSEvent/NSAlert on UIKit; nib-delegate startup; scene lifecycle to NSApplication notifications; input: touch=mouse (+hover), 2-finger/trackpad/wheel=scroll, hardware keys=Mac key events, event monitors |
| `AppKit_RuntimeHooks.m` | bundle/resource paths, Mono interp switch, network block, Metal fixes (Mac default library path, Mac2 GPU family, managed->shared storage, Mac-only methods absorbed), Metal HUD per layer |
| `AppKit_Stats.m` | `SHIM STATS fps cpu mem avail threads thermal` once a second |
| `AppKit_Flat.m` | symbols flat-namespace libraries expect from "any image" |
| `libSystem.m` | path redirects, **case-insensitive paths** inside the container (Mac games assume it) |
| `CoreGraphics.m` | display list/modes (one display, real pixels, 120 Hz) |
| `IOKit.m` | power notifications (dummy port) |
| `Security.m` | code-signing queries logged (results unchanged) |
| `libswiftCore.m` | macOS-only availability check |

## Limits

- Native arm64 Mac builds only. Intel-only Mac builds (e.g. Frostpunk) and Windows-only games: no.
- Mono/JIT runtimes need JIT, which iOS forbids; Unity's Mono interpreter-only mode crashes (tested
  with RimWorld). IL2CPP Unity Mac builds should work (native code).
- iOS kills apps that keep rendering in the background; games get NSApplication resign/hide
  notifications but some keep rendering anyway.
- iOS gives an app ~64 GB of address space (extended-virtual-addressing); engines that reserve more
  need `--bounded-reservations`, which only adapts a recognized reserve helper (Cyberpunk's).
- Games that run their own event loop work (UIKit runs on a separate stack); tested with Cyberpunk.
- DRM, anti-tamper and launcher checks (Steam, Denuvo, ...) are out of scope. Games that refuse to
  start without their store client won't run.

## Legal and safety

Not legal advice; the authors are not lawyers.

- **Your copies, your devices.** Convert only games and apps you own, install them only on devices
  you own, with your own Apple developer membership. Converted apps skip App Store review: only
  convert software you trust, and never install a converted app someone else built.
- **No redistribution.** Don't share converted or re-signed apps, IPAs or provisioning profiles, don't
  use enterprise certificates, and don't submit converted apps to the App Store or TestFlight.
- **Platform rules.** This works only through Apple-issued development signing and the entitlements
  Apple grants your profile; it does not bypass code signing, provisioning or entitlement checks and
  does not jailbreak. Running a game on a platform its publisher doesn't support may breach the game's
  EULA or store terms (e.g. Steam Subscriber Agreement); that is between you and them.
- **Out of scope.** DRM, anti-tamper, license and store-client checks. Games that need their store
  client running won't start, and contributions that work around such checks won't be accepted.
- **Trademarks.** Apple, macOS, iOS, iPadOS, iPad, iPhone, Metal and Xcode are trademarks of Apple
  Inc.; Steam of Valve Corporation; Cyberpunk 2077 of CD PROJEKT S.A.; DualSense of Sony Interactive
  Entertainment. Names are used only to describe compatibility.
- **License.** MIT (see LICENSE) covers this repository's code only, not any game or Apple software.
