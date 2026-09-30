#!/bin/sh
# Model-checks the TLA+ specs in specs/ with TLC.
#
# Usage: scripts/tla.sh [config ...]
# With no arguments, checks every specs/*.cfg. A config named
# `Module.cfg` or `Module.anything.cfg` checks `Module.tla`.
# Needs a Java runtime (`brew install openjdk`). TLC is downloaded once into
# DISPATCH_BUILD_DIR, pinned by version and checksum.

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch_root=${DISPATCH_BUILD_DIR:-"$HOME/Library/Caches/dispatch-build"}
tla_version=1.7.4
tla_sha256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
jar="$scratch_root/tla2tools-$tla_version.jar"

# Homebrew's openjdk is keg-only: /opt/homebrew on Apple silicon, /usr/local on Intel.
java=java
for candidate in /opt/homebrew/opt/openjdk/bin/java /usr/local/opt/openjdk/bin/java; do
    if [ -x "$candidate" ]; then
        java=$candidate
        break
    fi
done
if ! "$java" -version >/dev/null 2>&1; then
    echo "TLC needs a Java runtime: brew install openjdk" >&2
    exit 1
fi

if [ ! -f "$jar" ]; then
    mkdir -p "$scratch_root"
    curl -fsSL -o "$jar.download" \
        "https://github.com/tlaplus/tlaplus/releases/download/v$tla_version/tla2tools.jar"
    echo "$tla_sha256  $jar.download" | shasum -a 256 -c - >/dev/null
    mv "$jar.download" "$jar"
fi

# A restored CI cache is untrusted too; check its bytes before invoking TLC.
if ! echo "$tla_sha256  $jar" | shasum -a 256 -c - >/dev/null; then
    echo "TLC jar checksum mismatch: $jar" >&2
    exit 1
fi

if [ $# -eq 0 ]; then
    set -- "$project_root"/specs/*.cfg
fi

# TLC writes state files into its working directory; keep them out of the
# repository.
cd "$scratch_root"
for config in "$@"; do
    config=$(basename "$config" .cfg)
    module=${config%%.*}
    echo "== $config"
    "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
        -workers auto -cleanup -metadir "$scratch_root/tlc-states" \
        -config "$project_root/specs/$config.cfg" "$project_root/specs/$module.tla"
done
