#!/bin/sh
# Fetches FluidAudio (Apache-2.0) at a pinned commit for speaker diarisation and links it
# at Packages/JammerKit/Vendor/FluidAudio. Jämmer uses only its "Diarizer" trait (no TTS,
# no prebuilt NemoTextProcessing binary) and only the offline Community-1 pipeline, whose
# models are CC-BY-4.0 (docs/LICENSES.md). Not committed; run once.
#   JAMMER_VENDOR_SRC=/big/disk scripts/fetch-fluidaudio.sh
set -eu
# Fetching, compiling or installing third-party code is Anders's to allow, in the session's own window,
# each time it is done (the series' rule). So this script does nothing until it is told he has:
#   JAMMER_FETCH_ALLOWED=yes scripts/fetch-fluidaudio.sh
[ "${JAMMER_FETCH_ALLOWED:-}" = "yes" ] || { echo "$(basename "$0"): this fetches and builds third-party code, which Anders allows each time. After his yes: JAMMER_FETCH_ALLOWED=yes scripts/$(basename "$0")" >&2; exit 77; }
root="$(cd "$(dirname "$0")/.." && pwd)"
tag=v0.18.3
commit=c8b41f98eae668794dd0083bbe028fe7e6585051
src_root="${JAMMER_VENDOR_SRC:-$root/build/vendor-src}"
src="$src_root/FluidAudio"
mkdir -p "$src_root" "$root/Packages/JammerKit/Vendor"
if [ ! -d "$src/.git" ]; then
    git clone -q --filter=blob:none https://github.com/FluidInference/FluidAudio.git "$src"
fi
git -C "$src" fetch -q --tags origin
git -C "$src" -c advice.detachedHead=false checkout -q "$tag"
actual="$(git -C "$src" rev-parse HEAD)"
[ "$actual" = "$commit" ] || { echo "FluidAudio $tag is $actual, expected $commit; not linking." >&2; exit 1; }
ln -sfn "$src" "$root/Packages/JammerKit/Vendor/FluidAudio"
echo "FluidAudio $tag ($commit) linked at Packages/JammerKit/Vendor/FluidAudio"
