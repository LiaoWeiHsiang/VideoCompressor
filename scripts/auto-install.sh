#!/usr/bin/env bash
#
# Keep every paired iPhone on a fresh build, without being asked.
#
# Runs often (launchd fires it every 30 minutes) but works at most once a day per phone:
# the point is that a phone which was away all night still gets today's build the moment it
# comes back on the network, not that the build runs 48 times.
#
#   ./scripts/auto-install.sh              one pass — install anywhere it is due
#   ./scripts/auto-install.sh --force      ignore the once-a-day rule (for testing)
#   ./scripts/auto-install.sh --status     when each phone was last done, and what is due
#   ./scripts/auto-install.sh --enable     install the launchd job (every 30 min)
#   ./scripts/auto-install.sh --disable    remove it
#
# It never launches the app on the phone and never touches a phone it cannot reach, so it
# is safe to leave running.
#
set -uo pipefail          # deliberately not -e: one unreachable phone must not abort the run

cd "$(dirname "$0")/.."
REPO="$PWD"

STATE_DIR="$HOME/Library/Application Support/VideoCompressor-autoinstall"
LOG="$HOME/Library/Logs/VideoCompressor-autoinstall.log"
LABEL="com.weihsiangliao.videocompressor.autoinstall"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL_SECONDS=1800     # how often launchd asks; the daily guard decides what happens
MIN_GAP_SECONDS=$(( 20 * 3600 ))   # "once a day", with slack so a 24h cadence never slips a day

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

# Keep the log from growing without bound — this runs 48 times a day, forever.
if [[ -f "$LOG" ]] && (( $(wc -c < "$LOG") > 1048576 )); then
  tail -c 262144 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# ── Devices ───────────────────────────────────────────────────────────────────
list_devices() {
  local out; out=$(mktemp)
  xcrun devicectl list devices --json-output "$out" >/dev/null 2>&1 || true
  python3 -c '
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
for d in devices:
    hardware = d.get("hardwareProperties", {})
    udid = hardware.get("udid")
    if udid:
        print("\t".join([udid,
                         d.get("deviceProperties", {}).get("name", "?"),
                         hardware.get("marketingName", "?")]))
' "$out"
  rm -f "$out"
}

# `info details` answers from the pairing database even for a phone that is switched off;
# `lockState` has to reach the hardware, so it fails exactly when an install would.
reachable() {
  xcrun devicectl device info lockState --device "$1" --timeout 20 >/dev/null 2>&1
}

stamp_file() { echo "$STATE_DIR/$1.last"; }

due() {
  local stamp; stamp=$(stamp_file "$1")
  [[ "${FORCE:-0}" == "1" ]] && return 0
  [[ -f "$stamp" ]] || return 0
  local last; last=$(cat "$stamp" 2>/dev/null || echo 0)
  (( $(date +%s) - last >= MIN_GAP_SECONDS ))
}

# ── Subcommands ───────────────────────────────────────────────────────────────
FORCE=0
case "${1:-}" in
  --force) FORCE=1 ;;
  --status)
    printf '%-20s %-10s %s\n' MODEL DUE 'LAST INSTALL'
    while IFS=$'\t' read -r udid name model; do
      [[ -z "$udid" ]] && continue
      stamp=$(stamp_file "$udid")
      if [[ -f "$stamp" ]]; then
        # Not `date -r`: BSD date reads that as an epoch, GNU date (which is what is on
        # PATH here, via Homebrew) reads it as a filename and errors.
        when=$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%d %H:%M'))" "$(cat "$stamp")")
      else
        when="never"
      fi
      if due "$udid"; then verdict="yes"; else verdict="no"; fi
      printf '%-20s %-10s %s\n' "$model" "$verdict" "$when"
    done < <(list_devices)
    echo
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      echo "launchd job: loaded (every $((INTERVAL_SECONDS / 60)) min)"
    else
      echo "launchd job: not loaded — ./scripts/auto-install.sh --enable"
    fi
    echo "log: $LOG"
    exit 0
    ;;
  --enable)
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$REPO/scripts/auto-install.sh</string>
    </array>
    <key>StartInterval</key><integer>$INTERVAL_SECONDS</integer>
    <key>RunAtLoad</key><true/>
    <!-- A LaunchAgent, not a LaunchDaemon: signing needs the login keychain, which is
         locked when nobody is logged in. See the note in --help. -->
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityIO</key><true/>
    <key>Nice</key><integer>5</integer>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
    <key>WorkingDirectory</key><string>$REPO</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$PLIST" || {
      echo "error: launchctl bootstrap failed" >&2; exit 1; }
    echo "Enabled. Checks every $((INTERVAL_SECONDS / 60)) minutes, installs at most once a day per phone."
    echo "  status:  ./scripts/auto-install.sh --status"
    echo "  log:     $LOG"
    exit 0
    ;;
  --disable)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    rm -f "$PLIST"
    echo "Disabled."
    exit 0
    ;;
  -h|--help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Logged out: this cannot work, and the reason is not fixable here. Signing a build needs
the Apple Development private key from the login keychain, which macOS locks when nobody
is logged in — codesign would fail every time. A locked screen is fine (the keychain stays
unlocked), so leaving the Mac logged in with the display asleep does what you want.
EOF
    exit 0
    ;;
  "") ;;
  *) echo "error: unknown option $1" >&2; exit 1 ;;
esac

# ── One pass ──────────────────────────────────────────────────────────────────
BUILT=0        # build once per run, however many phones are waiting for it

while IFS=$'\t' read -r udid name model; do
  [[ -z "$udid" ]] && continue

  due "$udid" || continue
  reachable "$udid" || continue

  log "$model ($udid) is due and reachable — installing"

  # Signing fails with a clear message when the keychain is locked; catch it here so the
  # log says why rather than burying it in xcodebuild output.
  if ! security show-keychain-info ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    log "  skipped: the login keychain is locked, so the build cannot be signed"
    continue
  fi

  if (( BUILT == 0 )); then
    if ! DEVICE_ID="$udid" SKIP_LAUNCH=1 "$REPO/scripts/build.sh" --install >> "$LOG" 2>&1 < /dev/null; then
      log "  FAILED: build or install returned non-zero"
      continue
    fi
    BUILT=1
  else
    # Second phone in the same pass: the .app is already built and signed, so just push it.
    APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
          -maxdepth 5 -path '*/Build/Products/Debug-iphoneos/VideoCompressor.app' \
          -print 2>/dev/null | head -1)
    installed=0
    for attempt in 1 2 3; do
      if [[ -n "$APP" ]] && xcrun devicectl device install app --device "$udid" "$APP" >> "$LOG" 2>&1 < /dev/null; then
        installed=1; break
      fi
      sleep $(( attempt * 5 ))
    done
    if (( installed == 0 )); then
      log "  FAILED: could not install the existing build"
      continue
    fi
  fi

  date +%s > "$(stamp_file "$udid")"
  log "  done"
done < <(list_devices)

exit 0
