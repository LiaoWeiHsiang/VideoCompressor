#!/usr/bin/env bash
#
# One command: build VideoCompressor and put it on an iPhone — over Wi-Fi if the phone is
# not plugged in.
#
#   ./scripts/deploy.sh                 build and install on the remembered device
#   ./scripts/deploy.sh 11              …on the first device matching "11" (name or model)
#   ./scripts/deploy.sh --list          show paired devices and whether each is reachable
#   ./scripts/deploy.sh --fast          skip the build, reinstall the last one that was built
#   ./scripts/deploy.sh --wait 120      wait up to 120s for a sleeping phone to answer
#
# Wi-Fi install needs one manual step, once per phone. `--list` says whether it is done.
#
set -euo pipefail

cd "$(dirname "$0")/.."

REMEMBERED=".deploy-device"      # gitignored; holds the last UDID used
WAIT_SECONDS=45
DO_BUILD=1
MATCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)  ACTION=list; shift ;;
    --fast)  DO_BUILD=0; shift ;;
    --wait)  WAIT_SECONDS="${2:?--wait needs a number of seconds}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)      echo "error: unknown option $1" >&2; exit 1 ;;
    *)       MATCH="$1"; shift ;;
  esac
done

command -v xcrun >/dev/null || { echo "error: xcrun not found" >&2; exit 1; }

# ── Device inventory ──────────────────────────────────────────────────────────
# JSON, not the human-readable table: the column layout is not a stable interface, and
# device names containing spaces (or CJK, which the table mangles into ????) break parsing.
devices_json() {
  local out; out=$(mktemp)
  xcrun devicectl list devices --json-output "$out" >/dev/null 2>&1 || true
  cat "$out"; rm -f "$out"
}

# Prints: udid<TAB>name<TAB>model
list_devices() {
  devices_json | python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)["result"]["devices"]
except Exception:
    sys.exit(0)
for d in devices:
    hardware = d.get("hardwareProperties", {})
    udid = hardware.get("udid")
    if not udid:
        continue
    name = d.get("deviceProperties", {}).get("name", "?")
    model = hardware.get("marketingName", "?")
    print("\t".join([udid, name, model]))
'
}

# Whether the device answers at all right now — over USB or over the network, whichever it
# has. This is the check that matters: a phone that is paired but asleep, on another
# network, or never enabled for wireless debugging all fail here, and the fix differs.
#
# `info details` is NOT usable for this. Its own help says it returns "the best information
# available" when it cannot connect, so it succeeds for a phone that is switched off — it
# reports a paired device from the database, not a live one. `lockState` has to reach the
# hardware to answer, so it fails exactly when an install would.
reachable() {
  xcrun devicectl device info lockState --device "$1" --timeout 20 >/dev/null 2>&1
}

if [[ "${ACTION:-}" == "list" ]]; then
  printf '%-38s %-20s %-10s %s\n' UDID MODEL REACHABLE NAME
  while IFS=$'\t' read -r udid name model; do
    [[ -z "$udid" ]] && continue
    if reachable "$udid"; then state="yes"; else state="no"; fi
    printf '%-38s %-20s %-10s %s\n' "$udid" "$model" "$state" "$name"
  done < <(list_devices)
  exit 0
fi

# ── Pick a device ─────────────────────────────────────────────────────────────
TARGET=""
TARGET_NAME=""

pick_matching() {
  local needle="$1"
  while IFS=$'\t' read -r udid name model; do
    [[ -z "$udid" ]] && continue
    if [[ "$udid" == *"$needle"* || "$name" == *"$needle"* || "$model" == *"$needle"* ]]; then
      TARGET="$udid"; TARGET_NAME="$name ($model)"; return 0
    fi
  done < <(list_devices)
  return 1
}

if [[ -n "$MATCH" ]]; then
  pick_matching "$MATCH" || { echo "error: no paired device matches \"$MATCH\"." >&2
                              echo "       ./scripts/deploy.sh --list  to see what is paired." >&2
                              exit 1; }
elif [[ -f "$REMEMBERED" ]] && pick_matching "$(cat "$REMEMBERED")"; then
  :
else
  COUNT=$(list_devices | grep -c . || true)
  if [[ "$COUNT" == "1" ]]; then
    IFS=$'\t' read -r TARGET TARGET_NAME _ < <(list_devices)
  elif [[ "$COUNT" == "0" ]]; then
    echo "error: no paired iPhone found. Plug one in once to pair it." >&2
    exit 1
  else
    echo "More than one phone is paired — say which:" >&2
    list_devices | awk -F'\t' '{ printf "  ./scripts/deploy.sh %s\t(%s, %s)\n", $2, $2, $3 }' >&2
    exit 1
  fi
fi

echo "==> Target: ${TARGET_NAME:-$TARGET}"

# ── Wait for it to answer ─────────────────────────────────────────────────────
# A phone with its screen off can take a few seconds to respond over Wi-Fi, so a single
# probe would report a working setup as broken.
if ! reachable "$TARGET"; then
  echo "==> Not answering yet; waiting up to ${WAIT_SECONDS}s (unlock the phone to speed this up)"
  DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))
  until reachable "$TARGET"; do
    if (( $(date +%s) >= DEADLINE )); then
      cat >&2 <<EOF

error: the phone never answered.

  Over Wi-Fi this usually means wireless debugging was never switched on for it.
  It is a one-time step, and it has to be done while the phone is plugged in:

    1. Plug the phone into this Mac and unlock it.
    2. Xcode ▸ Window ▸ Devices and Simulators (⇧⌘2).
    3. Select the phone, tick "Connect via network".
    4. Wait for the globe icon to appear next to it, then unplug.

  After that, check with:  ./scripts/deploy.sh --list

  Otherwise: the phone and this Mac must be on the same Wi-Fi network, the phone
  must be unlocked, and it must not be in Low Power Mode with the screen off.
EOF
      exit 1
    fi
    sleep 3
  done
fi

echo "$TARGET" > "$REMEMBERED"

# ── Build and install ─────────────────────────────────────────────────────────
# build.sh already knows how to sign, locate the .app and launch it; DEVICE_ID stops it
# picking a different phone than the one chosen here.
export DEVICE_ID="$TARGET"

if [[ "$DO_BUILD" == "1" ]]; then
  ./scripts/build.sh --install
else
  APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -maxdepth 5 -path '*/Build/Products/Debug-iphoneos/VideoCompressor.app' \
        -print 2>/dev/null | head -1)
  [[ -n "$APP" ]] || { echo "error: no previous build found — run without --fast once." >&2; exit 1; }
  echo "==> Installing $APP"
  xcrun devicectl device install app --device "$TARGET" "$APP"
  xcrun devicectl device process launch --device "$TARGET" com.weihsiangliao.VideoCompressor
fi

cat <<EOF

Done. Installed on ${TARGET_NAME:-$TARGET}.

Free provisioning signs a build for 7 days, so this needs re-running about weekly to
keep the app launchable — that is Apple's limit, not the script's.
EOF
