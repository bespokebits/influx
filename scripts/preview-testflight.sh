#!/usr/bin/env bash
# Builds Influx Preview (ADR 0042) on this Mac from the checked-out commit and
# uploads it to TestFlight, for internal testers. This is how a change gets
# checked on devices; Influx itself is built by Xcode Cloud, only for a
# public release (scripts/testflight.mjs).
#
#   scripts/preview-testflight.sh           build, upload and wait for both
#                                           platforms
#   scripts/preview-testflight.sh --print   the commands, one per line,
#                                           without running them
#
# It needs Xcode signed in to the team's account, which signs and uploads
# (automatic signing; no key or certificate is read from a file), and the
# App Store Connect key that scripts/testflight.mjs uses, to follow the
# upload. The working tree must be clean, so the build is its commit.
#
# The build number is the UTC minute (YYMMDDHHMM), the same for both
# platforms: unique and rising without asking App Store Connect.
#
# INFLUX_XCODEBUILD, in the environment or in ~/.config/influx/devices.conf,
# names a wrapper to run in place of `xcodebuild`, as in scripts/verify.sh.
# `--print` is for a session that may only start a build as a command of its
# own: it runs each printed line itself, in order. INFLUX_PREVIEW_OUT names
# the folder for the archives (default: a new one under TMPDIR).
set -euo pipefail
cd "$(dirname "$0")/.."

# devices.conf; ~/.config/flux is its older home.
devices_env="${INFLUX_DEVICES_ENV:-}"
if [[ -z "$devices_env" ]]; then
  devices_env="$HOME/.config/influx/devices.conf"
  [[ -f "$devices_env" ]] || devices_env="$HOME/.config/flux/devices.conf"
fi
env_xcodebuild="${INFLUX_XCODEBUILD:-}"
# shellcheck source=/dev/null
[[ -f "$devices_env" ]] && source "$devices_env"
read -r -a xcodebuild_cmd <<<"${env_xcodebuild:-${INFLUX_XCODEBUILD:-xcodebuild}}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "preview-testflight: the working tree has changes; commit them first, so the build is its commit" >&2
  exit 2
fi
commit="$(git rev-parse --short=7 HEAD)"
build="$(date -u +%y%m%d%H%M)"
tmp="${TMPDIR:-/tmp}"
out="${INFLUX_PREVIEW_OUT:-${tmp%/}/influx-preview-$build}"
out="${out%/}"

archive() { # scheme, platform
  printf '%q ' "${xcodebuild_cmd[@]}" -project "$PWD/Influx.xcodeproj" -scheme "$1" \
    -destination "generic/platform=$2" -archivePath "$out/$1.xcarchive" -allowProvisioningUpdates \
    "CURRENT_PROJECT_VERSION=$build" "INFLUX_COMMIT=$commit" archive
  echo
}
# Xcode packages the app with `rsync` from the PATH, and only Apple's takes
# the options it passes: with another first (Homebrew's), the export ends in
# "Copy failed". So the upload runs with the system's tools first, and the
# rest of the PATH after them, where a wrapper named in INFLUX_XCODEBUILD and
# whatever it runs are still found.
upload() { # scheme
  printf '%q ' env "PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH" "${xcodebuild_cmd[@]}" -exportArchive -archivePath "$out/$1.xcarchive" -exportPath "$out/$1" \
    -exportOptionsPlist "$PWD/Configs/PreviewUpload.plist" -allowProvisioningUpdates
  echo
}
commands() {
  # First, so a missing app record or key stops it before anything is built,
  # and so the builds have a group to go to: it changes nothing when the
  # group and its testers are there already.
  printf '%q ' "$PWD/scripts/testflight.mjs" preview-setup; echo
  printf '%q ' xcodegen generate --spec "$PWD/project.yml"; echo
  archive InfluxPreview-iOS iOS
  archive InfluxPreview-macOS macOS
  upload InfluxPreview-iOS
  upload InfluxPreview-macOS
  printf '%q ' "$PWD/scripts/testflight.mjs" preview-wait "$build"; echo
}

case "${1:-}" in
  --print) commands ;;
  "")
    echo "preview-testflight: Influx Preview 0.1.0 ($build) from $commit, archives in $out"
    while IFS= read -r line; do
      echo "+ $line"
      eval "$line"
    done < <(commands)
    ;;
  *) echo "usage: scripts/preview-testflight.sh [--print]" >&2; exit 2 ;;
esac
