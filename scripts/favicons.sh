#!/usr/bin/env bash
# Cut the website's favicons from the app icon, so they cannot drift apart.
#
#   ./scripts/favicons.sh
#
# genicon.swift draws the icon at build time rather than keeping a binary in
# the repo; these are the same drawing, sized down. Re-run after changing it.

set -euo pipefail

cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift scripts/genicon.swift "$TMP/AppIcon.iconset"

cp "$TMP/AppIcon.iconset/icon_16x16.png"   docs/favicon-16.png
cp "$TMP/AppIcon.iconset/icon_32x32.png"   docs/favicon-32.png
# Apple wants 180 for a home-screen icon; scale the 256 down rather than the
# 512, which is a smaller jump and keeps the key edges crisp.
sips -z 180 180 "$TMP/AppIcon.iconset/icon_256x256.png" \
    --out docs/apple-touch-icon.png > /dev/null

echo "wrote docs/favicon-16.png, docs/favicon-32.png, docs/apple-touch-icon.png"
