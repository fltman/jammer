#!/bin/sh
# Rewrites site/agents.md from the same code that serves GET /jammer, and brings the
# manual in step with the features the release build has (Config/Features.xcconfig).
set -eu
"$(dirname "$0")/apply-features.py"
cd "$(dirname "$0")/../Packages/JammerKit"
JAMMER_WRITE_GUIDE=1 swift test --filter SiteGuideTests
