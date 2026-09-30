#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stage_root=$(mktemp -d /tmp/dispatch-build.XXXXXX)
output_root=${DISPATCH_OUTPUT_DIR:-"$project_root/build"}
app_path="$output_root/Dispatch.app"
archive_path="$output_root/Dispatch.app.zip"

cleanup() {
    rm -rf "$stage_root"
}
trap cleanup EXIT INT TERM

swift build \
    --package-path "$project_root" \
    --scratch-path "$stage_root/.build" \
    --configuration release \
    --product Dispatch

binary_path="$stage_root/.build/release/Dispatch"
bundle_path="$stage_root/Dispatch.app"

mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp "$binary_path" "$bundle_path/Contents/MacOS/Dispatch"
cp "$project_root/Resources/Info.plist" "$bundle_path/Contents/Info.plist"
versions=$("$project_root/scripts/version.sh" "$project_root")
marketing_version=$(printf '%s\n' "$versions" | sed -n '1p')
build_version=$(printf '%s\n' "$versions" | sed -n '2p')
plutil -replace CFBundleShortVersionString -string "$marketing_version" "$bundle_path/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_version" "$bundle_path/Contents/Info.plist"

if [ -f "$project_root/Resources/AppIcon.icns" ]; then
    cp "$project_root/Resources/AppIcon.icns" "$bundle_path/Contents/Resources/AppIcon.icns"
fi

xattr -cr "$bundle_path"

# A stable signing identity keeps macOS privacy grants (Input Monitoring,
# Accessibility) across rebuilds; an ad-hoc signature changes with every build.
local_identity="Dispatch Local Dev"
if [ -n "${DISPATCH_CODESIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp \
        --sign "$DISPATCH_CODESIGN_IDENTITY" "$bundle_path"
elif security find-identity -p codesigning | grep -q "\"$local_identity\""; then
    codesign --force --sign "$local_identity" "$bundle_path"
else
    echo "Signing ad hoc; create a \"$local_identity\" certificate to keep privacy grants across builds." >&2
    codesign --force --sign - "$bundle_path"
fi
codesign --verify --deep --strict "$bundle_path"

# Preserve a clean distributable artifact even when the repository lives in a
# File Provider-backed folder that attaches metadata to the unpacked bundle.
archive_stage="$stage_root/Dispatch.app.zip"
ditto -c -k --norsrc --noextattr --keepParent "$bundle_path" "$archive_stage"
verification_root="$stage_root/verification"
mkdir -p "$verification_root"
ditto -x -k "$archive_stage" "$verification_root"
codesign --verify --deep --strict "$verification_root/Dispatch.app"

mkdir -p "$output_root"
rm -rf "$app_path"
rm -f "$archive_path"
ditto --noextattr --noqtn "$bundle_path" "$app_path"
cp "$archive_stage" "$archive_path"
xattr -cr "$app_path"

# File Provider-backed folders can attach Finder metadata between the copy and
# verification. Strip it once more if strict verification observes that race.
if ! codesign --verify --deep --strict "$app_path"; then
    xattr -cr "$app_path"
    codesign --verify --deep --strict "$app_path"
fi

printf '%s\n' "$app_path"
printf '%s\n' "$archive_path"
