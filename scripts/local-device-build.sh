#!/usr/bin/env bash
# Builds Influx Preview (ADR 0042) on this Mac from the checked-out commit,
# signed for development, and puts it on the test devices without TestFlight.
# It is for when TestFlight can't take builds (docs/device-builds.md); when it
# can, scripts/preview-testflight.sh is the way builds reach devices.
#
#   scripts/local-device-build.sh ios [--device <udid>] [--no-install]
#       Build for a paired iPhone and install it over the network. It
#       replaces any Influx Preview from TestFlight (same bundle ID and team,
#       so its data and sign-ins stay). The production app is never touched.
#   scripts/local-device-build.sh mac
#       Build for macOS and zip the app for the test Mac.
#
#   --update-profiles  let Xcode create or renew profiles (needs a working
#                      account in Xcode → Settings → Accounts). Without it the
#                      build uses only the profiles Xcode already has.
#   --no-install       build and check only; leave the iPhone alone
#
# The development profiles for dev.bespokebits.influx.preview carry every
# entitlement Preview uses (iCloud on Production, the keychain groups, App
# Attest, push), so a local build syncs and signs in like a TestFlight one.
# A device must be listed in its platform's profile; the script checks.
#
# ~/.config/influx/devices.conf (local, never committed, no secrets) may set:
#   INFLUX_LOCAL_XCODEBUILD  the command to run in place of `xcodebuild` for
#                            this script (else INFLUX_XCODEBUILD). A wrapper
#                            must keep the build products after it returns.
#   INFLUX_IPHONE            the iPhone's UDID (else the first paired iPhone)
#   INFLUX_TEST_MAC          the test Mac's provisioning UDID, checked against
#                            the Mac profile
#   INFLUX_LOCAL_BUILD_OUT   where the Mac zip goes (default: a folder in TMPDIR)
#
# The build number is the UTC minute (YYMMDDHHMM), as scripts/preview-testflight.sh
# numbers its builds, so the next TestFlight build installs over this one.
#
# Run it in a session on the build machine, not over SSH: signing reads the
# login keychain of the signed-in session.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

platform="${1:-}"; [[ "$platform" == ios || "$platform" == mac ]] || usage
shift
device="" install=1 update_profiles=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="${2:?--device needs a udid}"; shift 2 ;;
    --no-install) install=0; shift ;;
    --update-profiles) update_profiles=1; shift ;;
    *) usage ;;
  esac
done

if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
  echo "local-device-build: run this in a session on the build machine, not over SSH" >&2
  exit 1
fi

# devices.conf; ~/.config/flux is its older home.
devices_env="${INFLUX_DEVICES_ENV:-}"
if [[ -z "$devices_env" ]]; then
  devices_env="$HOME/.config/influx/devices.conf"
  [[ -f "$devices_env" ]] || devices_env="$HOME/.config/flux/devices.conf"
fi
env_xcodebuild="${INFLUX_LOCAL_XCODEBUILD:-${INFLUX_XCODEBUILD:-}}"
# shellcheck source=/dev/null
[[ -f "$devices_env" ]] && source "$devices_env"
read -r -a xcodebuild_cmd <<<"${env_xcodebuild:-${INFLUX_LOCAL_XCODEBUILD:-${INFLUX_XCODEBUILD:-xcodebuild}}}"

bundle_id=dev.bespokebits.influx.preview
container=iCloud.dev.bespokebits.influx
team="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Configs/DevelopmentTeam.xcconfig | head -n1)"
[[ -n "$team" ]] || { echo "local-device-build: no DEVELOPMENT_TEAM in Configs/DevelopmentTeam.xcconfig" >&2; exit 1; }
commit="$(git rev-parse --short=7 HEAD)"
build="$(date -u +%y%m%d%H%M)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "note: the working tree has changes; the build includes them, and its version line names $commit" >&2
fi

xcodegen generate --quiet --spec project.yml

