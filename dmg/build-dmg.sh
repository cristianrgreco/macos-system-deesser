#!/usr/bin/env bash
#
# Build the styled DeEsser.dmg: app icon on the left, a drag arrow, and the
# Applications folder on the right, over the brand background. Window chrome
# (toolbar/sidebar) is hidden and the layout is baked into the DMG's .DS_Store.
#
# Usage: dmg/build-dmg.sh <path-to-DeEsser.app> [output.dmg]
#
# Requires `create-dmg` (brew install create-dmg). The background images are
# committed; regenerate them with `swift dmg/make-background.swift` if you
# change the window geometry below.

set -euo pipefail

APP_PATH="${1:?usage: build-dmg.sh <DeEsser.app> [output.dmg]}"
OUT_DMG="${2:-DeEsser.dmg}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$APP_PATH" ]; then
  echo "App not found at $APP_PATH" >&2
  exit 1
fi

# Icon centers must match make-background.swift (appX/dropX/iconY).
APP_X=175
DROP_X=485
ICON_Y=170

# Stage just the app into its own folder; create-dmg adds the Applications
# drop-link itself, so the staging dir must contain nothing else.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/DeEsser.app"

# create-dmg refuses to overwrite; clear any stale output first.
rm -f "$OUT_DMG"

create-dmg \
  --volname "DeEsser" \
  --background "$HERE/background.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --text-size 13 \
  --icon "DeEsser.app" "$APP_X" "$ICON_Y" \
  --hide-extension "DeEsser.app" \
  --app-drop-link "$DROP_X" "$ICON_Y" \
  --no-internet-enable \
  "$OUT_DMG" \
  "$STAGE"

echo "Built $OUT_DMG"
