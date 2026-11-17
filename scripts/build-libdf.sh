#!/bin/sh
# Builds DeepFilterNet's libDF (MIT/Apache-2.0, Rust) from a pinned commit into
# Packages/JammerKit/Vendor/DeepFilter.xcframework (static, C API) and copies the
# DeepFilterNet3 model next to it. Not committed; run once. Needs cargo.
#   JAMMER_VENDOR_SRC=/big/disk CARGO_HOME=/big/disk/cargo scripts/build-libdf.sh
set -eu
# Fetching, compiling or installing third-party code is Anders's to allow, in the session's own window,
# each time it is done (the series' rule). So this script does nothing until it is told he has:
#   JAMMER_FETCH_ALLOWED=yes scripts/build-libdf.sh
[ "${JAMMER_FETCH_ALLOWED:-}" = "yes" ] || { echo "$(basename "$0"): this fetches and builds third-party code, which Anders allows each time. After his yes: JAMMER_FETCH_ALLOWED=yes scripts/$(basename "$0")" >&2; exit 77; }
root="$(cd "$(dirname "$0")/.." && pwd)"
commit=7b14b895fe7fc42cab72b4a4c1e49c982bd6404b
src_root="${JAMMER_VENDOR_SRC:-$root/build/vendor-src}"
src="$src_root/DeepFilterNet"
target="${CARGO_TARGET_DIR:-$src_root/libdf-target}"
out="$root/Packages/JammerKit/Vendor"
mkdir -p "$src_root" "$out"
if [ ! -d "$src/.git" ]; then
    git clone --quiet https://github.com/Rikorose/DeepFilterNet "$src"
fi
git -C "$src" fetch --quiet --depth 1 origin "$commit" 2>/dev/null || true
git -C "$src" -c advice.detachedHead=false checkout --quiet "$commit"
# The upstream Cargo.lock is behind its manifests; ours is the resolution that was built
# and licence-checked (docs/licenses/libdf-crates.tsv).
cp "$root/scripts/libdf/Cargo.lock" "$src/Cargo.lock"
# No strip: since Rust 1.77 release builds run strip, which leaves a dylib that Apple's linker rejects.
(cd "$src/libDF" && CARGO_TARGET_DIR="$target" MACOSX_DEPLOYMENT_TARGET=27.0 CARGO_PROFILE_RELEASE_STRIP=none \
    cargo build --quiet --release --locked --no-default-features --features capi --lib)
# A dynamic framework: the cdylib exports only the C API, so none of Rust's own
# symbols meet the app's link, and it signs like any embedded framework.
stage="$target/jammer-stage"
fw="$stage/DeepFilter.framework"
rm -rf "$stage" && mkdir -p "$fw/Versions/A/Headers" "$fw/Versions/A/Modules" "$fw/Versions/A/Resources"
cp "$target/release/libdf.dylib" "$fw/Versions/A/DeepFilter"
install_name_tool -id @rpath/DeepFilter.framework/Versions/A/DeepFilter "$fw/Versions/A/DeepFilter"
cat > "$fw/Versions/A/Headers/deep_filter.h" <<'H'
// The C API of DeepFilterNet's libDF (libDF/src/capi.rs), as used by Jammer.
#pragma once
#include <stddef.h>
typedef struct DFState DFState;
/// path: a DeepFilterNet .tar.gz ONNX model (must exist: libDF aborts otherwise).
/// atten_lim: the most it may attenuate, in dB (100 = no limit). log_level may be NULL.
DFState *df_create(const char *path, float atten_lim, const char *log_level);
size_t df_get_frame_length(DFState *st);
void df_set_atten_lim(DFState *st, float lim_db);
void df_set_post_filter_beta(DFState *st, float beta);
/// One frame (df_get_frame_length samples, 48 kHz mono) in, one out. Returns the local SNR.
float df_process_frame(DFState *st, float *input, float *output);
void df_free(DFState *st);
H
cat > "$fw/Versions/A/Modules/module.modulemap" <<'MAP'
framework module DeepFilter {
    header "deep_filter.h"
    export *
}
MAP
cat > "$fw/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DeepFilter</string>
<key>CFBundleIdentifier</key><string>com.brattoo.jammer.DeepFilter</string>
<key>CFBundleName</key><string>DeepFilter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.5.6</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
ln -s A "$fw/Versions/Current"
for f in DeepFilter Headers Modules Resources; do ln -s "Versions/Current/$f" "$fw/$f"; done
rm -rf "$out/DeepFilter.xcframework"
xcodebuild -create-xcframework -framework "$fw" -output "$out/DeepFilter.xcframework" > /dev/null
cp "$src/models/DeepFilterNet3_onnx.tar.gz" "$out/DeepFilterNet3_onnx.tar.gz"
echo "Built $out/DeepFilter.xcframework from DeepFilterNet $commit"
