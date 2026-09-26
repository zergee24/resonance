#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
root_dir="${script_dir}/.."
cd "$root_dir"

verification_dir="$root_dir/test-output/verification"
mkdir -p "$verification_dir"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-personal-verify.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

raphael="$root_dir/Samples/Raphael/Artipical_Raphael_HBB_R.csv"
he1="$root_dir/Sources/ResonanceApp/Resources/Sennheiser_HE1_HuiHiFi.csv"
alter="$root_dir/Sources/ResonanceApp/Resources/MA_Audio_Alter_Ego_No_Dot_HuiHiFi.csv"
output="$verification_dir/personal-live.json"

[[ -f "$raphael" ]] || { print -u2 "missing Raphael curve: $raphael"; exit 1; }
[[ -f "$he1" ]] || { print -u2 "missing HE1 curve: $he1"; exit 1; }
[[ -f "$alter" ]] || { print -u2 "missing Alter Ego curve: $alter"; exit 1; }

[[ "$(shasum -a 256 "$he1" | awk '{print $1}')" == "c0cf6879dda2a0ae42bdee0e33fb94b4046d4e62d9389a9daeac31a68a2e973a" ]] || { print -u2 "HE1 SHA-256 mismatch"; exit 1; }
[[ "$(shasum -a 256 "$alter" | awk '{print $1}')" == "d79f238017fae0df980d1fc952d0499de46a173e7d3900e70bd1a441a736bfbc" ]] || { print -u2 "Alter Ego SHA-256 mismatch"; exit 1; }

binary="$temporary_dir/verify-personal"
swiftc -O -swift-version 5 -parse-as-library \
  -framework Accelerate \
  -framework AVFoundation \
  "$root_dir/Sources/ResonanceCore/Models.swift" \
  "$root_dir/Sources/ResonanceCore/SpectrumAnalyzer.swift" \
  "$root_dir/Sources/ResonanceCore/Matcher.swift" \
  "$root_dir/Sources/ResonanceCore/CurveImporter.swift" \
  "$root_dir/Sources/ResonanceCore/PersonalMatcher.swift" \
  "$root_dir/scripts/verify-personal.swift" \
  -o "$binary"

core_sha256="$(shasum -a 256 "$root_dir/Sources/ResonanceCore/PersonalMatcher.swift" | awk '{print $1}')"
args=(--raphael "$raphael" --he1 "$he1" --alter "$alter" --output "$output" --core-sha256 "$core_sha256")
if (( ${+RESONANCE_PERSONAL_LIVE_FEATURE} )); then args+=(--live-feature "$RESONANCE_PERSONAL_LIVE_FEATURE"); fi
if (( ${+RESONANCE_PERSONAL_LIVE_AUDIO} )); then args+=(--live-audio "$RESONANCE_PERSONAL_LIVE_AUDIO"); fi
if (( ${+RESONANCE_PERSONAL_LIVE_ID} )); then args+=(--live-id "$RESONANCE_PERSONAL_LIVE_ID"); fi

user_args=("$@")
"$binary" "${args[@]}" "${user_args[@]}"
report="$output"
for (( i = 1; i <= ${#user_args[@]}; i++ )); do
  if [[ "${user_args[$i]}" == "--output" ]] && (( i < ${#user_args[@]} )); then
    report="${user_args[$((i + 1))]}"
  fi
done
print "Report: $report"
