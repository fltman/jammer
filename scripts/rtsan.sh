#!/bin/sh
# Runs the engine under RealtimeSanitizer (RTSan): the dynamic counterpart of
# -Werror=function-effects. Needs an upstream LLVM with the macOS runtime
# (Apple's clang has none), e.g. `brew install llvm`. LLVM=/path/to/llvm overrides.
#   scripts/rtsan.sh           build and run the harness; exit 1 on a violation
#   scripts/rtsan.sh --plant   prove the harness catches a planted violation
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
llvm="${LLVM:-}"
if [ -z "$llvm" ]; then
    for p in /opt/homebrew/opt/llvm /opt/homebrew/opt/llvm@23 /opt/homebrew/opt/llvm@20; do
        if ls "$p"/lib/clang/*/lib/darwin/libclang_rt.rtsan_osx_dynamic.dylib >/dev/null 2>&1; then llvm="$p"; break; fi
    done
fi
[ -n "$llvm" ] || { echo "No LLVM with RTSan found. Install one (brew install llvm) or set LLVM=…" >&2; exit 2; }
out="$root/build/rtsan"
mkdir -p "$out"
eng="$root/Packages/JammerKit/Sources/JammerEngine"
plant=""
[ "${1:-}" = "--plant" ] && plant="-DJM_RTSAN_PLANT"
"$llvm/bin/clang++" -std=c++20 -O1 -g -fsanitize=realtime $plant \
    -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -mmacosx-version-min=27.0 \
    -I "$eng/include" -I "$eng" -Wall -Wextra -Wno-unknown-attributes \
    "$eng"/*.cpp "$root/Packages/JammerKit/Tests/rtsan/driver.cpp" \
    -framework AudioToolbox -framework CoreAudio -o "$out/jammer-rtsan"
echo "Built with $("$llvm/bin/clang++" --version | head -1)"
if [ -n "$plant" ]; then
    if "$out/jammer-rtsan" 2>"$out/plant.log"; then echo "The planted violation was not caught." >&2; exit 1; fi
    grep -m1 "RealtimeSanitizer" "$out/plant.log" || { cat "$out/plant.log" >&2; exit 1; }
    echo "RTSan caught the planted violation, as it should."
else
    "$out/jammer-rtsan"
fi
