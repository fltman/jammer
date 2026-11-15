#!/bin/sh
# Builds DeepFilterNet's libDF (MIT/Apache-2.0, Rust) from a pinned commit into
# Packages/JammerKit/Vendor/DeepFilter.xcframework (static, C API) and copies the
# DeepFilterNet3 model next to it. Not committed; run once. Needs cargo.
#   JAMMER_VENDOR_SRC=/big/disk CARGO_HOME=/big/disk/cargo scripts/build-libdf.sh
set -eu
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
(cd "$src/libDF" && CARGO_TARGET_DIR="$target" MACOSX_DEPLOYMENT_TARGET=27.0 \
    cargo build --quiet --release --locked --no-default-features --features capi --lib)
stage="$target/jammer-stage"
rm -rf "$stage" && mkdir -p "$stage/include/DeepFilter"
cp "$target/release/libdf.a" "$stage/libdf.a"
strip -S "$stage/libdf.a" 2>/dev/null || true
cat > "$stage/include/DeepFilter/deep_filter.h" <<'H'
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
cat > "$stage/include/DeepFilter/module.modulemap" <<'MAP'
module DeepFilter {
    header "deep_filter.h"
    link framework "Security"
    link framework "CoreFoundation"
    export *
}
MAP
rm -rf "$out/DeepFilter.xcframework"
xcodebuild -create-xcframework -library "$stage/libdf.a" -headers "$stage/include" -output "$out/DeepFilter.xcframework" > /dev/null
cp "$src/models/DeepFilterNet3_onnx.tar.gz" "$out/DeepFilterNet3_onnx.tar.gz"
echo "Built $out/DeepFilter.xcframework from DeepFilterNet $commit"
