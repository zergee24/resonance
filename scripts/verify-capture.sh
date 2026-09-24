#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-capture-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx14.2 \
  -framework AVFoundation -framework CoreAudio -framework Combine \
  Sources/ResonanceApp/AudioCapture.swift Tests/CaptureProbe/RingProbe.swift \
  -o "$probe_dir/capture-probe"
"$probe_dir/capture-probe"
