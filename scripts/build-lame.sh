#!/bin/sh
# Builds LAME 3.100 (LGPL) as a dynamic framework: Packages/JammerKit/Vendor/LAME.xcframework.
# LGPL allows this only as a separately replaceable dynamic library; the source and
# licence are recorded in docs/LICENSES.md. Not committed; run once.
#   JAMMER_VENDOR_SRC=/big/disk scripts/build-lame.sh
set -eu
# Fetching, compiling or installing third-party code is Anders's to allow, in the session's own window,
# each time it is done (the series' rule). So this script does nothing until it is told he has:
#   JAMMER_FETCH_ALLOWED=yes scripts/build-lame.sh
[ "${JAMMER_FETCH_ALLOWED:-}" = "yes" ] || { echo "$(basename "$0"): this fetches and builds third-party code, which Anders allows each time. After his yes: JAMMER_FETCH_ALLOWED=yes scripts/$(basename "$0")" >&2; exit 77; }
# Builds only under the series' build lock (re-entrant: under precommit or commit-checked it runs as it is;
# scripts/check-build-lock.py holds every script that builds to this).
apps_tools="$(cd "$(dirname "$0")/../.." && pwd)/the-apps/tools"
case ":${APPS_HELD_LOCKS:-}:" in *":/tmp/the-apps-build.lock:"*) ;; *) [ ! -x "$apps_tools/with-build-lock.sh" ] || exec "$apps_tools/with-build-lock.sh" jammer --wait "${BUILD_WAIT:-3600}" -- "$0" "$@" ;; esac
root="$(cd "$(dirname "$0")/.." && pwd)"
version=3.100
sha256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
src_root="${JAMMER_VENDOR_SRC:-$root/build/vendor-src}"
out="$root/Packages/JammerKit/Vendor"
mkdir -p "$src_root" "$out"
tarball="$src_root/lame-$version.tar.gz"
if [ ! -f "$tarball" ]; then
    curl -fsSL -o "$tarball" "https://downloads.sourceforge.net/project/lame/lame/$version/lame-$version.tar.gz"
fi
echo "$sha256  $tarball" | shasum -a 256 -c - >/dev/null || { echo "lame-$version.tar.gz doesn't match its SHA-256; not building." >&2; exit 1; }
src="$src_root/lame-$version"
rm -rf "$src" && tar -xzf "$tarball" -C "$src_root"
# 3.100's export list names a function that doesn't exist; the macOS linker refuses it.
sed -i '' '/lame_init_old/d' "$src/include/libmp3lame.sym"
stage="$src_root/lame-stage"
rm -rf "$stage"
(cd "$src" && CFLAGS="-O2 -arch arm64 -mmacosx-version-min=27.0" ./configure --quiet --prefix="$stage" \
    --disable-frontend --disable-static --enable-shared --disable-gtktest > /dev/null && make -s -j8 > /dev/null && make -s install > /dev/null)
fw="$src_root/lame-fw/LAME.framework"
rm -rf "$src_root/lame-fw" && mkdir -p "$fw/Versions/A/Headers" "$fw/Versions/A/Modules" "$fw/Versions/A/Resources"
cp "$stage/lib/libmp3lame.0.dylib" "$fw/Versions/A/LAME"
install_name_tool -id @rpath/LAME.framework/Versions/A/LAME "$fw/Versions/A/LAME"
cp "$stage/include/lame/lame.h" "$fw/Versions/A/Headers/lame.h"
cp "$src/COPYING" "$fw/Versions/A/Resources/COPYING-LGPL"
cat > "$fw/Versions/A/Modules/module.modulemap" <<'MAP'
framework module LAME {
    header "lame.h"
    export *
}
MAP
cat > "$fw/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LAME</string>
<key>CFBundleIdentifier</key><string>com.brattoo.jammer.LAME</string>
<key>CFBundleName</key><string>LAME</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
ln -s A "$fw/Versions/Current"
for f in LAME Headers Modules Resources; do ln -s "Versions/Current/$f" "$fw/$f"; done
rm -rf "$out/LAME.xcframework"
xcodebuild -create-xcframework -framework "$fw" -output "$out/LAME.xcframework" > /dev/null
echo "Built $out/LAME.xcframework from LAME $version"
