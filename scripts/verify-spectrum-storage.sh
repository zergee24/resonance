#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

verification_dir="$root_dir/test-output/verification"
mkdir -p "$verification_dir"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-spectrum-storage.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

binary="$temporary_dir/verify-spectrum-storage"
swiftc -O -swift-version 5 -parse-as-library \
  Sources/ResonanceCore/Models.swift \
  scripts/verify-spectrum-storage.swift \
  -o "$binary"

report="$verification_dir/spectrum-storage.md"
{
  printf '%s\n' '# SpectrumFrame storage verification'
  printf '%s\n' '' '- Command: `scripts/verify-spectrum-storage.sh`' "- Swift: \`$(swift --version | head -1)\`" ''
  "$binary"
} | tee "$report"

printf '%s\n' "Report: $report"
