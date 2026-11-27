#!/bin/sh
# Builds another vendor's Audio Unit with a sidechain input, to TEST Jämmer's sidechain keys against.
# It is not part of Jämmer and never ships:
#   ZL Compressor 0.6.1 (ZL Audio)   AGPL-3.0   https://github.com/ZL-Audio/ZLCompressor
#   and, as that project's own submodules, which its build needs:
#     JUCE (ZL Audio's fork)   AGPL-3.0 (or JUCE's commercial licence)
#     highway 1.4.0            Apache-2.0 or BSD-3-Clause
#     zldsp_fft                Apache-2.0
# Rules (docs/LICENSES.md, "Used in tests only"): nothing of it is read into, copied to or linked with
# Jämmer, its helpers or its tests; it is built by itself, in a folder outside this repository; it is not
# installed in the Mac's plugin folders (the build is told not to copy it there); the test is handed the
# finished Audio Unit by path and loads it as a host loads a plugin:
#   JAMMER_KEYED_AU="<folder>/build/ZLCompressor_artefacts/Release/AU/ZL Compressor.component" \
#     swift test --filter ThirdPartyKeyTests      (in Packages/JammerKit)
# Fetching and compiling it was approved by Anders on 2026-11-16 ("Build it from source").
#   scripts/build-test-sidechain-plugin.sh <folder outside the repository>
set -eu
# Fetching, compiling or installing third-party code is Anders's to allow, in the session's own window,
# each time it is done (the series' rule). So this script does nothing until it is told he has:
#   JAMMER_FETCH_ALLOWED=yes scripts/build-test-sidechain-plugin.sh
[ "${JAMMER_FETCH_ALLOWED:-}" = "yes" ] || { echo "$(basename "$0"): this fetches and builds third-party code, which Anders allows each time. After his yes: JAMMER_FETCH_ALLOWED=yes scripts/$(basename "$0")" >&2; exit 77; }
# Builds only under the series' build lock (re-entrant: under precommit or commit-checked it runs as it is;
# scripts/check-build-lock.py holds every script that builds to this).
apps_tools="$(cd "$(dirname "$0")/../.." && pwd)/the-apps/tools"
case ":${APPS_HELD_LOCKS:-}:" in *":/tmp/the-apps-build.lock:"*) ;; *) [ ! -x "$apps_tools/with-build-lock.sh" ] || exec "$apps_tools/with-build-lock.sh" jammer --wait "${BUILD_WAIT:-3600}" -- "$0" "$@" ;; esac
dir="${1:?give a folder outside the repository, e.g. $JAMMER_TEST_MEDIA/third-party/zlcompressor}"
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$dir"
case "$(cd "$dir" && pwd -P)/" in "$root"/*) echo "Not inside the repository." >&2; exit 64 ;; esac
commit=6d8c79cff62b42b1d5e4cf60c8eda2ca90b7e938
if [ ! -d "$dir/src/.git" ]; then git -c advice.detachedHead=false clone -q --depth 1 --branch 0.6.1 https://github.com/ZL-Audio/ZLCompressor.git "$dir/src"; fi
actual="$(git -C "$dir/src" rev-parse HEAD)"
[ "$actual" = "$commit" ] || { echo "The source is at $actual, expected $commit; not building." >&2; exit 1; }
git -C "$dir/src" submodule update -q --init --depth 1
# Only the Audio Unit, for this Mac, and not copied to ~/Library/Audio/Plug-Ins.
cmake -S "$dir/src" -B "$dir/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DZL_JUCE_FORMATS=AU -DZL_JUCE_COPY_PLUGIN=FALSE \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DZL_HWY_STATIC_TARGET=NEON > "$dir/configure.log" 2>&1
cmake --build "$dir/build" > "$dir/build.log" 2>&1
echo "$dir/build/ZLCompressor_artefacts/Release/AU/ZL Compressor.component"
