#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-compact-library.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

swiftc -O -swift-version 5 -parse-as-library \
  -emit-library -emit-module \
  -module-name ResonanceCore \
  -emit-module-path "$temporary_dir/ResonanceCore.swiftmodule" \
  "$root_dir"/Sources/ResonanceCore/*.swift \
  -o "$temporary_dir/libResonanceCore.dylib" \
  -framework Accelerate -framework AVFoundation

swiftc -O -swift-version 5 -parse-as-library \
  -module-name CompactLibraryTool \
  "$root_dir/Sources/ResonanceApp/LocalStore.swift" \
  "$root_dir/scripts/compact-library.swift" \
  -I "$temporary_dir" -L "$temporary_dir" -lResonanceCore \
  -framework Accelerate -framework AVFoundation -lsqlite3 \
  -o "$temporary_dir/compact-library"

DYLD_LIBRARY_PATH="$temporary_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
  "$temporary_dir/compact-library" "$@"
