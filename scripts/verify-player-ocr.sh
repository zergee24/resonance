#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h}/.."
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-player-ocr-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

cp "$repo_root/Sources/ResonanceApp/PlayerObserver.swift" "$probe_dir/PlayerObserver.swift"
sed -i '' 's/private func cropBottomBar/func cropBottomBar/' "$probe_dir/PlayerObserver.swift"
sed -i '' 's/private func suppressRedBadgePixels/func suppressRedBadgePixels/' "$probe_dir/PlayerObserver.swift"
sed -i '' 's/private func publishStableOCR/func publishStableOCR/' "$probe_dir/PlayerObserver.swift"
sed -i '' 's/private func publishSnapshot/func publishSnapshot/' "$probe_dir/PlayerObserver.swift"
sed -i '' 's/private var systemSnapshot/var systemSnapshot/' "$probe_dir/PlayerObserver.swift"
sed -i '' 's/private func makeSystemSnapshot/func makeSystemSnapshot/' "$probe_dir/PlayerObserver.swift"
# LibraryModels now exposes the production personal-reference result type.
swiftc -parse-as-library -emit-module -emit-library -module-name ResonanceCore \
  "$repo_root/Sources/ResonanceCore/Models.swift" \
  "$repo_root/Sources/ResonanceCore/PersonalMatcher.swift" \
  -emit-module-path "$probe_dir/ResonanceCore.swiftmodule" \
  -o "$probe_dir/libResonanceCore.dylib"
swiftc -parse-as-library \
  -I "$probe_dir" -L "$probe_dir" -lResonanceCore \
  -Xlinker -rpath -Xlinker "$probe_dir" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Combine \
  -framework ScreenCaptureKit \
  -framework Vision \
  "$probe_dir/PlayerObserver.swift" \
  "$repo_root/Sources/ResonanceApp/SystemPlayerReader.swift" \
  "$repo_root/Sources/ResonanceApp/LibraryModels.swift" \
  "$repo_root/Tests/PlayerProbe/OCRProbe.swift" \
  -o "$probe_dir/player-ocr-probe"
"$probe_dir/player-ocr-probe"
