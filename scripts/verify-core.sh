#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

verification_dir="$root_dir/test-output/verification"
mkdir -p "$verification_dir"
report="$verification_dir/core-harness.md"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-core-verify.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

binary="$temporary_dir/verify-core"
swiftc -O \
  -framework Accelerate \
  -framework AVFoundation \
  Sources/ResonanceCore/Models.swift \
  Sources/ResonanceCore/SpectrumAnalyzer.swift \
  Sources/ResonanceCore/Matcher.swift \
  Sources/ResonanceCore/CurveImporter.swift \
  scripts/verify-core.swift \
  -o "$binary"

{
  printf '%s\n' '# ResonanceCore verification'
  printf '%s\n' '' '- Command: `scripts/verify-core.sh`' "- Swift: \`$(swift --version | head -1)\`" ''
  "$binary" 2>&1
} | tee "$report"

printf '%s\n' "Report: $report"
