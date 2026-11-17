#!/bin/zsh
# Opens a practice copy of Rumi beside the installed one: it moves and deletes nothing (every Trash request is answered
# "done"), so the Bin card can be played again and again. It works on its own copy of Rumi's saved map.
set -euo pipefail
ROOT=${0:A:h:h}; DATA="$ROOT/build/practice-data"
[[ -d "$ROOT/build/Rumi.app" ]] || "$ROOT/scripts/build.sh"
[[ -d "$DATA" ]] || cp -R "$HOME/Library/Application Support/com.clinton.rumi" "$DATA"
pkill -f "Rumi --dev practice" 2>/dev/null || true
open -n "$ROOT/build/Rumi.app" --env RUMI_REVIEW=1 --env RUMI_DATA_DIR="$DATA" --args --dev practice
