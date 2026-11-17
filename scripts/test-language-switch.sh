#!/bin/zsh
# The one-language switch, on the debug build, without a window: Jämmer starts in English whatever
# language it is told the Mac has, and in Swedish only with `-language sv` (and then only where the
# catalogue has Swedish: until it does, that start is English too, and this says so).
set -u
app="$(cd "$(dirname "$0")/.." && pwd)/build/dd/Build/Products/Debug/Jammer.app/Contents/MacOS/Jammer"
[[ -x "$app" ]] || { echo "test-language-switch: build the app first"; exit 1; }
say() { env -u OPENROUTER_API_KEY "$app" -ai.noKeychain YES -printLanguage YES "$@" 2>/dev/null | grep '^language ' | head -1; }
has_sv=$([[ -d "$(dirname "$app")/../Resources/sv.lproj" ]] && echo yes || echo no)
for mac in "(sv)" "(sv-SE, en)" "(de)" "(en)"; do
  got=$(say -AppleLanguages "$mac")
  [[ "$got" == "language en: "* ]] || { echo "test-language-switch: on a Mac set to $mac the app said \"$got\", not English"; exit 1; }
done
got=$(say -AppleLanguages "(en)" -language sv)
if [[ $has_sv == yes ]]; then
  [[ "$got" == "language sv: "* ]] || { echo "test-language-switch: with -language sv the app said \"$got\", not Swedish"; exit 1; }
  echo "test-language-switch: English on a Mac set to Swedish, German or English; Swedish only with -language sv ($got)"
else
  [[ "$got" == "language en: "* ]] || { echo "test-language-switch: with -language sv and no Swedish in the bundle the app said \"$got\""; exit 1; }
  echo "test-language-switch: English on a Mac set to Swedish, German or English; the bundle has no Swedish yet, so -language sv is English too"
fi
# Numbers follow the Mac's region, in either language (as macOS does).
for lang in en sv; do
  comma=$(say -AppleLanguages "(en)" -AppleLocale sv_SE -language $lang); point=$(say -AppleLanguages "(en)" -AppleLocale en_US -language $lang)
  [[ "$comma" == *"number 0,25" && "$point" == *"number 0.25" ]] || { echo "test-language-switch: numbers don't follow the region ($lang: Swedish region \"$comma\", US region \"$point\")"; exit 1; }
done
echo "test-language-switch: numbers follow the region in both languages (0,25 in Sweden, 0.25 in the US)"
