#!/bin/bash
# Regression check after shim/converter changes: build, install and launch each app on the iPad.
# Pass = it renders (NEED "SHIM STATS fps>0" lines) within LIMIT seconds and isn't killed.
# usage: UDID=<device> tools/smoke.sh [probe cyberpunk ...]   (default: all)
# Takes the iPad for a few minutes; the last app is left running. Details: $T/smoke-<name>.out
cd "$(dirname "$0")/.."
export UDID=${UDID:?set UDID (xcrun devicectl list devices)}
T=${T:-${TMPDIR:-/tmp/}macos-on-ios}
NEED=${NEED:-5}; LIMIT=${LIMIT:-240}
APPS=${*:-probe cyberpunk}

bid() { case $1 in probe) n=macprobe ;; *) n=$(echo "$1" | tr -d -) ;; esac; echo "${BUNDLE_PREFIX:-com.example}.$n"; }
start() {  # build + install + launch; the console keeps streaming into $T/<bid>.console.log
  case $1 in
    probe) probe/build.sh mac && tools/run_app.sh "$T/MacProbe.app" "$(bid probe)" 3 ;;
    *)     "games/$1/run.sh" 3 ;;
  esac
}

results=()
for app in $APPS; do
  b=$(bid "$app"); log="$T/$b.console.log"; t0=$(date +%s)
  echo "== $app ($b)"
  if ! start "$app" > "$T/smoke-$app.out" 2>&1; then
    results+=("$app FAIL build/install (see $T/smoke-$app.out)"); continue
  fi
  verdict="FAIL no frames after ${LIMIT}s"
  while [ $(( $(date +%s) - t0 )) -lt "$LIMIT" ]; do
    if grep -qE 'terminated due to|exit code|ERROR: ' "$log"; then
      verdict="FAIL killed: $(grep -m1 -oE 'terminated due to.*|exit code.*|ERROR: .*' "$log" | cut -c1-80)"; break
    fi
    n=$(grep -cE 'SHIM STATS fps=[1-9]' "$log")
    if [ "$n" -ge "$NEED" ]; then
      last=$(grep -E 'SHIM STATS fps=[1-9]' "$log" | tail -1 | grep -oE 'fps=[0-9]+ .*mem=[0-9]+')
      verdict="PASS in $(( $(date +%s) - t0 ))s ($last MB)"; break
    fi
    /bin/sleep 2
  done
  echo "   $verdict"; results+=("$app $verdict")
done

echo; printf '%s\n' "${results[@]}"
! printf '%s\n' "${results[@]}" | grep -q FAIL
