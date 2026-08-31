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

if [[ -f .env ]]; then
  set -a; source .env; set +a
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

echo "==> Generating project (team ${DEVELOPMENT_TEAM})"
xcodegen generate

ACTION=build
case "${1:-}" in
  --test) ACTION=test ;;
esac

echo "==> Running xcodebuild $ACTION for device $DEVICE_ID"
xcodebuild \
  -project VideoCompressor.xcodeproj \
  -scheme VideoCompressor \
  -destination "id=${DEVICE_ID}" \
  -allowProvisioningUpdates \
  "$ACTION"

if [[ "${1:-}" == "--install" ]]; then
  # -showBuildSettings covers every target in the scheme, so match on the product that is
  # actually an .app — picking the last FULL_PRODUCT_NAME lands on the share extension.
  APP=$(xcodebuild -project VideoCompressor.xcodeproj -scheme VideoCompressor \
        -destination "id=${DEVICE_ID}" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '
            / BUILT_PRODUCTS_DIR /            { dir = $2 }
            / FULL_PRODUCT_NAME /             { if ($2 ~ /\.app$/) app = $2 }
            END                               { if (app != "") print dir "/" app }')

  if [[ -z "$APP" ]]; then
    echo "error: could not locate the built .app" >&2
    exit 1
  fi

  echo "==> Installing $APP"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
  xcrun devicectl device process launch --device "$DEVICE_ID" com.weihsiangliao.VideoCompressor
fi
