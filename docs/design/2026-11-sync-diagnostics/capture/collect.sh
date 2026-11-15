#!/usr/bin/env bash
# Copies one capture run's pictures into the review folder, named for their
# column, as lossless WebP (needs `cwebp`). The Mac pictures are used as
# the fixture drew them; the iPhone pictures are cut to the top of the
# screen, where the panel is.
#
#   capture/collect.sh <column> <folder of pictures>
#
# <column> is `current` or `A`. A run's mock-up pictures always go to
# column B, whichever column the run was for.
#
# The folder holds what the fixture wrote (`mac-light.png`,
# `ios-light.png`, ...) and, for the iPhone, any screenshots of the
# simulator taken while the fixture held each state, named
# `device-ios-light.png` and so on. A screenshot of the simulator is used
# before the fixture's own picture, which has no status bar.
set -euo pipefail
column="$1"
from="$2"
cd "$(dirname "$0")/.."
mkdir -p images

# How much of the iPhone screen to keep, in pixels from the top.
phone_height=1170

for look in light dark; do
  for state in "" -copied -mockup; do
    case "$state" in
      -mockup) name="B-$look" ;;
      *) name="$column-$look$state" ;;
    esac
    mac="$from/mac-$look$state.png"
    if [ -f "$mac" ]; then
      cwebp -quiet -lossless "$mac" -o "images/mac-$name.webp"
    fi
    phone="$from/device-ios-$look$state.png"
    [ -f "$phone" ] || phone="$from/ios-$look$state.png"
    if [ -f "$phone" ]; then
      width=$(sips -g pixelWidth "$phone" | awk '/pixelWidth/ { print $2 }')
      cwebp -quiet -lossless -crop 0 0 "$width" "$phone_height" "$phone" -o "images/ios-$name.webp"
    fi
  done
done
ls images
