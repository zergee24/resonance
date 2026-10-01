#!/bin/zsh
set -euo pipefail
root="${0:A:h}/.."
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resonance-analysis.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

swiftc -emit-library -emit-module -module-name ResonanceCore \
  -emit-module-path "$tmp/ResonanceCore.swiftmodule" \
  "$root"/Sources/ResonanceCore/*.swift \
  -o "$tmp/libResonanceCore.dylib" \
  -framework Accelerate -framework AVFoundation

# Compile the real queue/store, without the app entry point, browser, player,
# capture driver, or default AppModel initializer. All writes are temporary.
swiftc -parse-as-library -module-name RecordingAnalysisHarness \
  "$root/Sources/ResonanceApp/LibraryModels.swift" \
  "$root/Sources/ResonanceApp/LocalStore.swift" \
  "$root/Sources/ResonanceApp/RawAudioCache.swift" \
  "$root/Sources/ResonanceApp/RecordingContinuation.swift" \
  "$root/Sources/ResonanceApp/RecordingAnalysis.swift" \
  "$root/scripts/verify-recording-analysis.swift" \
  -I "$tmp" -L "$tmp" -lResonanceCore \
  -framework Accelerate -framework AVFoundation -lsqlite3 \
  -o "$tmp/recording-analysis-harness"
DYLD_LIBRARY_PATH="$tmp" "$tmp/recording-analysis-harness"
