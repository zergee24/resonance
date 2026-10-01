#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

verification_dir="$root_dir/test-output/verification"
mkdir -p "$verification_dir"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-compact-spectrum.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

binary="$temporary_dir/verify-compact-spectrum"
swiftc -O -swift-version 5 -parse-as-library \
  -framework Accelerate \
  -framework AVFoundation \
  Sources/ResonanceCore/Models.swift \
  Sources/ResonanceCore/CompactSpectrum.swift \
  Sources/ResonanceCore/SpectrumAnalyzer.swift \
  scripts/verify-compact-spectrum.swift \
  -o "$binary"

report="$verification_dir/compact-spectrum.md"
{
  printf '%s\n' '# Compact spectrum verification'
  printf '%s\n' '' '- Command: `scripts/verify-compact-spectrum.sh`' "- Swift: \`$(swift --version | head -1)\`" ''
  "$binary"
} | tee "$report"

printf '%s\n' "Report: $report"
