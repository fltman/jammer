#!/bin/zsh
# The language switch, on the debug build, without a window: Jämmer speaks Swedish on a Mac whose
# language is Swedish and English on any other, and `-language en|sv` decides instead (test copies).
set -u
app="$(cd "$(dirname "$0")/.." && pwd)/build/dd/Build/Products/Debug/Jammer.app/Contents/MacOS/Jammer"
[[ -x "$app" ]] || { echo "test-language-switch: build the app first"; exit 1; }
say() { env -u OPENROUTER_API_KEY "$app" -ai.noKeychain YES -printLanguage YES "$@" 2>/dev/null | grep '^language ' | head -1; }
[[ -d "$(dirname "$app")/../Resources/sv.lproj" ]] || { echo "test-language-switch: the bundle has no Swedish"; exit 1; }
for case in "(sv):sv" "(sv-SE, en):sv" "(de):en" "(de, sv):sv" "(en):en" "(en, sv):en"; do
  mac=${case%:*}; want=${case##*:}
  got=$(say -AppleLanguages "$mac")
  [[ "$got" == "language $want: "* ]] || { echo "test-language-switch: on a Mac set to $mac the app said \"$got\", not $want"; exit 1; }
done
got=$(say -AppleLanguages "(en)" -language sv)
[[ "$got" == "language sv: "* ]] || { echo "test-language-switch: with -language sv the app said \"$got\", not Swedish"; exit 1; }
got=$(say -AppleLanguages "(sv)" -language en)
[[ "$got" == "language en: "* ]] || { echo "test-language-switch: with -language en on a Swedish Mac the app said \"$got\", not English"; exit 1; }
echo "test-language-switch: Swedish on a Mac set to Swedish (first, or before German), English on English or German; -language en|sv decides over the Mac"
# Numbers follow the Mac's region, in either language (as macOS does).
for lang in en sv; do
  comma=$(say -AppleLanguages "(en)" -AppleLocale sv_SE -language $lang); point=$(say -AppleLanguages "(en)" -AppleLocale en_US -language $lang)
  [[ "$comma" == *"number 0,25" && "$point" == *"number 0.25" ]] || { echo "test-language-switch: numbers don't follow the region ($lang: Swedish region \"$comma\", US region \"$point\")"; exit 1; }
  # Inside a sentence from the packages too (the area's description: 4.20–4.60 s).
  [[ "$comma" == *", 4,20–4,60 s, "* && "$point" == *", 4.20–4.60 s, "* ]] || { echo "test-language-switch: numbers inside a sentence don't follow the region ($lang: \"$comma\" / \"$point\")"; exit 1; }
done
echo "test-language-switch: numbers follow the region in both languages, inside sentences too (0,25 and 4,20–4,60 s in Sweden, 0.25 and 4.20–4.60 s in the US)"
