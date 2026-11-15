#!/bin/zsh
# Dev loop: build, then run with the page served live from web/ — edit CSS/HTML and press ⌥⌘R in the app.
set -euo pipefail
ROOT=${0:A:h:h}
"$ROOT/scripts/build.sh"
RUMI_WEB_ROOT="$ROOT/web" "$ROOT/build/Rumi.app/Contents/MacOS/Rumi" --dev   # --dev: honour RUMI_WEB_ROOT, allow the Web Inspector
