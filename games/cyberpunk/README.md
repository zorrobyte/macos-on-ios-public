# Cyberpunk 2077

Steam Mac build (native arm64). Status Oct 2026, iPad Pro 13" M5 16 GB, iPadOS 27.0.1: playable.
Menus, saves from the Mac, driving and combat with a DualSense. ~30-40 fps in the world (mostly Low,
50-65% dynamic resolution, no RT), 60 fps with FSR 3 frame generation. App ~8.3 GB.

Unofficial notes; not affiliated with or endorsed by CD PROJEKT or Valve. Requires your own copy of
the game; no game files are included. The game runs with its own unmodified Steam library
(`--keep-original libsteam_api`); no Steam, DRM or integrity-check workaround is included.

## Setup

1. `export UDID=<device> TEAM=<team id> IDENTITY="Apple Development: <name> (<id>)" BUNDLE_PREFIX=com.yourname`
2. Profile with both memory entitlements (a paid developer team; wildcard profiles can't carry them):
   `tools/make_profile.sh $BUNDLE_PREFIX.cyberpunk com.apple.developer.kernel.increased-memory-limit com.apple.developer.kernel.extended-virtual-addressing`
   Apple grants these per profile and may deny or revoke them.
3. `games/cyberpunk/run.sh 60` once (creates the app container; quits without data).
4. Push the data that sits **next to** the Mac app (~83 GB, ~2 min over USB) to `Documents/cyberpunk/`:
   ```sh
   C="$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"
   for d in engine r6 archive; do xcrun devicectl device copy to --device $UDID --domain-type appDataContainer \
     --domain-identifier $BUNDLE_PREFIX.cyberpunk --source "$C/$d" --destination "Documents/cyberpunk/$d"; done
   ```
5. Optional, to bring your Mac saves: copy `~/Library/Application Support/CD Projekt Red/Cyberpunk 2077/saves`
   to the same path under the app container's `Library/Application Support/`. Accept the game's EULA
   when it asks on the iPad.
6. `games/cyberpunk/run.sh 60`, or tap the icon.
7. In game: Graphics -> **V-Sync Off** (the auto preset picks a 30 fps V-Sync lock).

## What it took (symptom -> fix)

| symptom | fix |
|---|---|
| dyld rejects a bundled video library (misaligned LINKEDIT string pool) | `tools/macho.py` realigns it during conversion |
| startup memory reservations fail (iOS leaves ~64 GB of address space; the game reserves more) | `--bounded-reservations`: the mmap shim grants smaller reservations and reports the granted bounds; the game binary is not modified (`shim/overrides/libSystem_Reservations.m`) |
| exits right after polling for events | the game runs its own loop: UIKit starts on its own stack at the first poll |
| black screen after startup | full-screen notifications are posted |
| data not found | data lives beside the .app: `--redirect-app-parent Documents/cyberpunk` |
| controller ignored | UIKit never parks inside a main-queue block; controllers are re-announced after launch |
| 30 fps with GPU headroom | in-game V-Sync setting |

Debugging: `--trace CLASS.SELECTOR`, `tools/lldb_threads.py`, the `SHIM STATS` line.
Tests for the reservation adapter: `python3 -m unittest discover -s tools -p 'test_*.py' -v`.
