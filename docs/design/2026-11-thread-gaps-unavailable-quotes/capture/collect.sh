#!/usr/bin/env bash
# Copies one capture run's pictures into the review folder's `images/`, as
# lossless WebP (needs `cwebp`), keeping the names the fixture gave them:
# `<platform>-<surface>-<column>[-<case>]-<look>.webp`.
#
#   capture/collect.sh <folder of pictures>
#
# The folder is the one the fixture printed. Run it once for the Mac run
# and once for the iPhone run, then `node build-manifest.mjs`.
set -euo pipefail
from="$1"
cd "$(dirname "$0")/.."
mkdir -p images
for png in "$from"/*.png; do
  name="$(basename "$png" .png)"
  cwebp -quiet -lossless "$png" -o "images/$name.webp"
done
ls images | wc -l
