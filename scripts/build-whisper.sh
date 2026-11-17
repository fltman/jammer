#!/bin/sh
# Builds whisper.cpp (MIT, with ggml) from a pinned commit into
# Packages/JammerKit/Vendor/whisper.xcframework: macOS arm64, static, Metal shaders
# embedded, Accelerate for BLAS. The xcframework is not committed; run this once.
#   JAMMER_VENDOR_SRC=/some/big/disk scripts/build-whisper.sh
set -eu
# Fetching, compiling or installing third-party code is Anders's to allow, in the session's own window,
# each time it is done (the series' rule). So this script does nothing until it is told he has:
#   JAMMER_FETCH_ALLOWED=yes scripts/build-whisper.sh
[ "${JAMMER_FETCH_ALLOWED:-}" = "yes" ] || { echo "$(basename "$0"): this fetches and builds third-party code, which Anders allows each time. After his yes: JAMMER_FETCH_ALLOWED=yes scripts/$(basename "$0")" >&2; exit 77; }
root="$(cd "$(dirname "$0")/.." && pwd)"
commit=d1be6fde11ac6e0407606b4e42fe72d34add8037   # v1.9.5
src_root="${JAMMER_VENDOR_SRC:-$root/build/vendor-src}"
src="$src_root/whisper.cpp"
build="$src_root/whisper-build"
out="$root/Packages/JammerKit/Vendor"
mkdir -p "$src_root" "$out"
if [ ! -d "$src/.git" ]; then
    git clone --quiet https://github.com/ggml-org/whisper.cpp "$src"
fi
git -C "$src" fetch --quiet --depth 1 origin "$commit" 2>/dev/null || true
git -C "$src" -c advice.detachedHead=false checkout --quiet "$commit"
cmake -S "$src" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 \
    -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS_DEFAULT=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DWHISPER_COREML=OFF > "$build.log"
cmake --build "$build" --config Release >> "$build.log"
# One static library and the public headers.
stage="$build/stage"
rm -rf "$stage" && mkdir -p "$stage/include/whisper"
libtool -static -o "$stage/libwhisper-all.a" $(find "$build" -name '*.a' ! -path "*/stage/*") 2>/dev/null
cp "$src/include/whisper.h" "$src"/ggml/include/*.h "$stage/include/whisper/"
cat > "$stage/include/whisper/module.modulemap" <<'MAP'
module whisper {
    header "whisper.h"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "MetalKit"
    link framework "Foundation"
    export *
}
MAP
rm -rf "$out/whisper.xcframework"
xcodebuild -create-xcframework -library "$stage/libwhisper-all.a" -headers "$stage/include" -output "$out/whisper.xcframework" > /dev/null
echo "Built $out/whisper.xcframework from whisper.cpp $commit"
