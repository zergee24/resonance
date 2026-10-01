#!/bin/zsh
set -euo pipefail

root="${0:A:h}/.."
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resonance-streaming-analysis.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mode="${1:-}"
analyzer_source="${2:-$root/Sources/ResonanceCore/SpectrumAnalyzer.swift}"
if [[ "$mode" != "" && "$mode" != "--memory-only" ]]; then
  print -u2 "usage: $0 [--memory-only [SpectrumAnalyzer.swift]]"
  exit 2
fi

swiftc -O -swift-version 5 \
  -framework Accelerate \
  -framework AVFoundation \
  "$root/Sources/ResonanceCore/Models.swift" \
  "$root/Sources/ResonanceCore/CompactSpectrum.swift" \
  "$analyzer_source" \
  "$root/scripts/verify-streaming-analysis.swift" \
  -o "$tmp/probe"

if [[ "$mode" == "--memory-only" ]]; then
  nice -n 15 "$tmp/probe" --memory-only
else
  nice -n 15 "$tmp/probe"
fi
