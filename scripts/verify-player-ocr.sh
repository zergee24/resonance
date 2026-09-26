#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h}/.."
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-player-ocr-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

cp "$repo_root/Sources/ResonanceApp/PlayerObserver.swift" "$probe_dir/PlayerObserver.swift"
sed -i '' 's/private func cropBottomBar/func cropBottomBar/' "$probe_dir/PlayerObserver.swift"
swiftc -parse-as-library \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Combine \
  -framework ScreenCaptureKit \
  -framework Vision \
  "$probe_dir/PlayerObserver.swift" \
  "$repo_root/Tests/PlayerProbe/OCRProbe.swift" \
  -o "$probe_dir/player-ocr-probe"
"$probe_dir/player-ocr-probe"
