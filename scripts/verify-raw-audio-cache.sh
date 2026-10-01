#!/bin/zsh
set -euo pipefail

root="${0:A:h}/.."
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resonance-raw-audio-cache.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

swiftc -emit-library -emit-module -module-name ResonanceCore \
  -emit-module-path "$tmp/ResonanceCore.swiftmodule" \
  "$root"/Sources/ResonanceCore/*.swift \
  -o "$tmp/libResonanceCore.dylib" \
  -framework Accelerate -framework AVFoundation

swiftc -parse-as-library -module-name RawAudioCacheHarness \
  "$root/Sources/ResonanceApp/LibraryModels.swift" \
  "$root/Sources/ResonanceApp/LocalStore.swift" \
  "$root/Sources/ResonanceApp/RawAudioCache.swift" \
  "$root/scripts/verify-raw-audio-cache.swift" \
  -I "$tmp" -L "$tmp" -lResonanceCore \
  -framework Accelerate -framework AVFoundation -lsqlite3 \
  -o "$tmp/raw-audio-cache-harness"

DYLD_LIBRARY_PATH="$tmp" "$tmp/raw-audio-cache-harness"
