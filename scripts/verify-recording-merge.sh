#!/bin/zsh
set -euo pipefail
root="${0:A:h}/.."
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resonance-merge.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

core_sources=("$root"/Sources/ResonanceCore/*.swift)
swiftc -emit-library -emit-module -module-name ResonanceCore \
  -emit-module-path "$tmp/ResonanceCore.swiftmodule" \
  "${core_sources[@]}" \
  -o "$tmp/libResonanceCore.dylib" \
  -framework Accelerate -framework AVFoundation

app_sources=()
for source in "$root"/Sources/ResonanceApp/*.swift; do
  [[ "${source:t}" == "ResonanceApp.swift" ]] && continue
  [[ "${source:t}" == "PersonalReferenceSamples.swift" ]] && continue
  [[ "${source:t}" == "RaphaelSample.swift" ]] && continue
  app_sources+=("$source")
done
swiftc -parse-as-library -module-name RecordingMergeHarness \
  "${app_sources[@]}" "$root/scripts/verify-recording-merge.swift" \
  -I "$tmp" -L "$tmp" -lResonanceCore \
  -framework Accelerate -framework AVFoundation -framework AppKit \
  -framework SwiftUI -framework WebKit -framework CoreAudio \
  -framework ApplicationServices -framework ScreenCaptureKit -framework Vision \
  -lsqlite3 -o "$tmp/recording-merge-harness"
DYLD_LIBRARY_PATH="$tmp" "$tmp/recording-merge-harness"
