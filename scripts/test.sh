#!/bin/sh
# Runs the package tests. The engine's realtime guard runs as part of the build
# (-Werror=function-effects), so a passing build is itself a check.
set -eu
cd "$(dirname "$0")/../Packages/JammerKit"
swift build
swift test "$@"
