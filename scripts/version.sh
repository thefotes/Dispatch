#!/bin/sh

# Print the numeric marketing and build versions, one per line.
set -eu

project_root=${1:-"$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"}
plist="$project_root/Resources/Info.plist"
if [ ! -f "$plist" ]; then
    plist="$project_root/Info.plist"
fi

plist_value() {
    if [ -f "$plist" ]; then
        plutil -extract "$1" raw -o - "$plist" 2>/dev/null || true
    fi
}

numeric_dots() {
    printf '%s\n' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)*$'
}

marketing_version=''
build_version=''
if [ -e "$project_root/.git" ]; then
    description=$(git -C "$project_root" describe --tags --long --dirty 2>/dev/null || true)
    if printf '%s\n' "$description" | grep -Eq '^v?[0-9]+(\.[0-9]+)*-[0-9]+-g[0-9a-f]+(-dirty)?$'; then
        tag=${description%%-*}
        candidate=${tag#v}
        marketing_version=$candidate
    fi
    count=$(git -C "$project_root" rev-list --count HEAD 2>/dev/null || true)
    if numeric_dots "$count" && [ "$count" -gt 0 ]; then
        build_version=$count
    fi
fi

if [ -z "$marketing_version" ]; then
    candidate=$(plist_value CFBundleShortVersionString)
    if numeric_dots "$candidate"; then
        marketing_version=$candidate
    else
        marketing_version=0.0.0
    fi
fi
if [ -z "$build_version" ]; then
    candidate=$(plist_value CFBundleVersion)
    if numeric_dots "$candidate"; then
        build_version=$candidate
    else
        build_version=1
    fi
fi

printf '%s\n%s\n' "$marketing_version" "$build_version"
