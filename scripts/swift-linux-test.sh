#!/usr/bin/env bash
# Build and test the Swift package on Linux, exactly as CI's swift-linux job
# does. Hosted and self-hosted Linux use the same official image, pinned by
# its multi-architecture digest (amd64, arm64).
# Bumping the image is a dependency change: the new digest must be at least
# 14 days old.
#
# Needs a running Docker daemon. The container reads the checkout read-only and
# builds a copy without any .build directory, so it neither reuses a macOS
# build nor leaves root-owned files behind.
#
#   PACKAGE_DIR   package directory relative to the repo root (default: .)
#   APT_PACKAGES  extra system packages the build needs, e.g. libsqlite3-dev
set -euo pipefail

image="swift:6.4.0-noble@sha256:64bab762bc73a3fda6d9ebc559258bd6d7660c10a705bb25ecacad2f99d066f9"
repo="$(cd "$(dirname "$0")/.." && pwd)"
package_dir="${PACKAGE_DIR:-.}"
apt_packages="${APT_PACKAGES:-}"

docker run --rm -v "$repo:/repo:ro" -e PACKAGE_DIR="$package_dir" -e APT_PACKAGES="$apt_packages" \
  "$image" bash -euo pipefail -c '
  if [ -n "$APT_PACKAGES" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    # shellcheck disable=SC2086 # a space-separated package list
    apt-get -qq install -y --no-install-recommends $APT_PACKAGES >/dev/null
  fi
  mkdir -p /work
  tar -C /repo --exclude="*/.build" --exclude=./.build --exclude=./.git -cf - . | tar -C /work -xf -
  cd "/work/$PACKAGE_DIR"
  swift --version
  swift build --build-tests
  # Keep wall-clock deadline and performance assertions independent of
  # unrelated test load on the hosted runner. Tests retain their own tasks.
  swift test --no-parallel'
