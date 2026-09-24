#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-capture-cancellation-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx14.2 \
  -framework AVFoundation -framework CoreAudio -framework Combine \
  Sources/ResonanceApp/AudioCapture.swift Tests/CaptureProbe/StartCancellationProbe.swift \
  -o "$probe_dir/capture-cancellation-probe"
"$probe_dir/capture-cancellation-probe"
