#!/bin/sh
# Fetches the two plugin-format SDKs at pinned commits and links them under
# Packages/JammerKit/Vendor (not committed; run once):
#   CLAP        1.2.9           MIT, Copyright (c) 2021 Alexandre BIQUE         -> Vendor/clap
#   VST 3 SDK   v3.8.1_build_84 MIT since 3.8, Copyright (c) Steinberg Media Technologies GmbH -> Vendor/vst3sdk
# Of the VST 3 SDK only pluginterfaces, base and public.sdk (the hosting helpers) are fetched:
# not VSTGUI, not the examples. Licences read at the source 2026-11-15 (docs/LICENSES.md).
#   JAMMER_VENDOR_SRC=/big/disk scripts/fetch-plugin-sdks.sh
set -eu
# Fetching, compiling or installing third-party code is Anders's to allow, in the session's own window,
# each time it is done (the series' rule). So this script does nothing until it is told he has:
#   JAMMER_FETCH_ALLOWED=yes scripts/fetch-plugin-sdks.sh
[ "${JAMMER_FETCH_ALLOWED:-}" = "yes" ] || { echo "$(basename "$0"): this fetches and builds third-party code, which Anders allows each time. After his yes: JAMMER_FETCH_ALLOWED=yes scripts/$(basename "$0")" >&2; exit 77; }
root="$(cd "$(dirname "$0")/.." && pwd)"
src_root="${JAMMER_VENDOR_SRC:-$root/build/vendor-src}"
mkdir -p "$src_root" "$root/Packages/JammerKit/Vendor"

pinned() { # dir url tag commit
    if [ ! -d "$1/.git" ]; then git clone -q --filter=blob:none --no-checkout "$2" "$1"; fi
    git -C "$1" fetch -q --tags origin
    git -C "$1" -c advice.detachedHead=false checkout -q "$3"
    actual="$(git -C "$1" rev-parse HEAD)"
    [ "$actual" = "$4" ] || { echo "$2 $3 is $actual, expected $4; not linking." >&2; exit 1; }
}

pinned "$src_root/clap" https://github.com/free-audio/clap.git 1.2.9 cd94482ba5941ae410809b6fbaed3bc851044270
ln -sfn "$src_root/clap" "$root/Packages/JammerKit/Vendor/clap"
echo "CLAP 1.2.9 linked at Packages/JammerKit/Vendor/clap"

pinned "$src_root/vst3sdk" https://github.com/steinbergmedia/vst3sdk.git v3.8.1_build_84 3cdf9ca5d1f5b1b21e0a86832aa4abe55607bd96
# The three parts that are needed, at the commits the SDK release pins.
git -C "$src_root/vst3sdk" submodule update -q --init --depth 1 pluginterfaces base public.sdk
ln -sfn "$src_root/vst3sdk" "$root/Packages/JammerKit/Vendor/vst3sdk"
echo "VST 3 SDK v3.8.1_build_84 linked at Packages/JammerKit/Vendor/vst3sdk (pluginterfaces, base, public.sdk)"
for m in pluginterfaces base public.sdk; do echo "  $m $(git -C "$src_root/vst3sdk/$m" rev-parse HEAD)"; done
