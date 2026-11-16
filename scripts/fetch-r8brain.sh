#!/bin/sh
# Fetches r8brain-free-src, the sample rate converter, at a pinned commit and links it under
# Packages/JammerKit/Vendor (not committed; run once):
#   r8brain-free-src 7.7   MIT, Copyright (c) 2013-2026 Aleksey Vaneev   -> Vendor/r8brain
# The free library, not the commercial r8brain PRO. Jämmer compiles it from this source with its
# bundled Ooura FFT (fft4g.h); PFFFT and Intel IPP are not enabled. Licence read at the source
# 2026-11-16 (docs/LICENSES.md). Fetching it was approved by Anders on 2026-11-16.
# The author asks for this credit: "Sample rate converter designed by Aleksey Vaneev of Voxengo".
#   JAMMER_VENDOR_SRC=/big/disk scripts/fetch-r8brain.sh
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
src_root="${JAMMER_VENDOR_SRC:-$root/build/vendor-src}"
mkdir -p "$src_root" "$root/Packages/JammerKit/Vendor"
dir="$src_root/r8brain"
commit=5792291ad66b04e87fd61a3d92606214632c6cfc
if [ ! -d "$dir/.git" ]; then git clone -q --filter=blob:none --no-checkout https://github.com/avaneev/r8brain-free-src.git "$dir"; fi
git -C "$dir" fetch -q origin "$commit" 2>/dev/null || git -C "$dir" fetch -q origin
git -C "$dir" -c advice.detachedHead=false checkout -q "$commit"
actual="$(git -C "$dir" rev-parse HEAD)"
[ "$actual" = "$commit" ] || { echo "r8brain is at $actual, expected $commit; not linking." >&2; exit 1; }
# What was read is what is used: the licence is MIT and the version is the one recorded.
grep -q "^MIT License" "$dir/LICENSE" || { echo "r8brain's LICENSE no longer starts with \"MIT License\"; read it again before using it." >&2; exit 1; }
grep -q '#define R8B_VERSION "7.7"' "$dir/r8bbase.h" || { echo "r8brain's version is not 7.7; check docs/LICENSES.md and this script." >&2; exit 1; }
ln -sfn "$dir" "$root/Packages/JammerKit/Vendor/r8brain"
echo "r8brain-free-src 7.7 ($commit) linked at Packages/JammerKit/Vendor/r8brain"
