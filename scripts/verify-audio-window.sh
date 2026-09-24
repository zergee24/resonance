#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-audio-window-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macosx14.2 \
  -framework AVFoundation \
  Sources/ResonanceCore/CapturedAudioWindow.swift \
  Tests/ListeningProbe/AudioWindowProbe.swift \
  -o "$probe_dir/audio-window-probe"

"$probe_dir/audio-window-probe"
