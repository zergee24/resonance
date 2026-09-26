#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h}/.."
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-system-player-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

swiftc -parse-as-library \
  -framework Foundation \
  "$repo_root/Sources/ResonanceApp/SystemPlayerReader.swift" \
  "$repo_root/Tests/PlayerProbe/SystemPlayerReaderProbe.swift" \
  -o "$probe_dir/system-player-probe"

"$probe_dir/system-player-probe" "$repo_root/Support/SystemPlayer"
