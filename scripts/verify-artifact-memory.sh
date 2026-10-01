#!/bin/zsh
set -euo pipefail
root="${0:A:h}/.."
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resonance-artifact-memory.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
# The optional first argument allows a preserved pre-change codec to be
# measured by the identical harness in a fresh process.
store_source="${1:-$root/Sources/ResonanceApp/LocalStore.swift}"
swiftc -O -swift-version 5 -parse-as-library \
  "$root/Sources/ResonanceCore/Models.swift" \
  "$root/Sources/ResonanceCore/CompactSpectrum.swift" \
  "$store_source" "$root/scripts/verify-artifact-memory.swift" \
  -lsqlite3 -o "$tmp/probe"
"$tmp/probe"
