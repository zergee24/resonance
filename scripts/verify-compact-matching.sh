#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-compact-matching.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

binary="$temporary_dir/verify-compact-matching"
swiftc -O -swift-version 5 -parse-as-library \
  -framework Accelerate \
  -framework AVFoundation \
  "$root_dir/Sources/ResonanceCore/Models.swift" \
  "$root_dir/Sources/ResonanceCore/SpectrumAnalyzer.swift" \
  "$root_dir/Sources/ResonanceCore/CompactSpectrum.swift" \
  "$root_dir/Sources/ResonanceCore/Matcher.swift" \
  "$root_dir/Sources/ResonanceCore/PersonalMatcher.swift" \
  "$root_dir/Sources/ResonanceCore/CurveImporter.swift" \
  "$root_dir/scripts/verify-compact-matching.swift" \
  -o "$binary"

"$binary" "$@"
