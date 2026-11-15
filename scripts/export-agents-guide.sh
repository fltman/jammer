#!/bin/sh
# Rewrites site/agents.md from the same code that serves GET /jammer.
set -eu
cd "$(dirname "$0")/../Packages/JammerKit"
JAMMER_WRITE_GUIDE=1 swift test --filter SiteGuideTests
