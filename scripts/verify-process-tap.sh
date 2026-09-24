#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

probe_dir="$PWD/.build/process-tap-probe"
mkdir -p "$probe_dir"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx14.2 \
  -framework AVFoundation -framework CoreAudio \
  Tests/CaptureProbe/TonePlayer.swift \
  -o "$probe_dir/tone-player"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx14.2 \
  -framework AVFoundation -framework CoreAudio -framework Combine \
  Sources/ResonanceApp/AudioCapture.swift \
  Tests/CaptureProbe/AudioCaptureRealProbe.swift \
  -o "$probe_dir/audio-capture-real-probe"

"$probe_dir/audio-capture-real-probe" "$probe_dir/tone-player"
