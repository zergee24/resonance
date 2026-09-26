#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
configuration="${1:-release}"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
bundle="$PWD/dist/共鸣.app"
icon_source="$PWD/Support/AppIcon.png"
if [[ ! -f "$icon_source" ]]; then
  print -u2 "missing app icon source: $icon_source"
  exit 1
fi
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/Resonance" "$bundle/Contents/MacOS/Resonance"
cp Support/Info.plist "$bundle/Contents/Info.plist"
for resource in "$binary_dir"/*.bundle(N); do
  ditto "$resource" "$bundle/Contents/Resources/${resource:t}"
done

# Build the native macOS icon from one transparent PNG source. iconutil is
# part of Xcode Command Line Tools and keeps the release bundle dependency-free.
iconset_parent="$(mktemp -d "${TMPDIR:-/tmp}/resonance-iconset.XXXXXX")"
iconset_dir="$iconset_parent/AppIcon.iconset"
mkdir "$iconset_dir"
trap 'rm -rf "$iconset_parent"' EXIT
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier local.tony.Resonance "$bundle"
printf '%s\n' "$bundle"
