#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

verification_dir="$root_dir/test-output/verification"
mkdir -p "$verification_dir"
report="$verification_dir/listening-policy.txt"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-listening-policy.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

binary="$temporary_dir/listening-policy-probe"
swiftc -O \
  -swift-version 5 \
  -parse-as-library \
  Sources/ResonanceCore/AutomaticListeningPolicy.swift \
  Tests/ListeningProbe/PolicyProbe.swift \
  -o "$binary"

{
  printf '%s\n' 'Resonance automatic-listening policy verification'
  printf '%s\n' "Command: scripts/verify-listening.sh"
  printf '%s\n' "Swift: $(swift --version | head -1)"
  printf '%s\n' ''
  "$binary"
} | tee "$report"

printf '%s\n' "Report: $report"