if [[ "$platform" == ios ]]; then
  device="${device:-${INFLUX_IPHONE:-}}"
  if [[ -z "$device" ]]; then
    devices="$(mktemp -t influx-devices)"
    xcrun devicectl list devices --json-output "$devices" >/dev/null 2>&1 || true
    device="$(python3 -I -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hp, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hp.get("deviceType") == "iPhone" and hp.get("reality") == "physical" and cp.get("pairingState") == "paired":
        print(hp["udid"]); break
' "$devices" 2>/dev/null || true)"
    rm -f "$devices"
  fi
  [[ -n "$device" ]] || { echo "local-device-build: no paired iPhone; pass --device <udid> (xcrun devicectl list devices)" >&2; exit 1; }
  scheme=InfluxPreview-iOS destination="id=$device" products="Preview-iphoneos"
else
  scheme=InfluxPreview-macOS destination="platform=macOS" products="Preview"
fi

extra=()
[[ "$update_profiles" == 1 ]] && extra+=(-allowProvisioningUpdates)
log="$(mktemp -t influx-local-build)"
echo "building $scheme ($build) at $commit; log: $log"
if ! "${xcodebuild_cmd[@]}" -project "$PWD/Influx.xcodeproj" -scheme "$scheme" -configuration Preview \
    -destination "$destination" ${extra[@]+"${extra[@]}"} \
    "CURRENT_PROJECT_VERSION=$build" "INFLUX_COMMIT=$commit" build >"$log" 2>&1; then
  grep -E "error:" "$log" | sort -u | head -20 >&2 || true
  echo "local-device-build: the build failed; full log: $log" >&2
  exit 1
fi

# The app's path, from the build's own CodeSign line (it has a space in it).
app="$(grep -oE "/[^ ]*/Build/Products/$products/Influx\\\\ Preview\\.app" "$log" | tail -n1 | sed 's/\\ / /g' || true)"
[[ -d "$app" ]] || { echo "local-device-build: the built app is not named in the log: $log" >&2; exit 1; }

# Check what was built before it goes anywhere.
codesign --verify --deep --strict "$app"
if [[ "$platform" == ios ]]; then info="$app/Info.plist" profile="$app/embedded.mobileprovision"
else info="$app/Contents/Info.plist" profile="$app/Contents/embedded.provisionprofile"; fi
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
fail() { echo "local-device-build: $*" >&2; exit 1; }
[[ "$(plist CFBundleIdentifier "$info")" == "$bundle_id" ]] || fail "the bundle ID is not $bundle_id"
[[ "$(plist CFBundleVersion "$info")" == "$build" ]] || fail "the build number is not $build"
[[ "$(plist InfluxCloudKitContainer "$info")" == "$container" ]] || fail "the app does not sync with $container"
granted="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)"
for want in "$container" "$team.dev.bespokebits.influx" "Production"; do
  [[ "$granted" == *"<string>$want</string>"* ]] || fail "the signature does not grant $want"
done
[[ -f "$profile" ]] || fail "no provisioning profile is embedded"
listed="$(openssl smime -inform der -verify -noverify -in "$profile" 2>/dev/null | python3 -I -c '
import plistlib, sys
p = plistlib.loads(sys.stdin.buffer.read())
print(p["ExpirationDate"].date())
print("\n".join(p.get("ProvisionedDevices", [])))
')"
echo "profile: development, expires $(head -n1 <<<"$listed")"
target="$device"; [[ "$platform" == mac ]] && target="${INFLUX_TEST_MAC:-}"
if [[ -n "$target" ]]; then
  [[ $'\n'"$listed"$'\n' == *$'\n'"$target"$'\n'* ]] || fail "the profile does not list $target, so it won't open there"
fi

if [[ "$platform" == ios ]]; then
  if [[ "$install" == 0 ]]; then echo "built and checked, not installed: $app"; exit 0; fi
  echo "installing on $device"
  xcrun devicectl device install app --device "$device" "$app" >/dev/null
  echo "done: Influx Preview $(plist CFBundleShortVersionString "$info") ($build) from $commit is on the iPhone"
else
  tmp="${TMPDIR:-/tmp}"
  out="${INFLUX_LOCAL_BUILD_OUT:-${tmp%/}/influx-local-build}"
  mkdir -p "$out"
  zip="$out/Influx-Preview-$commit.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  echo "done: $zip"
fi
