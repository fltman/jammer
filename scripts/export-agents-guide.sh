#!/bin/sh
# Rewrites site/agents.md from the same code that serves GET /jammer, and brings the
# manual in step with the features the release build has (Config/Features.xcconfig).
set -eu
# Builds only under the series' build lock (re-entrant: under precommit or commit-checked it runs as it is;
# scripts/check-build-lock.py holds every script that builds to this).
apps_tools="$(cd "$(dirname "$0")/../.." && pwd)/the-apps/tools"
case ":${APPS_HELD_LOCKS:-}:" in *":/tmp/the-apps-build.lock:"*) ;; *) [ ! -x "$apps_tools/with-build-lock.sh" ] || exec "$apps_tools/with-build-lock.sh" jammer --wait "${BUILD_WAIT:-3600}" -- "$0" "$@" ;; esac
"$(dirname "$0")/apply-features.py"
cd "$(dirname "$0")/../Packages/JammerKit"
JAMMER_WRITE_GUIDE=1 swift test --filter SiteGuideTests
