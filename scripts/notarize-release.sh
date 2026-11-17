#!/bin/zsh
# Notarises the app that scripts/sign-release.sh signed: uploads it to Apple's notary service, waits for the
# verdict, staples the ticket and checks it. An upload is Anders's to allow, each time, in the session's own
# window (the series' rule); so this does nothing until told he has:
#   JAMMER_UPLOAD_ALLOWED=yes JAMMER_NOTARY_PROFILE=jammer-notary scripts/notarize-release.sh
# The profile is a notarytool keychain profile Anders made himself (xcrun notarytool store-credentials);
# its password never passes through here.
set -eu
cd "$(dirname "$0")/.."
[[ "${JAMMER_UPLOAD_ALLOWED:-}" == "yes" ]] || { echo "notarize-release: this uploads the app to Apple, which Anders allows each time. After his yes: JAMMER_UPLOAD_ALLOWED=yes JAMMER_NOTARY_PROFILE=<profile> scripts/notarize-release.sh" >&2; exit 77; }
profile="${JAMMER_NOTARY_PROFILE:?name the notarytool keychain profile}"
app=build/release-signed/dd/Build/Products/Release/Jammer.app
[[ -d "$app" ]] || { echo "notarize-release: sign it first (scripts/sign-release.sh)" >&2; exit 1; }
codesign --verify --deep --strict "$app" || { echo "notarize-release: the signature doesn't verify; sign it again" >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
zip=build/release-signed/Jammer-$version-notarize.zip
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "notarize-release: uploading $(du -h "$zip" | cut -f1) to Apple's notary service (profile $profile)"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait --output-format plist > build/release-signed/notary.plist
verdict="$(/usr/libexec/PlistBuddy -c 'Print :status' build/release-signed/notary.plist 2>/dev/null || echo unknown)"
sid="$(/usr/libexec/PlistBuddy -c 'Print :id' build/release-signed/notary.plist 2>/dev/null || echo "")"
echo "notarize-release: Apple says: $verdict (submission $sid)"
if [[ "$verdict" != "Accepted" ]]; then
  [[ -n "$sid" ]] && xcrun notarytool log "$sid" --keychain-profile "$profile" build/release-signed/notary-log.json && echo "notarize-release: the log is in build/release-signed/notary-log.json"
  exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app" 2>&1 | tail -2
final=build/release-signed/Jammer-$version.zip
rm -f "$final"
ditto -c -k --keepParent "$app" "$final"
echo "notarize-release: notarised and stapled: $final (not uploaded anywhere else)"
