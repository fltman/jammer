#!/bin/zsh
# A Release build signed with a Developer ID, ready for notarisation: the rehearsal Anders allowed on
# 2026-11-17, and the way the real release is signed. Nothing is uploaded here (notarisation is
# scripts/notarize-release.sh, asked of Anders each time).
#
#   JAMMER_SIGN_ID="Developer ID Application: …" scripts/sign-release.sh
#
# Steps: a Release build (signed by Xcode with the identity, the hardened runtime and a secure timestamp);
# Sparkle's nested programs signed again with the same identity, from the inside out, as Sparkle's
# documentation asks for Developer ID distribution (its XPC services, Autoupdate, Updater.app, then the
# framework); the app signed again over them with its own entitlements; then checked: codesign --verify
# --deep --strict, and what Gatekeeper would say (which is "rejected … Unnotarized" until notarised).
set -eu
cd "$(dirname "$0")/.."
id="${JAMMER_SIGN_ID:?name the Developer ID identity: JAMMER_SIGN_ID=\"Developer ID Application: …\"}"
team="$(print -r -- "$id" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
[[ -n "$team" ]] || { echo "sign-release: the identity's name doesn't end with its team id in brackets" >&2; exit 1; }
out=build/release-signed
log="$out/build.log"
mkdir -p "$out"
echo "sign-release: building Release, signed by $id"
xcodebuild -project Jammer.xcodeproj -scheme Jammer -configuration Release -derivedDataPath "$out/dd" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$id" DEVELOPMENT_TEAM="$team" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" build > "$log" 2>&1 || { tail -20 "$log"; echo "sign-release: the build failed ($log)" >&2; exit 1; }
app="$out/dd/Build/Products/Release/Jammer.app"
fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --sign "$id" --options runtime --timestamp "$@"; }
# Sparkle, from the inside out (its documentation, "Sandboxing and code signing": the Downloader keeps its entitlements).
sign "$fw/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$fw/XPCServices/Downloader.xpc"
sign "$fw/Autoupdate"
sign "$fw/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
# The app over everything, with the entitlements Xcode gave it.
ent="$out/entitlements.plist"
codesign -d --entitlements :- "$app" > "$ent" 2>/dev/null
# get-task-allow lets a debugger attach; Apple refuses to notarise a program that has it (found in the
# rehearsal, 2026-11-17: Xcode had injected it). Never in a release.
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ent" 2>/dev/null || true
sign --entitlements "$ent" "$app"
echo "sign-release: checking"
codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | tail -3
codesign -dvv "$app" 2>&1 | grep -E "^Authority=|^TeamIdentifier=|^Timestamp=|flags=" | head -6
# Every Mach-O in the bundle carries the identity and the hardened runtime.
bad=0
while IFS= read -r f; do
  info="$(codesign -dvv "$f" 2>&1)"
  if ! print -r -- "$info" | grep -q "TeamIdentifier=$team" || ! print -r -- "$info" | grep -q "runtime"; then echo "  not signed for release: ${f#$app/}"; bad=1; fi
done < <(find "$app" -type f -perm -u+x -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)
[[ $bad == 0 ]] && echo "sign-release: every program in the bundle is signed by $team with the hardened runtime"
while IFS= read -r f; do
  if codesign -d --entitlements - --xml "$f" 2>/dev/null | grep -q "get-task-allow"; then echo "  get-task-allow in ${f#$app/}: Apple won't notarise it"; bad=1; fi
done < <(find "$app" -type f -perm -u+x -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)
[[ $bad == 0 ]] && echo "sign-release: no program carries get-task-allow"
echo "sign-release: Gatekeeper says (before notarisation):"
spctl --assess --type execute --verbose=2 "$app" 2>&1 | tail -2
echo "sign-release: $app"
exit $bad
