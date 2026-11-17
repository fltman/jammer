#!/bin/sh
# Fetches Sparkle, the update framework, as its release archive at a pinned version and checksum, and places
# it under Packages/JammerKit/Vendor/Sparkle (not committed; run once):
#   Sparkle 2.10.1   MIT (with bsdiff BSD-2, sais-lite MIT, ed25519 zlib, SUSignatureVerifier BSD-2; all in its
#                    LICENSE, read at the source 2026-11-17, docs/LICENSES.md)
# The archive holds Sparkle.framework (embedded in the app) and bin/ (generate_keys, sign_update,
# generate_appcast: tools for the release, never in the app). Fetching it was approved by Anders on 2026-11-17.
#   JAMMER_VENDOR_SRC=/big/disk scripts/fetch-sparkle.sh
set -eu
# Fetching third-party code is Anders's to allow, in the session's own window, each time it is done:
#   JAMMER_FETCH_ALLOWED=yes scripts/fetch-sparkle.sh
[ "${JAMMER_FETCH_ALLOWED:-}" = "yes" ] || { echo "$(basename "$0"): this fetches third-party code, which Anders allows each time. After his yes: JAMMER_FETCH_ALLOWED=yes scripts/$(basename "$0")" >&2; exit 77; }
root="$(cd "$(dirname "$0")/.." && pwd)"
src_root="${JAMMER_VENDOR_SRC:-$root/build/vendor-src}"
version=2.10.1
sha=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
archive="$src_root/Sparkle-$version.tar.xz"
mkdir -p "$src_root" "$root/Packages/JammerKit/Vendor"
if [ ! -f "$archive" ]; then curl -fsSL -o "$archive.part" "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" && mv "$archive.part" "$archive"; fi
actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
[ "$actual" = "$sha" ] || { echo "Sparkle's archive has SHA-256 $actual, expected $sha (GitHub's digest for the release); not using it." >&2; exit 1; }
dir="$src_root/Sparkle-$version"
rm -rf "$dir"; mkdir -p "$dir"
tar -xJf "$archive" -C "$dir"
# What was read is what is used.
grep -q "Permission is hereby granted, free of charge" "$dir/LICENSE" || { echo "Sparkle's LICENSE is not the MIT text that was read; read it again." >&2; exit 1; }
[ -d "$dir/Sparkle.framework" ] && [ -x "$dir/bin/generate_keys" ] && [ -x "$dir/bin/sign_update" ] || { echo "Sparkle's archive doesn't hold Sparkle.framework and bin/ as expected." >&2; exit 1; }
ln -sfn "$dir" "$root/Packages/JammerKit/Vendor/Sparkle"
echo "Sparkle $version linked at Packages/JammerKit/Vendor/Sparkle"
