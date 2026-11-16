#!/bin/zsh
# Proves that the build switches in Config/Features.xcconfig reach a Release build made by Xcode, both
# ways, by looking in the binary, and that what is for debug builds only is not in it.
#
#   scripts/check-release-switches.sh        (three Release builds without signing; about ten minutes)
#
# Why it exists: the package manifest used to read the switch from the config file, and Xcode keeps an
# evaluated manifest until the manifest's text changes, so JAMMER_DEREVERB = NO still shipped the reverb
# code (found 2026-11-16). The switch now stands in Package.swift as text written by apply-features.py.
# Counting is done in a file, never with `grep -q` on a pipe: under pipefail a writer that gets SIGPIPE
# makes "found" read as "not found".
set -u
cd "$(dirname "$0")/.."
F=Config/Features.xcconfig
keep="$(mktemp -d)"; cp "$F" "$keep/Features.xcconfig"
restore() { cp "$keep/Features.xcconfig" "$F"; python3 scripts/apply-features.py; rm -rf "$keep"; }
trap restore EXIT
failed=0
build() { # <label> <expected count of the reverb code: 0 or more>
  xcodebuild -project Jammer.xcodeproj -scheme Jammer -configuration Release -derivedDataPath build/dd-rel CODE_SIGNING_ALLOWED=NO build > "$keep/build.log" 2>&1
  grep -q "BUILD SUCCEEDED" "$keep/build.log" || { echo "$1: the Release build failed (see $keep/build.log)"; failed=1; return; }
  app=build/dd-rel/Build/Products/Release/Jammer.app
  : > "$keep/strings.txt"
  for f in "$app"/Contents/MacOS/*(N.) "$app"/Contents/Frameworks/*.framework/Versions/A/*(N.) "$app"/Contents/Helpers/*(N.); do strings -a "$f" >> "$keep/strings.txt"; done
  n=$(grep -c WPEDereverb "$keep/strings.txt")
  echo "$1: reverb code in the bundle: $n"
  if [[ "$2" == 0 && $n != 0 ]] || [[ "$2" != 0 && $n == 0 ]]; then echo "   WRONG: expected ${2/#0/none}${2/#1/some}"; failed=1; fi
  # Debug-only launch arguments must never be in a release.
  # (As whole strings: "agentFolders" is a field of the API and is meant to be there. That the search
  # finds them at all is shown on the Debug build, where each is counted once or more.)
  for word in openaiEndpoint openaiTestKey linkAnyOpen agentFolder pluginFolder; do
    c=$(grep -c -x "$word" "$keep/strings.txt")
    [[ $c == 0 ]] || { echo "   WRONG: \"$word\" is in the Release bundle ($c)"; failed=1; }
  done
}
set_switch() { sed -i '' "s/^JAMMER_DEREVERB = .*$/JAMMER_DEREVERB = $1/" "$F"; python3 scripts/apply-features.py; }
set_switch YES; build "JAMMER_DEREVERB = YES" 1
set_switch NO;  build "JAMMER_DEREVERB = NO " 0
set_switch YES; build "JAMMER_DEREVERB = YES again" 1
[[ $failed == 0 ]] && echo "The switch reaches the Release build both ways, and no debug-only argument is in it." || echo "FAILED."
exit $failed
