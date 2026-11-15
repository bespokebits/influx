#!/bin/sh
# Xcode Cloud post-clone hook. Must stay executable and live in ci_scripts/
# next to the generated Influx.xcodeproj.
#
# Influx.xcodeproj is gitignored; XcodeGen generates it from project.yml. This
# runs after Xcode Cloud clones the repo and before it opens the project.
set -e

# A direct release download is faster than Homebrew on Xcode Cloud agents;
# the version is pinned for reproducible builds.
XCODEGEN_VERSION="2.44.1"
curl -fsSL \
  --retry 5 \
  --retry-all-errors \
  --retry-delay 5 \
  --connect-timeout 20 \
  --max-time 180 \
  -o /tmp/xcodegen.zip \
  "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
unzip -q /tmp/xcodegen.zip -d /tmp/xcodegen

cd "$CI_PRIMARY_REPOSITORY_PATH"
/tmp/xcodegen/xcodegen/bin/xcodegen generate

# Xcode Cloud disables automatic SwiftPM resolution and needs Package.resolved
# inside the generated workspace, where git cannot carry it. The root
# Package.resolved is a copy of InfluxKit/Package.resolved (swift-pins checks
# that they match); copy it into place once InfluxKit has dependencies.
if [ -f Package.resolved ]; then
  SWIFTPM_DIR="Influx.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
  mkdir -p "$SWIFTPM_DIR"
  cp Package.resolved "$SWIFTPM_DIR/Package.resolved"
fi

echo "ci_post_clone: generated Influx.xcodeproj (xcodegen ${XCODEGEN_VERSION})"
