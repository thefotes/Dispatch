#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version_script="$project_root/scripts/version.sh"
fixture_root=$(mktemp -d /private/tmp/dispatch-version-test.XXXXXX)
trap 'rm -rf "$fixture_root"' EXIT INT TERM

assert_version() {
    expected=$(printf '%s\n%s' "$1" "$2")
    actual=$("$version_script" "$3")
    if [ "$actual" != "$expected" ]; then
        printf 'Expected version %s / %s, got: %s\n' "$1" "$2" "$actual" >&2
        exit 1
    fi
}

mkdir "$fixture_root/source"
cp "$project_root/Resources/Info.plist" "$fixture_root/source/Info.plist"
assert_version 1.0.0 1 "$fixture_root/source"

git -C "$fixture_root/source" init -q
git -C "$fixture_root/source" config user.name 'Version Test'
git -C "$fixture_root/source" config user.email 'version-test@example.invalid'
git -C "$fixture_root/source" add Info.plist
git -C "$fixture_root/source" commit -qm initial
assert_version 1.0.0 1 "$fixture_root/source"

git -C "$fixture_root/source" tag v1.1.0
assert_version 1.1.0 1 "$fixture_root/source"

git -C "$fixture_root/source" commit --allow-empty -qm next
assert_version 1.1.0 2 "$fixture_root/source"

printf '\n' >> "$fixture_root/source/Info.plist"
assert_version 1.1.0 2 "$fixture_root/source"
git -C "$fixture_root/source" restore Info.plist

git -C "$fixture_root/source" tag v1.1.0-beta
assert_version 1.0.0 2 "$fixture_root/source"

mkdir "$fixture_root/no-plist"
assert_version 0.0.0 1 "$fixture_root/no-plist"

printf 'Version derivation tests passed.\n'
