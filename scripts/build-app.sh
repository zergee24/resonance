#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
configuration="${1:-release}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
bundle="$PWD/dist/共鸣.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/Resonance" "$bundle/Contents/MacOS/Resonance"
cp Support/Info.plist "$bundle/Contents/Info.plist"
for resource in "$binary_dir"/*.bundle(N); do
  ditto "$resource" "$bundle/Contents/Resources/${resource:t}"
done
codesign --force --sign - --identifier local.tony.Resonance "$bundle"
printf '%s\n' "$bundle"
