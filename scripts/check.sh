#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch_root=${DISPATCH_BUILD_DIR:-"$HOME/Library/Caches/dispatch-build"}

mkdir -p "$scratch_root"

# File Provider-backed folders (e.g. cloud-synced `~/Documents`) can attach
# extended attributes to build outputs, breaking SwiftPM's codesign of test
# bundles. Build in a scratch path outside the repository instead.
swift build --package-path "$project_root" --scratch-path "$scratch_root/.build"
swift test --parallel --package-path "$project_root" --scratch-path "$scratch_root/.build"
swiftlint lint --strict --no-cache --config "$project_root/.swiftlint.yml"
"$project_root/scripts/test-version.sh"
"$project_root/scripts/tla.sh"
