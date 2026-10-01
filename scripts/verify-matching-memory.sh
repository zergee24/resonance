#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-matching-memory.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
verification_dir="$root_dir/test-output/verification"
mkdir -p "$verification_dir"

swiftc -emit-library -emit-module -module-name ResonanceCore \
  -emit-module-path "$temporary_dir/ResonanceCore.swiftmodule" \
  "$root_dir"/Sources/ResonanceCore/*.swift \
  -o "$temporary_dir/libResonanceCore.dylib" \
  -framework Accelerate -framework AVFoundation

# Compile the real MatchingService extension and LocalStore against a
# state-only AppModel host. No formal app, browser, player, capture device, or
# real library is instantiated; all artifacts are temporary.
compile_harness() {
  local output="$1"
  local service_source="$2"
  swiftc -parse-as-library -D MATCHING_MEMORY_VERIFICATION \
  -module-name MatchingMemoryHarness \
  "$root_dir/Sources/ResonanceApp/LibraryModels.swift" \
  "$root_dir/Sources/ResonanceApp/LocalStore.swift" \
  "$service_source" \
  "$root_dir/scripts/verify-matching-memory.swift" \
  -I "$temporary_dir" -L "$temporary_dir" -lResonanceCore \
  -framework Accelerate -framework AVFoundation -framework AppKit \
  -framework UniformTypeIdentifiers -lsqlite3 \
  -o "$output"
}

baseline_binary="$temporary_dir/matching-memory-baseline"
# Mutate only a temporary source copy to prove this test detects the original
# overlap. No baseline bypass or alternate runtime path exists in the app.
baseline_source="$temporary_dir/MatchingServiceWithoutWait.swift"
sed '/await previousMatchTask[?][.]value/d' \
  "$root_dir/Sources/ResonanceApp/MatchingService.swift" > "$baseline_source"
compile_harness "$baseline_binary" "$baseline_source"

baseline_log="$verification_dir/matching-memory-baseline-failure.log"
if DYLD_LIBRARY_PATH="$temporary_dir" "$baseline_binary" >"$baseline_log" 2>&1; then
  print -u2 "baseline unexpectedly passed; serialization regression test is invalid"
  cat "$baseline_log" >&2
  exit 1
else
  baseline_status=$?
  if ! grep -q 'a replacement matching worker overlapped the canceled worker' "$baseline_log"; then
    print -u2 "baseline failed for an unexpected reason"
    cat "$baseline_log" >&2
    exit 1
  fi
  print "Baseline without await previous: expected failure (exit $baseline_status); log: $baseline_log"
fi

binary="$temporary_dir/matching-memory-harness"
compile_harness "$binary" "$root_dir/Sources/ResonanceApp/MatchingService.swift"

DYLD_LIBRARY_PATH="$temporary_dir" "$binary"
