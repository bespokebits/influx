#!/usr/bin/env bash
# Local baseline. On Linux: the repository rules, the pins and InfluxKit in
# the pinned Swift image. On a Mac it also generates the Xcode project and
# runs both app schemes' tests.
#
#   scripts/verify.sh                 every step
#   scripts/verify.sh rules           the repository rules and the pins
#   scripts/verify.sh package         InfluxKit's build and tests
#   scripts/verify.sh apps            both app schemes' tests (Mac only)
#   scripts/verify.sh apps --print    the project generation and the two
#                                     app-test commands, one per line,
#                                     without running them
#
# A build machine that must run Xcode through a wrapper names it once, in the
# environment or in ~/.config/influx/devices.conf (a local file of IDs and
# paths, never committed, no secrets):
#   INFLUX_XCODEBUILD       the command to run in place of `xcodebuild`, with
#                           any arguments of its own, split on spaces
#   INFLUX_SIMULATOR_UDID   the iOS simulator to test on, by UDID; without it
#                           the simulator is chosen by name (INFLUX_SIMULATOR,
#                           default iPhone 18 Pro)
# `apps --print` is for a session that may only start a build as a command
# of its own: it runs each printed line itself, in order, so what it runs is
# still what this script names. The first line generates Influx.xcodeproj,
# which is never committed, so the two after it work from a clean checkout.
# The lines have no quotes when a UDID is set.
set -euo pipefail
cd "$(dirname "$0")/.."

# devices.conf; ~/.config/flux is its older home.
devices_env="${INFLUX_DEVICES_ENV:-${FLUX_DEVICES_ENV:-}}"
if [[ -z "$devices_env" ]]; then
  devices_env="$HOME/.config/influx/devices.conf"
  [[ -f "$devices_env" ]] || devices_env="$HOME/.config/flux/devices.conf"
fi
# The environment wins over the file, for every name this script reads.
env_xcodebuild="${INFLUX_XCODEBUILD:-}"
env_simulator_udid="${INFLUX_SIMULATOR_UDID:-}"
env_simulator="${INFLUX_SIMULATOR:-${FLUX_SIMULATOR:-}}"
# shellcheck source=/dev/null
[[ -f "$devices_env" ]] && source "$devices_env"
read -r -a xcodebuild_cmd <<<"${env_xcodebuild:-${INFLUX_XCODEBUILD:-xcodebuild}}"
simulator_udid="${env_simulator_udid:-${INFLUX_SIMULATOR_UDID:-}}"
simulator_name="${env_simulator:-${INFLUX_SIMULATOR:-${FLUX_SIMULATOR:-iPhone 18 Pro}}}"
if [[ -n "$simulator_udid" ]]; then
  ios_destination="id=$simulator_udid"
else
  ios_destination="platform=iOS Simulator,name=$simulator_name"
fi

# Each scheme tests only its own unit-test target; naming it keeps the
# command the same whether the scheme or this script chooses.
mac_tests=("${xcodebuild_cmd[@]}" -project "$PWD/Influx.xcodeproj" -scheme Influx-macOS
  -destination platform=macOS -only-testing:InfluxTests-macOS test)
ios_tests=("${xcodebuild_cmd[@]}" -project "$PWD/Influx.xcodeproj" -scheme Influx-iOS
  -destination "$ios_destination" -only-testing:InfluxTests-iOS test)

rules() {
  if [ -x scripts/check-template.sh ]; then scripts/check-template.sh; fi
  python3 scripts/test_check_publication.py
  python3 scripts/check-publication.py
  python3 scripts/check-swift-pins.py --offline --package InfluxKit --copy Package.resolved
}

package() {
  if command -v swift >/dev/null 2>&1; then
    (cd InfluxKit && swift build --build-tests && swift test)
  else
    echo "swift not found; running the Linux container build instead"
    PACKAGE_DIR=InfluxKit APT_PACKAGES=libsqlite3-dev scripts/swift-linux-test.sh
  fi
}

apps() {
  if [ "$(uname)" != Darwin ]; then
    echo "the app schemes need a Mac; skipped"
    return 0
  fi
  if [ "${1:-}" = --print ]; then
    # %q quotes only what needs it, so a line can be pasted as it is.
    printf '%q ' xcodegen generate --spec "$PWD/project.yml"; echo
    printf '%q ' "${mac_tests[@]}"; echo
    printf '%q ' "${ios_tests[@]}"; echo
    return 0
  fi
  xcodegen generate
  pretty() { if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else cat; fi; }
  "${mac_tests[@]}" | pretty
  "${ios_tests[@]}" | pretty
}

case "${1:-all}" in
  all) rules; package; apps ;;
  rules) rules ;;
  package) package ;;
  apps) apps "${2:-}" ;;
  *) echo "usage: scripts/verify.sh [rules|package|apps [--print]]" >&2; exit 2 ;;
esac
