#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-compact-codec.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

binary="$temporary_dir/verify-compact-codec"
swiftc -O -swift-version 5 -parse-as-library \
  Sources/ResonanceCore/Models.swift \
  scripts/verify-compact-codec.swift \
  -o "$binary"

"$binary"
