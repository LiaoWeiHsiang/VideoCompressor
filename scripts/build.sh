#!/usr/bin/env bash
#
# Regenerate, build, and (optionally) install VideoCompressor on a connected iPhone.
#
# A free Apple developer account signs builds for only 7 days, so this needs re-running
# roughly weekly to keep the app launchable. That is a limitation of free provisioning,
# not of this script.
#
#   ./scripts/build.sh              build only
#   ./scripts/build.sh --install    build, then install and launch on the device
#   ./scripts/build.sh --test       build and run the test suite on the device
#
set -euo pipefail

cd "$(dirname "$0")/.."

# An explicitly-exported DEVICE_ID must beat the one in .env. `source` with `set -a`
# overwrites whatever the caller exported, so deploy.sh could pick one phone, announce it,
# and silently install on the other — the file was quietly winning.
DEVICE_ID_FROM_CALLER="${DEVICE_ID:-}"
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi
if [[ -n "$DEVICE_ID_FROM_CALLER" ]]; then
  DEVICE_ID="$DEVICE_ID_FROM_CALLER"
fi

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "error: DEVELOPMENT_TEAM is not set." >&2
  echo "       cp .env.example .env   and fill in your Apple Team ID." >&2
  exit 1
fi

for tool in xcodegen xcodebuild; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found in PATH" >&2; exit 1; }
done

# Pick the first paired device unless DEVICE_ID is already set. Parsed from JSON rather
# than the human-readable table, whose column layout is not a stable interface — and we
# specifically need the hardware UDID, which is what -destination expects.
if [[ -z "${DEVICE_ID:-}" ]]; then
  DEVICE_JSON=$(mktemp)
  trap 'rm -f "$DEVICE_JSON"' EXIT
  if xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1; then
    DEVICE_ID=$(python3 -c '
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
for d in devices:
    udid = d.get("hardwareProperties", {}).get("udid")
    if udid:
        print(udid)
        break
' "$DEVICE_JSON")
  fi
fi
if [[ -z "${DEVICE_ID:-}" ]]; then
  echo "error: no connected device found. Plug in an iPhone, unlock it, and trust this Mac." >&2
  echo "       Or set DEVICE_ID=<udid> explicitly." >&2
  exit 1
fi

"$(dirname "$0")/check-tests.sh"

echo "==> Generating project (team ${DEVELOPMENT_TEAM})"
xcodegen generate

ACTION=build
case "${1:-}" in
  --test) ACTION=test ;;
esac

echo "==> Running xcodebuild $ACTION for device $DEVICE_ID"
# Unit tests only on device. The UI tests are simulator-only: a second test runner would
# claim another of the three App IDs a free developer account allows per device, and the
# flows they cover do not need real encoding hardware.
ONLY_UNIT=()
if [[ "$ACTION" == "test" ]]; then
  ONLY_UNIT=(-only-testing:VideoCompressorTests)
fi

xcodebuild \
  -project VideoCompressor.xcodeproj \
  -scheme VideoCompressor \
  -destination "id=${DEVICE_ID}" \
  -allowProvisioningUpdates \
  ${ONLY_UNIT[@]+"${ONLY_UNIT[@]}"} \
  "$ACTION"

if [[ "${1:-}" == "--install" ]]; then
  # -showBuildSettings covers every target in the scheme, so match on the product that is
  # actually an .app — picking the last FULL_PRODUCT_NAME lands on the share extension.
  # `generic/platform=iOS`, not the real device: resolving a specific destination needs the
  # phone to answer, so a Wi-Fi phone that blinked out here killed the script silently —
  # stderr discarded, `set -e` and `pipefail` doing the rest, right after BUILD SUCCEEDED.
  # The product path does not depend on which phone it is going to.
  SETTINGS_ERR=$(mktemp)
  APP=$(xcodebuild -project VideoCompressor.xcodeproj -scheme VideoCompressor \
        -destination "generic/platform=iOS" -showBuildSettings 2>"$SETTINGS_ERR" \
        | awk -F' = ' '
            / BUILT_PRODUCTS_DIR /            { dir = $2 }
            / FULL_PRODUCT_NAME /             { if ($2 ~ /\.app$/) app = $2 }
            END                               { if (app != "") print dir "/" app }')

  if [[ -z "$APP" ]]; then
    echo "error: could not locate the built .app" >&2
    sed -n '1,5p' "$SETTINGS_ERR" >&2
    rm -f "$SETTINGS_ERR"
    exit 1
  fi
  rm -f "$SETTINGS_ERR"

  echo "==> Installing $APP"
  # Over Wi-Fi the tunnel drops often enough that a single attempt is not a fair test:
  # "The device disconnected immediately after connecting" is transient and succeeds on a
  # retry. Failing the whole run on the first blip would make an unattended job useless.
  install_attempt=1
  until xcrun devicectl device install app --device "$DEVICE_ID" "$APP"; do
    if (( install_attempt >= 3 )); then
      echo "error: install failed after $install_attempt attempts" >&2
      exit 1
    fi
    echo "==> Install attempt $install_attempt failed; retrying"
    install_attempt=$(( install_attempt + 1 ))
    sleep $(( install_attempt * 5 ))
  done
  # The unattended daily job sets SKIP_LAUNCH: bringing an app to the foreground on someone's
  # phone in the middle of the night is not a side effect an install should have.
  if [[ "${SKIP_LAUNCH:-0}" != "1" ]]; then
    xcrun devicectl device process launch --device "$DEVICE_ID" com.weihsiangliao.VideoCompressor
  fi
fi
