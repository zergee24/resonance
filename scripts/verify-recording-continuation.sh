#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

verification_dir="$root_dir/test-output/verification"
mkdir -p "$verification_dir"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-recording-continuation.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

swiftc -swift-version 5 -parse-as-library \
  -emit-module -emit-library \
  -module-name ResonanceCore \
  Sources/ResonanceCore/Models.swift \
  Sources/ResonanceCore/PersonalMatcher.swift \
  -emit-module-path "$temporary_dir/ResonanceCore.swiftmodule" \
  -o "$temporary_dir/libResonanceCore.dylib"

binary="$temporary_dir/verify-recording-continuation"
swiftc -O -swift-version 5 -parse-as-library \
  -I "$temporary_dir" -L "$temporary_dir" -lResonanceCore \
  Sources/ResonanceApp/LibraryModels.swift \
  Sources/ResonanceApp/RecordingContinuation.swift \
  scripts/verify-recording-continuation.swift \
  -o "$binary"

report="$verification_dir/recording-continuation.md"
{
  printf '%s\n' '# Recording continuation verification'
  printf '%s\n' '' '- Command: `scripts/verify-recording-continuation.sh`' "- Swift: \`$(swift --version | head -1)\`" ''
  DYLD_LIBRARY_PATH="$temporary_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$binary"
} | tee "$report"

printf '%s\n' "Report: $report"
